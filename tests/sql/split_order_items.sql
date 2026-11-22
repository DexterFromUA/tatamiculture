-- Use real CRM RPCs inside a rolled-back transaction.
begin;
drop index public.shop_settings_single_row_idx;

do $$
declare
  manager uuid := gen_random_uuid();
  buyer uuid := gen_random_uuid();
  shop uuid;
  product uuid;
  variant uuid;
  discount uuid;
  original public.orders;
  cod_order uuid;
  split_id uuid;
  cod_split_id uuid;
  line_a uuid;
  line_b uuid;
  cod_line uuid;
  request jsonb;
  result jsonb;
begin
  insert into auth.users(id) values (manager), (buyer);
  insert into public.shop_settings(name) values ('Split order fixture') returning id into shop;
  insert into public.store_members(store_id, user_id, role) values (shop, manager, 'OWNER');
  insert into public.customer_discounts(store_id,user_id,percent,mode,order_limit)
    values (shop,buyer,10,'orders',1) returning id into discount;
  insert into public.products(store_id,name,weight_grams) values (shop,'Shirt',220) returning id into product;
  insert into public.product_variants(product_id,name,price,stock_quantity)
    values (product,'M',1100,5) returning id into variant;
  insert into public.variant_costs(variant_id,cost_amount) values (variant,300);
  insert into public.orders(store_id,user_id,customer_name,customer_email,customer_phone,delivery_city,delivery_address,
      total_price,currency,status,payment_status,payment_method,customer_discount_id,customer_discount_percent,customer_discount_amount)
    values (shop,buyer,'Buyer','','+380991231234','Київ','1',2700,'UAH','IN_PROGRESS','PAID','ONLINE',discount,10,300)
    returning * into original;
  insert into public.payments(order_id,provider,provider_order_id,status)
    values(original.id,'MONOBANK','split-test-payment','PAID');
  insert into public.order_items(order_id,product_id,variant_id,product_name,variant_name,quantity,unit_price,compare_at_price,line_total,stock_deducted)
    values (original.id,product,variant,'Shirt','M',2,900,1000,1800,true) returning id into line_a;
  insert into public.order_items(order_id,product_id,variant_id,product_name,variant_name,quantity,unit_price,compare_at_price,line_total,stock_deducted)
    values (original.id,product,variant,'Shirt','L',1,900,1000,900,false) returning id into line_b;
  insert into public.order_financials(order_id,cost_amount) values (original.id,900);
  update public.products set weight_grams = 500 where id = product;
  update public.variant_costs set cost_amount = 800 where variant_id = variant;

  request := jsonb_build_array(jsonb_build_object('item_id',line_a,'quantity',1,'expected_quantity',2,'expected_line_total',1800),
    jsonb_build_object('item_id',line_b,'quantity',1,'expected_quantity',1,'expected_line_total',900));
  perform set_config('request.jwt.claim.sub',buyer::text,true);
  set local role authenticated;
  begin
    perform public.split_order_items(original.id,request);
    raise exception 'Customer could split an order';
  exception when insufficient_privilege then null;
  end;
  reset role;
  perform set_config('request.jwt.claim.sub',manager::text,true);

  begin
    perform public.split_order_items(original.id,jsonb_build_array(
      jsonb_build_object('item_id',line_a,'quantity',2,'expected_quantity',2,'expected_line_total',1800),
      jsonb_build_object('item_id',line_b,'quantity',1,'expected_quantity',1,'expected_line_total',900)));
    raise exception 'Split emptied the original order';
  exception when raise_exception then
    if sqlerrm <> 'Leave at least one item in the original order.' then raise; end if;
  end;

  update public.orders set nova_poshta_ttn='59000000000001' where id=original.id;
  begin
    perform public.split_order_items(original.id,request);
    raise exception 'Order with a TTN was split';
  exception when sqlstate 'PT409' then
    if sqlerrm <> 'Unlink the TTN before splitting the order.' then raise; end if;
  end;
  update public.orders set nova_poshta_ttn=null where id=original.id;

  set local role authenticated;
  result := public.split_order_items(original.id,request);
  split_id := (result->>'order_id')::uuid;
  begin
    perform public.split_order_items(original.id,request);
    raise exception 'Stale request created another order';
  exception when sqlstate 'PT409' then
    if sqlerrm <> 'The selected items have changed. Refresh the order and try again.' then raise; end if;
  end;
  reset role;

  if not exists (select from public.orders o where o.id=split_id and o.split_origin_id=original.id
      and o.user_id=buyer and o.crm_customer_id=original.crm_customer_id and o.status=original.status
      and o.payment_status='PAID' and o.total_price=1800 and o.customer_discount_amount=200
      and o.receipt_code <> original.receipt_code and o.nova_poshta_ttn is null) then
    raise exception 'Separate order failed to preserve customer, payment, prices or shipping state';
  end if;
  if not exists (select from public.orders o where o.id=original.id and o.total_price=900
      and o.customer_discount_amount=100 and o.split_origin_id=original.id) then
    raise exception 'Original order totals were not reduced correctly';
  end if;
  if (select stock_quantity from public.product_variants where id=variant) <> 5
    or not exists (select from public.order_items where id=line_b and order_id=split_id and procurement_restocked=false)
    or not exists (select from public.order_items i join public.order_item_costs c on c.item_id=i.id
      where i.order_id=split_id and i.stock_deducted and i.quantity=1 and i.weight_grams=220 and c.unit_cost=300)
    or (select cost_amount from public.order_financials where order_id=split_id) <> 600
    or (select cost_amount from public.order_financials where order_id=original.id) <> 300 then
    raise exception 'Inventory or order snapshots changed unexpectedly';
  end if;
  if public.customer_discount_usage(discount) <> 1 or exists (select from public.payments where order_id=split_id)
    or exists (select from public.customer_notifications where order_id=split_id) then
    raise exception 'Split duplicated a discount use, invoice or new-purchase notification';
  end if;

  perform public.correct_admin_order_status(array[original.id], 'CANCELLED_BY_STORE', true, false, null, null);
  if (select automatic_available from public.get_order_cancellation_refunds(array[original.id])) is distinct from false then
    raise exception 'Split part still offers automatic bank refund';
  end if;
  begin
    perform public.begin_order_cancellation_refund(original.id, manager, 'automatic', 900);
    raise exception 'Split part submitted automatic bank refund';
  exception when sqlstate 'PT409' then
    if sqlerrm <> 'Refunds for split orders must be recorded manually.' then raise; end if;
  end;
  perform public.begin_order_cancellation_refund(original.id, manager, 'manual', 900);
  if (select payment_status from public.orders where id=split_id) <> 'PAID'
    or (select status from public.payments where order_id=original.id) <> 'PAID'
    or public.customer_discount_usage(discount) <> 1
    or (select stock_quantity from public.product_variants where id=variant) <> 6 then
    raise exception 'Cancel/refund touched the other part or original invoice';
  end if;

  insert into public.orders(store_id,customer_name,customer_email,customer_phone,delivery_city,delivery_address,total_price,currency)
    values (shop,'Guest','','+380992345678','Київ','1',2000,'UAH') returning id into cod_order;
  insert into public.order_items(order_id,product_id,variant_id,product_name,variant_name,quantity,unit_price,line_total,stock_deducted)
    values (cod_order,product,variant,'Shirt','M',2,1000,2000,true) returning id into cod_line;
  result := public.split_order_items(cod_order,jsonb_build_array(
    jsonb_build_object('item_id',cod_line,'quantity',1,'expected_quantity',2,'expected_line_total',2000)));
  cod_split_id := (result->>'order_id')::uuid;
  if (select count(*) from public.orders where id in (cod_order,cod_split_id)
      and total_price=1000 and payment_method='CASH_ON_DELIVERY' and payment_status='PENDING') <> 2 then
    raise exception 'Cash-on-delivery amount or payment state was not preserved';
  end if;
end;
$$;

rollback;
