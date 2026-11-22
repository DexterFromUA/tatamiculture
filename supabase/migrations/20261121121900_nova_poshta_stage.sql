begin;

alter table public.nova_poshta_test_waybills
  add column stage_state text check (stage_state in ('pending', 'created', 'deleted')),
  add column stage_ref text,
  add column stage_number text;
grant select on public.nova_poshta_test_waybills to service_role;
grant update (stage_state, stage_ref, stage_number) on public.nova_poshta_test_waybills to service_role;

-- Reserve a local waybill before sending the request to prevent duplicate shipments.
create function public.begin_nova_poshta_stage_waybill(p_store_id uuid, p_order_id uuid, p_shipment jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  result jsonb;
begin
  if p_order_id is null then raise exception 'Order is required'; end if;
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || p_store_id::text, 0));
  if exists (select from public.nova_poshta_test_waybills w join public.orders o on o.id = w.order_id
      where w.store_id = p_store_id and w.order_id = p_order_id and w.stage_state = 'pending'
        and o.nova_poshta_ttn is distinct from w.number) then
    raise exception 'Check the Stage shipment in delivery settings before retrying.';
  end if;
  result := public.create_nova_poshta_test_waybill(p_store_id, p_order_id, p_shipment);
  if not (result->>'existing')::boolean then
    update public.nova_poshta_test_waybills set stage_state = 'pending'
      where id = (result->>'documentRef')::uuid and store_id = p_store_id;
  end if;
  return result;
end;
$$;
revoke all on function public.begin_nova_poshta_stage_waybill(uuid, uuid, jsonb) from public, anon;
grant execute on function public.begin_nova_poshta_stage_waybill(uuid, uuid, jsonb) to authenticated;

create function public.list_nova_poshta_test_waybills(p_store_id uuid, p_include_stage boolean)
returns table (id uuid, number text, status_code text, receipt_code text, created_at timestamptz, stage_state text, stage_number text)
language sql stable security definer set search_path = '' as $$
  select row.id, row.number, row.status_code, row.receipt_code, row.created_at, w.stage_state, w.stage_number
  from public.list_nova_poshta_test_waybills(p_store_id) row
  join public.nova_poshta_test_waybills w using (id)
  where p_include_stage or w.stage_state is null
  order by row.created_at desc, row.id;
$$;
revoke all on function public.list_nova_poshta_test_waybills(uuid, boolean) from public, anon;
grant execute on function public.list_nova_poshta_test_waybills(uuid, boolean) to authenticated;

create or replace function public.delete_nova_poshta_test_waybill(p_store_id uuid, p_id uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  waybill public.nova_poshta_test_waybills;
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || p_store_id::text, 0));
  select * into waybill from public.nova_poshta_test_waybills where id = p_id and store_id = p_store_id for update;
  if not found then return; end if;
  if waybill.stage_state in ('pending', 'created') then
    raise exception 'Confirm the Stage shipment was deleted first.';
  end if;
  delete from public.nova_poshta_test_waybills where id = waybill.id;
  if exists (select from public.orders where id = waybill.order_id and nova_poshta_ttn = waybill.number) then
    perform public.unlink_order_ttn(waybill.order_id, waybill.number);
  end if;
end;
$$;

create function public.apply_nova_poshta_stage_tracking(p_store_id uuid, p_id uuid, p_code text, p_label text, p_checked_at timestamptz)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  number text;
begin
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || p_store_id::text, 0));
  update public.nova_poshta_test_waybills w
    set status_code = case when p_code in ('1','5','7','9','103') then p_code else w.status_code end
    where w.id = p_id and w.store_id = p_store_id and w.stage_state = 'created'
    returning w.number into number;
  if not found then return false; end if;
  return public.apply_nova_poshta_tracking_update(p_store_id, number, p_code, p_label, p_checked_at, true);
end;
$$;
revoke all on function public.apply_nova_poshta_stage_tracking(uuid, uuid, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_nova_poshta_stage_tracking(uuid, uuid, text, text, timestamptz) to service_role;

create or replace function public.get_order_delivery_actions(p_order_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  target public.orders;
  attempt public.order_ttn_reservations;
  pending_stock boolean;
begin
  select * into target from public.orders where id = p_order_id;
  if not found or not coalesce(public.is_store_member(target.store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  select exists (
    select from public.orders o where o.store_id = target.store_id and o.cancel_stock_pending
      and (o.id = p_order_id or exists (
        select from public.order_merge_members m where m.root_id = p_order_id and m.order_id = o.id
      ))
  ) into pending_stock;
  select * into attempt from public.order_ttn_reservations where order_id = p_order_id;
  return jsonb_build_object(
    'cancelStockPending', pending_stock, 'ttn', target.nova_poshta_ttn,
    'stageNumber', (select w.stage_number from public.nova_poshta_test_waybills w
      where w.store_id = target.store_id and w.number = target.nova_poshta_ttn and w.stage_state = 'created'),
    'ttnAttempt', case when attempt.attempt_id is not null and target.nova_poshta_ttn is null
      then jsonb_build_object('id', attempt.attempt_id,
        'state', case when attempt.needs_review or attempt.created_at <= now() - interval '8 minutes'
          then 'review' else 'creating' end)
    end
  );
end;
$$;
revoke all on function public.get_order_delivery_actions(uuid) from public, anon, service_role;
grant execute on function public.get_order_delivery_actions(uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
