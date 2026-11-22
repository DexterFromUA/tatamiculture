begin;

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
  if target.status = 'COMPLETED' then
    raise sqlstate 'PT409' using message = 'A TTN cannot be created for a completed order.';
  end if;
  if target.status not in ('PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED') then
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
  perform o.id from public.orders o join public.order_merge_members m on o.id=m.order_id
    where m.root_id=p_order_id order by o.id for update of o;
  if exists(select from public.order_merge_members m join public.orders o on o.id=m.order_id
    where m.root_id=p_order_id and o.status in ('CANCELLED_BY_STORE','CANCELLED_BY_USER')) then
    raise exception 'Cancelled orders cannot be included in a shipment';
  end if;
  if exists (
    select from public.order_merge_members m join public.orders o on o.id = m.order_id
    where m.root_id = p_order_id and o.status = 'COMPLETED'
  ) then
    raise sqlstate 'PT409' using message = 'A TTN cannot be created for a completed order.';
  end if;
  insert into public.order_ttn_reservations(order_id) values(p_order_id);
end; $$;

create or replace function public.protect_merged_shipment_during_creation() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.status = 'COMPLETED' and old.status is distinct from new.status
    and exists (select from public.order_ttn_reservations r where r.order_id = old.id) then
    raise exception 'TTN creation is in progress for one of these orders';
  end if;
  if exists(select from public.order_merge_members m join public.order_ttn_reservations r on r.order_id=m.root_id
    where m.order_id=old.id) then raise exception 'TTN creation is in progress for one of these orders'; end if;
  return new;
end; $$;

create or replace function public.unlink_order_ttn(p_order_id uuid, p_ttn text) returns void
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
  perform o.id from public.orders o join public.order_merge_members m on m.order_id = o.id
    where m.root_id = p_order_id order by o.id for update of o;
  if target.status = 'COMPLETED' or exists (
    select from public.order_merge_members m join public.orders o on o.id = m.order_id
    where m.root_id = p_order_id and o.nova_poshta_ttn = p_ttn and o.status = 'COMPLETED'
  ) then
    raise sqlstate 'PT409' using message = 'The TTN of a completed order cannot be unlinked.';
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

commit;
