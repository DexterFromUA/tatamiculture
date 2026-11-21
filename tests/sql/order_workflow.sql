begin;

do $$
declare
  manager uuid := gen_random_uuid();
  outsider uuid := gen_random_uuid();
  shop uuid;
  online_order public.orders;
  cod_order public.orders;
  reserved_refund jsonb;
  duplicate_refund jsonb;
  first_attempt uuid;
  second_attempt uuid;
  outcome text;
  received_at timestamptz := now();
begin
  select id into shop from public.shop_settings;
  insert into auth.users(id, raw_user_meta_data) values (manager, '{}'), (outsider, '{}');
  insert into public.store_members(store_id, user_id, role) values (shop, manager, 'OWNER');
  perform set_config('request.jwt.claim.sub', manager::text, true);
  insert into public.delivery_settings(store_id) values (shop)
    on conflict (store_id) do update set auto_update_order_status = excluded.auto_update_order_status;

  insert into public.orders (
    store_id, customer_name, customer_phone, customer_email, delivery_city, delivery_address,
    total_price, currency, status, payment_method, payment_status
  ) values (shop, 'Online', '0991000001', '', 'Київ', '1', 15000, 'UAH', 'PAID', 'ONLINE', 'PAID')
  returning * into online_order;
  insert into public.orders (
    store_id, customer_name, customer_phone, customer_email, delivery_city, delivery_address,
    total_price, currency
  ) values (shop, 'COD', '0991000002', '', 'Київ', '1', 12000, 'UAH') returning * into cod_order;
  if online_order.status <> 'IN_PROGRESS' or not online_order.is_new or online_order.payment_status <> 'PAID'
    or cod_order.status <> 'IN_PROGRESS' or cod_order.is_new or cod_order.payment_status <> 'PENDING' then
    raise exception 'Wrong initial order workflow';
  end if;

  begin
    perform public.reserve_order_ttn(cod_order.id);
    raise exception 'Early TTN creation was accepted';
  exception when raise_exception then
    if sqlerrm <> 'Move the order to preparing for shipment first' then raise; end if;
  end;
  perform public.update_admin_orders(array[online_order.id], 'WAITING_FOR_STOCK', true);
  perform public.attach_verified_order_ttn(online_order.id, '59000000000002', 'early-waybill');
  perform public.apply_nova_poshta_tracking(shop, '59000000000002', '7', 'Ready to collect', received_at + interval '1 minute');
  if (select status from public.orders where id = online_order.id) <> 'WAITING_FOR_STOCK' then
    raise exception 'Early tracking changed a procurement stage';
  end if;
  perform public.update_admin_orders(array[online_order.id], 'PREPARING_SHIPMENT', true);
  perform public.apply_nova_poshta_tracking(shop, '59000000000002', '7', 'Ready to collect', received_at + interval '2 minutes');
  if (select status from public.orders where id = online_order.id) <> 'DELIVERED' then
    raise exception 'Starting preparation did not enable tracking for an existing waybill';
  end if;
  perform public.unlink_order_ttn(online_order.id, '59000000000002');
  perform public.update_admin_orders(array[online_order.id], 'IN_PROGRESS', true);
  select * into online_order from public.orders where id = online_order.id;
  if online_order.is_new or online_order.payment_status <> 'PAID' then
    raise exception 'The first status change did not permanently clear the new badge';
  end if;
  perform public.update_admin_orders(array[cod_order.id], 'PREPARING_SHIPMENT');
  perform public.reserve_order_ttn(cod_order.id);
  perform public.release_order_ttn(cod_order.id);
  update public.orders set nova_poshta_ttn = '59000000000001' where id = cod_order.id;

  perform public.apply_nova_poshta_tracking(shop, '59000000000001', '1', 'Created', received_at);
  if (select status from public.orders where id = cod_order.id) <> 'PREPARING_SHIPMENT' then
    raise exception 'Creating the TTN advanced the order';
  end if;
  perform public.apply_nova_poshta_tracking(shop, '59000000000001', '5', 'In transit', received_at + interval '1 minute');
  if (select status from public.orders where id = cod_order.id) <> 'IN_TRANSIT' then
    raise exception 'The parcel did not advance to in transit';
  end if;
  perform public.apply_nova_poshta_tracking(shop, '59000000000001', '7', 'Ready to collect', received_at + interval '2 minutes');
  if not exists (select from public.orders where id = cod_order.id and status = 'DELIVERED' and payment_status = 'PENDING') then
    raise exception 'Arrival wrongly credited the cash on delivery';
  end if;
  perform public.apply_nova_poshta_tracking(shop, '59000000000001', '5', 'In transit', received_at + interval '1 minute');
  if (select nova_poshta_status_code from public.orders where id = cod_order.id) <> '7' then
    raise exception 'An older tracking result overwrote a newer result';
  end if;
  perform public.apply_nova_poshta_tracking(shop, '59000000000001', '103', 'Refused', received_at + interval '3 minutes');
  if (select status from public.orders where id = cod_order.id) <> 'DELIVERED' then raise exception 'Refusal caused an automatic cancellation'; end if;

  update public.delivery_settings set auto_update_order_status = false where store_id = shop;
  perform public.apply_nova_poshta_tracking(shop, '59000000000001', '10', 'Collected with COD', received_at + interval '4 minutes');
  if not exists (select from public.orders where id = cod_order.id and status = 'DELIVERED' and payment_status = 'PENDING'
      and nova_poshta_status_code = '10' and nova_poshta_status = 'Collected with COD')
    or not exists (select from public.order_delivery_events where order_id = cod_order.id and status_code = '10')
    or not exists (select from public.active_nova_poshta_shipments() where ttn = '59000000000001') then
    raise exception 'Turning off order automation either changed the order or stopped tracking';
  end if;
  perform public.update_admin_orders(array[cod_order.id], 'IN_TRANSIT');
  if (select status from public.orders where id = cod_order.id) <> 'IN_TRANSIT' then
    raise exception 'Disabling automation blocked a manual status change';
  end if;

  update public.delivery_settings set auto_update_order_status = true where store_id = shop;
  perform public.apply_nova_poshta_tracking(shop, '59000000000001', '10', 'Collected with COD', received_at + interval '5 minutes');
  if (select status from public.orders where id = cod_order.id) <> 'IN_TRANSIT' then
    raise exception 'Repeating the same carrier event undid the manual status change';
  end if;
  perform public.apply_nova_poshta_tracking(shop, '59000000000001', '11', 'Collected', received_at + interval '6 minutes');
  if not exists (select from public.orders where id = cod_order.id and status = 'COMPLETED' and payment_status = 'PAID')
    or exists (select from public.active_nova_poshta_shipments() where ttn = '59000000000001')
    or (select count(*) from public.order_delivery_events where order_id = cod_order.id and status_code = '10') <> 1 then
    raise exception 'Recipient handover did not complete the order and stop tracking';
  end if;

  insert into public.payments(order_id, provider, provider_order_id, status)
    values (online_order.id, 'MONOBANK', online_order.id::text, 'PAID');
  perform public.update_admin_orders(array[online_order.id], 'CANCELLED_BY_STORE', true);
  begin
    perform public.begin_order_cancellation_refund(online_order.id, outsider, 'automatic', 15000);
    raise exception 'Unauthorized refund was accepted';
  exception when insufficient_privilege then null;
  end;
  reserved_refund := public.begin_order_cancellation_refund(online_order.id, manager, 'automatic', 15000);
  duplicate_refund := public.begin_order_cancellation_refund(online_order.id, manager, 'manual', 15000);
  if (reserved_refund->>'id') is null or duplicate_refund ? 'id' or duplicate_refund->>'status' <> 'processing'
     or (select payment_status from public.orders where id = online_order.id) <> 'PAID' then
    raise exception 'A duplicate request was allowed or an unfinished refund reported as paid back';
  end if;
  outcome := public.finish_order_cancellation_refund((reserved_refund->>'id')::uuid, 'completed');
  if outcome <> 'completed' or public.finish_order_cancellation_refund((reserved_refund->>'id')::uuid, 'completed') <> 'completed'
    or (select count(*) from public.order_returns where order_id = online_order.id) <> 1
    or (select payment_status from public.orders where id = online_order.id) <> 'REFUNDED'
    or (select status from public.payments where order_id = online_order.id) <> 'REFUNDED' then
    raise exception 'A confirmed online refund was not recorded exactly once';
  end if;

  insert into public.orders (
    store_id, customer_name, customer_phone, customer_email, delivery_city, delivery_address,
    total_price, currency, status, payment_method, payment_status
  ) values (shop, 'Review', '0991000003', '', 'Київ', '1', 15325, 'UAH', 'CANCELLED_BY_STORE', 'ONLINE', 'PAID')
  returning * into online_order;
  insert into public.payments(order_id, provider, provider_order_id, status)
    values (online_order.id, 'MONOBANK', online_order.id::text, 'PAID');
  first_attempt := (public.begin_order_cancellation_refund(online_order.id, manager, 'automatic', 15325)->>'id')::uuid;
  if public.can_review_order_refund(first_attempt)
    or has_function_privilege('authenticated', 'public.resolve_order_cancellation_refund(uuid,uuid,uuid,text)', 'execute') then
    raise exception 'A new attempt is already eligible for manual review or can bypass verification';
  end if;
  begin
    perform public.resolve_order_cancellation_refund(online_order.id, first_attempt, manager, 'not_started');
    raise exception 'A new attempt was unlocked';
  exception when raise_exception then
    if sqlerrm <> 'The refund has changed or is still being processed. Check its status again.' then raise; end if;
  end;
  update public.order_cancellation_refunds set updated_at = now() - interval '15 minutes' where id = first_attempt;
  if not public.can_review_order_refund(first_attempt) then
    raise exception 'An old attempt is not eligible for review';
  end if;
  outcome := public.resolve_order_cancellation_refund(online_order.id, first_attempt, manager, 'not_started');
  if outcome <> 'failed' or
    exists (select from public.order_returns where order_id = online_order.id) then
    raise exception 'Confirming an absent refund did not release the lock safely';
  end if;
  second_attempt := (public.begin_order_cancellation_refund(online_order.id, manager, 'automatic', 15325)->>'id')::uuid;
  if second_attempt is null or second_attempt = first_attempt then
    raise exception 'A retry did not acquire a new attempt ID';
  end if;
  update public.order_cancellation_refunds set updated_at = now() - interval '15 minutes' where id = second_attempt;
  begin
    perform public.resolve_order_cancellation_refund(online_order.id, first_attempt, manager, 'record_paid');
    raise exception 'An old attempt confirmed a new refund';
  exception when raise_exception then
    if sqlerrm <> 'The refund has changed or is still being processed. Check its status again.' then raise; end if;
  end;
  outcome := public.resolve_order_cancellation_refund(online_order.id, second_attempt, manager, 'record_paid');
  if outcome <> 'completed'
    or not exists (select from public.order_returns where id = second_attempt and amount = 15325 and author_id = manager)
    or (select count(*) from public.order_events where order_id = online_order.id and kind = 'refund_review' and author_id = manager) <> 2 then
    raise exception 'Manual review did not record the refund and its author';
  end if;

  perform public.update_admin_orders(array[cod_order.id], 'CANCELLED_BY_STORE', true);
  if public.begin_order_cancellation_refund(cod_order.id, manager, 'manual', 12000)->>'status' <> 'completed'
    or (select amount from public.order_returns where order_id = cod_order.id) <> 12000 then
    raise exception 'A confirmed manual refund was not recorded';
  end if;
end;
$$;

rollback;
