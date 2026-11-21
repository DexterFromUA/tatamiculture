begin;

-- Starting preparation enables tracking even if the waybill was attached earlier.
create function public.start_order_shipment_tracking() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.manual_tracking_status_code := null;
  return new;
end;
$$;
create trigger start_order_shipment_tracking before update of status on public.orders
  for each row when (old.status in ('IN_PROGRESS', 'WAITING_FOR_STOCK') and new.status = 'PREPARING_SHIPMENT')
  execute function public.start_order_shipment_tracking();

CREATE OR REPLACE FUNCTION "public"."reserve_order_ttn"("p_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  target public.orders;
begin
  select * into target from public.orders where id=p_order_id;
  if target.id is null then raise exception 'Order not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || target.store_id::text, 0));
  select * into target from public.orders where id=p_order_id for update;
  if target.status not in ('PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED', 'COMPLETED') then
    raise exception 'Move the order to preparing for shipment first';
  end if;
  if target.status::text like 'CANCELLED%' then
    raise exception 'A TTN cannot be created for a cancelled order';
  end if;
  if exists(select 1 from public.order_merge_members where order_id=p_order_id and root_id<>p_order_id) then
    raise exception 'Create the TTN from the primary order';
  end if;
  if exists(select 1 from public.orders where (id=p_order_id or id in
    (select order_id from public.order_merge_members where root_id=p_order_id))
    and (nova_poshta_ttn is not null or nova_poshta_document_ref is not null)) then
    raise exception 'This order already has a TTN';
  end if;
  insert into public.order_ttn_reservations(order_id) values(p_order_id);
end; $$;

create or replace function public.apply_nova_poshta_tracking(
  p_store_id uuid, p_ttn text, p_code text, p_status text, p_checked_at timestamptz
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
      and not coalesce(shipment.payment_test_mode, shipment.monobank_test_mode)
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

notify pgrst, 'reload schema';
commit;
