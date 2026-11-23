-- The legacy SMS-named setting controlled restock subscriptions and their existing push channel.
alter table public.shop_settings
  add column restock_sms_enabled boolean not null default false,
  add column order_push_enabled boolean not null default true,
  add column order_sms_enabled boolean not null default false;

create function public.set_customer_notification_channel(p_store_id uuid, p_topic text, p_channel text, p_enabled boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare saved public.shop_settings;
begin
  if p_topic is null or p_topic not in ('restock', 'order')
    or p_channel is null or p_channel not in ('push', 'sms') or p_enabled is null then
    raise invalid_parameter_value;
  end if;
  update public.shop_settings s set
    sms_notifications_enabled = case when (p_topic, p_channel) = ('restock', 'push') then p_enabled else s.sms_notifications_enabled end,
    restock_sms_enabled = case when (p_topic, p_channel) = ('restock', 'sms') then p_enabled else s.restock_sms_enabled end,
    order_push_enabled = case when (p_topic, p_channel) = ('order', 'push') then p_enabled else s.order_push_enabled end,
    order_sms_enabled = case when (p_topic, p_channel) = ('order', 'sms') then p_enabled else s.order_sms_enabled end
  where s.id = p_store_id and exists (select from public.store_members m
    where m.store_id = s.id and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER'))
  returning s.* into saved;
  if not found then raise insufficient_privilege; end if;
  if not p_enabled and p_channel = 'sms' then
    delete from public.customer_sms_deliveries d where d.store_id = p_store_id and d.topic = p_topic and d.claimed_at is null;
  elsif not p_enabled and p_topic = 'restock' then
    delete from public.customer_push_deliveries d using public.products p
      where d.kind = 'restock' and d.path = '/product/' || p.id::text and p.store_id = p_store_id;
  elsif not p_enabled then
    delete from public.customer_push_deliveries d using public.orders o
      where (d.kind like 'status:%' or d.kind like 'pickup:%' or d.kind like 'shipment:%')
        and d.path = '/receipt/' || o.receipt_code and o.store_id = p_store_id;
  end if;
  return jsonb_build_object('restockPush', saved.sms_notifications_enabled, 'restockSms', saved.restock_sms_enabled,
    'orderPush', saved.order_push_enabled, 'orderSms', saved.order_sms_enabled);
end;
$$;

create function public.notification_sms_phone(p_phone text)
returns text language plpgsql immutable set search_path = '' as $$
begin
  return ltrim(public.validate_checkout_phone(p_phone), '+');
exception when invalid_parameter_value then return null;
end;
$$;

create table public.crm_staff_sms_preferences (
  store_id uuid not null,
  user_id uuid not null,
  primary key (store_id, user_id),
  foreign key (store_id, user_id) references public.store_members(store_id, user_id) on delete cascade
);
alter table public.crm_staff_sms_preferences enable row level security;
revoke all on public.crm_staff_sms_preferences from public, anon, authenticated, service_role;

create table public.customer_sms_deliveries (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.shop_settings(id) on delete cascade,
  phone text not null check (phone ~ '^[1-9][0-9]{7,14}$'),
  body text not null check (char_length(body) between 1 and 500),
  topic text not null check (topic in ('manual', 'order', 'restock', 'staff')),
  staff_user_id uuid,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  result text check (result in ('accepted', 'failed')),
  foreign key (store_id, staff_user_id) references public.crm_staff_sms_preferences(store_id, user_id) on delete cascade
);
create index customer_sms_deliveries_pending on public.customer_sms_deliveries(created_at, id) where claimed_at is null;
create index customer_sms_deliveries_staff on public.customer_sms_deliveries(store_id, staff_user_id) where staff_user_id is not null;
alter table public.customer_sms_deliveries enable row level security;
revoke all on public.customer_sms_deliveries from public, anon, authenticated, service_role;

create table public.crm_sms_requests (
  id uuid primary key,
  store_id uuid not null references public.shop_settings(id) on delete cascade,
  payload_hash bytea not null,
  recipient_count integer not null default 0
);
alter table public.crm_sms_requests enable row level security;
revoke all on public.crm_sms_requests from public, anon, authenticated, service_role;

create function public.crm_sms_numbers(p_store_id uuid, p_customer_id uuid)
returns setof text language sql stable set search_path = '' as $$
  select distinct n.phone
  from public.crm_customers c cross join lateral (select public.notification_sms_phone(c.phone) as phone) n
  where c.store_id = p_store_id and (p_customer_id is null or c.id = p_customer_id) and n.phone is not null;
$$;

create function public.crm_sms_audience(p_store_id uuid, p_customer_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare recipient_count integer; recipient_phone text;
begin
  if not exists (select from public.store_members m where m.store_id = p_store_id
    and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then raise insufficient_privilege; end if;
  select count(*)::integer, case when p_customer_id is not null then max(phone) end
  into recipient_count, recipient_phone from public.crm_sms_numbers(p_store_id, p_customer_id) phone;
  return jsonb_build_object('count', recipient_count, 'phone', case when recipient_phone is not null then '+' || recipient_phone end,
    'confirmed', p_customer_id is not null and recipient_count > 0 and public.crm_customer_phone_confirmed(p_store_id, p_customer_id));
end;
$$;

create function public.queue_crm_sms(p_store_id uuid, p_request_id uuid, p_message text, p_expected_count integer,
  p_customer_id uuid default null, p_expected_phone text default null)
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
  body_hash := extensions.digest(jsonb_build_array(p_customer_id, p_expected_phone, message)::text, 'sha256');
  insert into public.crm_sms_requests(id, store_id, payload_hash)
  values (p_request_id, p_store_id, body_hash) on conflict (id) do nothing;
  if not found then
    select r.recipient_count into queued from public.crm_sms_requests r
    where r.id = p_request_id and r.store_id = p_store_id and r.payload_hash = body_hash;
    if not found then raise insufficient_privilege; end if;
    return queued;
  end if;

  with deliveries as (
    insert into public.customer_sms_deliveries(store_id, phone, body, topic)
    select p_store_id, phone, message, 'manual' from public.crm_sms_numbers(p_store_id, p_customer_id) phone
    where p_customer_id is null or phone = public.notification_sms_phone(p_expected_phone)
    returning phone
  ), notices as (
    insert into public.customer_notifications(store_id, user_id, kind, value)
    select distinct p_store_id, u.id, 'manual', message
    from deliveries d
    join auth.users u on u.phone in (d.phone, '+' || d.phone)
    join public.crm_customer_keys k on k.store_id = p_store_id and k.key = 'user:' || u.id::text
      and (p_customer_id is null or k.customer_id = p_customer_id)
    where u.phone_confirmed_at is not null and u.deleted_at is null and not u.is_anonymous
  ) select count(*)::integer into queued from deliveries;
  if queued <> p_expected_count then
    raise sqlstate 'PT409' using message = 'SMS recipient list changed. Check it before sending.';
  end if;
  update public.crm_sms_requests set recipient_count = queued where id = p_request_id;
  return queued;
end;
$$;

create function public.set_crm_staff_sms_enabled(p_store_id uuid, p_user_id uuid, p_enabled boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select from public.store_members m where m.store_id = p_store_id and m.user_id = auth.uid()
    and m.role in ('OWNER', 'MANAGER')) then raise insufficient_privilege; end if;
  if p_enabled is null then raise invalid_parameter_value; end if;
  perform 1 from public.store_members m where m.store_id = p_store_id and m.user_id = p_user_id
    and m.role in ('OWNER', 'MANAGER') for update;
  if not found then raise insufficient_privilege; end if;
  if p_enabled then
    insert into public.crm_staff_sms_preferences values (p_store_id, p_user_id) on conflict do nothing;
  else
    delete from public.crm_staff_sms_preferences where store_id = p_store_id and user_id = p_user_id;
  end if;
end;
$$;

drop function public.crm_staff_push_settings(uuid);
create function public.crm_staff_push_settings(p_store_id uuid)
returns table(user_id uuid, display_name text, role public.staff_role, enabled boolean, has_subscription boolean,
  sms_enabled boolean, has_sms_phone boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (select from public.store_members m where m.store_id = p_store_id
    and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then raise insufficient_privilege; end if;
  return query
  select m.user_id, coalesce(nullif(btrim(profile.name), ''), nullif(u.email::text, ''),
    '•••• ' || right(nullif(u.phone, ''), 4)), m.role, prefs.user_id is not null,
    exists (select from public.customer_push_subscriptions s where s.user_id = m.user_id),
    sms.user_id is not null, u.phone_confirmed_at is not null and public.notification_sms_phone(u.phone) is not null
  from public.store_members m
  join auth.users u on u.id = m.user_id
  left join public.profiles profile on profile.id = m.user_id
  left join public.crm_staff_push_preferences prefs on prefs.store_id = m.store_id and prefs.user_id = m.user_id
  left join public.crm_staff_sms_preferences sms on sms.store_id = m.store_id and sms.user_id = m.user_id
  where m.store_id = p_store_id and m.role in ('OWNER', 'MANAGER') and u.deleted_at is null and not u.is_anonymous
  order by m.role, 2, m.user_id;
end;
$$;

create or replace function public.clear_demoted_staff_push_preference() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.crm_staff_push_preferences where store_id = new.store_id and user_id = new.user_id;
  delete from public.crm_staff_sms_preferences where store_id = new.store_id and user_id = new.user_id;
  return new;
end;
$$;

create function public.queue_order_sms() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  destination text;
  status_text text;
  starts_work boolean;
begin
  if new.split_origin_id is not null then return new; end if;
  if tg_op = 'UPDATE' then
    if old.status is not distinct from new.status then return new; end if;
    starts_work := new.is_new and not old.is_new and new.status = 'IN_PROGRESS';
  else
    starts_work := new.status = 'IN_PROGRESS' and (new.payment_method = 'CASH_ON_DELIVERY' or new.payment_status = 'PAID');
    if not starts_work then return new; end if;
  end if;

  if starts_work then
    insert into public.customer_sms_deliveries(store_id, phone, body, topic, staff_user_id)
    select new.store_id, n.phone, 'Tatami: Нове замовлення в CRM.', 'staff', p.user_id
    from public.crm_staff_sms_preferences p
    join public.store_members m on (m.store_id, m.user_id) = (p.store_id, p.user_id)
    join auth.users u on u.id = m.user_id
    cross join lateral (select public.notification_sms_phone(u.phone) as phone) n
    where p.store_id = new.store_id and m.role in ('OWNER', 'MANAGER') and u.phone_confirmed_at is not null
      and u.deleted_at is null and not u.is_anonymous and n.phone is not null
    for key share of p;
  end if;

  if not exists (select from public.shop_settings where id = new.store_id and order_sms_enabled) then return new; end if;
  destination := public.notification_sms_phone(new.customer_phone);
  if destination is null then return new; end if;
  status_text := case new.status::text
    when 'IN_PROGRESS' then 'Замовлення в обробці.'
    when 'WAITING_FOR_STOCK' then 'Замовлення очікує надходження.'
    when 'PREPARING_SHIPMENT' then 'Замовлення готується до відправлення.'
    when 'IN_TRANSIT' then 'Замовлення в дорозі.'
    when 'READY_FOR_PICKUP' then 'Замовлення готове до видачі.'
    when 'DELIVERED' then 'Замовлення доставлено.'
    when 'COMPLETED' then 'Замовлення завершено.'
    when 'CANCELLED_BY_USER' then 'Замовлення скасовано.'
    when 'CANCELLED_BY_STORE' then 'Замовлення скасовано.'
  end;
  if status_text is not null then
    insert into public.customer_sms_deliveries(store_id, phone, body, topic)
    values (new.store_id, destination, 'Tatami: ' || status_text, 'order');
  end if;
  return new;
end;
$$;
create trigger queue_order_sms after insert or update of status on public.orders
  for each row execute function public.queue_order_sms();

create function public.queue_restock_sms() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.customer_sms_deliveries(store_id, phone, body, topic)
  select p.store_id, n.phone, 'Tatami: ' || left(p.name, 90) || ' (' || left(v.name, 30) || ') знову в наявності.', 'restock'
  from public.product_variants v join public.products p on p.id = v.product_id
  join public.shop_settings sh on sh.id = p.store_id
  join auth.users u on u.id = new.user_id
  cross join lateral (select public.notification_sms_phone(u.phone) as phone) n
  where v.id = new.variant_id and sh.restock_sms_enabled and u.phone_confirmed_at is not null
    and u.deleted_at is null and not u.is_anonymous and n.phone is not null;
  return new;
end;
$$;
create trigger queue_restock_sms after update of notified_at on public.restock_subscriptions
  for each row when (old.notified_at is null and new.notified_at is not null) execute function public.queue_restock_sms();

-- Preserve manual pushes, payment events and discount notices when a status channel is disabled.
create function public.filter_customer_notification_push() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.kind = 'restock' and exists (
    select from public.products p join public.shop_settings sh on sh.id = p.store_id
    where p.id = split_part(new.path, '/', 3)::uuid and not sh.sms_notifications_enabled
  ) then return null; end if;
  if (new.kind like 'status:%' or new.kind like 'shipment:%' or new.kind like 'pickup:%') and exists (
    select from public.orders o join public.shop_settings sh on sh.id = o.store_id
    where o.receipt_code = split_part(new.path, '/', 3) and not sh.order_push_enabled
  ) then return null; end if;
  return new;
end;
$$;

create trigger filter_customer_notification_push before insert on public.customer_push_deliveries
  for each row execute function public.filter_customer_notification_push();

create function public.customer_sms_job_authorized(p_token text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select from public.customer_push_job_secret where
    extensions.digest(token, 'sha256') = extensions.digest(p_token, 'sha256'));
$$;

create function public.claim_customer_sms_deliveries(p_token text)
returns table(id uuid, phone text, body text) language plpgsql security definer set search_path = '' as $$
begin
  if not public.customer_sms_job_authorized(p_token) then raise insufficient_privilege; end if;
  return query with batch as (
    select d.id from public.customer_sms_deliveries d
    join public.shop_settings sh on sh.id = d.store_id
    where d.claimed_at is null and d.created_at > now() - interval '1 day'
      and (d.topic <> 'order' or sh.order_sms_enabled) and (d.topic <> 'restock' or sh.restock_sms_enabled)
    order by d.created_at, d.id limit 30 for update of d skip locked
  )
  update public.customer_sms_deliveries d set claimed_at = now()
  from batch where d.id = batch.id returning d.id, d.phone, d.body;
end;
$$;

create function public.complete_customer_sms_delivery(p_token text, p_id uuid, p_accepted boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.customer_sms_job_authorized(p_token) then raise insufficient_privilege; end if;
  update public.customer_sms_deliveries set result = case when p_accepted then 'accepted' else 'failed' end
  where id = p_id and claimed_at is not null and result is null;
end;
$$;

create function public.run_customer_sms_job() returns bigint
language plpgsql security definer set search_path = '' as $$
declare request_id bigint;
begin
  delete from public.customer_sms_deliveries where created_at <= now() - interval '1 day';
  if not exists (select from public.customer_sms_deliveries d join public.shop_settings sh on sh.id = d.store_id
    where d.claimed_at is null and (d.topic <> 'order' or sh.order_sms_enabled)
      and (d.topic <> 'restock' or sh.restock_sms_enabled)) then return null; end if;
  select net.http_post(
    url := s.project_url || '/functions/v1/customer-sms',
    headers := jsonb_build_object('X-Push-Job', j.token, 'Content-Type', 'application/json'),
    body := '{}'::jsonb, timeout_milliseconds := 115000
  ) into request_id from public.nova_poshta_tracking_schedule s cross join public.customer_push_job_secret j
  where s.project_url is not null;
  return request_id;
end;
$$;

revoke all on function public.set_customer_notification_channel(uuid,text,text,boolean), public.notification_sms_phone(text),
  public.crm_sms_numbers(uuid,uuid), public.crm_sms_audience(uuid,uuid), public.queue_crm_sms(uuid,uuid,text,integer,uuid,text),
  public.set_crm_staff_sms_enabled(uuid,uuid,boolean), public.crm_staff_push_settings(uuid), public.queue_order_sms(),
  public.queue_restock_sms(), public.filter_customer_notification_push(), public.customer_sms_job_authorized(text), public.claim_customer_sms_deliveries(text),
  public.complete_customer_sms_delivery(text,uuid,boolean), public.run_customer_sms_job()
from public, anon, authenticated, service_role;
grant execute on function public.set_customer_notification_channel(uuid,text,text,boolean),
  public.crm_sms_audience(uuid,uuid), public.queue_crm_sms(uuid,uuid,text,integer,uuid,text),
  public.set_crm_staff_sms_enabled(uuid,uuid,boolean), public.crm_staff_push_settings(uuid) to authenticated;
grant execute on function public.customer_sms_job_authorized(text), public.claim_customer_sms_deliveries(text),
  public.complete_customer_sms_delivery(text,uuid,boolean) to service_role;

select cron.schedule('tatami-customer-sms', '* * * * *', 'select public.run_customer_sms_job()');
notify pgrst, 'reload schema';
