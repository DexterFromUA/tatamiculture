begin;

alter table public.delivery_settings add column nova_poshta_test_mode boolean not null default false;

create table public.nova_poshta_test_waybills (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.shop_settings on delete cascade,
  order_id uuid references public.orders on delete set null,
  number text generated always as ('TEST-' || upper(replace(id::text, '-', ''))) stored unique,
  status_code text not null default '1' check (status_code in ('1', '5', '7', '9', '103')),
  created_at timestamptz not null default now()
);
create index nova_poshta_test_waybills_store on public.nova_poshta_test_waybills(store_id, created_at desc);
alter table public.nova_poshta_test_waybills enable row level security;
revoke all on public.nova_poshta_test_waybills from public, anon, authenticated, service_role;

create function public.guard_live_waybill_reservation() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  target public.orders;
begin
  select * into strict target from public.orders where id = new.order_id;
  if exists (select from public.delivery_settings s where s.store_id = target.store_id and s.nova_poshta_test_mode)
      or coalesce(target.payment_test_mode, target.monobank_test_mode) then
    raise exception 'Live TTN creation requires live delivery mode and a live order.';
  end if;
  return new;
end;
$$;
create trigger guard_live_waybill_reservation before insert on public.order_ttn_reservations
  for each row execute function public.guard_live_waybill_reservation();

create function public.set_nova_poshta_test_mode(p_store_id uuid, p_test_mode boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || p_store_id::text, 0));
  if exists (select from public.order_ttn_reservations r
      join public.orders o on o.id = r.order_id
      where o.store_id = p_store_id and not r.needs_review and r.created_at > now() - interval '8 minutes') then
    raise exception 'Wait for active TTN creation before changing delivery mode.';
  end if;
  insert into public.delivery_settings(store_id, nova_poshta_test_mode) values (p_store_id, p_test_mode)
    on conflict (store_id) do update set nova_poshta_test_mode = excluded.nova_poshta_test_mode;
end;
$$;
revoke all on function public.set_nova_poshta_test_mode(uuid, boolean) from public, anon;
grant execute on function public.set_nova_poshta_test_mode(uuid, boolean) to authenticated;

create function public.list_nova_poshta_test_waybills(p_store_id uuid)
returns table (id uuid, number text, status_code text, receipt_code text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  return query
    select w.id, w.number, w.status_code, o.receipt_code, w.created_at from public.nova_poshta_test_waybills w
    left join public.orders o on o.id = w.order_id and o.nova_poshta_ttn = w.number
    where w.store_id = p_store_id order by w.created_at desc, w.id;
end;
$$;
revoke all on function public.list_nova_poshta_test_waybills(uuid) from public, anon;
grant execute on function public.list_nova_poshta_test_waybills(uuid) to authenticated;

create function public.create_nova_poshta_test_waybill(p_store_id uuid, p_order_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  target public.orders;
  waybill public.nova_poshta_test_waybills;
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || p_store_id::text, 0));
  if not exists (select from public.delivery_settings where store_id = p_store_id and nova_poshta_test_mode) then
    raise exception 'Enable Nova Poshta test mode first.';
  end if;
  if p_order_id is not null then
    select * into target from public.orders where id = p_order_id and store_id = p_store_id for update;
    if not found or not coalesce(target.payment_test_mode, target.monobank_test_mode) then
      raise exception 'Test waybills can only be linked to test orders.';
    end if;
    if exists (select from public.order_merge_members m
      where m.order_id = target.id and m.root_id <> target.id) then
      raise exception 'Create the TTN from the primary order';
    end if;
    if target.nova_poshta_ttn is not null then
      select * into waybill from public.nova_poshta_test_waybills where store_id = p_store_id and number = target.nova_poshta_ttn;
      if found then return jsonb_build_object('ttn', waybill.number, 'documentRef', waybill.id, 'existing', true); end if;
      raise exception 'This order already has a TTN.';
    end if;
    if target.status not in ('PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED', 'COMPLETED') then
      raise exception 'Move the order to preparing for shipment first';
    end if;
    if exists (select from public.order_ttn_reservations where order_id = target.id) then
      raise exception 'Resolve the pending TTN attempt first.';
    end if;
    if exists (select from public.order_merge_members m join public.orders o on o.id = m.order_id
      where m.root_id = target.id and (not coalesce(o.payment_test_mode, o.monobank_test_mode)
        or o.status in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER') or o.nova_poshta_ttn is not null)) then
      raise exception 'Every order in a test shipment must be active, in test mode and without a TTN.';
    end if;
  end if;

  insert into public.nova_poshta_test_waybills(store_id, order_id) values (p_store_id, p_order_id) returning * into waybill;
  if p_order_id is not null then
    update public.orders o set nova_poshta_ttn = waybill.number,
      nova_poshta_document_ref = case when o.id = p_order_id then waybill.id::text end,
      nova_poshta_ttn_created_at = now(), nova_poshta_status_code = '1', nova_poshta_status = 'Створено',
      nova_poshta_status_updated_at = now(), manual_tracking_status_code = null
    where o.store_id = p_store_id and (o.id = p_order_id or exists (
      select from public.order_merge_members m where m.root_id = p_order_id and m.order_id = o.id
    ));
  end if;
  return jsonb_build_object('ttn', waybill.number, 'documentRef', waybill.id, 'existing', false);
end;
$$;
revoke all on function public.create_nova_poshta_test_waybill(uuid, uuid) from public, anon;
grant execute on function public.create_nova_poshta_test_waybill(uuid, uuid) to authenticated;

create function public.apply_nova_poshta_tracking_update(
  p_store_id uuid, p_ttn text, p_code text, p_status text, p_checked_at timestamptz, p_simulated boolean
) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  auto_update boolean;
  shipment public.orders;
  next_status public.order_status;
  tracking_changed boolean;
  changed boolean := false;
begin
  if nullif(p_ttn, '') is null or nullif(p_status, '') is null or p_checked_at is null then
    raise exception 'Invalid shipment status';
  end if;
  select s.auto_update_order_status into auto_update
  from public.delivery_settings s where s.store_id = p_store_id for share;

  for shipment in
    select * from public.orders
    where store_id = p_store_id and nova_poshta_ttn = p_ttn
      and (not p_simulated or coalesce(payment_test_mode, monobank_test_mode))
    order by id for update
  loop
    if p_checked_at <= shipment.nova_poshta_status_updated_at or p_checked_at < shipment.nova_poshta_ttn_created_at then
      continue;
    end if;
    tracking_changed := shipment.nova_poshta_status_code is distinct from p_code
      or shipment.nova_poshta_status is distinct from p_status;
    next_status := shipment.status;
    if coalesce(auto_update, true)
      and shipment.manual_tracking_status_code is distinct from p_code
      and (p_simulated or not coalesce(shipment.payment_test_mode, shipment.monobank_test_mode))
      and shipment.status in ('PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED') then
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
      nova_poshta_status_updated_at = p_checked_at, status = next_status,
      manual_tracking_status_code = case when shipment.manual_tracking_status_code = p_code then p_code end,
      shipment_was_dispatched = shipment.shipment_was_dispatched or coalesce(p_code in ('4', '5', '6', '7', '8', '9', '10', '11', '101'), false)
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

revoke all on function public.apply_nova_poshta_tracking_update(uuid, text, text, text, timestamptz, boolean)
  from public, anon, authenticated, service_role;

create or replace function public.apply_nova_poshta_tracking(
  p_store_id uuid, p_ttn text, p_code text, p_status text, p_checked_at timestamptz
) returns boolean
language sql security definer set search_path = '' as $$
  select case when p_ttn like 'TEST-%' then false else
    public.apply_nova_poshta_tracking_update(p_store_id, p_ttn, p_code, p_status, p_checked_at, false) end;
$$;

create function public.update_nova_poshta_test_waybill(p_store_id uuid, p_id uuid, p_status_code text)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  waybill public.nova_poshta_test_waybills;
  status_label text := case p_status_code
    when '1' then 'Створено' when '5' then 'У дорозі' when '7' then 'У відділенні'
    when '9' then 'Отримано' when '103' then 'Відмова від отримання' end;
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  if status_label is null then raise exception 'Invalid test waybill status'; end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || p_store_id::text, 0));
  update public.nova_poshta_test_waybills set status_code = p_status_code
    where id = p_id and store_id = p_store_id returning * into waybill;
  if not found then raise exception 'Test waybill not found'; end if;
  perform public.apply_nova_poshta_tracking_update(p_store_id, waybill.number, p_status_code, status_label, clock_timestamp(), true);
end;
$$;
revoke all on function public.update_nova_poshta_test_waybill(uuid, uuid, text) from public, anon;
grant execute on function public.update_nova_poshta_test_waybill(uuid, uuid, text) to authenticated;

create function public.delete_nova_poshta_test_waybill(p_store_id uuid, p_id uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  waybill public.nova_poshta_test_waybills;
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || p_store_id::text, 0));
  delete from public.nova_poshta_test_waybills where id = p_id and store_id = p_store_id returning * into waybill;
  if not found or waybill.order_id is null then return; end if;
  if exists (select from public.orders where id = waybill.order_id and nova_poshta_ttn = waybill.number) then
    perform public.unlink_order_ttn(waybill.order_id, waybill.number);
  end if;
end;
$$;
revoke all on function public.delete_nova_poshta_test_waybill(uuid, uuid) from public, anon;
grant execute on function public.delete_nova_poshta_test_waybill(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
