-- Exercise the order and inventory writes in a subtransaction that always rolls back.
do $$
declare
  manager uuid := gen_random_uuid();
  outsider uuid := gen_random_uuid();
  shop uuid := gen_random_uuid();
  product uuid := gen_random_uuid();
  variant uuid := gen_random_uuid();
  request_id uuid := gen_random_uuid();
  buyer jsonb := '{"name":"CRM test customer","phone":"+380990002222"}';
  delivery jsonb := '{"city":"Test","address":"Test branch","cityRef":"test-city","addressRef":"test-branch","serviceType":"WarehouseWarehouse"}';
  items jsonb;
  placed public.orders;
  retried public.orders;
begin
  if has_function_privilege('anon', 'public.create_crm_order(uuid,uuid,jsonb,jsonb,jsonb,text,integer)', 'execute')
    or not has_function_privilege('authenticated', 'public.create_crm_order(uuid,uuid,jsonb,jsonb,jsonb,text,integer)', 'execute') then
    raise exception 'Unexpected CRM order permissions';
  end if;

  begin
    drop index public.shop_settings_single_row_idx; -- Allow isolated fixtures until rollback.
    insert into auth.users(id) values (manager), (outsider);
    insert into public.shop_settings (id, name) values (shop, 'CRM order test');
    insert into public.store_members(store_id, user_id, role) values (shop, manager, 'OWNER');
    insert into public.store_payment_methods(store_id, cash_on_delivery) values (shop, false);
    insert into public.products(id, store_id, name, discount_percent) values (product, shop, 'Test product', 10);
    insert into public.product_variants(id, product_id, name, price, stock_quantity, discount_percent)
      values (variant, product, 'M', 10000, 2, 15);
    insert into public.product_costs(product_id, cost_amount) values (product, 2000);
    items := jsonb_build_array(jsonb_build_object('variantId', variant, 'quantity', 2));

    perform set_config('request.jwt.claim.sub', outsider::text, true);
    begin
      perform public.create_crm_order(shop, request_id, items, buyer, delivery, '', 17000);
      raise exception 'Nonmember unexpectedly created an order';
    exception when insufficient_privilege then null;
    end;

    perform set_config('request.jwt.claim.sub', manager::text, true);
    begin
      perform public.create_crm_order(shop, request_id, items, buyer, delivery, '', 18000);
      raise exception 'Unexpectedly accepted a stale price';
    exception when sqlstate 'PT409' then null;
    end;

    placed := public.create_crm_order(shop, request_id, items, buyer, delivery, 'Manual test', 17000);
    retried := public.create_crm_order(shop, request_id, items, buyer, delivery, 'Manual test', 17000);
    if placed.id is distinct from request_id or retried.id is distinct from placed.id
      or placed.total_price <> 17000 or placed.user_id is not null or placed.crm_customer_id is null
      or placed.payment_method <> 'CASH_ON_DELIVERY' or placed.payment_status <> 'PENDING'
      or placed.delivery_address_ref is distinct from 'test-branch'
      or (select stock_quantity from public.product_variants where id = variant) <> 0
      or (select count(*) from public.order_items where order_id = placed.id) <> 1
      or not exists (
        select from public.order_items i join public.order_item_costs c on c.item_id = i.id
        where i.order_id = placed.id and i.unit_price = 8500 and i.quantity = 2
          and i.stock_deducted and c.unit_cost = 2000
      )
      or not exists (
        select from public.order_events where order_id = placed.id and kind = 'status'
          and new_value = placed.status::text and author_id = manager
      ) then
      raise exception 'Unexpected manual order, stock balance, or order history';
    end if;

    begin
      perform public.create_crm_order(shop, gen_random_uuid(), items, buyer, delivery, '', 17000);
      raise exception 'Unexpectedly created an order without stock';
    exception when sqlstate 'PT409' then null;
    end;

    raise sqlstate 'PT999';
  exception when sqlstate 'PT999' then null;
  end;
end;
$$;

select 'CRM order checks passed' as result;
