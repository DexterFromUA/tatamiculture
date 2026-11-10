-- Preserve historical statuses when grouping. The primary order supplies the displayed status.
create or replace function public.merge_orders(p_order_ids uuid[], p_target_id uuid)
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
  update public.orders set crm_customer_id=target.crm_customer_id
    where id=any(ids) and id<>p_target_id;
  insert into public.order_events(order_id,kind,new_value,author_id)
    select id,'merge',p_target_id::text,auth.uid() from public.orders where id=any(ids);
  return p_target_id;
end; $$;
