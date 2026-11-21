begin;

-- NULL for stock-backed lines, false for procurement, true once credited.
alter table public.order_items add column procurement_restocked boolean;

update public.order_items i set procurement_restocked = false
from public.orders o
where o.id = i.order_id and o.payment_method = 'ONLINE' and i.stock_deducted = false
  and not coalesce(o.payment_test_mode, o.monobank_test_mode)
  and o.status not in ('CANCELLED_BY_STORE','CANCELLED_BY_USER')
  and not exists (select from public.order_events e where e.order_id = o.id and e.kind = 'status'
    and e.new_value in ('CANCELLED_BY_STORE','CANCELLED_BY_USER'));

create function public.mark_order_procurement() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select from public.orders o where o.id = new.order_id and o.payment_method = 'ONLINE'
    and not coalesce(o.payment_test_mode, o.monobank_test_mode)) then
    new.procurement_restocked := false;
  end if;
  return new;
end;
$$;
create trigger mark_order_procurement before insert on public.order_items
for each row when (new.stock_deducted = false) execute function public.mark_order_procurement();

create function public.restock_cancelled_procurement() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  item record;
  added integer;
  credited integer := 0;
begin
  if old.status not in ('WAITING_FOR_STOCK','PREPARING_SHIPMENT','IN_TRANSIT','DELIVERED','COMPLETED')
    and not exists (select from public.order_events e where e.order_id = new.id and e.kind = 'status'
      and e.new_value in ('WAITING_FOR_STOCK','PREPARING_SHIPMENT','IN_TRANSIT','DELIVERED','COMPLETED')) then
    return new;
  end if;
  for item in select i.* from public.order_items i where i.order_id = new.id
    and i.procurement_restocked = false and i.variant_id is not null order by i.variant_id, i.id for update
  loop
    select greatest(item.quantity - coalesce(sum(r.quantity),0),0) into added
      from public.item_returns r where r.item_id = item.id and r.restock and r.status in ('received','completed');
    if added > 0 then
      update public.product_variants set stock_quantity = stock_quantity + added where id = item.variant_id;
      credited := credited + added;
    end if;
    update public.order_items set procurement_restocked = true where id = item.id;
    update public.item_returns set restock = false where item_id = item.id and restock and status = 'requested';
  end loop;
  if credited > 0 then
    perform set_config('tatami.procurement_credit',
      (coalesce(nullif(current_setting('tatami.procurement_credit', true), ''), '0')::integer + credited)::text, true);
    insert into public.order_events(order_id, kind, new_value, author_id)
      values (new.id, 'procurement_restock', credited::text, auth.uid());
  end if;
  return new;
end;
$$;
create trigger restock_cancelled_procurement after update of status on public.orders
for each row when (new.payment_method = 'ONLINE' and not coalesce(new.payment_test_mode, new.monobank_test_mode)
  and new.status in ('CANCELLED_BY_USER','CANCELLED_BY_STORE')
  and old.status not in ('CANCELLED_BY_USER','CANCELLED_BY_STORE'))
execute function public.restock_cancelled_procurement();

-- Reopening a cancelled order also reopens item returns; keep stock idempotent.
create function public.prevent_duplicate_procurement_return() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select from public.order_items where id = new.item_id and procurement_restocked) then
    new.restock := false;
  end if;
  return new;
end;
$$;
create trigger prevent_duplicate_procurement_return before insert on public.item_returns
for each row when (new.restock) execute function public.prevent_duplicate_procurement_return();

create function public.update_admin_orders_with_stock_notice(
  p_order_ids uuid[], p_status public.order_status, p_confirm_paid boolean, p_restore_stock boolean
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  updated jsonb;
begin
  perform set_config('tatami.procurement_credit', '0', true);
  updated := public.update_admin_orders(p_order_ids,p_status,p_confirm_paid,p_restore_stock);
  return jsonb_build_object('orders', updated, 'stock_added', current_setting('tatami.procurement_credit')::integer);
end;
$$;
revoke all on function public.update_admin_orders_with_stock_notice(uuid[], public.order_status, boolean, boolean) from public, anon;
grant execute on function public.update_admin_orders_with_stock_notice(uuid[], public.order_status, boolean, boolean) to authenticated;
notify pgrst, 'reload schema';
commit;
