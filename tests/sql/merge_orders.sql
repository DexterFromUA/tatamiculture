-- Rollback-safe checks against the migrated database.
begin;
do $$
declare
  manager uuid := gen_random_uuid(); outsider uuid := gen_random_uuid(); shop uuid;
  first_order uuid; second_order uuid; paid_order uuid; product uuid; stats record;
begin
  insert into auth.users(id,raw_user_meta_data) values(manager,'{}'),(outsider,'{}');
  insert into public.stores(slug,name,contact_email,contact_phone,contact_city)
    values('merge-test-'||manager::text,'Merge test','merge@example.invalid','000','Test') returning id into shop;
  insert into public.store_members(store_id,user_id,role) values(shop,manager,'OWNER');
  perform set_config('request.jwt.claim.sub',manager::text,true);
  insert into public.products(store_id,name,weight_grams) values(shop,'Test product',500) returning id into product;
  insert into public.orders(store_id,customer_name,customer_email,customer_phone,delivery_city,delivery_address,total_price,currency,payment_method)
    values(shop,'First','first@example.invalid','0991111111','Test','Test',10000,'UAH','CASH_ON_DELIVERY') returning id into first_order;
  insert into public.orders(store_id,customer_name,customer_email,customer_phone,delivery_city,delivery_address,total_price,currency,payment_method,status)
    values(shop,'Second','second@example.invalid','0992222222','Test','Test',20000,'UAH','CASH_ON_DELIVERY','IN_PROGRESS') returning id into second_order;
  insert into public.orders(store_id,customer_name,customer_email,customer_phone,delivery_city,delivery_address,total_price,currency,payment_method,status,payment_status)
    values(shop,'Paid','paid@example.invalid','0993333333','Test','Test',30000,'UAH','ONLINE','PAID','PAID') returning id into paid_order;
  insert into public.order_items(order_id,product_id,product_name,variant_name,quantity,unit_price,line_total)
    values(first_order,product,'Test','M',1,10000,10000),(second_order,product,'Test','M',2,10000,20000);

  begin
    perform public.merge_orders(array[first_order,paid_order],first_order);
    raise exception 'Mixed payment accepted';
  exception when raise_exception then
    if sqlerrm <> 'Paid and unpaid orders cannot be merged together' then raise; end if;
  end;
  perform public.reserve_order_ttn(first_order);
  begin
    perform public.merge_orders(array[first_order,second_order],first_order);
    raise exception 'Reserved TTN accepted';
  exception when raise_exception then
    if sqlerrm <> 'TTN creation is in progress for one of these orders' then raise; end if;
  end;
  perform public.release_order_ttn(first_order);
  perform public.merge_orders(array[first_order,second_order],first_order);
  select * into stats from public.merged_order_shipping(first_order);
  if stats.total_minor<>30000 or stats.cod_minor<>30000 or stats.weight_grams<>1500 then raise exception 'Wrong shipping totals'; end if;
  if (select status from public.orders where id=second_order)<>'IN_PROGRESS' then raise exception 'Original status was changed'; end if;
  if (select crm_customer_id from public.orders where id=second_order) is distinct from (select crm_customer_id from public.orders where id=first_order) then raise exception 'Customer was not selected'; end if;
  perform public.change_merged_order_status(first_order,'IN_PROGRESS');
  if (select count(*) from public.orders where id in(first_order,second_order) and status='IN_PROGRESS')<>2 then raise exception 'Status did not propagate'; end if;
  if exists(select 1 from public.orders where id in(first_order,second_order) and payment_status<>'PENDING') then raise exception 'A non-paid status changed payment'; end if;
  perform public.change_merged_order_status(first_order,'PAID');
  if (select count(*) from public.orders where id in(first_order,second_order) and status='PAID' and payment_status='PAID')<>2 then raise exception 'Manual paid status did not confirm all payments'; end if;
  begin
    perform public.change_merged_order_status(first_order,'PENDING');
    raise exception 'Paid group status changed without confirmation';
  exception when sqlstate 'PT409' then null;
  end;
  perform public.update_admin_orders(array[first_order],'IN_PROGRESS',true);
  if (select count(*) from public.orders where id in(first_order,second_order) and payment_status='PAID')<>2 then raise exception 'Fulfilment status reversed payment'; end if;
  perform public.update_admin_orders(array[first_order],'PENDING',true);
  if (select count(*) from public.orders where id in(first_order,second_order) and status='PENDING' and payment_status='PENDING')<>2 then raise exception 'Manual pending status did not reset all payments'; end if;
  begin
    perform public.cancel_merged_unpaid_order(first_order);
    raise exception 'A historical payment was ignored during stock restoration';
  exception when sqlstate 'PT409' then null;
  end;
  update public.orders set status='PENDING', payment_status='PENDING' where id=paid_order;
  delete from public.order_events where order_id=paid_order;
  insert into public.payments(order_id,provider,provider_order_id,status)
  values(paid_order,'LIQPAY',paid_order::text,'PAID');
  begin
    perform public.update_admin_orders(array[first_order,paid_order],'DELIVERED');
    raise exception 'Bulk status changed without confirmation';
  exception when sqlstate 'PT409' then null;
  end;
  if exists(select 1 from public.orders where id in(first_order,second_order,paid_order) and status<>'PENDING') then raise exception 'Unconfirmed bulk status was partially applied'; end if;
  begin
    perform public.change_order_status(paid_order,'IN_PROGRESS');
    raise exception 'Provider payment was ignored';
  exception when sqlstate 'PT409' then null;
  end;
  set local role service_role;
  -- Simulate the webhook's combined success update and payment-only fallback.
  update public.orders set status='PAID', payment_status='PAID' where id in(first_order,paid_order);
  update public.orders set payment_status='PAID' where id=second_order;
  reset role;
  if (select count(*) from public.orders where id in(first_order,second_order) and payment_status='PAID')<>2 then raise exception 'Webhook could not update payment after a manual correction'; end if;
  if not exists(select 1 from public.orders where id=first_order and status='PAID') then raise exception 'Webhook could not update order status after a manual correction'; end if;
  if not exists(select 1 from public.orders where id=paid_order and status='PAID' and payment_status='PAID') then raise exception 'Automatic payment was blocked for an unmodified order'; end if;
  update public.orders set nova_poshta_ttn='test-ttn' where id=first_order;
  begin
    perform public.merge_orders(array[first_order,paid_order],first_order);
    raise exception 'Order with TTN accepted';
  exception when raise_exception then
    if sqlerrm <> 'Orders with an existing TTN cannot be merged' then raise; end if;
  end;
  perform set_config('request.jwt.claim.sub',outsider::text,true);
  begin
    perform public.merge_orders(array[first_order,paid_order],first_order);
    raise exception 'Unauthorized merge accepted';
  exception when raise_exception then
    if sqlerrm <> 'Access denied' then raise; end if;
  end;
end; $$;
rollback;
