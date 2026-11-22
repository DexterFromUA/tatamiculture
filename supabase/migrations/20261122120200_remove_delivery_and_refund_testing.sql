begin;

-- Protect the live carrier path for test payments even after delivery testing is removed.
create or replace function public.guard_live_waybill_reservation() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  is_test boolean;
begin
  select coalesce(payment_test_mode, monobank_test_mode) into strict is_test
  from public.orders where id = new.order_id;
  if is_test then raise exception 'A live TTN is unavailable for a test order.'; end if;
  return new;
end;
$$;

create or replace function public.get_order_delivery_actions(p_order_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  target public.orders;
  attempt public.order_ttn_reservations;
  pending_stock boolean;
begin
  select * into target from public.orders where id = p_order_id;
  if not found or not coalesce(public.is_store_member(target.store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  select exists (
    select from public.orders o where o.store_id = target.store_id and o.cancel_stock_pending
      and (o.id = p_order_id or exists (
        select from public.order_merge_members m where m.root_id = p_order_id and m.order_id = o.id
      ))
  ) into pending_stock;
  select * into attempt from public.order_ttn_reservations where order_id = p_order_id;
  return jsonb_build_object(
    'cancelStockPending', pending_stock, 'ttn', target.nova_poshta_ttn,
    'ttnAttempt', case when attempt.attempt_id is not null and target.nova_poshta_ttn is null
      then jsonb_build_object('id', attempt.attempt_id,
        'state', case when attempt.needs_review or attempt.created_at <= now() - interval '8 minutes'
          then 'review' else 'creating' end)
    end
  );
end;
$$;

create or replace function public.apply_nova_poshta_tracking(
  p_store_id uuid, p_ttn text, p_code text, p_status text, p_checked_at timestamptz
) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  auto_update boolean;
  shipment public.orders;
  next_status public.order_status;
  tracking_changed boolean;
  changed boolean := false;
begin
  if nullif(p_ttn, '') is null or nullif(p_status, '') is null or p_checked_at is null then
    raise exception 'Invalid shipment status';
  end if;
  if p_ttn like 'TEST-%' then return false; end if;
  select s.auto_update_order_status into auto_update
  from public.delivery_settings s where s.store_id = p_store_id for share;

  for shipment in
    select * from public.orders
    where store_id = p_store_id and nova_poshta_ttn = p_ttn
    order by id for update
  loop
    if p_checked_at <= shipment.nova_poshta_status_updated_at or p_checked_at < shipment.nova_poshta_ttn_created_at then
      continue;
    end if;
    tracking_changed := shipment.nova_poshta_status_code is distinct from p_code
      or shipment.nova_poshta_status is distinct from p_status;
    next_status := shipment.status;
    if coalesce(auto_update, true)
      and shipment.manual_tracking_status_code is distinct from p_code
      and not coalesce(shipment.payment_test_mode, shipment.monobank_test_mode)
      and shipment.status in ('PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED') then
      if p_code in ('9', '10', '11')
        and ((shipment.payment_method = 'ONLINE' and shipment.payment_status = 'PAID')
          or (shipment.payment_method = 'CASH_ON_DELIVERY' and shipment.payment_status in ('PENDING', 'PAID'))) then
        next_status := 'COMPLETED';
      elsif p_code in ('7', '8') then
        next_status := 'DELIVERED';
      elsif p_code in ('4', '5', '6', '101') and shipment.status <> 'DELIVERED' then
        next_status := 'IN_TRANSIT';
      end if;
    end if;
    update public.orders set nova_poshta_status = p_status, nova_poshta_status_code = p_code,
      nova_poshta_status_updated_at = p_checked_at, status = next_status,
      manual_tracking_status_code = case when shipment.manual_tracking_status_code = p_code then p_code end,
      shipment_was_dispatched = shipment.shipment_was_dispatched or coalesce(p_code in ('4', '5', '6', '7', '8', '9', '10', '11', '101'), false)
    where id = shipment.id;
    if tracking_changed then
      insert into public.order_delivery_events (order_id, status_code, status_text)
      values (shipment.id, p_code, p_status);
    end if;
    changed := changed or tracking_changed or next_status <> shipment.status;
  end loop;
  return changed;
end;
$$;

create or replace function public.create_crm_order(
  p_store_id uuid, p_request_id uuid, p_items jsonb, p_customer jsonb,
  p_delivery jsonb, p_note text, p_expected_total integer
) returns public.orders
language plpgsql security definer set search_path = '' as $$
declare
  created_order public.orders;
  quote record;
  buyer_name text := btrim(coalesce(p_customer->>'name', ''));
  buyer_phone text := btrim(coalesce(p_customer->>'phone', ''));
  buyer_email text := lower(btrim(coalesce(p_customer->>'email', '')));
  city_name text := btrim(coalesce(p_delivery->>'city', ''));
  address_name text := btrim(coalesce(p_delivery->>'address', ''));
  city_ref text := nullif(btrim(p_delivery->>'cityRef'), '');
  address_ref text := nullif(btrim(p_delivery->>'addressRef'), '');
  service_type text := p_delivery->>'serviceType';
  order_note text := btrim(coalesce(p_note, ''));
begin
  if not public.is_store_member(p_store_id) then
    raise insufficient_privilege using message = 'Manager access required';
  end if;
  if p_request_id is null then
    raise invalid_parameter_value using message = 'Invalid order request.';
  end if;

  -- Reuse the order ID on retries, including after a lost response.
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));
  select * into created_order from public.orders
  where id = p_request_id and store_id = p_store_id;
  if found then return created_order; end if;

  if buyer_name = '' or length(buyer_name) > 200
    or buyer_phone !~ '^\+[1-9][0-9]{7,14}$' or length(buyer_email) > 254 then
    raise invalid_parameter_value using message = 'Enter a valid customer name and phone number.';
  end if;
  if city_name = '' or address_name = '' or length(city_name) > 200 or length(address_name) > 500 then
    raise invalid_parameter_value using message = 'Enter the city and delivery address.';
  end if;
  if (city_ref is null) <> (address_ref is null)
    or (city_ref is not null and coalesce(service_type, '') not in ('WarehouseWarehouse', 'WarehousePostomat')) then
    raise invalid_parameter_value using message = 'Choose a city and Nova Poshta branch';
  end if;
  if length(order_note) > 2000 then
    raise invalid_parameter_value using message = 'The order note is too long.';
  end if;

  select * into quote from public.quote_catalog_cart(p_store_id, p_items, null, true);
  if p_expected_total is distinct from quote.total then
    raise sqlstate 'PT409' using message = 'Order prices changed. Review the total and try again.';
  end if;

  insert into public.orders (
    id, store_id, customer_name, customer_phone, customer_email, delivery_city, delivery_address,
    delivery_city_ref, delivery_address_ref, delivery_service_type, note, total_price, currency,
    payment_method, payment_test_mode, status, payment_status
  )
  select p_request_id, s.id, buyer_name, buyer_phone, buyer_email, city_name, address_name,
    city_ref, address_ref, case when city_ref is not null then service_type end, order_note, quote.total, s.currency,
    'CASH_ON_DELIVERY', false,
    case when quote.total = 0 then 'PAID'::public.order_status else 'PENDING'::public.order_status end,
    case when quote.total = 0 then 'PAID'::public.payment_status else 'PENDING'::public.payment_status end
  from public.shop_settings s where s.id = p_store_id
  returning * into created_order;

  insert into public.order_items (
    order_id, product_id, variant_id, product_name, variant_name, quantity,
    unit_price, compare_at_price, line_total, is_preorder, stock_deducted
  )
  select created_order.id, line.product_id, line.variant_id, line.product_name, line.variant_name, line.quantity,
    line.unit_price, line.compare_at_price, line.line_total, line.is_preorder, line.stock_deducted
  from jsonb_populate_recordset(null::public.order_items, quote.items) as line;

  update public.product_variants v set stock_quantity = v.stock_quantity - line.quantity
  from jsonb_populate_recordset(null::public.order_items, quote.items) as line
  where v.id = line.variant_id and line.stock_deducted;

  return created_order;
end;
$$;

create or replace function public.begin_order_cancellation_refund(
  p_order_id uuid, p_actor uuid, p_method text, p_amount integer
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  target public.orders;
  payment public.payments;
  operation public.order_cancellation_refunds;
  returned bigint;
begin
  select * into target from public.orders where id = p_order_id for update;
  if not found or not exists (select from public.store_members
      where store_id = target.store_id and user_id = p_actor) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  if target.status not in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER')
    or coalesce(target.payment_test_mode, target.monobank_test_mode) then
    raise exception 'Only cancelled live orders can be refunded';
  end if;
  if p_method is null or p_method not in ('manual', 'automatic', 'check') then raise exception 'Invalid refund method'; end if;

  select * into operation from public.order_cancellation_refunds where order_id = target.id;
  if p_method = 'check' then
    if operation.status is distinct from 'processing' then
      return jsonb_build_object('status', operation.status);
    end if;
    select * into payment from public.payments where id = operation.payment_id;
  else
    if operation.status in ('processing', 'completed') then
      return jsonb_build_object('status', operation.status);
    end if;
    select coalesce(sum(amount), 0) into returned from public.order_returns where order_id = target.id;
    if target.payment_status <> 'PAID' or p_amount is distinct from target.total_price - returned or p_amount <= 0 then
      raise exception 'The refundable amount has changed. Reload the order and try again.';
    end if;
    if p_method = 'automatic' then
      select * into payment from public.payments
      where order_id = target.id and status = 'PAID' and provider in ('MONOBANK', 'LIQPAY') for update;
      if payment.id is null or target.payment_method <> 'ONLINE' or returned <> 0 then
        raise exception 'Automatic refund is unavailable for this order';
      end if;
    end if;
    insert into public.order_cancellation_refunds (order_id, payment_id, requested_by, amount, method, status)
    values (target.id, payment.id, p_actor, p_amount, p_method, 'processing')
    on conflict (order_id) do update set id = excluded.id, payment_id = excluded.payment_id,
      requested_by = excluded.requested_by, amount = excluded.amount, method = excluded.method,
      status = excluded.status, error = null, updated_at = now()
    returning * into operation;
    if p_method = 'manual' then
      return jsonb_build_object('status', public.finish_order_cancellation_refund(operation.id, 'completed'));
    end if;
  end if;
  return jsonb_build_object('status', operation.status, 'id', operation.id, 'amount', operation.amount,
    'currency', target.currency, 'provider', payment.provider, 'reference', payment.provider_order_id,
    'payment_id', payment.provider_payment_id, 'payment_test_mode', target.payment_test_mode);
end;
$$;

create or replace function public.finish_order_cancellation_refund(p_id uuid, p_status text, p_error text default null)
returns text language plpgsql security definer set search_path = '' as $$
declare
  operation public.order_cancellation_refunds;
  target public.orders;
begin
  if p_status not in ('completed', 'failed') then raise exception 'Invalid refund status'; end if;
  select o.* into target from public.orders o
    join public.order_cancellation_refunds r on r.order_id = o.id where r.id = p_id for update of o;
  select * into operation from public.order_cancellation_refunds where id = p_id for update;
  if not found then raise exception 'Refund operation not found'; end if;
  if operation.status <> 'processing' then return operation.status; end if;
  if coalesce(target.payment_test_mode, target.monobank_test_mode) then
    raise exception 'Only cancelled live orders can be refunded';
  end if;
  -- Keep the update and ledger entry in a single transaction.
  update public.order_cancellation_refunds set status = p_status, error = p_error, updated_at = now() where id = p_id;
  if p_status = 'completed' then
    insert into public.order_returns (id, order_id, amount, reason, author_id)
      values (p_id, target.id, operation.amount, 'Повернення за скасоване замовлення', operation.requested_by);
    insert into public.order_events (order_id, kind, new_value, author_id)
      values (target.id, 'return', operation.amount::text, operation.requested_by);
    update public.orders set payment_status = 'REFUNDED' where id = target.id;
    update public.payments set status = 'REFUNDED', updated_at = now()
      where order_id = target.id and status = 'PAID';
  end if;
  return p_status;
end;
$$;

create or replace function public.pending_order_cancellation_refund(p_provider text, p_reference text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', r.id, 'amount', r.amount, 'currency', o.currency,
    'provider', p.provider, 'reference', p.provider_order_id, 'payment_id', p.provider_payment_id,
    'payment_test_mode', o.payment_test_mode)
  from public.order_cancellation_refunds r
  join public.payments p on p.id = r.payment_id
  join public.orders o on o.id = r.order_id
  where r.status = 'processing' and p.provider = p_provider and p.provider_order_id = p_reference
    and not coalesce(o.payment_test_mode, o.monobank_test_mode);
$$;

create or replace function public.resolve_order_cancellation_refund(
  p_order_id uuid, p_attempt_id uuid, p_actor uuid, p_resolution text
) returns text language plpgsql security definer set search_path = '' as $$
declare
  target public.orders;
  operation public.order_cancellation_refunds;
  outcome text;
begin
  select * into target from public.orders where id = p_order_id for update;
  if not found or not exists (select from public.store_members
      where store_id = target.store_id and user_id = p_actor) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  if target.status not in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER')
    or coalesce(target.payment_test_mode, target.monobank_test_mode) then
    raise exception 'Only cancelled live orders can be refunded';
  end if;
  select * into operation from public.order_cancellation_refunds where order_id = target.id for update;
  if operation.id is distinct from p_attempt_id or not public.can_review_order_refund(operation.id) then
    raise exception 'The refund has changed or is still being processed. Check its status again.';
  end if;
  if p_resolution = 'record_paid' then
    update public.order_cancellation_refunds set requested_by = p_actor, method = 'manual' where id = operation.id;
    outcome := public.finish_order_cancellation_refund(operation.id, 'completed');
  elsif p_resolution = 'not_started' then
    outcome := public.finish_order_cancellation_refund(operation.id, 'failed',
      'The bank did not start this refund. You can try again.');
  else
    raise exception 'Invalid refund resolution';
  end if;
  insert into public.order_events (order_id, kind, new_value, author_id)
    values (target.id, 'refund_review', case when p_resolution = 'record_paid'
      then 'Refund recorded after checking the bank' else 'The bank did not start this refund. You can try again.' end, p_actor);
  return outcome;
end;
$$;

-- Retain recorded financial outcomes and archived test shipment data.
drop function public.get_order_cancellation_refunds(uuid[], boolean);
drop function public.create_crm_order(uuid, uuid, jsonb, jsonb, jsonb, text, integer, boolean);

drop function public.active_nova_poshta_stage_waybills();
drop function public.apply_nova_poshta_stage_tracking(uuid, uuid, text, text, timestamptz);
drop function public.apply_nova_poshta_stage_tracking(uuid, uuid, text, text, timestamptz, boolean);
drop function public.update_nova_poshta_test_waybill(uuid, uuid, text);
drop function public.apply_nova_poshta_tracking_update(uuid, text, text, text, timestamptz, boolean);
drop function public.delete_nova_poshta_test_waybill(uuid, uuid);
drop function public.list_nova_poshta_test_waybills(uuid, boolean);
drop function public.list_nova_poshta_test_waybills(uuid);
drop function public.begin_nova_poshta_stage_waybill(uuid, uuid, jsonb);
drop function public.create_nova_poshta_test_waybill(uuid, uuid, jsonb);
drop function public.create_nova_poshta_test_waybill(uuid, uuid);
drop function public.set_nova_poshta_test_mode(uuid, boolean);
alter table public.delivery_settings drop column nova_poshta_test_mode;
revoke all on public.nova_poshta_test_waybills from public, anon, authenticated, service_role;
revoke update (stage_state, stage_ref, stage_number) on public.nova_poshta_test_waybills from service_role;

notify pgrst, 'reload schema';

commit;
