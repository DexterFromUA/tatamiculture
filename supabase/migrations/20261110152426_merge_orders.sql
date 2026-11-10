-- Orders keep their original receipts, payments, line items and audit history.
-- This table groups them for fulfilment without changing payment-provider IDs.
create table public.order_merge_members (
  order_id uuid primary key references public.orders(id),
  root_id uuid not null references public.orders(id),
  created_at timestamptz not null default now(),
  author_id uuid references auth.users(id)
);
create index order_merge_members_root_idx on public.order_merge_members(root_id);
alter table public.order_merge_members enable row level security;
create policy "staff read merged orders" on public.order_merge_members for select to authenticated
  using (exists (select 1 from public.orders o where o.id=order_id and public.is_store_member(o.store_id)));
grant select on public.order_merge_members to authenticated;

create table public.order_ttn_reservations (
  order_id uuid primary key references public.orders(id),
  created_at timestamptz not null default now()
);
alter table public.order_ttn_reservations enable row level security;

create function public.merge_orders(p_order_ids uuid[], p_target_id uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
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
  update public.orders set crm_customer_id=target.crm_customer_id, status=target.status
    where id=any(ids) and id<>p_target_id;
  insert into public.order_events(order_id,kind,new_value,author_id)
    select id,'merge',p_target_id::text,auth.uid() from public.orders where id=any(ids);
  return p_target_id;
end; $$;
revoke all on function public.merge_orders(uuid[],uuid) from public;
grant execute on function public.merge_orders(uuid[],uuid) to authenticated;

create function public.change_merged_order_status(p_order_id uuid, p_status public.order_status)
returns public.orders language plpgsql security definer set search_path='' as $$
declare target public.orders; item record;
begin
  select * into target from public.orders where id=p_order_id;
  if target.id is null or not coalesce(public.is_store_member(target.store_id),false) then raise exception 'Access denied'; end if;
  for item in select id from public.orders where id=p_order_id or id in
    (select order_id from public.order_merge_members where root_id=p_order_id) order by id
  loop
    perform public.change_order_status(item.id,p_status);
  end loop;
  select * into target from public.orders where id=p_order_id;
  return target;
end; $$;
revoke all on function public.change_merged_order_status(uuid,public.order_status) from public;
grant execute on function public.change_merged_order_status(uuid,public.order_status) to authenticated;

create function public.cancel_merged_unpaid_order(p_order_id uuid)
returns public.orders language plpgsql security definer set search_path='' as $$
declare target public.orders; item record;
begin
  select * into target from public.orders where id=p_order_id;
  if target.id is null or not coalesce(public.is_store_member(target.store_id),false) then raise exception 'Access denied'; end if;
  for item in select id from public.orders where id=p_order_id or id in
    (select order_id from public.order_merge_members where root_id=p_order_id) order by id
  loop
    perform public.cancel_unpaid_order(item.id);
  end loop;
  select * into target from public.orders where id=p_order_id;
  return target;
end; $$;
revoke all on function public.cancel_merged_unpaid_order(uuid) from public;
grant execute on function public.cancel_merged_unpaid_order(uuid) to authenticated;

create function public.reserve_order_ttn(p_order_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare target public.orders;
begin
  select * into target from public.orders where id=p_order_id;
  if target.id is null then raise exception 'Order not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || target.store_id::text, 0));
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
create function public.release_order_ttn(p_order_id uuid) returns void
language sql security definer set search_path='' as $$
  delete from public.order_ttn_reservations where order_id=p_order_id;
$$;
revoke all on function public.reserve_order_ttn(uuid), public.release_order_ttn(uuid) from public, anon, authenticated;
grant execute on function public.reserve_order_ttn(uuid), public.release_order_ttn(uuid) to service_role;

-- Summarize a group only for service-role integrations. A receipt remains an
-- individual, private snapshot and never exposes another customer's details.
create function public.merged_order_shipping(p_order_id uuid)
returns table(order_ids uuid[],total_minor bigint,cod_minor bigint,weight_grams bigint)
language sql stable security definer set search_path='' as $$
  with group_orders as (
    select o.* from public.orders o
    where o.id=p_order_id or o.id in (select m.order_id from public.order_merge_members m where m.root_id=p_order_id)
  ), weights as (
    select oi.quantity, coalesce(oi.weight_grams,p.weight_grams) weight
    from public.order_items oi join group_orders g on g.id=oi.order_id
    left join public.products p on p.id=oi.product_id
  )
  select array_agg(id),sum(total_price)::bigint,
    coalesce(sum(total_price) filter (where payment_method='CASH_ON_DELIVERY' and payment_status<>'PAID'),0)::bigint,
    (select case when count(*)=count(weight) then sum(weight::bigint*quantity) end from weights)
  from group_orders;
$$;
revoke all on function public.merged_order_shipping(uuid) from public, anon, authenticated;
grant execute on function public.merged_order_shipping(uuid) to service_role;
notify pgrst, 'reload schema';
