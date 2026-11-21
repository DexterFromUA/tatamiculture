begin;
CREATE OR REPLACE FUNCTION "public"."merge_orders"("p_order_ids" "uuid"[], "p_target_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  target public.orders;
  ids uuid[];
  selected_count integer;
  paid_count integer;
begin
  if p_order_ids is null or cardinality(p_order_ids) < 2 or not p_target_id = any(p_order_ids) then
    raise exception 'Select at least two orders and a primary order';
  end if;
  select * into target from public.orders where id=p_target_id;
  if target.id is null or not coalesce(public.is_store_member(target.store_id), false) then
    raise exception 'Access denied';
  end if;
  -- Serialize merge operations for the store, then lock all underlying orders.
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || target.store_id::text, 0));
  select array_agg(distinct o.id order by o.id) into ids
  from public.orders o
  left join public.order_merge_members m on m.order_id=o.id
  where o.id=any(p_order_ids) or m.root_id=any(p_order_ids);
  if (select count(distinct x) from unnest(p_order_ids) x) <> cardinality(p_order_ids)
     or (select count(*) from public.orders where id=any(p_order_ids)) <> cardinality(p_order_ids) then
    raise exception 'Invalid order selection';
  end if;
  perform 1 from public.orders where id=any(ids) order by id for update;
  select * into target from public.orders where id=p_target_id;
  if exists(select 1 from public.order_merge_members where order_id=any(p_order_ids) and root_id<>order_id) then
    raise exception 'Choose the primary order of an existing merged order';
  end if;
  if exists(select 1 from public.orders where id=any(ids) and store_id<>target.store_id) then
    raise exception 'Orders must belong to the same store';
  end if;
  if exists(select 1 from public.orders where id=any(ids) and (nova_poshta_ttn is not null or nova_poshta_document_ref is not null)) then
    raise exception 'Orders with an existing TTN cannot be merged';
  end if;
  if exists(select 1 from public.order_ttn_reservations where order_id=any(ids)) then
    raise exception 'TTN creation is in progress for one of these orders';
  end if;
  if exists(select from public.orders where id=any(ids) and status in ('CANCELLED_BY_STORE','CANCELLED_BY_USER')) then
    raise exception 'Cancelled orders cannot be included in a shipment';
  end if;
  if exists(select 1 from public.orders where id=any(ids) and currency<>target.currency) then
    raise exception 'Orders in different currencies cannot be merged';
  end if;
  if exists(select 1 from public.orders where id=any(ids) and coalesce(payment_test_mode,false)<>coalesce(target.payment_test_mode,false)) then
    raise exception 'Test and live orders cannot be merged';
  end if;
  select count(*), count(*) filter (where payment_status='PAID') into selected_count, paid_count
    from public.orders where id=any(ids);
  if paid_count>0 and paid_count<selected_count then
    raise exception 'Paid and unpaid orders cannot be merged together';
  end if;
  insert into public.order_merge_members(order_id,root_id,author_id)
    select id,p_target_id,auth.uid() from public.orders where id=any(ids)
    on conflict (order_id) do update set root_id=excluded.root_id,author_id=excluded.author_id;
  update public.orders set crm_customer_id=target.crm_customer_id
    where id=any(ids) and id<>p_target_id;
  insert into public.order_events(order_id,kind,new_value,author_id)
    select id,'merge',p_target_id::text,auth.uid() from public.orders where id=any(ids);
  return p_target_id;
end; $$;
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
  perform o.id from public.orders o join public.order_merge_members m on o.id=m.order_id
    where m.root_id=p_order_id order by o.id for update of o;
  if exists(select from public.order_merge_members m join public.orders o on o.id=m.order_id
    where m.root_id=p_order_id and o.status in ('CANCELLED_BY_STORE','CANCELLED_BY_USER')) then
    raise exception 'Cancelled orders cannot be included in a shipment';
  end if;
  insert into public.order_ttn_reservations(order_id) values(p_order_id);
end; $$;

CREATE OR REPLACE FUNCTION "public"."merged_order_shipping"("p_order_id" "uuid") RETURNS TABLE("order_ids" "uuid"[], "total_minor" bigint, "cod_minor" bigint, "weight_grams" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if exists(select from public.order_merge_members m join public.orders o on o.id=m.order_id
      where m.root_id=p_order_id and o.status in ('CANCELLED_BY_USER','CANCELLED_BY_STORE')) then
    raise exception 'Cancelled orders cannot be included in a shipment';
  end if;
  return query with group_orders as (
    select o.* from public.orders o
    where o.id=p_order_id or o.id in (select m.order_id from public.order_merge_members m where m.root_id=p_order_id)
  ), weights as (
    select oi.quantity, coalesce(oi.weight_grams,p.weight_grams) weight
    from public.order_items oi join group_orders g on g.id=oi.order_id
    left join public.products p on p.id=oi.product_id
  )
  select array_agg(id),sum(total_price)::bigint,
    coalesce(sum(total_price) filter (where payment_method='CASH_ON_DELIVERY' and payment_status<>'PAID'),0)::bigint,
    (select case when count(*)=count(weight) then sum(weight::bigint*quantity)::bigint end from weights)
  from group_orders;
end;
$$;

-- For a reopened order only fulfilment in the current cycle qualifies a new procurement credit.
alter table public.orders add column reopened_procurement_progressed boolean;
drop trigger restock_cancelled_procurement on public.orders;
create trigger restock_cancelled_procurement after update of status on public.orders
for each row when (new.payment_method='ONLINE' and not coalesce(new.payment_test_mode,new.monobank_test_mode)
  and new.status in ('CANCELLED_BY_USER','CANCELLED_BY_STORE') and old.status not in ('CANCELLED_BY_USER','CANCELLED_BY_STORE')
  and old.reopened_procurement_progressed is not false)
execute function public.restock_cancelled_procurement();

create function public.protect_merged_shipment_during_creation() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if exists(select from public.order_merge_members m join public.order_ttn_reservations r on r.order_id=m.root_id
    where m.order_id=old.id) then raise exception 'TTN creation is in progress for one of these orders'; end if;
  return new;
end; $$;
create trigger protect_merged_shipment_during_creation before update of status,payment_status on public.orders for each row
when(old.status is distinct from new.status or old.payment_status is distinct from new.payment_status)
execute function public.protect_merged_shipment_during_creation();

create function public.correct_reopened_order() returns trigger language plpgsql
security definer set search_path = '' as $$
declare
  item record;
  source text := current_setting('tatami.reopen_source',true);
  received text := current_setting('tatami.cod_received',true);
begin
  if old.status = 'COMPLETED' and old.payment_method = 'CASH_ON_DELIVERY'
    and old.payment_status = 'PAID' and old.total_price > 0 then
    if coalesce(received,'') not in ('yes','no') then raise exception 'Confirm COD collection'; end if;
    if received = 'no' then new.payment_status := 'PENDING'; end if;
  end if;
  if old.status in ('CANCELLED_BY_USER','CANCELLED_BY_STORE') and new.status not in ('CANCELLED_BY_USER','CANCELLED_BY_STORE') then
    new.reopened_procurement_progressed := new.status in ('WAITING_FOR_STOCK','PREPARING_SHIPMENT','IN_TRANSIT','DELIVERED','COMPLETED');
    for item in select * from public.order_items where order_id=new.id
      and not coalesce(stock_deducted,not is_preorder) order by variant_id,id for update
    loop
      if coalesce(source,'') not in ('stock','supplier') then raise exception 'Choose stock for reopened orders'; end if;
      if source = 'stock' then
        update public.product_variants set stock_quantity=stock_quantity-item.quantity
          where id=item.variant_id and stock_quantity>=item.quantity;
        if not found then raise exception 'Not enough stock to reopen the order'; end if;
        update public.order_items set stock_deducted=true, procurement_restocked=null where id=item.id;
      else
        update public.order_items set procurement_restocked=case when new.payment_method='ONLINE' then false end where id=item.id;
      end if;
    end loop;
  elsif old.reopened_procurement_progressed is false and new.status in ('WAITING_FOR_STOCK','PREPARING_SHIPMENT','IN_TRANSIT','DELIVERED','COMPLETED') then
    new.reopened_procurement_progressed := true;
  end if;
  return new;
end; $$;
create trigger correct_reopened_order before update of status on public.orders for each row
when(old.status is distinct from new.status and not coalesce(old.payment_test_mode,old.monobank_test_mode))
execute function public.correct_reopened_order();

create function public.correct_admin_order_status(p_order_ids uuid[],p_status public.order_status,
  p_confirm_paid boolean,p_restore_stock boolean,p_source text,p_received text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb;
begin
  perform set_config('tatami.reopen_source',coalesce(p_source,''),true);
  perform set_config('tatami.cod_received',coalesce(p_received,''),true);
  result := public.update_admin_orders_with_stock_notice(p_order_ids,p_status,p_confirm_paid,p_restore_stock);
  perform set_config('tatami.reopen_source','',true);
  perform set_config('tatami.cod_received','',true);
  return result;
end; $$;
revoke all on function public.correct_admin_order_status(uuid[],public.order_status,boolean,boolean,text,text) from public,anon;
grant execute on function public.correct_admin_order_status(uuid[],public.order_status,boolean,boolean,text,text) to authenticated;

-- The customer keeps this unguessable request ID across network retries.
create table public.cod_checkout_requests(
  request_id uuid primary key, fingerprint text not null, order_id uuid not null references public.orders on delete cascade
);
alter table public.cod_checkout_requests enable row level security;
revoke all on public.cod_checkout_requests from public,anon,authenticated;
create function public.place_cod_order(p_request_id uuid,p_order jsonb) returns public.orders
language plpgsql security definer set search_path='' as $$
declare
  fingerprint text := encode(extensions.digest(jsonb_build_array(auth.uid(),p_order)::text,'sha256'),'hex');
  previous public.cod_checkout_requests;
  result public.orders;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
  select * into previous from public.cod_checkout_requests where request_id=p_request_id;
  if found then
    if previous.fingerprint <> fingerprint then raise exception 'Checkout request changed'; end if;
    select * into strict result from public.orders where id=previous.order_id;
  else
    result := public.create_discounted_store_order((p_order->>'p_store_id')::uuid,p_order->'p_items',
      p_order->>'p_customer_name',p_order->>'p_customer_email',p_order->>'p_customer_phone',p_order->>'p_delivery_city',
      p_order->>'p_delivery_address',p_order->>'p_note',p_order->>'p_delivery_city_ref',p_order->>'p_delivery_address_ref',
      p_order->>'p_delivery_service_type',(p_order->>'p_expected_discount_percent')::numeric,(p_order->>'p_expected_total')::integer);
    insert into public.cod_checkout_requests values(p_request_id,fingerprint,result.id);
  end if;
  return result;
end; $$;
revoke all on function public.place_cod_order(uuid,jsonb) from public;
grant execute on function public.place_cod_order(uuid,jsonb) to anon,authenticated;
create function public.recover_cod_receipt(p_request_id uuid) returns text
language sql stable security definer set search_path='' as $$
  select o.receipt_code from public.cod_checkout_requests r join public.orders o on o.id=r.order_id
  where r.request_id=p_request_id and o.user_id is not distinct from auth.uid();
$$;
revoke all on function public.recover_cod_receipt(uuid) from public;
grant execute on function public.recover_cod_receipt(uuid) to anon,authenticated;

create function public.existing_import_orders(p_store uuid,p_ids uuid[]) returns setof uuid
language sql stable security invoker set search_path='' as $$
  select id from public.orders where store_id=p_store and id=any(p_ids) and public.is_store_member(p_store);
$$;
revoke all on function public.existing_import_orders(uuid,uuid[]) from public,anon;
grant execute on function public.existing_import_orders(uuid,uuid[]) to authenticated;
notify pgrst,'reload schema';
commit;
