create table public.customer_push_broadcasts (
  id uuid primary key,
  store_id uuid not null references public.shop_settings(id) on delete cascade,
  message_hash bytea not null,
  recipient_count integer not null default 0
);
alter table public.customer_push_broadcasts enable row level security;
revoke all on public.customer_push_broadcasts from public, anon, authenticated, service_role;

create function public.crm_push_broadcast_audience(p_store_id uuid)
returns table(subscription_id uuid, user_id uuid)
language sql stable set search_path = '' as $$
  select s.id, s.user_id
  from public.customer_push_subscriptions s
  join public.crm_customer_keys k on k.store_id = p_store_id and k.key = 'user:' || s.user_id::text
  join auth.users u on u.id = s.user_id
  where u.deleted_at is null and not u.is_anonymous;
$$;

create function public.crm_push_broadcast_size(p_store_id uuid)
returns integer language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (select from public.store_members m
    where m.store_id = p_store_id and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then
    raise exception 'Manager access required' using errcode = '42501';
  end if;

  return (select count(distinct a.user_id)::integer from public.crm_push_broadcast_audience(p_store_id) a);
end;
$$;

create function public.queue_crm_push_broadcast(p_store_id uuid, p_request_id uuid, p_message text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  message text := btrim(p_message, E' \t\r\n');
  body_hash bytea;
  recipients integer;
begin
  if not exists (select from public.store_members m
    where m.store_id = p_store_id and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then
    raise exception 'Manager access required' using errcode = '42501';
  end if;
  if p_request_id is null or message is null or char_length(message) not between 1 and 500 then
    raise exception 'Enter a notification between 1 and 500 characters.' using errcode = '22023';
  end if;

  body_hash := extensions.digest(message, 'sha256');
  insert into public.customer_push_broadcasts(id, store_id, message_hash)
  values (p_request_id, p_store_id, body_hash) on conflict (id) do nothing;
  if not found then
    select b.recipient_count into recipients from public.customer_push_broadcasts b
    where b.id = p_request_id and b.store_id = p_store_id and b.message_hash = body_hash;
    if not found then raise insufficient_privilege; end if;
    return recipients;
  end if;

  -- Lock the current devices so an opt-out can safely remove pending deliveries after this transaction.
  with devices as materialized (
    select s.id, s.user_id
    from public.crm_push_broadcast_audience(p_store_id) a
    join public.customer_push_subscriptions s on s.id = a.subscription_id
    for key share of s
  ), notices as (
    insert into public.customer_notifications(store_id, user_id, kind, value)
    select distinct p_store_id, d.user_id, 'manual', message from devices d
    returning user_id
  ), queued as (
    insert into public.customer_push_deliveries(subscription_id, kind, path)
    select d.id, 'manual:' || message, '/account' from devices d join notices n on n.user_id = d.user_id
  )
  select count(*)::integer into recipients from notices;

  update public.customer_push_broadcasts set recipient_count = recipients where id = p_request_id;
  return recipients;
end;
$$;

revoke all on function public.crm_push_broadcast_audience(uuid), public.crm_push_broadcast_size(uuid),
  public.queue_crm_push_broadcast(uuid, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.crm_push_broadcast_size(uuid), public.queue_crm_push_broadcast(uuid, uuid, text) to authenticated;
notify pgrst, 'reload schema';
