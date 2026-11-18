begin;
do $$
declare
  buyer uuid := gen_random_uuid();
  shop uuid;
  discount uuid;
  product uuid;
  legacy_product uuid;
  inherited uuid;
  overridden uuid;
  exempt uuid;
  legacy uuid;
  mixed_cart jsonb;
  sale_only jsonb;
  order_row public.orders;
  invoice public.online_checkouts;
  details jsonb := '{"name":"Test","phone":"+380990002222","city":"Test","address":"Test","expectedDiscountPercent":15}';
begin
  insert into auth.users(id, raw_user_meta_data) values (buyer, '{"name":"Pricing test"}');
  insert into public.stores(slug, name, contact_email, contact_phone, contact_city, currency)
    values ('catalog-pricing-' || buyer, 'Pricing test', '', '', 'Test', 'UAH') returning id into shop;
  insert into public.store_customers(store_id, user_id) values (shop, buyer);
  insert into public.customer_discounts(store_id, user_id, percent, mode, order_limit)
    values (shop, buyer, 15, 'orders', 10) returning id into discount;
  perform set_config('request.jwt.claim.sub', buyer::text, true);
  insert into public.products(store_id, name, discount_percent) values (shop, 'New sale', 10) returning id into product;
  insert into public.products(store_id, name) values (shop, 'Legacy sale') returning id into legacy_product;
  insert into public.product_variants(product_id, name, price, stock_quantity)
    values (product, 'M', 10000, 8) returning id into inherited;
  insert into public.product_variants(product_id, name, price, stock_quantity, discount_percent)
    values (product, 'L', 10000, 8, 20) returning id into overridden;
  insert into public.product_variants(product_id, name, price, stock_quantity, discount_percent)
    values (product, 'XL', 10000, 8, 0) returning id into exempt;
  insert into public.product_variants(product_id, name, price, stock_quantity, compare_at_price)
    values (legacy_product, 'M', 9000, 8, 10000) returning id into legacy;

  sale_only := jsonb_build_array(jsonb_build_object('variantId', inherited, 'quantity', 1));
  order_row := public.create_discounted_store_order(shop, sale_only, 'Test', '', '+380990002222', 'Test', 'Test',
    p_expected_discount_percent => 15, p_expected_total => 9000);
  if order_row.total_price <> 9000 or order_row.customer_discount_id is not null
    or public.customer_discount_usage(discount) <> 0 then
    raise exception 'Stacking was enabled by default or used a personal-discount allowance';
  end if;

  update public.products set stack_customer_discount = true where id = product;
  select jsonb_agg(jsonb_build_object('variantId', variant_id, 'quantity', 1)) into mixed_cart
  from unnest(array[inherited, overridden, exempt, legacy]) as variant_id;
  begin
    perform public.create_discounted_store_order(shop, mixed_cart, 'Test', '', '+380990002222', 'Test', 'Test',
      p_expected_total => 1);
    raise exception 'COD accepted an outdated total';
  exception when sqlstate 'PT409' then null;
  end;
  begin
    perform public.prepare_online_checkout('LIQPAY', buyer, shop, mixed_cart, details || '{"expectedTotal":1}', false);
    raise exception 'Online checkout accepted an outdated total';
  exception when sqlstate 'PT409' then null;
  end;

  order_row := public.create_discounted_store_order(shop, mixed_cart, 'Test', '', '+380990002222', 'Test', 'Test',
    p_expected_discount_percent => 15, p_expected_total => 33150);
  if order_row.total_price <> 33150 or order_row.customer_discount_amount <> 2850 or exists (
    select 1 from public.order_items i where i.order_id = order_row.id and (
      (i.variant_id = inherited and i.unit_price <> 7650) or
      (i.variant_id = overridden and i.unit_price <> 8000) or
      (i.variant_id = exempt and i.unit_price <> 8500) or
      (i.variant_id = legacy and i.unit_price <> 9000) or i.compare_at_price is distinct from 10000
    )
  ) then raise exception 'Incorrect COD line prices or personal savings'; end if;

  invoice := public.prepare_online_checkout('LIQPAY', buyer, shop, mixed_cart, details || '{"expectedTotal":33150}', false);
  if invoice.total_price <> 33150 or invoice.customer_discount_amount <> 2850 then
    raise exception 'Online checkout differs from COD';
  end if;
  update public.products set discount_percent = 30 where id = product;
  perform public.confirm_online_checkout('LIQPAY', invoice.provider_order_id, 33150, 'UAH', 'test', '{}');
  if not exists (select 1 from public.orders where id = invoice.id and total_price = 33150 and customer_discount_amount = 2850) then
    raise exception 'The order lost its invoice price snapshot';
  end if;

  update public.product_variants set discount_percent = 100 where id = inherited;
  order_row := public.create_discounted_store_order(shop, sale_only, 'Test', '', '+380990002222', 'Test', 'Test', p_expected_total => 0);
  if order_row.total_price <> 0 or order_row.payment_status <> 'PAID' or order_row.customer_discount_id is not null then
    raise exception 'A free catalogue order required payment or used the personal discount';
  end if;
end;
$$;
rollback;
