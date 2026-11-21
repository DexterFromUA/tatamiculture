begin;

do $$
declare
  manager uuid := gen_random_uuid();
  stranger uuid := gen_random_uuid();
  shop uuid;
  product uuid;
  variant uuid;
  deferred public.orders;
  shipped public.orders;
  items jsonb;
  customer jsonb := '{"name":"Stock Test","phone":"+380990000001"}';
  destination jsonb := '{"city":"Київ","address":"Відділення №1"}';
begin
  select id into shop from public.shop_settings;
  insert into auth.users(id) values (manager), (stranger);
  insert into public.store_members(store_id,user_id,role) values (shop,manager,'OWNER');
  perform set_config('request.jwt.claim.sub',manager::text,true);
  insert into public.products(store_id,name) values (shop,'Test') returning id into product;
  insert into public.product_variants(product_id,name,stock_quantity,price,allow_out_of_stock)
    values (product,'M',0,105050,true) returning id into variant;
  items := jsonb_build_array(jsonb_build_object('variantId',variant,'quantity',1));

  deferred := public.create_crm_order(shop,gen_random_uuid(),items,customer,destination,'',105050);
  perform public.update_admin_orders(array[deferred.id],'WAITING_FOR_STOCK');
  begin
    perform public.update_admin_orders(array[deferred.id],'PREPARING_SHIPMENT');
    raise exception 'Prepared an order without stock';
  exception when raise_exception then
    if sqlerrm <> 'There is not enough stock to prepare the order.' then raise; end if;
  end;
  if (select status from public.orders where id = deferred.id) <> 'WAITING_FOR_STOCK' then
    raise exception 'Failed allocation changed the status';
  end if;

  update public.product_variants set stock_quantity = 1 where id = variant;
  perform public.update_admin_orders(array[deferred.id],'PREPARING_SHIPMENT');
  perform public.update_admin_orders(array[deferred.id],'PREPARING_SHIPMENT');
  if (select stock_quantity from public.product_variants where id = variant) <> 0 or
    not coalesce((select stock_deducted from public.order_items where order_id = deferred.id), false) then
    raise exception 'Preparation did not reserve replenished stock exactly once';
  end if;

  -- Record payment to exercise the same cancellation path as a paid online order.
  update public.orders set payment_method = 'ONLINE', payment_status = 'PAID' where id = deferred.id;
  perform public.update_admin_orders(array[deferred.id],'CANCELLED_BY_STORE',true);
  perform public.update_admin_orders(array[deferred.id],'CANCELLED_BY_STORE',true);
  if (select stock_quantity from public.product_variants where id = variant) <> 1 or
    (select payment_status from public.orders where id = deferred.id) <> 'PAID' then
    raise exception 'Cancelling before shipment did not restore stock exactly once and preserve payment';
  end if;

  shipped := public.create_crm_order(shop,gen_random_uuid(),items,customer,destination,'',105050);
  perform public.update_admin_orders(array[shipped.id],'PREPARING_SHIPMENT');
  update public.orders set nova_poshta_ttn = '59000000000123' where id = shipped.id;
  perform public.update_admin_orders(array[shipped.id],'IN_TRANSIT');
  perform public.update_admin_orders(array[shipped.id],'CANCELLED_BY_STORE');
  if (select stock_quantity from public.product_variants where id = variant) <> 0 or
    not (select cancel_stock_pending from public.orders where id = shipped.id) then
    raise exception 'Cancelled shipment returned to stock before physical receipt';
  end if;
  perform set_config('request.jwt.claim.sub',stranger::text,true);
  begin
    perform public.confirm_cancelled_order_stock_return(shipped.id);
    raise exception 'Non-staff accepted a return to stock';
  exception when insufficient_privilege then null;
  end;
  perform set_config('request.jwt.claim.sub',manager::text,true);
  perform public.confirm_cancelled_order_stock_return(shipped.id);
  perform public.confirm_cancelled_order_stock_return(shipped.id);
  if (select stock_quantity from public.product_variants where id = variant) <> 1 or
    (select cancel_stock_pending from public.orders where id = shipped.id) then
    raise exception 'Receipt did not restore stock exactly once';
  end if;
end;
$$;

rollback;
