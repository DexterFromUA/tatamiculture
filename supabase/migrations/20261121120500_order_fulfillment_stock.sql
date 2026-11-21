begin;

alter table public.orders add column cancel_stock_pending boolean not null default false;

-- Lock and allocate by variant, so a batch or merged order either gets all
-- of its missing stock or remains at its previous stage.
create function public.reserve_order_fulfillment_stock(p_order_ids uuid[]) returns void
language plpgsql set search_path = '' as $$
declare
  demand record;
begin
  if exists (
    select from public.order_items i
    join public.orders o on o.id = i.order_id
    where i.order_id = any(p_order_ids) and not coalesce(o.payment_test_mode, o.monobank_test_mode)
      and not coalesce(i.stock_deducted, not i.is_preorder) and i.variant_id is null
  ) then
    raise exception 'An order item no longer has a stock variant.';
  end if;

  for demand in
    select i.variant_id, sum(i.quantity) as quantity
    from public.order_items i
    join public.orders o on o.id = i.order_id
    where i.order_id = any(p_order_ids) and not coalesce(o.payment_test_mode, o.monobank_test_mode)
      and not coalesce(i.stock_deducted, not i.is_preorder)
    group by i.variant_id order by i.variant_id
  loop
    update public.product_variants as v
    set stock_quantity = (v.stock_quantity - demand.quantity)::integer
    where v.id = demand.variant_id and v.stock_quantity >= demand.quantity;
    if not found then
      raise exception 'There is not enough stock to prepare the order.';
    end if;
  end loop;

  update public.order_items i set stock_deducted = true
  from public.orders o
  where o.id = i.order_id and i.order_id = any(p_order_ids)
    and not coalesce(o.payment_test_mode, o.monobank_test_mode)
    and not coalesce(i.stock_deducted, not i.is_preorder);
end;
$$;
revoke all on function public.reserve_order_fulfillment_stock(uuid[]) from public, anon, authenticated, service_role;

create function public.release_order_fulfillment_stock(p_order_ids uuid[]) returns void
language plpgsql set search_path = '' as $$
declare
  released record;
begin
  for released in
    select i.variant_id, sum(greatest(i.quantity - returned.quantity, 0)) as quantity
    from public.order_items i
    join public.orders o on o.id = i.order_id
    cross join lateral (
      select coalesce(sum(r.quantity), 0) as quantity from public.item_returns r
      where r.item_id = i.id and r.restock and r.status in ('received', 'completed')
    ) returned
    where i.order_id = any(p_order_ids) and not coalesce(o.payment_test_mode, o.monobank_test_mode)
      and coalesce(i.stock_deducted, not i.is_preorder) and i.variant_id is not null
    group by i.variant_id order by i.variant_id
  loop
    if released.quantity > 0 then
      update public.product_variants v set stock_quantity = (v.stock_quantity + released.quantity)::integer
      where v.id = released.variant_id;
    end if;
  end loop;

  -- A return may already have been opened before the cancellation. Whoever
  -- confirms receipt next can complete it without posting the stock twice.
  update public.item_returns r set restock = false
  from public.order_items i, public.orders o
  where r.item_id = i.id and o.id = i.order_id and i.order_id = any(p_order_ids)
    and not coalesce(o.payment_test_mode, o.monobank_test_mode)
    and coalesce(i.stock_deducted, not i.is_preorder) and r.status = 'requested' and r.restock;
  update public.order_items i set stock_deducted = false
  from public.orders o
  where o.id = i.order_id and i.order_id = any(p_order_ids)
    and not coalesce(o.payment_test_mode, o.monobank_test_mode)
    and coalesce(i.stock_deducted, not i.is_preorder);
  update public.orders set cancel_stock_pending = false
  where id = any(p_order_ids) and cancel_stock_pending;
end;
$$;
revoke all on function public.release_order_fulfillment_stock(uuid[]) from public, anon, authenticated, service_role;

-- Staff use this after the parcel is physically back. A cancelled order
-- that was already restocked is a harmless no-op on retry.
create function public.confirm_cancelled_order_stock_return(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  store uuid;
  affected_ids uuid[];
begin
  select o.store_id into store from public.orders o where o.id = p_order_id;
  if store is null or not coalesce(public.is_store_member(store), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || store::text, 0));
  select array_agg(o.id order by o.id) into affected_ids from public.orders o
  where o.store_id = store and (o.id = p_order_id or exists (
    select from public.order_merge_members m where m.root_id = p_order_id and m.order_id = o.id
  ));
  perform o.id from public.orders o where o.id = any(affected_ids) order by o.id for update;
  select array_agg(o.id) into affected_ids from public.orders o
  where o.id = any(affected_ids) and o.status in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER') and o.cancel_stock_pending;
  if affected_ids is not null then
    perform public.release_order_fulfillment_stock(affected_ids);
  end if;
end;
$$;
revoke all on function public.confirm_cancelled_order_stock_return(uuid) from public, anon, service_role;
grant execute on function public.confirm_cancelled_order_stock_return(uuid) to authenticated;

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
  if p_status in ('PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED', 'COMPLETED') then
    select array_agg(o.id) into stock_order_ids from public.orders o
    where o.id = any(affected_ids)
      and o.status in ('PENDING', 'IN_PROGRESS', 'WAITING_FOR_STOCK', 'PREPARING_SHIPMENT')
      and o.nova_poshta_ttn is null and o.nova_poshta_document_ref is null;
    if stock_order_ids is not null then
      perform public.reserve_order_fulfillment_stock(stock_order_ids);
    end if;
  end if;

  if p_status in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER') and not p_restore_stock then
    select array_agg(o.id) into stock_order_ids from public.orders o
    where o.id = any(affected_ids) and o.status in ('PENDING', 'IN_PROGRESS', 'WAITING_FOR_STOCK', 'PREPARING_SHIPMENT')
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
  shipment_ids uuid[];
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
  select array_agg(o.id) into shipment_ids from public.orders o
  where o.id = p_order_id or exists (
    select from public.order_merge_members m where m.root_id=p_order_id and m.order_id=o.id
  );
  perform o.id from public.orders o where o.id = any(shipment_ids) order by o.id for update;
  perform public.reserve_order_fulfillment_stock(shipment_ids);
end; $$;

notify pgrst, 'reload schema';

commit;
