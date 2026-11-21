begin;

alter table public.orders add column is_new boolean not null default false;
alter table public.orders drop constraint test_payment_order_status_check;
alter table public.orders add constraint test_payment_order_status_check check (
  not coalesce(payment_test_mode, monobank_test_mode)
  or status in ('PENDING', 'PAID', 'IN_PROGRESS', 'CANCELLED_BY_USER', 'CANCELLED_BY_STORE')
);

-- Historical orders keep their payment state and do not generate new notifications.
alter table public.orders disable trigger orders_capture_events;
update public.orders
set status = case
  when status = 'DELIVERED' and payment_status = 'PAID' then 'COMPLETED'::public.order_status
  when status = 'READY_FOR_PICKUP' and nova_poshta_status_code in ('7', '8') then 'DELIVERED'::public.order_status
  when status = 'READY_FOR_PICKUP' then 'PREPARING_SHIPMENT'::public.order_status
  else 'IN_PROGRESS'::public.order_status
end
where status = 'PAID' or (not coalesce(payment_test_mode, monobank_test_mode)
  and (status = 'READY_FOR_PICKUP'
    or (status = 'DELIVERED' and payment_status = 'PAID')
    or (status = 'PENDING' and payment_method = 'CASH_ON_DELIVERY')));
alter table public.orders enable trigger orders_capture_events;
alter table public.orders add constraint order_status_is_not_payment check (status <> 'PAID');

create function public.apply_order_workflow() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.status = 'PAID' then
      new.status := 'IN_PROGRESS';
      new.is_new := new.payment_method = 'ONLINE' and new.payment_status = 'PAID'
        and not coalesce(new.payment_test_mode, new.monobank_test_mode);
    elsif new.payment_method = 'CASH_ON_DELIVERY' and new.status = 'PENDING' then
      new.status := 'IN_PROGRESS';
    end if;
    return new;
  end if;

  -- Legacy payment callbacks and RPCs may still ask to set the old order
  -- status. Keep fulfillment where it is after processing has started.
  if new.status = 'PAID' then
    new.status := case when old.status = 'PENDING' then 'IN_PROGRESS'::public.order_status else old.status end;
  end if;
  if new.status is distinct from old.status then
    new.is_new := old.status = 'PENDING' and new.status = 'IN_PROGRESS'
      and new.payment_method = 'ONLINE' and new.payment_status = 'PAID'
      and not coalesce(new.payment_test_mode, new.monobank_test_mode)
      and not exists (
        select 1 from public.order_events e where e.order_id = new.id and (
          (e.kind = 'status' and e.new_value in ('IN_PROGRESS', 'PAID'))
          or (e.kind = 'payment_status' and e.new_value = 'PAID')
        )
      );
    if new.status = 'COMPLETED' and new.payment_method = 'CASH_ON_DELIVERY' and new.payment_status = 'PENDING' then
      new.payment_status := 'PAID';
    end if;
  end if;
  return new;
end;
$$;

create trigger apply_order_workflow before insert or update of status on public.orders
for each row execute function public.apply_order_workflow();

CREATE OR REPLACE FUNCTION "public"."apply_admin_order_update"("p_order_ids" "uuid"[], "p_status" "public"."order_status", "p_confirm_paid" boolean, "p_include_group" boolean, "p_restore_stock" boolean) RETURNS SETOF "public"."orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  store uuid;
  affected_ids uuid[];
  order_id uuid;
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

  if p_include_group then
    -- Use the same lock as merge_orders so group membership stays fixed.
    perform pg_advisory_xact_lock(hashtextextended('order-merge:' || store::text, 0));
  end if;
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
  if p_restore_stock then
    foreach order_id in array affected_ids loop
      perform public.restore_stock_and_cancel_order(order_id);
    end loop;
  else
    update public.orders o
    set status = p_status,
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
  v_item public.order_items;
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

  for v_item in select * from public.order_items where order_id = v_order.id loop
    if not coalesce(v_order.payment_test_mode, v_order.monobank_test_mode) and coalesce(v_item.stock_deducted, not v_item.is_preorder) and v_item.variant_id is not null then
      update public.product_variants
      set stock_quantity = stock_quantity + v_item.quantity
      where id = v_item.variant_id;
    end if;
  end loop;

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
declare target public.orders;
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

create or replace function public.crm_orders_page(
  p_store_id uuid, p_page integer, p_page_size integer, p_search text default '',
  p_status text default 'ALL', p_from date default null, p_to date default null,
  p_order_ids uuid[] default null, p_customer_id uuid default null
) returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  search text := lower(btrim(coalesce(p_search, '')));
  order_search text := regexp_replace(search, '^#', '');
  phone_search text := case when search ~ '^[+0-9[:space:]().-]+$'
    then regexp_replace(search, '[^0-9]', '', 'g') else '' end;
begin
  if not public.is_store_member(p_store_id) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  return (
    with matches as materialized (
      select o.id, o.created_at
      from public.orders o
      left join public.order_merge_members membership on membership.order_id = o.id
      cross join lateral (select regexp_replace(o.customer_phone, '[^0-9]', '', 'g') as digits) phone
      where o.store_id = p_store_id
        and (membership.root_id is null or membership.root_id = o.id)
        and (p_status = 'ALL' or (p_status = 'NO_TTN' and coalesce(btrim(o.nova_poshta_ttn), '') = '') or o.status::text = p_status
          or (p_status = 'CANCELLED_BY_STORE' and o.status = 'CANCELLED_BY_USER'))
        and (p_from is null or o.created_at >= (p_from::timestamp at time zone 'Europe/Kyiv'))
        and (p_to is null or o.created_at < ((p_to + 1)::timestamp at time zone 'Europe/Kyiv'))
        and (p_order_ids is null or o.id = any(p_order_ids) or exists (
          select from public.order_merge_members m where m.root_id = o.id and m.order_id = any(p_order_ids)
        ))
        and (p_customer_id is null or o.crm_customer_id = p_customer_id or exists (
          select from public.order_merge_members m join public.orders child on child.id = m.order_id
          where m.root_id = o.id and child.store_id = p_store_id and child.crm_customer_id = p_customer_id
        ))
        and (search = '' or strpos(lower(o.customer_name), search) > 0
          or (phone_search <> '' and (strpos(phone.digits, phone_search) > 0 or (
            length(phone_search) between 9 and 12 and length(phone.digits) >= 9
            and right(phone.digits, 9) = right(phone_search, 9)
          )))
          or (order_search <> '' and (strpos(lower(o.receipt_code), order_search) > 0
            or strpos(lower(o.nova_poshta_ttn), order_search) > 0 or exists (
              select from public.order_merge_members m join public.orders child on child.id = m.order_id
              where m.root_id = o.id and child.store_id = p_store_id
                and (strpos(lower(child.receipt_code), order_search) > 0 or strpos(lower(child.nova_poshta_ttn), order_search) > 0)
            ))))
    ), totals as (select count(*) as matches from matches),
    paging as (
      select totals.matches, w.* from totals cross join lateral public.crm_page_window(totals.matches, p_page, p_page_size) w
    ), page_ids as (
      select id, created_at from matches order by created_at desc, id desc
      limit (select page_size from paging) offset (select row_offset from paging)
    )
    select jsonb_build_object('total', paging.matches, 'page', paging.page, 'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', o.id, 'user_id', o.user_id, 'crm_customer_id', o.crm_customer_id,
        'customer_discount_amount', o.customer_discount_amount, 'receipt_code', o.receipt_code,
        'customer_name', o.customer_name, 'customer_email', o.customer_email, 'customer_phone', o.customer_phone,
        'note', o.note, 'is_new', o.is_new, 'payment_test_mode', o.payment_test_mode, 'status', o.status, 'payment_status', o.payment_status,
        'total_price', coalesce(members.total, o.total_price), 'currency', o.currency, 'created_at', o.created_at,
        'nova_poshta_ttn', o.nova_poshta_ttn, 'nova_poshta_document_ref', o.nova_poshta_document_ref,
        'nova_poshta_status', o.nova_poshta_status, 'nova_poshta_status_code', o.nova_poshta_status_code,
        'payment_method', o.payment_method, 'delivery_city_ref', o.delivery_city_ref, 'delivery_address_ref', o.delivery_address_ref,
        'member_ids', coalesce(members.ids, array[o.id])
      ) order by o.created_at desc, o.id desc)
      from page_ids p join public.orders o on o.id = p.id
      cross join lateral (
        select array_agg(child.id order by child.id) as ids, sum(child.total_price) as total
        from public.order_merge_members m join public.orders child on child.id = m.order_id
        where m.root_id = o.id and child.store_id = p_store_id
      ) members
    ), '[]'::jsonb)) from paging
  );
end;
$$;

CREATE OR REPLACE FUNCTION "public"."request_item_return"("p_id" "uuid", "p_item" "uuid", "p_quantity" integer, "p_reason" "text", "p_restock" boolean, "p_replacement" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare item public.order_items; target public.orders; used bigint; replacement public.product_variants;
begin
 select * into item from public.order_items where id=p_item;
 select * into target from public.orders where id=item.order_id for update;
 if target.id is null or not coalesce(public.is_store_member(target.store_id),false) then raise exception 'Access denied'; end if;
 if exists(select 1 from public.item_returns where id=p_id and order_id=target.id) then return; end if;
 if target.status not in ('DELIVERED', 'COMPLETED') then raise exception 'Only delivered orders can be returned'; end if;
 select coalesce(sum(quantity),0) into used from public.item_returns where item_id=p_item and status<>'cancelled';
 if p_quantity is null or p_quantity<1 or p_quantity+used>item.quantity then raise exception 'Invalid return quantity'; end if;
 if p_replacement is not null then
  select * into replacement from public.product_variants where id=p_replacement;
  if replacement.id is null or replacement.product_id is distinct from item.product_id or replacement.id=item.variant_id
    or replacement.price<>item.unit_price or replacement.is_preorder then raise exception 'Select another size of the same product at the same price'; end if;
 end if;
 insert into public.item_returns(id,order_id,item_id,quantity,reason,restock,replacement_variant,refund_amount,author_id)
 values(p_id,target.id,p_item,p_quantity,trim(p_reason),p_restock,p_replacement,case when p_replacement is null then item.unit_price*p_quantity else 0 end,auth.uid());
 insert into public.order_events(order_id,kind,new_value,author_id) values(target.id,'item_return','requested',auth.uid());
end; $$;

notify pgrst, 'reload schema';

commit;
