-- Keep existing RPC calls working through default arguments.
-- A null selection means all customers. An empty array selects nobody.
drop function public.queue_crm_push_broadcast(uuid, uuid, text);
drop function public.crm_push_broadcast_size(uuid);
drop function public.crm_push_broadcast_audience(uuid);
drop function public.queue_crm_sms(uuid, uuid, text, integer, uuid, text);
drop function public.crm_sms_audience(uuid, uuid);
drop function public.crm_sms_numbers(uuid, uuid);

create function public.crm_push_broadcast_audience(p_store_id uuid, p_customer_ids uuid[])
returns table(subscription_id uuid, user_id uuid)
language sql stable set search_path = '' as $$
  select s.id, s.user_id
  from public.customer_push_subscriptions s
  join public.crm_customer_keys k on k.store_id = p_store_id and k.key = 'user:' || s.user_id::text
  join auth.users u on u.id = s.user_id
  where u.deleted_at is null and not u.is_anonymous
    and (p_customer_ids is null or k.customer_id = any(p_customer_ids));
$$;

create function public.crm_push_broadcast_size(p_store_id uuid, p_customer_ids uuid[] default null)
returns integer language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (select from public.store_members m
    where m.store_id = p_store_id and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then
    raise exception 'Manager access required' using errcode = '42501';
  end if;

  return (select count(distinct a.user_id)::integer from public.crm_push_broadcast_audience(p_store_id, p_customer_ids) a);
end;
$$;

create function public.queue_crm_push_broadcast(p_store_id uuid, p_request_id uuid, p_message text, p_customer_ids uuid[] default null)
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

  if p_customer_ids is not null then
    p_customer_ids := array(select distinct id from unnest(p_customer_ids) as selected(id) order by id);
  end if;
  body_hash := extensions.digest(case when p_customer_ids is null then message
    else jsonb_build_array(p_customer_ids, message)::text end, 'sha256');
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
    from public.crm_push_broadcast_audience(p_store_id, p_customer_ids) a
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

create function public.crm_sms_numbers(p_store_id uuid, p_customer_id uuid, p_customer_ids uuid[])
returns setof text language sql stable set search_path = '' as $$
  select distinct n.phone
  from public.crm_customers c cross join lateral (select public.notification_sms_phone(c.phone) as phone) n
  where c.store_id = p_store_id and (p_customer_id is null or c.id = p_customer_id)
    and (p_customer_ids is null or c.id = any(p_customer_ids)) and n.phone is not null;
$$;

create function public.crm_sms_audience(p_store_id uuid, p_customer_id uuid default null, p_customer_ids uuid[] default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare recipient_count integer; recipient_phone text;
begin
  if not exists (select from public.store_members m where m.store_id = p_store_id
    and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then raise insufficient_privilege; end if;
  select count(*)::integer, case when p_customer_id is not null then max(phone) end
  into recipient_count, recipient_phone from public.crm_sms_numbers(p_store_id, p_customer_id, p_customer_ids) phone;
  return jsonb_build_object('count', recipient_count, 'phone', case when recipient_phone is not null then '+' || recipient_phone end,
    'confirmed', p_customer_id is not null and recipient_count > 0 and public.crm_customer_phone_confirmed(p_store_id, p_customer_id));
end;
$$;

create function public.queue_crm_sms(p_store_id uuid, p_request_id uuid, p_message text, p_expected_count integer,
  p_customer_id uuid default null, p_expected_phone text default null, p_customer_ids uuid[] default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  message text := btrim(p_message, E' \t\r\n');
  body_hash bytea;
  queued integer;
begin
  if not exists (select from public.store_members m where m.store_id = p_store_id
    and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then raise insufficient_privilege; end if;
  if p_request_id is null or message is null or char_length(message) not between 1 and 500
    or p_expected_count is null or p_expected_count < 1 then raise invalid_parameter_value; end if;
  if p_customer_ids is not null then
    p_customer_ids := array(select distinct id from unnest(p_customer_ids) as selected(id) order by id);
  end if;
  body_hash := extensions.digest(case when p_customer_ids is null
    then jsonb_build_array(p_customer_id, p_expected_phone, message)::text
    else jsonb_build_array(p_customer_ids, p_customer_id, p_expected_phone, message)::text end, 'sha256');
  insert into public.crm_sms_requests(id, store_id, payload_hash)
  values (p_request_id, p_store_id, body_hash) on conflict (id) do nothing;
  if not found then
    select r.recipient_count into queued from public.crm_sms_requests r
    where r.id = p_request_id and r.store_id = p_store_id and r.payload_hash = body_hash;
    if not found then raise insufficient_privilege; end if;
    return queued;
  end if;

  insert into public.customer_sms_deliveries(store_id, phone, body, topic)
  select p_store_id, phone, message, 'manual' from public.crm_sms_numbers(p_store_id, p_customer_id, p_customer_ids) phone
  where p_customer_id is null or phone = public.notification_sms_phone(p_expected_phone);
  get diagnostics queued = row_count;
  if queued <> p_expected_count then
    raise sqlstate 'PT409' using message = 'SMS recipient list changed. Check it before sending.';
  end if;
  update public.crm_sms_requests set recipient_count = queued where id = p_request_id;
  return queued;
end;
$$;

revoke all on function public.crm_push_broadcast_audience(uuid, uuid[]),
  public.crm_push_broadcast_size(uuid, uuid[]), public.queue_crm_push_broadcast(uuid, uuid, text, uuid[]),
  public.crm_sms_numbers(uuid, uuid, uuid[]), public.crm_sms_audience(uuid, uuid, uuid[]),
  public.queue_crm_sms(uuid, uuid, text, integer, uuid, text, uuid[])
  from public, anon, authenticated, service_role;
grant execute on function public.crm_push_broadcast_size(uuid, uuid[]),
  public.queue_crm_push_broadcast(uuid, uuid, text, uuid[]), public.crm_sms_audience(uuid, uuid, uuid[]),
  public.queue_crm_sms(uuid, uuid, text, integer, uuid, text, uuid[]) to authenticated;

notify pgrst, 'reload schema';
