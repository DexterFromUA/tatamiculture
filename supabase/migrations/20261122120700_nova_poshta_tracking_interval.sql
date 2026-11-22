alter table public.delivery_settings
  add column nova_poshta_tracking_interval_hours integer not null default 2
  check (nova_poshta_tracking_interval_hours in (1, 2, 3, 6, 12, 24));

-- The CRM has one shop, and its delivery settings control the existing tracking job.
create function public.sync_nova_poshta_tracking_interval() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  interval_hours integer := 2;
  tracking_schedule text;
begin
  if tg_op <> 'DELETE' then
    interval_hours := new.nova_poshta_tracking_interval_hours;
  end if;

  if tg_op = 'UPDATE' and interval_hours = old.nova_poshta_tracking_interval_hours then
    return null;
  end if;

  tracking_schedule := case interval_hours
    when 1 then '0 * * * *'
    when 24 then '0 0 * * *'
    else format('0 */%s * * *', interval_hours)
  end;
  perform cron.schedule(
    'tatami-nova-poshta-tracking',
    tracking_schedule,
    'select public.run_nova_poshta_tracking_job()'
  );
  return null;
end;
$$;
revoke all on function public.sync_nova_poshta_tracking_interval() from public, anon, authenticated, service_role;

create trigger sync_nova_poshta_tracking_interval
  after insert or update of nova_poshta_tracking_interval_hours or delete on public.delivery_settings
  for each row execute function public.sync_nova_poshta_tracking_interval();

notify pgrst, 'reload schema';
