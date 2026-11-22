create or replace function public.queue_customer_order_push() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  order_row public.orders;
  push_kind text;
  target_path text := '/receipt/' || new.receipt_code;
begin
  push_kind := new.kind;
  if new.kind in ('status', 'payment_status') and new.value is not null then
    push_kind := new.kind || ':' || new.value;
  end if;

  if new.kind = 'status' and new.value = 'IN_PROGRESS' and exists (
    select from public.orders o join public.order_events e on e.id = new.event_id
    where o.id = new.order_id and o.payment_method = 'CASH_ON_DELIVERY'
      and e.old_value is null
  ) then
    push_kind := 'status:IN_PROGRESS:cod';
  end if;

  if new.kind = 'status' and new.value = 'DELIVERED' and exists (
    select from public.orders o where o.id = new.order_id
      and o.nova_poshta_status_code in ('7', '8')
      and o.nova_poshta_ttn = current_setting('tatami.customer_push_tracking_ttn', true)
  ) then
    -- The tracking update queues the more useful pickup message.
    return new;
  end if;

  if new.kind = 'status' and new.value = 'COMPLETED' and exists (
    select from public.orders o where o.id = new.order_id
      and o.nova_poshta_status_code in ('9', '10', '11')
  ) then
    push_kind := 'status:COMPLETED:received';
  end if;

  if (new.kind = 'payment_status' and new.value = 'PAID')
    or (new.kind = 'status' and new.value in ('CANCELLED_BY_USER', 'CANCELLED_BY_STORE')) then
    delete from public.customer_push_deliveries d using public.customer_push_subscriptions s
    where d.subscription_id = s.id and s.user_id = new.user_id
      and d.kind = 'payment_retry:reserved:' || new.order_id::text;
  end if;

  if new.kind = 'payment_status' then
    select * into order_row from public.orders where id = new.order_id;
    if new.value = 'PENDING' and order_row.payment_method = 'CASH_ON_DELIVERY' then
      -- The order confirmation already covers the initial COD state.
      return new;
    elsif new.value = 'FAILED' and order_row.status in ('CANCELLED_BY_USER', 'CANCELLED_BY_STORE') then
      -- Cancelling an unpaid reservation also sets FAILED. It is no longer payable.
      return new;
    elsif new.value = 'FAILED' and order_row.status = 'PENDING' and order_row.payment_method = 'ONLINE' then
      push_kind := 'payment_retry:reserved:' || new.order_id::text;
      target_path := '/account#order-' || new.order_id::text;
    elsif new.value = 'REFUNDED' and exists (
      select from public.order_events e where e.order_id = new.order_id and e.kind = 'return'
        and e.created_at = new.created_at
    ) then
      -- A confirmed full refund already wrote a return event in this transaction.
      return new;
    end if;
  end if;

  insert into public.customer_push_deliveries(subscription_id, kind, path)
  select id, push_kind, target_path
  from public.customer_push_subscriptions where user_id = new.user_id;
  return new;
end;
$$;

create function public.queue_customer_checkout_failure() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'PAID' then
    delete from public.customer_push_deliveries d using public.customer_push_subscriptions s
    where d.subscription_id = s.id and s.user_id = new.user_id
      and d.kind = 'payment_retry:checkout:' || new.id::text;
    return new;
  end if;
  if new.user_id is not null and new.provider_order_id is not null
    and not exists (select from public.orders o where o.id = new.id) then
    insert into public.customer_push_deliveries(subscription_id, kind, path)
    select id, 'payment_retry:checkout:' || new.id::text, '/checkout'
    from public.customer_push_subscriptions where user_id = new.user_id;
  end if;
  return new;
end;
$$;

create trigger queue_customer_checkout_failure after update of status on public.online_checkouts
  for each row when ((old.status = 'PENDING' and new.status = 'FAILED')
    or (old.status is distinct from new.status and new.status = 'PAID'))
  execute function public.queue_customer_checkout_failure();

create unique index customer_push_one_shipment_update_per_device
  on public.customer_push_deliveries(subscription_id, kind)
  where kind like 'pickup:%' or kind like 'shipment:%';

create function public.queue_customer_shipment_push() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  paid_storage_from text := '';
  push_kind text;
begin
  if new.user_id is null or coalesce(new.nova_poshta_ttn, '') !~ '^[0-9]{14}$'
    or new.status in ('COMPLETED', 'CANCELLED_BY_USER', 'CANCELLED_BY_STORE') then
    return new;
  end if;

  if new.nova_poshta_status_code in ('7', '8') then
    if new.nova_poshta_status_code = '7'
      and new.nova_poshta_ttn = current_setting('tatami.customer_push_tracking_ttn', true) then
      paid_storage_from := coalesce(current_setting('tatami.customer_push_paid_storage_from', true), '');
    end if;
    push_kind := 'pickup:' || new.nova_poshta_status_code || ':' || paid_storage_from;
  elsif new.nova_poshta_status_code in ('4', '5', '6', '101')
    and coalesce(old.nova_poshta_status_code, '') not in ('4', '5', '6', '101')
    and new.status not in ('IN_TRANSIT', 'DELIVERED') then
    push_kind := 'shipment:in_transit';
  elsif new.nova_poshta_status_code in ('9', '10', '11')
    and coalesce(old.nova_poshta_status_code, '') not in ('9', '10', '11') then
    push_kind := 'shipment:received';
  elsif new.nova_poshta_status_code in ('102', '103')
    and coalesce(old.nova_poshta_status_code, '') not in ('102', '103') then
    push_kind := 'shipment:refused';
  else
    push_kind := case new.nova_poshta_status_code
      when '104' then 'shipment:rerouted'
      when '105' then 'shipment:storage_ended'
      when '111' then 'shipment:missed'
      when '112' then 'shipment:rescheduled'
    end;
  end if;
  if push_kind is null then return new; end if;

  insert into public.customer_push_deliveries(subscription_id, kind, path)
  select id, push_kind || ':' || new.nova_poshta_ttn, '/receipt/' || new.receipt_code
  from public.customer_push_subscriptions where user_id = new.user_id
  on conflict (subscription_id, kind) where kind like 'pickup:%' or kind like 'shipment:%' do nothing;
  return new;
end;
$$;

create trigger queue_customer_shipment_push after update of nova_poshta_status_code on public.orders
  for each row when (new.nova_poshta_status_code is not null and old.nova_poshta_status_code is distinct from new.nova_poshta_status_code)
  execute function public.queue_customer_shipment_push();

create function public.apply_nova_poshta_tracking_with_storage(
  p_store_id uuid, p_ttn text, p_code text, p_status text, p_checked_at timestamptz,
  p_paid_storage_from date
) returns boolean language plpgsql set search_path = '' as $$
declare
  changed boolean;
begin
  perform set_config('tatami.customer_push_tracking_ttn', coalesce(p_ttn, ''), true);
  perform set_config('tatami.customer_push_paid_storage_from', coalesce(to_char(p_paid_storage_from, 'YYYY-MM-DD'), ''), true);
  changed := public.apply_nova_poshta_tracking(p_store_id, p_ttn, p_code, p_status, p_checked_at);
  perform set_config('tatami.customer_push_tracking_ttn', '', true);
  perform set_config('tatami.customer_push_paid_storage_from', '', true);
  return changed;
end;
$$;

revoke all on function public.queue_customer_checkout_failure(), public.queue_customer_shipment_push(),
  public.apply_nova_poshta_tracking_with_storage(uuid, text, text, text, timestamptz, date)
  from public, anon, authenticated, service_role;
grant execute on function public.apply_nova_poshta_tracking_with_storage(uuid, text, text, text, timestamptz, date)
  to service_role;
notify pgrst, 'reload schema';
