-- Exercise checkout and RLS with isolated fixtures; no orders or settings persist.
begin;
do $$
declare
  manager uuid := gen_random_uuid();
  outsider uuid := gen_random_uuid();
  shop uuid;
  product uuid;
  variant uuid;
  cart jsonb;
  placed public.orders;
begin
  insert into auth.users(id) values (manager), (outsider);
  insert into public.stores(slug, name, contact_email, contact_phone, contact_city) values ('verify-payment-' || manager, 'Payment verification', 'test@example.invalid', '000', 'Test') returning id into shop;
  insert into public.store_members(store_id, user_id, role) values (shop, manager, 'OWNER');
  insert into public.products(store_id, name) values (shop, 'Fixture') returning id into product;
  insert into public.product_variants(product_id, name, price, stock_quantity) values (product, 'M', 10000, 3) returning id into variant;
  cart := jsonb_build_array(jsonb_build_object('variantId', variant, 'quantity', 1));

  perform set_config('request.jwt.claim.sub', manager::text, true);
  execute 'set local role authenticated';
  insert into public.store_payment_methods(store_id, cash_on_delivery, monobank) values (shop, false, false);
  begin
    perform public.create_store_order(shop, cart, 'Test', 'test@example.invalid', '000', 'City', 'Address');
    raise exception 'Disabled cash on delivery accepted';
  exception when sqlstate 'PT409' then null;
  end;
  begin
    perform public.create_order_with_payment('LIQPAY', manager, shop, cart, 'Test', 'test@example.invalid', '000', 'City', 'Address');
    raise exception 'Online RPC exposed to customers';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claim.sub', outsider::text, true);
  update public.store_payment_methods set cash_on_delivery = true where store_id = shop;
  if found then raise exception 'Nonmember updated payment settings'; end if;
  execute 'reset role';
  execute 'set local role anon';
  if not exists (select 1 from public.store_payment_methods where store_id = shop and liqpay and not cash_on_delivery) then
    raise exception 'Checkout cannot read payment settings';
  end if;
  execute 'reset role';

  execute 'set local role service_role';
  begin
    perform public.create_order_with_payment('MONOBANK', manager, shop, cart, 'Test', 'test@example.invalid', '000', 'City', 'Address');
    raise exception 'Disabled monobank accepted';
  exception when sqlstate 'PT409' then null;
  end;
  placed := public.create_order_with_payment('LIQPAY', manager, shop, cart, 'Test', 'test@example.invalid', '000', 'City', 'Address');
  if placed.payment_method is distinct from 'ONLINE' or placed.user_id is distinct from manager then
    raise exception 'Online order lost its method or customer';
  end if;
  execute 'reset role';
  if (select stock_quantity from public.product_variants where id = variant) <> 2 then raise exception 'Incorrect stock after payment attempts'; end if;

  perform set_config('request.jwt.claim.sub', manager::text, true);
  execute 'set local role authenticated';
  update public.store_payment_methods set cash_on_delivery = true, liqpay = false where store_id = shop;
  placed := public.create_store_order(shop, cart, 'Test', 'test@example.invalid', '000', 'City', 'Address');
  if placed.payment_method is distinct from 'CASH_ON_DELIVERY' then raise exception 'Re-enabled cash on delivery failed'; end if;
  execute 'reset role';
  execute 'set local role service_role';
  begin
    perform public.create_order_with_payment('LIQPAY', null, shop, cart, 'Test', 'test@example.invalid', '000', 'City', 'Address');
    raise exception 'Disabled LiqPay accepted';
  exception when sqlstate 'PT409' then null;
  end;
  execute 'reset role';
end;
$$;
select 'Payment settings and checkout checks passed' as result;
rollback;
