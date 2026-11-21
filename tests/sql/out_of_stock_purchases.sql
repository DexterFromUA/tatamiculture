-- Verify the zero-stock exception and its inventory effects without persisting fixtures.
begin;
-- The production singleton is restored when the fixtures roll back.
drop index public.shop_settings_single_row_idx;

do $$
declare
  manager uuid := gen_random_uuid();
  shop uuid := gen_random_uuid();
  product uuid := gen_random_uuid();
  variant uuid := gen_random_uuid();
  preorder_variant uuid := gen_random_uuid();
  cart jsonb := jsonb_build_array(jsonb_build_object('variantId', variant, 'quantity', 2));
  preorder_cart jsonb := jsonb_build_array(jsonb_build_object('variantId', preorder_variant, 'quantity', 2));
  buyer jsonb := '{"name":"Inventory test","phone":"+380990008888"}';
  delivery jsonb := '{"city":"Test city","address":"Test branch"}';
  placed public.orders;
  attempt public.online_checkouts;
  duplicate uuid;
  result jsonb;
begin
  insert into auth.users(id) values (manager);
  insert into public.shop_settings (id, name) values (shop, 'Stock test');
  insert into public.store_members(store_id, user_id, role) values (shop, manager, 'OWNER');
  insert into public.store_payment_methods(store_id, cash_on_delivery, liqpay, payment_test_mode)
    values (shop, true, true, false);
  insert into public.products(id, store_id, name) values (product, shop, 'Test product');
  insert into public.product_variants(id, product_id, name, price, stock_quantity)
    values (variant, product, 'M', 10000, 0);
  insert into public.product_variants(id, product_id, name, price, stock_quantity, is_preorder)
    values (preorder_variant, product, 'L', 10000, 0, true);

  begin
    perform public.quote_catalog_cart(shop, cart, null, true);
    raise exception 'Zero stock was accepted by default';
  exception when sqlstate 'PT409' then null;
  end;

  update public.product_variants set allow_out_of_stock = true where id = variant;
  begin
    perform public.quote_catalog_cart(shop, preorder_cart, null, true);
    raise exception 'The exception leaked to another variant';
  exception when sqlstate 'PT409' then null;
  end;
  update public.product_variants set stock_quantity = 1 where id = variant;
  begin
    perform public.quote_catalog_cart(shop, cart, null, true);
    raise exception 'Positive stock below the requested quantity was accepted';
  exception when sqlstate 'PT409' then null;
  end;
  update public.product_variants set stock_quantity = 0 where id = variant;

  perform set_config('request.jwt.claim.sub', '', true);
  placed := public.create_discounted_store_order(shop, cart, buyer->>'name', '', buyer->>'phone',
    delivery->>'city', delivery->>'address', p_expected_total => 20000);
  if placed.user_id is not null or placed.total_price <> 20000 or not exists (
    select from public.order_items where order_id = placed.id and quantity = 2 and not stock_deducted and not is_preorder
  ) then
    raise exception 'Guest checkout did not create a regular order without stock deduction';
  end if;

  perform set_config('request.jwt.claim.sub', manager::text, true);
  placed := public.restore_stock_and_cancel_order(placed.id);
  if placed.status <> 'CANCELLED_BY_STORE' or placed.payment_status <> 'PENDING'
     or (select stock_quantity from public.product_variants where id = variant) <> 0 then
    raise exception 'COD cancellation changed the payment status or created stock';
  end if;

  update public.product_variants set allow_out_of_stock = true where id = preorder_variant;
  placed := public.create_crm_order(shop, gen_random_uuid(), cart || preorder_cart, buyer, delivery, '', 40000);
  if (select count(*) from public.order_items
      where order_id = placed.id and quantity = 2 and not stock_deducted
        and is_preorder = (variant_id = preorder_variant)) <> 2
     or exists (select from public.product_variants where id in (variant, preorder_variant) and stock_quantity <> 0) then
    raise exception 'Manual order did not preserve both variant types and their stock';
  end if;

  duplicate := public.duplicate_catalog_product(product);
  if (select count(*) from public.product_variants where product_id = duplicate and allow_out_of_stock) <> 2 then
    raise exception 'Product duplication lost a variant zero-stock setting';
  end if;

  attempt := public.prepare_online_checkout('LIQPAY', null, shop, cart || preorder_cart, buyer || delivery, false);
  if exists (select from public.orders where id = attempt.id) then
    raise exception 'Online checkout created an unpaid order';
  end if;
  update public.product_variants set allow_out_of_stock = false where id in (variant, preorder_variant);
  perform public.confirm_online_checkout('LIQPAY', attempt.provider_order_id, 40000, 'UAH', 'test', '{}');
  if (select count(*) from public.order_items i join public.orders o on o.id = i.order_id
      where o.id = attempt.id and o.payment_status = 'PAID' and not i.stock_deducted
        and i.is_preorder = (i.variant_id = preorder_variant)) <> 2
     or exists (select from public.product_variants where id in (variant, preorder_variant) and stock_quantity <> 0) then
    raise exception 'Payment confirmation did not preserve the quote and stock balance';
  end if;

  perform public.update_admin_orders(array[attempt.id], 'WAITING_FOR_STOCK', true);
  perform public.update_admin_orders(array[attempt.id], 'IN_PROGRESS', true);
  result := public.update_admin_orders_with_stock_notice(array[attempt.id], 'CANCELLED_BY_STORE', true, false);
  if result->>'stock_added' <> '4' or (select count(*) from public.product_variants
    where id in (variant, preorder_variant) and stock_quantity = 2) <> 2 then
    raise exception 'Cancelling a progressed procurement did not credit exactly four units';
  end if;
  result := public.update_admin_orders_with_stock_notice(array[attempt.id], 'CANCELLED_BY_STORE', true, false);
  if result->>'stock_added' <> '0' then raise exception 'A repeated cancellation duplicated stock'; end if;
  perform public.correct_admin_order_status(array[attempt.id], 'PREPARING_SHIPMENT', true, false, 'stock', null);
  result := public.update_admin_orders_with_stock_notice(array[attempt.id], 'CANCELLED_BY_STORE', true, false);
  if result->>'stock_added' <> '0' or exists (select from public.product_variants
    where id in (variant,preorder_variant) and stock_quantity <> 2) then raise exception 'Reopening an order duplicated stock'; end if;

  perform public.correct_admin_order_status(array[attempt.id], 'IN_PROGRESS', true, false, 'supplier', null);
  result := public.update_admin_orders_with_stock_notice(array[attempt.id], 'CANCELLED_BY_STORE', true, false);
  if result->>'stock_added' <> '0' then raise exception 'Old procurement stages credited a new unstarted purchase'; end if;

  -- A direct cancellation of a fresh paid order must leave empty stock untouched.
  update public.product_variants set stock_quantity = 0, allow_out_of_stock = true where id = variant;
  attempt := public.prepare_online_checkout('LIQPAY', null, shop, cart, buyer || delivery, false);
  perform public.confirm_online_checkout('LIQPAY', attempt.provider_order_id, 20000, 'UAH', 'test2', '{}');
  result := public.update_admin_orders_with_stock_notice(array[attempt.id], 'CANCELLED_BY_STORE', true, false);
  if result->>'stock_added' <> '0' or (select stock_quantity from public.product_variants where id = variant) <> 0 then
    raise exception 'An immediate cancellation added stock';
  end if;
end;
$$;

rollback;
select 'Zero-stock purchases verified' as result;
