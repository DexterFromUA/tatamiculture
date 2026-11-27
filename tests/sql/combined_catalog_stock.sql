-- Verify the same availability rules in the storefront, online checkout and CRM.
begin;
drop index public.shop_settings_single_row_idx;

do $test$
declare
  manager uuid := gen_random_uuid();
  shop uuid := gen_random_uuid();
  product uuid := gen_random_uuid();
  variant uuid := gen_random_uuid();
  cart jsonb := jsonb_build_array(jsonb_build_object('variantId', variant, 'quantity', 12));
  buyer jsonb := '{"name":"Stock fixture","phone":"+380990008888"}';
  delivery jsonb := '{"city":"Test city","address":"Test branch"}';
  placed public.orders;
  attempt public.online_checkouts;
  item public.order_items;
  split jsonb;
  split_order uuid;
  cancellation jsonb;
begin
  insert into auth.users(id) values (manager);
  insert into public.shop_settings (id, name) values (shop, 'Combined stock test');
  insert into public.store_members(store_id, user_id, role) values (shop, manager, 'OWNER');
  insert into public.store_payment_methods(store_id, cash_on_delivery, liqpay, payment_test_mode)
    values (shop, true, true, false);
  insert into public.products(id, store_id, name, is_active) values (product, shop, 'Supply test', true);
  insert into public.product_variants(id, product_id, name, price, stock_quantity)
    values (variant, product, 'M', 100, 10);
  insert into public.variant_supplier_stock(variant_id, quantity) values (variant, 25);

  if not has_function_privilege('anon', 'public.catalog_stock_quantity(public.product_variants)', 'execute')
    or has_table_privilege('anon', 'public.variant_supplier_stock', 'select') then
    raise exception 'Storefront access grants are incorrect';
  end if;
  execute 'set local role anon';
  if public.storefront_product_payload(product) #>> '{product_variants,0,catalog_stock_quantity}' is distinct from '35' then
    raise exception 'Public product payload did not add the balances';
  end if;
  execute 'reset role';

  placed := public.create_discounted_store_order(shop, cart, buyer->>'name', '', buyer->>'phone',
    delivery->>'city', delivery->>'address', p_expected_total => 1200);
  select * into strict item from public.order_items where order_id = placed.id;
  if not item.stock_deducted or item.supplier_stock_deducted <> 2
    or (select stock_quantity from public.product_variants where id = variant) is distinct from 0
    or (select quantity from public.variant_supplier_stock where variant_id = variant) is distinct from 23 then
    raise exception 'COD did not draw from local stock first';
  end if;

  perform set_config('request.jwt.claim.sub', manager::text, true);
  if public.crm_catalog_page(shop, 1, 20, '', 'out-of-stock')->>'total' is distinct from '0' then
    raise exception 'CRM classified a supplier-backed variant as out of stock';
  end if;
  split := public.split_order_items(placed.id, jsonb_build_array(jsonb_build_object(
    'item_id', item.id, 'quantity', 1, 'expected_quantity', 12, 'expected_line_total', 1200
  )));
  select order_id into strict split_order from public.order_items
  where variant_id = variant and order_id <> placed.id;
  if (select supplier_stock_deducted from public.order_items where order_id = split_order) is distinct from 1 then
    raise exception 'Splitting an order lost the supplier allocation: %', split;
  end if;
  perform public.restore_stock_and_cancel_order(split_order);
  perform public.restore_stock_and_cancel_order(placed.id);
  if (select stock_quantity from public.product_variants where id = variant) is distinct from 10
    or (select quantity from public.variant_supplier_stock where variant_id = variant) is distinct from 25 then
    raise exception 'Cancelling before procurement did not restore each balance';
  end if;

  attempt := public.prepare_online_checkout('LIQPAY', null, shop, cart, buyer || delivery, false);
  perform public.confirm_online_checkout('LIQPAY', attempt.provider_order_id, 1200, 'UAH', 'fixture', '{}');
  perform public.confirm_online_checkout('LIQPAY', attempt.provider_order_id, 1200, 'UAH', 'fixture', '{}');
  if (select supplier_stock_deducted from public.order_items where order_id = attempt.id) is distinct from 2
    or (select quantity from public.variant_supplier_stock where variant_id = variant) is distinct from 23 then
    raise exception 'Online confirmation did not allocate both balances exactly once';
  end if;
  perform public.update_admin_orders(array[attempt.id], 'WAITING_FOR_STOCK', true);
  cancellation := public.update_admin_orders_with_stock_notice(array[attempt.id], 'CANCELLED_BY_STORE', true, false);
  if cancellation->>'stock_added' is distinct from '2'
    or (select stock_quantity from public.product_variants where id = variant) is distinct from 12
    or (select quantity from public.variant_supplier_stock where variant_id = variant) is distinct from 23 then
    raise exception 'Cancelling after procurement did not restock the physical goods';
  end if;

  update public.product_variants set stock_quantity = 0 where id = variant;
  update public.variant_supplier_stock set quantity = 0, revision = gen_random_uuid() where variant_id = variant;
  begin
    perform public.quote_catalog_cart(shop, cart, null, true);
    raise exception 'Both balances were zero but checkout allowed the purchase';
  exception when sqlstate 'PT409' then null;
  end;
  update public.product_variants set allow_out_of_stock = true where id = variant;
  placed := public.create_crm_order(shop, gen_random_uuid(), cart, buyer, delivery, '', 1200);
  if not exists (select from public.order_items where order_id = placed.id and not stock_deducted)
    or (select stock_quantity from public.product_variants where id = variant) is distinct from 0
    or (select quantity from public.variant_supplier_stock where variant_id = variant) is distinct from 0 then
    raise exception 'The zero-stock exception modified a balance';
  end if;

  update public.variant_supplier_stock set quantity = 12 where variant_id = variant;
  placed := public.create_crm_order(shop, gen_random_uuid(), cart, buyer, delivery, '', 1200);
  update public.variant_supplier_stock set quantity = 7, revision = gen_random_uuid() where variant_id = variant;
  perform public.restore_stock_and_cancel_order(placed.id);
  if (select quantity from public.variant_supplier_stock where variant_id = variant) is distinct from 7 then
    raise exception 'Cancelling an old allocation changed a new supplier count';
  end if;
end;
$test$;

rollback;
select 'Combined stock verified' as result;
