-- Run after the reservation migration. Fixtures are rolled back.
begin;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_other uuid := gen_random_uuid();
  v_store uuid;
  v_product uuid;
  v_variant uuid;
  v_items jsonb;
  v_order public.orders;
  v_payment public.payments;
  v_operation uuid := gen_random_uuid();
begin
  insert into auth.users (id, raw_user_meta_data) values (v_owner, '{"name":"Buyer"}'), (v_other, '{"name":"Other buyer"}');
  insert into public.profiles (id) values (v_owner), (v_other) on conflict (id) do nothing;
  insert into public.stores (slug, name, contact_email, contact_phone, contact_city)
  values ('reservation-test-' || gen_random_uuid(), 'Reservation test', '', '', '') returning id into v_store;
  insert into public.products (store_id, name) values (v_store, 'Rashguard') returning id into v_product;
  insert into public.product_variants (product_id, name, price, stock_quantity)
  values (v_product, 'M', 150000, 5) returning id into v_variant;
  v_items := jsonb_build_array(jsonb_build_object('variantId', v_variant, 'quantity', 2));

  v_order := public.create_reserved_online_order('MONOBANK', v_owner, v_store, v_items, 'Buyer', '',
    '380501234567', 'Київ', '1', '', null, null, null, false);
  if not v_order.reserved_in_profile or v_order.payment_status <> 'PENDING'
      or (select stock_quantity from public.product_variants where id = v_variant) <> 3 then
    raise exception 'Pending online order did not reserve stock';
  end if;

  begin
    perform public.begin_reserved_order_action(v_order.id, v_other, v_operation);
    raise exception 'A different customer opened the reservation';
  exception when sqlstate 'PT404' then null;
  end;

  v_payment := public.begin_reserved_order_action(v_order.id, v_owner, v_operation);
  begin
    perform public.begin_reserved_order_action(v_order.id, v_owner, gen_random_uuid());
    raise exception 'Concurrent reservation action was accepted';
  exception when sqlstate 'PT409' then null;
  end;

  perform public.cancel_customer_reservation(v_order.id, v_owner, v_operation, v_payment.provider_order_id);
  perform public.apply_online_payment_callback('MONOBANK', v_payment.provider_order_id, false, null, '{}');
  if not exists (select 1 from public.orders where id = v_order.id and status = 'CANCELLED_BY_USER')
      or (select stock_quantity from public.product_variants where id = v_variant) <> 5 then
    raise exception 'Cancellation did not restore the original stock';
  end if;
  begin
    perform public.cancel_customer_reservation(v_order.id, v_owner, v_operation, v_payment.provider_order_id);
    raise exception 'Duplicate cancellation was accepted';
  exception when sqlstate 'PT409' then null;
  end;

  v_order := public.create_reserved_online_order('LIQPAY', v_owner, v_store, v_items, 'Buyer', '',
    '380501234567', 'Київ', '1', '', null, null, null, false);
  v_payment := public.begin_reserved_order_action(v_order.id, v_owner, v_operation);
  perform public.apply_online_payment_callback('LIQPAY', v_payment.provider_order_id, true, 'provider-payment', '{}');
  begin
    perform public.cancel_customer_reservation(v_order.id, v_owner, v_operation, v_payment.provider_order_id);
    raise exception 'A paid reservation was cancelled';
  exception when sqlstate 'PT409' then null;
  end;
  if not exists (select 1 from public.orders where id = v_order.id and status = 'PAID' and payment_status = 'PAID')
      or (select stock_quantity from public.product_variants where id = v_variant) <> 3 then
    raise exception 'Paid order state or stock changed unexpectedly';
  end if;

  if has_function_privilege('authenticated', 'public.cancel_customer_reservation(uuid,uuid,uuid,text)', 'execute')
      or has_function_privilege('anon', 'public.apply_online_payment_callback(text,text,boolean,text,jsonb)', 'execute') then
    raise exception 'Reservation state can be changed directly by a storefront caller';
  end if;
end;
$$;

rollback;
