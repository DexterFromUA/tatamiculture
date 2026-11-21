begin;

create table public.order_cancellation_refunds (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders(id) on delete cascade,
  payment_id uuid references public.payments(id) on delete set null,
  requested_by uuid references auth.users(id) on delete set null,
  method text not null check (method in ('manual', 'automatic')),
  status text not null check (status in ('processing', 'failed', 'completed')),
  amount integer not null check (amount > 0),
  error text,
  updated_at timestamptz not null default now()
);
alter table public.order_cancellation_refunds enable row level security;
revoke all on public.order_cancellation_refunds from public, anon, authenticated, service_role;

create function public.get_order_cancellation_refunds(p_order_ids uuid[]) returns table (
  order_id uuid, receipt_code text, currency text, amount integer, method text, status text, error text, automatic_available boolean
)
language sql stable security definer set search_path = '' as $$
  select o.id, o.receipt_code, o.currency,
    coalesce(r.amount, case when o.payment_status = 'REFUNDED' or returned.amount >= o.total_price
      then returned.amount else o.total_price - returned.amount end::integer),
    r.method, coalesce(r.status, case when o.payment_status = 'REFUNDED' or returned.amount >= o.total_price
      then 'completed' end), r.error,
    o.payment_method = 'ONLINE' and returned.amount = 0 and exists (
      select 1 from public.payments p where p.order_id = o.id and p.status = 'PAID'
        and p.provider in ('MONOBANK', 'LIQPAY')
    )
  from public.orders o
  left join public.order_cancellation_refunds r on r.order_id = o.id
  cross join lateral (select coalesce(sum(rr.amount), 0) as amount from public.order_returns rr where rr.order_id = o.id) returned
  where o.id = any(p_order_ids) and public.is_store_member(o.store_id)
    and o.status in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER')
    and not coalesce(o.payment_test_mode, o.monobank_test_mode)
    and o.total_price > 0
    and (o.payment_status in ('PAID', 'REFUNDED') or r.id is not null)
  order by o.created_at, o.id;
$$;
revoke all on function public.get_order_cancellation_refunds(uuid[]) from public, anon;
grant execute on function public.get_order_cancellation_refunds(uuid[]) to authenticated;

-- Both paths lock the source order. The operation ID is also sent to Monobank
-- so a retry of a status check can find this specific refund.
create function public.finish_order_cancellation_refund(p_id uuid, p_status text, p_error text default null)
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
revoke all on function public.finish_order_cancellation_refund(uuid, text, text) from public, anon, authenticated;
grant execute on function public.finish_order_cancellation_refund(uuid, text, text) to service_role;

create function public.begin_order_cancellation_refund(
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
  if p_method not in ('manual', 'automatic', 'check') then raise exception 'Invalid refund method'; end if;

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
revoke all on function public.begin_order_cancellation_refund(uuid, uuid, text, integer) from public, anon, authenticated;
grant execute on function public.begin_order_cancellation_refund(uuid, uuid, text, integer) to service_role;

create function public.pending_order_cancellation_refund(p_provider text, p_reference text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', r.id, 'amount', r.amount, 'currency', o.currency,
    'provider', p.provider, 'reference', p.provider_order_id, 'payment_id', p.provider_payment_id,
    'payment_test_mode', o.payment_test_mode)
  from public.order_cancellation_refunds r
  join public.payments p on p.id = r.payment_id
  join public.orders o on o.id = r.order_id
  where r.status = 'processing' and p.provider = p_provider and p.provider_order_id = p_reference;
$$;
revoke all on function public.pending_order_cancellation_refund(text, text) from public, anon, authenticated;
grant execute on function public.pending_order_cancellation_refund(text, text) to service_role;

create function public.protect_processing_order_refund() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select from public.order_cancellation_refunds where order_id = old.id and status = 'processing') then
    raise exception 'Wait for the refund result before changing this order';
  end if;
  if old.payment_status = 'REFUNDED' and (new.payment_status <> 'REFUNDED'
    or (old.status::text like 'CANCELLED%' and new.status::text not like 'CANCELLED%')) then
    raise exception 'This order has already been refunded';
  end if;
  return new;
end;
$$;
create trigger protect_processing_order_refund before update of status, payment_status on public.orders
for each row when (old.status is distinct from new.status or old.payment_status is distinct from new.payment_status)
execute function public.protect_processing_order_refund();

create function public.protect_processing_refund_ledger() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform 1 from public.orders where id = new.order_id for update;
  if exists (select from public.order_cancellation_refunds where order_id = new.order_id and status = 'processing') then
    raise exception 'Wait for the refund result before recording another refund';
  end if;
  return new;
end;
$$;
create trigger protect_processing_refund_ledger before insert on public.order_returns
for each row execute function public.protect_processing_refund_ledger();
notify pgrst, 'reload schema';

commit;
