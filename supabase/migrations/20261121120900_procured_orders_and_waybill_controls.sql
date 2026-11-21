begin;

alter table public.orders
  add column manual_tracking_status_code text,
  add column shipment_was_dispatched boolean not null default false;

update public.orders o set shipment_was_dispatched = true
where o.status in ('IN_TRANSIT', 'DELIVERED', 'COMPLETED')
  or o.nova_poshta_status_code in ('4', '5', '6', '7', '8', '9', '10', '11', '101')
  or (o.nova_poshta_ttn is not null and exists (
    select from public.order_delivery_events e where e.order_id = o.id
      and e.status_code in ('4', '5', '6', '7', '8', '9', '10', '11', '101')
  ));

-- Orders reserve available stock at checkout. Unallocated goods are bought for
-- the customer and never enter the available balance during fulfillment.
CREATE OR REPLACE FUNCTION "public"."apply_admin_order_update"("p_order_ids" "uuid"[], "p_status" "public"."order_status", "p_confirm_paid" boolean, "p_include_group" boolean, "p_restore_stock" boolean) RETURNS SETOF "public"."orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  store uuid;
  affected_ids uuid[];
  order_id uuid;
  stock_order_ids uuid[];
begin
  select o.store_id into store from public.orders o where o.id = p_order_ids[1];
  if store is null or not coalesce(public.is_store_member(store), false) or exists (
    select 1 from unnest(p_order_ids) requested(id)
    where not exists (select 1 from public.orders o where o.id = requested.id and o.store_id = store)
  ) then
    raise exception 'Access denied';
  end if;
  if p_status is null or (p_restore_stock and p_status <> 'CANCELLED_BY_STORE') then
    raise exception 'Invalid order status';
  end if;

  -- Keep group membership and parcel reservation stable until stock and status commit.
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || store::text, 0));
  select array_agg(o.id order by o.id) into affected_ids
  from public.orders o
  where o.store_id = store and (o.id = any(p_order_ids) or (
    p_include_group and exists (
      select 1 from public.order_merge_members m where m.order_id = o.id and m.root_id = any(p_order_ids)
    )
  ));

  perform o.id from public.orders o where o.id = any(affected_ids) order by o.id for update;
  perform p.id from public.payments p where p.order_id = any(affected_ids) order by p.order_id for update;

  if not coalesce(p_confirm_paid, false) and (
    exists (select 1 from public.orders o where o.id = any(affected_ids) and (o.status = 'PAID' or o.payment_status in ('PAID', 'REFUNDED')))
    or exists (select 1 from public.payments p where p.order_id = any(affected_ids) and p.status in ('PAID', 'REFUNDED'))
    or exists (
      select 1 from public.order_events e where e.order_id = any(affected_ids)
        and ((e.kind = 'status' and ('PAID' in (e.old_value, e.new_value)))
          or (e.kind = 'payment_status' and (e.old_value in ('PAID', 'REFUNDED') or e.new_value in ('PAID', 'REFUNDED'))))
    )
    or exists (select 1 from public.order_returns r where r.order_id = any(affected_ids))
  ) then
    raise sqlstate 'PT409' using message = 'Confirm status change for orders with a payment record';
  end if;

  if exists (
    select 1 from public.order_ttn_reservations r where r.order_id = any(affected_ids)
  ) then
    raise exception 'TTN creation is in progress for one of these orders';
  end if;
  if p_status = 'COMPLETED' and exists (
    select 1 from public.orders o where o.id = any(affected_ids)
    and (o.status::text like 'CANCELLED%' or
      (o.payment_method = 'ONLINE' and o.payment_status <> 'PAID') or
      (o.payment_method = 'CASH_ON_DELIVERY' and o.payment_status not in ('PAID', 'PENDING')))
  ) then
    raise exception 'Only active orders with valid payment can be completed';
  end if;
  if p_status in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER') and not p_restore_stock then
    select array_agg(o.id) into stock_order_ids from public.orders o
    where o.id = any(affected_ids) and o.status in ('PENDING', 'IN_PROGRESS', 'WAITING_FOR_STOCK', 'PREPARING_SHIPMENT')
      and not o.shipment_was_dispatched
      and o.nova_poshta_ttn is null and o.nova_poshta_document_ref is null;
    if stock_order_ids is not null then
      perform public.release_order_fulfillment_stock(stock_order_ids);
    end if;
    update public.orders o set cancel_stock_pending = true
    where o.id = any(affected_ids) and not (o.id = any(coalesce(stock_order_ids, array[]::uuid[])))
      and o.status not in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER')
      and not coalesce(o.payment_test_mode, o.monobank_test_mode)
      and exists (
        select from public.order_items i where i.order_id = o.id
          and coalesce(i.stock_deducted, not i.is_preorder) and i.variant_id is not null
      );
  end if;

  if p_restore_stock then
    foreach order_id in array affected_ids loop
      perform public.restore_stock_and_cancel_order(order_id);
    end loop;
  else
    update public.orders o
    set status = p_status,
        manual_tracking_status_code = case when o.status is distinct from p_status
          then o.nova_poshta_status_code else o.manual_tracking_status_code end,
        shipment_was_dispatched = o.shipment_was_dispatched or p_status in ('IN_TRANSIT', 'DELIVERED', 'COMPLETED'),
        cancel_stock_pending = o.cancel_stock_pending and p_status in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER'),
        payment_status = case p_status
          when 'PAID' then 'PAID'::public.payment_status
          when 'PENDING' then 'PENDING'::public.payment_status
          else o.payment_status
        end
    where o.id = any(affected_ids);
  end if;

  return query select o.* from public.orders o where o.id = any(affected_ids);
end;
$$;

CREATE OR REPLACE FUNCTION "public"."restore_stock_and_cancel_order"("p_order_id" "uuid") RETURNS "public"."orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_order public.orders;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found or not public.is_store_member(v_order.store_id) then
    raise exception 'You do not have access to this order';
  end if;
  if v_order.payment_status in ('PAID', 'REFUNDED') then
    raise exception 'A paid order cannot be cancelled with stock restoration';
  end if;
  if v_order.status not in ('PENDING', 'IN_PROGRESS', 'WAITING_FOR_STOCK', 'PREPARING_SHIPMENT')
      or v_order.shipment_was_dispatched
      or v_order.nova_poshta_ttn is not null or v_order.nova_poshta_document_ref is not null then
    raise exception 'Only pending unpaid orders can be cancelled with stock restoration';
  end if;

  perform public.release_order_fulfillment_stock(array[v_order.id]);

  update public.orders
  set status = 'CANCELLED_BY_STORE',
      payment_status = case when v_order.payment_method = 'CASH_ON_DELIVERY'
        then v_order.payment_status else 'FAILED'::public.payment_status end
  where id = v_order.id
  returning * into v_order;

  update public.payments
  set status = 'FAILED', updated_at = now()
  where order_id = v_order.id and status = 'PENDING';

  return v_order;
end;
$$;

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
  if not coalesce(target.payment_test_mode, target.monobank_test_mode)
      and target.status not in ('PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED', 'COMPLETED') then
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

drop function public.reserve_order_fulfillment_stock(uuid[]);

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

create function public.capture_order_waybill() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.order_events(order_id, kind, new_value, author_id)
    values(new.id, case when new.nova_poshta_ttn is null then 'ttn_unlinked' else 'ttn_linked' end,
      coalesce(new.nova_poshta_ttn, old.nova_poshta_ttn),
      coalesce(auth.uid(), nullif(current_setting('tatami.ttn_actor', true), '')::uuid));
  return new;
end;
$$;
revoke all on function public.capture_order_waybill() from public, anon, authenticated, service_role;
create trigger orders_capture_waybill after update of nova_poshta_ttn on public.orders
  for each row when (old.nova_poshta_ttn is distinct from new.nova_poshta_ttn)
  execute function public.capture_order_waybill();

create function public.settle_order_ttn_as_staff(
  p_order_id uuid, p_attempt_id uuid, p_outcome text, p_ttn text, p_document_ref text, p_actor uuid
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (
    select from public.orders o join public.store_members m on m.store_id = o.store_id
    where o.id = p_order_id and m.user_id = p_actor
  ) then raise insufficient_privilege using message = 'Store staff access required'; end if;
  perform set_config('tatami.ttn_actor', p_actor::text, true);
  if p_attempt_id is null and p_outcome = 'attached' then
    perform public.attach_verified_order_ttn(p_order_id, p_ttn, p_document_ref);
  else
    perform public.finish_order_ttn_attempt(p_order_id, p_attempt_id, p_outcome, p_ttn, p_document_ref);
  end if;
  perform set_config('tatami.ttn_actor', '', true);
end;
$$;
revoke all on function public.settle_order_ttn_as_staff(uuid, uuid, text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.settle_order_ttn_as_staff(uuid, uuid, text, text, text, uuid) to service_role;

create function public.unlink_order_ttn(p_order_id uuid, p_ttn text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  target public.orders;
begin
  select * into target from public.orders where id = p_order_id;
  if not found or not coalesce(public.is_store_member(target.store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || target.store_id::text, 0));
  select * into target from public.orders where id = p_order_id for update;
  if exists (select from public.order_merge_members where order_id = p_order_id and root_id <> p_order_id) then
    raise exception 'Unlink the TTN from the primary order.';
  end if;
  if p_ttn is null or target.nova_poshta_ttn is distinct from p_ttn then
    raise exception 'The TTN has changed. Refresh the order and try again.';
  end if;
  update public.orders o set nova_poshta_ttn = null, nova_poshta_document_ref = null,
      nova_poshta_ttn_created_at = null, nova_poshta_status = null, nova_poshta_status_code = null,
      nova_poshta_status_updated_at = null, manual_tracking_status_code = null
    where o.store_id = target.store_id and o.nova_poshta_ttn = p_ttn and
      (o.id = p_order_id or exists (
        select from public.order_merge_members m where m.root_id = p_order_id and m.order_id = o.id
      ));
end;
$$;
revoke all on function public.unlink_order_ttn(uuid, text) from public, anon, service_role;
grant execute on function public.unlink_order_ttn(uuid, text) to authenticated;

notify pgrst, 'reload schema';

commit;
