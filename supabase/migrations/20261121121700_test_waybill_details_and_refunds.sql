begin;

alter table public.nova_poshta_test_waybills add column shipment_details jsonb;

-- Keep standalone fixtures working while saving the same destination as live creation.
create function public.create_nova_poshta_test_waybill(p_store_id uuid, p_order_id uuid, p_shipment jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  result jsonb;
  destination jsonb := p_shipment->'destination';
  expected_cod bigint := (p_shipment->>'codMinor')::bigint;
  actual_cod bigint;
begin
  result := public.create_nova_poshta_test_waybill(p_store_id, p_order_id);
  if (result->>'existing')::boolean then return result; end if;
  select s.cod_minor into actual_cod from public.merged_order_shipping(p_order_id) s;
  if p_order_id is null or expected_cod is distinct from actual_cod then
    raise exception 'COD amount changed. Reopen the shipment.';
  end if;
  update public.nova_poshta_test_waybills set shipment_details = p_shipment
    where store_id = p_store_id and id = (result->>'documentRef')::uuid;
  update public.orders o set
    delivery_city_ref = coalesce(destination->>'delivery_city_ref', o.delivery_city_ref),
    delivery_city = coalesce(destination->>'delivery_city', o.delivery_city),
    delivery_address_ref = coalesce(destination->>'delivery_address_ref', o.delivery_address_ref),
    delivery_address = coalesce(destination->>'delivery_address', o.delivery_address),
    delivery_service_type = coalesce(destination->>'delivery_service_type', o.delivery_service_type)
    where o.store_id = p_store_id and o.nova_poshta_ttn = result->>'ttn';
  return result;
end;
$$;
revoke all on function public.create_nova_poshta_test_waybill(uuid, uuid, jsonb) from public, anon;
grant execute on function public.create_nova_poshta_test_waybill(uuid, uuid, jsonb) to authenticated;

alter table public.order_cancellation_refunds drop constraint order_cancellation_refunds_method_check;
alter table public.order_cancellation_refunds add constraint order_cancellation_refunds_method_check
  check (method in ('manual', 'automatic', 'simulated'));

create function public.get_order_cancellation_refunds(p_order_ids uuid[], p_include_test boolean) returns table (
  order_id uuid, receipt_code text, currency text, amount integer, method text, status text, error text, automatic_available boolean, simulated boolean
)
language sql stable security definer set search_path = '' as $$
  select o.id, o.receipt_code, o.currency,
    coalesce(r.amount, case when o.payment_status = 'REFUNDED' or returned.amount >= o.total_price
      then returned.amount else o.total_price - returned.amount end::integer),
    r.method, coalesce(r.status, case when o.payment_status = 'REFUNDED' or returned.amount >= o.total_price
      then 'completed' end), r.error,
    not coalesce(o.payment_test_mode, o.monobank_test_mode) and o.payment_method = 'ONLINE' and returned.amount = 0 and exists (
      select 1 from public.payments p where p.order_id = o.id and p.status = 'PAID'
        and p.provider in ('MONOBANK', 'LIQPAY')
    ), coalesce(o.payment_test_mode, o.monobank_test_mode)
  from public.orders o
  left join public.order_cancellation_refunds r on r.order_id = o.id
  cross join lateral (select coalesce(sum(rr.amount), 0) as amount from public.order_returns rr where rr.order_id = o.id) returned
  where o.id = any(p_order_ids) and public.is_store_member(o.store_id)
    and o.status in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER')
    and (not coalesce(o.payment_test_mode, o.monobank_test_mode)
      or (p_include_test and o.payment_method = 'ONLINE'))
    and o.total_price > 0
    and (o.payment_status in ('PAID', 'REFUNDED') or r.id is not null)
  order by o.created_at, o.id;
$$;
revoke all on function public.get_order_cancellation_refunds(uuid[], boolean) from public, anon;
grant execute on function public.get_order_cancellation_refunds(uuid[], boolean) to authenticated;

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
  -- Keep the update and ledger entry in a single transaction.
  update public.order_cancellation_refunds set status = p_status, error = p_error, updated_at = now() where id = p_id;
  if p_status = 'completed' then
    insert into public.order_returns (id, order_id, amount, reason, author_id)
      values (p_id, target.id, operation.amount, case when operation.method = 'simulated'
        then 'Тестове повернення за скасоване замовлення'
        else 'Повернення за скасоване замовлення' end, operation.requested_by);
    insert into public.order_events (order_id, kind, new_value, author_id)
      values (target.id, 'return', operation.amount::text, operation.requested_by);
    update public.orders set payment_status = 'REFUNDED' where id = target.id;
    update public.payments set status = 'REFUNDED', updated_at = now()
      where order_id = target.id and status = 'PAID';
  end if;
  return p_status;
end;
$$;
revoke all on function public.finish_order_cancellation_refund(uuid, text, text) from public, anon, authenticated;
grant execute on function public.finish_order_cancellation_refund(uuid, text, text) to service_role;

create or replace function public.begin_order_cancellation_refund(
  p_order_id uuid, p_actor uuid, p_method text, p_amount integer
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  target public.orders;
  payment public.payments;
  operation public.order_cancellation_refunds;
  returned bigint;
  is_test boolean;
begin
  select * into target from public.orders where id = p_order_id for update;
  if not found or not exists (select from public.store_members
      where store_id = target.store_id and user_id = p_actor) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  is_test := coalesce(target.payment_test_mode, target.monobank_test_mode);
  if p_method is null or p_method not in ('manual', 'automatic', 'check', 'simulated') then
    raise exception 'Invalid refund method';
  end if;
  if target.status not in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER') then
    raise exception 'Only cancelled orders can be refunded';
  end if;
  if p_method = 'simulated' then
    if not is_test or target.payment_method <> 'ONLINE' then
      raise exception 'Test refunds require an online test order.';
    end if;
  elsif is_test then
    raise exception 'Only cancelled live orders can be refunded';
  end if;

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
    if p_method in ('manual', 'simulated') then
      return jsonb_build_object('status', public.finish_order_cancellation_refund(operation.id, 'completed'));
    end if;
  end if;
  return jsonb_build_object('status', operation.status, 'id', operation.id, 'amount', operation.amount,
    'currency', target.currency, 'provider', payment.provider, 'reference', payment.provider_order_id,
    'payment_id', payment.provider_payment_id, 'payment_test_mode', target.payment_test_mode);
end;
$$;
revoke all on function public.begin_order_cancellation_refund(uuid, uuid, text, integer) from public, anon, authenticated;
grant execute on function public.begin_order_cancellation_refund(uuid, uuid, text, integer) to service_role;

notify pgrst, 'reload schema';
commit;
