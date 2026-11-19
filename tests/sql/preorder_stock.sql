-- Check both current and historical inventory snapshots. Roll back all fixtures.
begin;
-- The production singleton is restored when the fixtures roll back.
drop index public.shop_settings_single_row_idx;
do $$
declare
  manager uuid := gen_random_uuid();
  shop uuid;
  product uuid;
  variant uuid;
  cod public.orders;
  payment public.online_checkouts;
  cart jsonb;
  details jsonb := '{"name":"Test","phone":"+380990002222","city":"Test","address":"Test","email":""}';
begin
  insert into auth.users(id, raw_user_meta_data) values (manager, '{"name":"Inventory test"}');
  insert into public.shop_settings (name, currency)
    values ('Pre-order inventory test', 'UAH') returning id into shop;
  insert into public.store_members(store_id, user_id, role) values (shop, manager, 'OWNER');
  perform set_config('request.jwt.claim.sub', manager::text, true);
  insert into public.products(store_id, name) values (shop, 'Limited pre-order') returning id into product;
  insert into public.product_variants(product_id, name, price, stock_quantity, low_stock_threshold, is_preorder)
    values (product, 'M', 10000, 2, 2, true) returning id into variant;
  cart := jsonb_build_array(jsonb_build_object('variantId', variant, 'quantity', 2));

  cod := public.create_store_order(shop, cart, 'Test', '', '+380990002222', 'Test', 'Test');
  if (select stock_quantity from public.product_variants where id = variant) <> 0
    or not exists (select 1 from public.order_items where order_id = cod.id and is_preorder and stock_deducted) then
    raise exception 'COD did not deduct the pre-order inventory';
  end if;
  begin
    perform public.create_store_order(shop, cart, 'Test', '', '+380990002222', 'Test', 'Test');
    raise exception 'COD accepted a sold-out pre-order';
  exception when sqlstate 'PT409' then null;
  end;
  begin
    perform public.prepare_online_checkout('LIQPAY', manager, shop, cart, details, false);
    raise exception 'Online checkout accepted a sold-out pre-order';
  exception when sqlstate 'PT409' then null;
  end;

  perform public.cancel_unpaid_order(cod.id);
  if (select stock_quantity from public.product_variants where id = variant) <> 2 then
    raise exception 'Cancellation did not restore the deducted inventory';
  end if;

  -- Simulate an order made when pre-orders still used unlimited stock.
  cod := public.create_store_order(shop, cart, 'Test', '', '+380990002222', 'Test', 'Test');
  update public.order_items set stock_deducted = null where order_id = cod.id;
  update public.product_variants set stock_quantity = 2 where id = variant;
  perform public.cancel_unpaid_order(cod.id);
  if (select stock_quantity from public.product_variants where id = variant) <> 2 then
    raise exception 'Cancellation restored inventory that was never deducted';
  end if;

  payment := public.prepare_online_checkout('LIQPAY', manager, shop, cart, details, false);
  if (select stock_quantity from public.product_variants where id = variant) <> 2
    or exists (select 1 from public.orders where id = payment.id) then
    raise exception 'The unpaid invoice deducted inventory or created an order';
  end if;
  perform public.confirm_online_checkout('LIQPAY', payment.provider_order_id, payment.total_price, payment.currency, 'test', '{}');
  perform public.confirm_online_checkout('LIQPAY', payment.provider_order_id, payment.total_price, payment.currency, 'test', '{}');
  if (select stock_quantity from public.product_variants where id = variant) <> 0
    or not exists (select 1 from public.order_items where order_id = payment.id and is_preorder and stock_deducted) then
    raise exception 'Online payment did not deduct pre-order inventory exactly once';
  end if;

  perform public.subscribe_restock(variant, true);
  perform public.adjust_catalog_stock(variant, 'receipt', 1, 'Test restock');
  if not exists (select 1 from public.restock_subscriptions where variant_id = variant and user_id = manager and notified_at is not null) then
    raise exception 'Restocking the pre-order did not notify the subscriber';
  end if;
end;
$$;
rollback;
