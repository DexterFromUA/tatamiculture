create or replace function public.queue_customer_order_push() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.customer_push_deliveries(subscription_id, kind, path)
  select id,
    case when new.kind = 'status' and new.value is not null then 'status:' || new.value else new.kind end,
    '/receipt/' || new.receipt_code
  from public.customer_push_subscriptions where user_id = new.user_id;
  return new;
end;
$$;

-- A consolidated shipment can generate a waybill event for several receipts.
create unique index customer_push_one_waybill_per_device
  on public.customer_push_deliveries(subscription_id, kind)
  where kind like 'ttn_ready:%';

create function public.queue_customer_waybill_push() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  customer_id uuid;
  receipt_path text;
begin
  select o.user_id, '/receipt/' || o.receipt_code
    into customer_id, receipt_path from public.orders o where o.id = new.order_id;
  if customer_id is null then return new; end if;

  delete from public.customer_push_deliveries d
    using public.customer_push_subscriptions s
    where d.subscription_id = s.id and s.user_id = customer_id
      and d.path = receipt_path and d.kind like 'ttn_ready:%';

  if new.kind = 'ttn_linked' and new.new_value ~ '^[0-9]{14}$' then
    insert into public.customer_push_deliveries(subscription_id, kind, path)
    select id, 'ttn_ready:' || new.new_value, receipt_path
    from public.customer_push_subscriptions where user_id = customer_id
    on conflict (subscription_id, kind) where kind like 'ttn_ready:%' do nothing;
  end if;
  return new;
end;
$$;

revoke all on function public.queue_customer_waybill_push() from public, anon, authenticated, service_role;
create trigger queue_customer_waybill_push after insert on public.order_events
  for each row when (new.kind in ('ttn_linked', 'ttn_unlinked')) execute function public.queue_customer_waybill_push();
