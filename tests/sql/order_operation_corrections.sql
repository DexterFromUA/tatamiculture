begin;
do $$
declare
  staff uuid:=gen_random_uuid(); shop uuid; product uuid; v uuid; request_id uuid:=gen_random_uuid();
  a public.orders; b public.orders; payload jsonb; shipping record;
begin
  select id into shop from public.shop_settings;
  insert into auth.users(id) values(staff);
  insert into public.store_members(store_id,user_id,role) values(shop,staff,'OWNER');
  perform set_config('request.jwt.claim.sub',staff::text,true);
  insert into public.products(store_id,name,weight_grams) values(shop,'Audit',300) returning id into product;
  insert into public.product_variants(product_id,name,price,stock_quantity) values(product,'M',10000,2) returning id into v;
  payload:=jsonb_build_object('p_store_id',shop,'p_items',jsonb_build_array(jsonb_build_object('variantId',v,'quantity',1)),
    'p_customer_name','Buyer','p_customer_email','','p_customer_phone','+380990000001',
    'p_delivery_city','City','p_delivery_address','Branch','p_note','','p_expected_total',10000);
  a:=public.place_cod_order(request_id,payload);
  b:=public.place_cod_order(request_id,payload);
  if a.id<>b.id or (select stock_quantity from public.product_variants where id=v)<>1 then raise exception 'Duplicate checkout'; end if;
  b:=public.place_cod_order(gen_random_uuid(),payload);
  perform public.update_admin_orders(array[a.id],'PREPARING_SHIPMENT');
  perform public.update_admin_orders(array[b.id],'CANCELLED_BY_STORE');
  begin
    perform public.merge_orders(array[a.id,b.id],a.id);
    raise exception 'Merged a cancelled order';
  exception when raise_exception then
    if sqlerrm <> 'Cancelled orders cannot be included in a shipment' then raise; end if;
  end;
  begin
    perform public.update_admin_orders(array[b.id],'PREPARING_SHIPMENT');
    raise exception 'Missing source choice accepted';
  exception when raise_exception then
    if sqlerrm <> 'Choose stock for reopened orders' then raise; end if;
  end;
  perform public.correct_admin_order_status(array[b.id],'PREPARING_SHIPMENT',false,false,'stock',null);
  if (select stock_quantity from public.product_variants where id=v)<>0 then raise exception 'Reopened order missed stock'; end if;
  perform public.update_admin_orders(array[b.id],'CANCELLED_BY_STORE');
  perform public.correct_admin_order_status(array[b.id],'PREPARING_SHIPMENT',false,false,'supplier',null);
  if (select stock_quantity from public.product_variants where id=v)<>1 then raise exception 'Procurement took stock'; end if;
  perform public.update_admin_orders(array[a.id],'COMPLETED');
  perform public.correct_admin_order_status(array[a.id],'PREPARING_SHIPMENT',true,false,null,'no');
  select * into shipping from public.merged_order_shipping(a.id);
  if shipping.cod_minor <> 10000 then raise exception 'COD missing after correction'; end if;
  perform public.merge_orders(array[a.id,b.id],a.id);
  update public.orders set status='CANCELLED_BY_STORE' where id=b.id;
  begin
    perform public.reserve_order_ttn(a.id);
    raise exception 'Accepted stale shipment group';
  exception when raise_exception then
    if sqlerrm <> 'Cancelled orders cannot be included in a shipment' then raise; end if;
  end;
end; $$;
rollback;
