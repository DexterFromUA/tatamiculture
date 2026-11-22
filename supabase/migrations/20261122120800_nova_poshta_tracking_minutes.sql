begin;

drop trigger sync_nova_poshta_tracking_interval on public.delivery_settings;
drop function public.sync_nova_poshta_tracking_interval();

alter table public.delivery_settings
  drop constraint delivery_settings_nova_poshta_tracking_interval_hours_check;
alter table public.delivery_settings
  rename column nova_poshta_tracking_interval_hours to nova_poshta_tracking_interval_minutes;
update public.delivery_settings
set nova_poshta_tracking_interval_minutes = nova_poshta_tracking_interval_minutes * 60;
alter table public.delivery_settings
  alter column nova_poshta_tracking_interval_minutes set default 120,
  add constraint delivery_settings_nova_poshta_tracking_interval_minutes_check
    check (nova_poshta_tracking_interval_minutes > 0);

alter table public.nova_poshta_tracking_schedule add column last_dispatched_at timestamptz;

-- Keep the current schedule aligned with the previous UTC cron slots at migration time.
update public.nova_poshta_tracking_schedule
set last_dispatched_at = date_bin(
  make_interval(mins => coalesce((select nova_poshta_tracking_interval_minutes from public.delivery_settings limit 1), 120)),
  statement_timestamp(),
  '2000-01-01 00:00:00+00'::timestamptz
)
where singleton;

create or replace function public.run_nova_poshta_tracking_job() returns bigint
language sql security definer
set search_path = ''
as $$
  with timing as (
    select date_trunc('minute', statement_timestamp()) as tick,
      make_interval(mins => coalesce((select nova_poshta_tracking_interval_minutes from public.delivery_settings limit 1), 120)) as frequency
  ), due as (
    update public.nova_poshta_tracking_schedule s
    set last_dispatched_at = timing.tick
    from timing
    where s.singleton and s.project_url is not null
      and (s.last_dispatched_at is null or s.last_dispatched_at + timing.frequency <= timing.tick)
    returning s.project_url, s.token
  )
  select net.http_post(
    url := project_url || '/functions/v1/nova-poshta-track-ttn',
    headers := jsonb_build_object('Content-Type', 'application/json', 'X-Tracking-Job', token),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000
  )
  from due;
$$;

-- pg_cron checks locally each minute. Only a due run queues an HTTP request.
select cron.schedule('tatami-nova-poshta-tracking', '* * * * *', 'select public.run_nova_poshta_tracking_job()');

notify pgrst, 'reload schema';

commit;
