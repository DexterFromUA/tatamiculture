create table public.customer_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth_secret text not null,
  language text not null check (language in ('uk', 'en'))
);
create index customer_push_subscriptions_user on public.customer_push_subscriptions(user_id);

create table public.customer_push_deliveries (
  id uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references public.customer_push_subscriptions(id) on delete cascade,
  kind text not null,
  path text not null,
  created_at timestamptz not null default now(),
  next_attempt_at timestamptz not null default now(),
  attempts integer not null default 0
);
create index customer_push_deliveries_due on public.customer_push_deliveries(next_attempt_at)
  where attempts < 4;

create table public.customer_push_job_secret (
  singleton boolean primary key default true check (singleton),
  token text not null default encode(extensions.gen_random_bytes(32), 'hex')
);
insert into public.customer_push_job_secret default values;

alter table public.customer_push_subscriptions enable row level security;
alter table public.customer_push_deliveries enable row level security;
alter table public.customer_push_job_secret enable row level security;
revoke all on public.customer_push_subscriptions, public.customer_push_deliveries, public.customer_push_job_secret
  from public, anon, authenticated, service_role;
grant delete on public.customer_push_subscriptions, public.customer_push_deliveries to service_role;
grant select(id) on public.customer_push_subscriptions, public.customer_push_deliveries to service_role;

create function public.set_customer_push_subscription(
  p_endpoint text, p_p256dh text default null, p_auth text default null, p_language text default 'uk'
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise insufficient_privilege; end if;
  if p_p256dh is null and p_auth is null then
    delete from public.customer_push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
    return;
  end if;
  if p_endpoint is null or length(p_endpoint) > 2048
    or p_endpoint !~ '^https://((web[.]|[a-z0-9-]+[.])?push[.]apple[.]com|fcm[.]googleapis[.]com|updates[.]push[.]services[.]mozilla[.]com|[a-z0-9-]+[.]notify[.]windows[.]com)/[[:graph:]]+$'
    or p_p256dh is null or p_p256dh !~ '^[A-Za-z0-9_-]{87}=?$'
    or p_auth is null or p_auth !~ '^[A-Za-z0-9_-]{22}={0,2}$' then
    raise exception 'Invalid push subscription';
  end if;
  -- An installation may be reused after signing in to a different account.
  delete from public.customer_push_subscriptions where endpoint = p_endpoint and user_id <> auth.uid();
  insert into public.customer_push_subscriptions (endpoint, user_id, p256dh, auth_secret, language)
  values (p_endpoint, auth.uid(), rtrim(p_p256dh, '='), rtrim(p_auth, '='), case when p_language = 'en' then 'en' else 'uk' end)
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth_secret = excluded.auth_secret, language = excluded.language
    where customer_push_subscriptions.user_id = auth.uid();
end;
$$;

create function public.has_customer_push_subscription(p_endpoint text) returns boolean
  language sql stable security definer set search_path = '' as $$
  select exists(select from public.customer_push_subscriptions where endpoint = p_endpoint and user_id = auth.uid());
$$;

create function public.queue_customer_order_push() returns trigger
  language plpgsql security definer set search_path = '' as $$
begin
  insert into public.customer_push_deliveries(subscription_id, kind, path)
  select id, new.kind, '/receipt/' || new.receipt_code
  from public.customer_push_subscriptions where user_id = new.user_id;
  return new;
end;
$$;
create trigger queue_customer_order_push after insert on public.customer_notifications
  for each row execute function public.queue_customer_order_push();

create function public.queue_customer_restock_push() returns trigger
  language plpgsql security definer set search_path = '' as $$
begin
  insert into public.customer_push_deliveries(subscription_id, kind, path)
  select s.id, 'restock', '/product/' || v.product_id::text
  from public.customer_push_subscriptions s cross join public.product_variants v
  where s.user_id = new.user_id and v.id = new.variant_id;
  return new;
end;
$$;
create trigger queue_customer_restock_push after update of notified_at on public.restock_subscriptions
  for each row when (old.notified_at is null and new.notified_at is not null)
  execute function public.queue_customer_restock_push();

create function public.claim_customer_push_deliveries(p_token text)
returns table(id uuid, subscription_id uuid, endpoint text, p256dh text, auth_secret text, language text, kind text, path text)
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select from public.customer_push_job_secret where
    extensions.digest(token, 'sha256') = extensions.digest(p_token, 'sha256')) then
    raise insufficient_privilege;
  end if;
  return query with batch as (
    select d.id from public.customer_push_deliveries d
    where d.attempts < 4 and d.next_attempt_at <= now() and d.created_at > now() - interval '1 day'
    order by d.next_attempt_at, d.id limit 30 for update skip locked
  ), leased as (
    update public.customer_push_deliveries d
    set attempts = d.attempts + 1, next_attempt_at = now() + interval '2 minutes'
    from batch where d.id = batch.id
    returning d.id, d.subscription_id, d.kind, d.path
  )
  select d.id, s.id, s.endpoint, s.p256dh, s.auth_secret, s.language, d.kind, d.path
  from leased d join public.customer_push_subscriptions s on s.id = d.subscription_id;
end;
$$;

create function public.run_customer_push_job() returns bigint
language plpgsql security definer set search_path = '' as $$
declare request_id bigint;
begin
  delete from public.customer_push_deliveries where created_at <= now() - interval '1 day';
  if not exists (select from public.customer_push_deliveries where attempts < 4 and next_attempt_at <= now()) then
    return null;
  end if;
  select net.http_post(
    url := s.project_url || '/functions/v1/customer-push',
    headers := jsonb_build_object('X-Push-Job', j.token, 'Content-Type', 'application/json'),
    body := '{}'::jsonb, timeout_milliseconds := 115000
  ) into request_id from public.nova_poshta_tracking_schedule s cross join public.customer_push_job_secret j
  where s.project_url is not null;
  return request_id;
end;
$$;

revoke all on function public.set_customer_push_subscription(text, text, text, text),
  public.has_customer_push_subscription(text), public.queue_customer_order_push(),
  public.queue_customer_restock_push(), public.claim_customer_push_deliveries(text),
  public.run_customer_push_job() from public, anon, authenticated, service_role;
grant execute on function public.set_customer_push_subscription(text, text, text, text),
  public.has_customer_push_subscription(text) to authenticated;
grant execute on function public.claim_customer_push_deliveries(text) to service_role;
select cron.schedule('tatami-customer-push', '* * * * *', 'select public.run_customer_push_job()');
notify pgrst, 'reload schema';
