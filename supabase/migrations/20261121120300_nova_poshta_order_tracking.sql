begin;

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

create table public.nova_poshta_tracking_schedule (
  singleton boolean primary key default true check (singleton),
  project_url text check (project_url ~ '^https://[a-z0-9]+[.]supabase[.]co$'),
  token text not null default encode(extensions.gen_random_bytes(32), 'hex')
);
insert into public.nova_poshta_tracking_schedule default values;
alter table public.nova_poshta_tracking_schedule enable row level security;
revoke all on public.nova_poshta_tracking_schedule from public, anon, authenticated, service_role;

create function public.is_nova_poshta_tracking_job(p_token text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select extensions.digest(token, 'sha256') = extensions.digest(p_token, 'sha256')
    from public.nova_poshta_tracking_schedule where singleton
  ), false);
$$;
revoke all on function public.is_nova_poshta_tracking_job(text) from public, anon, authenticated;
grant execute on function public.is_nova_poshta_tracking_job(text) to service_role;

create function public.run_nova_poshta_tracking_job() returns bigint
language sql security definer set search_path = '' as $$
  select net.http_post(
    url := project_url || '/functions/v1/nova-poshta-track-ttn',
    headers := jsonb_build_object('Content-Type', 'application/json', 'X-Tracking-Job', token),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000
  )
  from public.nova_poshta_tracking_schedule where singleton and project_url is not null;
$$;
revoke all on function public.run_nova_poshta_tracking_job() from public, anon, authenticated, service_role;
select cron.schedule('tatami-nova-poshta-tracking', '0 */2 * * *', 'select public.run_nova_poshta_tracking_job()');

create function public.active_nova_poshta_shipments()
returns table(store_id uuid, ttn text, sender_phone text)
language sql stable security definer set search_path = '' as $$
  select o.store_id, o.nova_poshta_ttn, coalesce(s.sender_phone, '')
  from public.orders o
  left join public.delivery_settings s on s.store_id = o.store_id
  where nullif(o.nova_poshta_ttn, '') is not null
    and not coalesce(o.payment_test_mode, o.monobank_test_mode)
    and o.status not in ('COMPLETED', 'CANCELLED_BY_USER', 'CANCELLED_BY_STORE')
  group by o.store_id, o.nova_poshta_ttn, s.sender_phone
  order by min(o.nova_poshta_status_updated_at) nulls first, o.store_id, o.nova_poshta_ttn
  limit 500;
$$;
revoke all on function public.active_nova_poshta_shipments() from public, anon, authenticated;
grant execute on function public.active_nova_poshta_shipments() to service_role;

-- Status 9/10/11 is recipient handover. A return, refusal or redirection is recorded
-- in tracking but never used to infer cancellation, payment or a stock movement.
create function public.apply_nova_poshta_tracking(
  p_store_id uuid, p_ttn text, p_code text, p_status text, p_checked_at timestamptz
) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  shipment public.orders;
  next_status public.order_status;
  tracking_changed boolean;
  changed boolean := false;
begin
  if nullif(p_ttn, '') is null or nullif(p_status, '') is null or p_checked_at is null then
    raise exception 'Invalid shipment status';
  end if;
  for shipment in
    select * from public.orders
    where store_id = p_store_id and nova_poshta_ttn = p_ttn
    order by id for update
  loop
    if p_checked_at <= shipment.nova_poshta_status_updated_at then continue; end if;
    tracking_changed := shipment.nova_poshta_status_code is distinct from p_code
      or shipment.nova_poshta_status is distinct from p_status;
    next_status := shipment.status;
    if not coalesce(shipment.payment_test_mode, shipment.monobank_test_mode)
      and shipment.status not in ('COMPLETED', 'CANCELLED_BY_USER', 'CANCELLED_BY_STORE') then
      if p_code in ('9', '10', '11')
        and ((shipment.payment_method = 'ONLINE' and shipment.payment_status = 'PAID')
          or (shipment.payment_method = 'CASH_ON_DELIVERY' and shipment.payment_status in ('PENDING', 'PAID'))) then
        next_status := 'COMPLETED';
      elsif p_code in ('7', '8') then
        next_status := 'DELIVERED';
      elsif p_code in ('4', '5', '6', '101') and shipment.status <> 'DELIVERED' then
        next_status := 'IN_TRANSIT';
      end if;
    end if;
    update public.orders set nova_poshta_status = p_status, nova_poshta_status_code = p_code,
      nova_poshta_status_updated_at = p_checked_at, status = next_status
    where id = shipment.id;
    if tracking_changed then
      insert into public.order_delivery_events (order_id, status_code, status_text)
      values (shipment.id, p_code, p_status);
    end if;
    changed := changed or tracking_changed or next_status <> shipment.status;
  end loop;
  return changed;
end;
$$;
revoke all on function public.apply_nova_poshta_tracking(uuid, text, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_nova_poshta_tracking(uuid, text, text, text, timestamptz) to service_role;
notify pgrst, 'reload schema';

commit;
