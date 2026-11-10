drop trigger protect_manual_order_payment on public.orders;
drop function public.protect_manual_order_payment();
alter table public.orders drop column payment_status_set_by_admin;

alter function public.cancel_unpaid_order(uuid) rename to restore_stock_and_cancel_order;
revoke all on function public.restore_stock_and_cancel_order(uuid) from public, anon, authenticated, service_role;

create function public.apply_admin_order_update(
  p_order_ids uuid[], p_status public.order_status, p_confirm_paid boolean,
  p_include_group boolean, p_restore_stock boolean
) returns setof public.orders
language plpgsql security definer set search_path = '' as $$
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
    insert into public.order_status_history (order_id, status, author_id)
    select o.id, o.status, auth.uid() from public.orders o where o.id = any(affected_ids);
  end if;

  return query select o.* from public.orders o where o.id = any(affected_ids);
end;
$$;
revoke all on function public.apply_admin_order_update(uuid[], public.order_status, boolean, boolean, boolean)
  from public, anon, authenticated, service_role;

-- The admin UI uses one transaction for single and bulk updates, including each
-- member of a merged order. A declined confirmation leaves the whole batch intact.
create function public.update_admin_orders(
  p_order_ids uuid[], p_status public.order_status, p_confirm_paid boolean default false,
  p_restore_stock boolean default false
) returns jsonb
language sql security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'status', o.status, 'payment_status', o.payment_status)), '[]'::jsonb)
  from public.apply_admin_order_update(p_order_ids, p_status, p_confirm_paid, true, p_restore_stock) o;
$$;
revoke all on function public.update_admin_orders(uuid[], public.order_status, boolean, boolean) from public, anon;
grant execute on function public.update_admin_orders(uuid[], public.order_status, boolean, boolean) to authenticated;

-- Keep the existing RPC entry points subject to the same confirmation guard.
create or replace function public.change_order_status(p_order_id uuid, p_status public.order_status)
returns public.orders language sql security definer set search_path = '' as $$
  select o from public.apply_admin_order_update(array[p_order_id], p_status, false, false, false) o
  where o.id = p_order_id;
$$;

create or replace function public.change_merged_order_status(p_order_id uuid, p_status public.order_status)
returns public.orders language sql security definer set search_path = '' as $$
  select o from public.apply_admin_order_update(array[p_order_id], p_status, false, true, false) o
  where o.id = p_order_id;
$$;

create function public.cancel_unpaid_order(p_order_id uuid)
returns public.orders language sql security definer set search_path = '' as $$
  select o from public.apply_admin_order_update(array[p_order_id], 'CANCELLED_BY_STORE', false, false, true) o
  where o.id = p_order_id;
$$;
revoke all on function public.cancel_unpaid_order(uuid) from public, anon;
grant execute on function public.cancel_unpaid_order(uuid) to authenticated;

create or replace function public.cancel_merged_unpaid_order(p_order_id uuid)
returns public.orders language sql security definer set search_path = '' as $$
  select o from public.apply_admin_order_update(array[p_order_id], 'CANCELLED_BY_STORE', false, true, true) o
  where o.id = p_order_id;
$$;
