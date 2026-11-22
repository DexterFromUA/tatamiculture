begin;

alter table public.nova_poshta_test_waybills add column stage_manual_status_at timestamptz;

create function public.active_nova_poshta_stage_waybills()
returns table (id uuid, store_id uuid, number text, stage_number text)
language sql stable security definer set search_path = '' as $$
  select w.id, w.store_id, w.number, w.stage_number
  from public.nova_poshta_test_waybills w
  join public.orders o on o.store_id = w.store_id and o.nova_poshta_ttn = w.number
  where w.stage_state = 'created' and w.stage_number is not null
    and w.stage_manual_status_at is null
    and coalesce(o.payment_test_mode, o.monobank_test_mode)
    and o.status in ('PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED')
  group by w.id
  order by min(o.nova_poshta_status_updated_at) nulls first, w.id
  limit 100;
$$;
revoke all on function public.active_nova_poshta_stage_waybills() from public, anon, authenticated;
grant execute on function public.active_nova_poshta_stage_waybills() to service_role;

create or replace function public.update_nova_poshta_test_waybill(p_store_id uuid, p_id uuid, p_status_code text)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  waybill public.nova_poshta_test_waybills;
  checked_at timestamptz := clock_timestamp();
  status_label text := case p_status_code
    when '1' then 'Створено' when '5' then 'У дорозі' when '7' then 'У відділенні'
    when '9' then 'Отримано' when '103' then 'Відмова від отримання' end;
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  if status_label is null then raise exception 'Invalid test waybill status'; end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || p_store_id::text, 0));
  update public.nova_poshta_test_waybills set status_code = p_status_code,
    stage_manual_status_at = case when stage_state = 'created' then checked_at end
    where id = p_id and store_id = p_store_id and (stage_state is null or stage_state = 'created') returning * into waybill;
  if not found then raise exception 'Test waybill not found'; end if;
  perform public.apply_nova_poshta_tracking_update(p_store_id, waybill.number, p_status_code, status_label, checked_at, true);
end;
$$;

create function public.apply_nova_poshta_stage_tracking(
  p_store_id uuid, p_id uuid, p_code text, p_label text, p_checked_at timestamptz, p_resume boolean
) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  number text;
begin
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || p_store_id::text, 0));
  update public.nova_poshta_test_waybills w set stage_manual_status_at = null,
    status_code = case
      when p_code = '1' then '1' when p_code in ('4','5','6','101') then '5'
      when p_code in ('7','8') then '7' when p_code in ('9','10','11') then '9'
      when p_code = '103' then '103' else w.status_code end
    where w.id = p_id and w.store_id = p_store_id and w.stage_state = 'created'
      and (w.stage_manual_status_at is null or (p_resume and w.stage_manual_status_at <= p_checked_at))
      and not exists (
        select from public.orders o where o.store_id = w.store_id and o.nova_poshta_ttn = w.number
          and o.nova_poshta_status_updated_at >= p_checked_at
      )
    returning w.number into number;
  if not found then return false; end if;
  return public.apply_nova_poshta_tracking_update(p_store_id, number, p_code, p_label, p_checked_at, true);
end;
$$;
revoke all on function public.apply_nova_poshta_stage_tracking(uuid, uuid, text, text, timestamptz, boolean) from public, anon, authenticated;
grant execute on function public.apply_nova_poshta_stage_tracking(uuid, uuid, text, text, timestamptz, boolean) to service_role;

create or replace function public.apply_nova_poshta_stage_tracking(p_store_id uuid, p_id uuid, p_code text, p_label text, p_checked_at timestamptz)
returns boolean language sql security definer set search_path = '' as $$
  select public.apply_nova_poshta_stage_tracking(p_store_id, p_id, p_code, p_label, p_checked_at, false);
$$;

notify pgrst, 'reload schema';
commit;
