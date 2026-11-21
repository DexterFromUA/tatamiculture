begin;
alter table public.online_checkouts add column bank_checked_at timestamptz, add column bank_review_reason text;
create index online_checkout_reconciliation on public.online_checkouts(bank_checked_at nulls first, created_at)
  where status='PENDING' and not test_mode;
create function public.claim_payment_checks() returns table(id uuid, provider text, provider_order_id text, test_mode boolean, expires_at timestamptz)
language sql security definer set search_path='' as $$
  with batch as (select c.id from public.online_checkouts c
    where c.status='PENDING' and not c.test_mode and c.created_at < now()-interval '5 minutes'
      and (c.bank_checked_at is null or c.bank_checked_at < now() -
        case when c.expires_at < now()-interval '1 day' then interval '6 hours' else interval '14 minutes' end)
    order by c.bank_checked_at nulls first,c.created_at desc limit 60 for update skip locked)
  update public.online_checkouts c set bank_checked_at=now() from batch
    where batch.id=c.id returning c.id,c.provider,c.provider_order_id,c.test_mode,c.expires_at;
$$;
revoke all on function public.claim_payment_checks() from public,anon,authenticated;
grant execute on function public.claim_payment_checks() to service_role;
create function public.payment_reviews(p_store uuid) returns table(receipt_code text, provider text, bank_reference text, total_price integer,currency text, reason text)
language sql stable security definer set search_path='' as $$
  select c.receipt_code,c.provider,c.provider_order_id,c.total_price,c.currency,c.bank_review_reason from public.online_checkouts c
  where c.store_id=p_store and public.is_store_member(p_store) and c.status='PENDING'
    and c.bank_review_reason is not null and not c.test_mode order by c.created_at desc;
$$;
revoke all on function public.payment_reviews(uuid) from public,anon;
grant execute on function public.payment_reviews(uuid) to authenticated;

create table public.payment_job_secret(singleton boolean primary key default true check(singleton),
  token text not null default encode(extensions.gen_random_bytes(32),'hex'));
alter table public.payment_job_secret enable row level security;
revoke all on public.payment_job_secret from public,anon,authenticated,service_role;
insert into public.payment_job_secret default values;
create function public.is_payment_check_job(p_token text) returns boolean language sql stable security definer set search_path='' as $$
  select extensions.digest(token,'sha256')=extensions.digest(p_token,'sha256') from public.payment_job_secret;
$$;
revoke all on function public.is_payment_check_job(text) from public,anon,authenticated;
grant execute on function public.is_payment_check_job(text) to service_role;
create function public.run_payment_checks() returns bigint language sql security definer set search_path='' as $$
  select net.http_post(url:=s.project_url||'/functions/v1/reconcile-payments',
    headers:=jsonb_build_object('X-Payment-Job',j.token,'Content-Type','application/json'),
    body:='{}'::jsonb,timeout_milliseconds:=120000)
  from public.nova_poshta_tracking_schedule s cross join public.payment_job_secret j where s.project_url is not null;
$$;
revoke all on function public.run_payment_checks() from public,anon,authenticated,service_role;
select cron.schedule('tatami-payment-checks','*/15 * * * *','select public.run_payment_checks()');
notify pgrst,'reload schema';
commit;
