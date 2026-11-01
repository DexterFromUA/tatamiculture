-- Release stock held by an unpaid order that could not reach the payment page.
-- This is deliberately a separate action from a normal status change, so stock
-- cannot be returned accidentally for an already paid order.
create or replace function public.cancel_unpaid_order(p_order_id uuid)
returns public.orders
language plpgsql security definer set search_path = public as $$
declare
  v_order public.orders;
  v_item public.order_items;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found or not public.is_store_member(v_order.store_id) then
    raise exception 'You do not have access to this order';
  end if;
  if v_order.payment_status = 'PAID' then
    raise exception 'A paid order cannot be cancelled with stock restoration';
  end if;
  if v_order.status <> 'PENDING' then
    raise exception 'Only pending unpaid orders can be cancelled with stock restoration';
  end if;

  for v_item in select * from public.order_items where order_id = v_order.id loop
    if not v_item.is_preorder and v_item.variant_id is not null then
      update public.product_variants
      set stock_quantity = stock_quantity + v_item.quantity
      where id = v_item.variant_id;
    end if;
  end loop;

  update public.orders
  set status = 'CANCELLED_BY_STORE', payment_status = 'FAILED'
  where id = v_order.id
  returning * into v_order;

  update public.payments
  set status = 'FAILED', updated_at = now()
  where order_id = v_order.id and status = 'PENDING';

  insert into public.order_status_history (order_id, status, author_id)
  values (v_order.id, v_order.status, auth.uid());
  return v_order;
end;
$$;

grant execute on function public.cancel_unpaid_order(uuid) to authenticated;
