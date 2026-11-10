-- A manager marking an order as paid also confirms its payment state. Provider
-- payment records remain separate and retain their original audit trail.
create or replace function public.change_order_status(p_order_id uuid, p_status public.order_status)
returns public.orders language plpgsql security definer set search_path = '' as $$
declare v_order public.orders;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found or not coalesce(public.is_store_member(v_order.store_id), false) then
    raise exception 'You do not have access to this order';
  end if;
  update public.orders
  set status = p_status,
      payment_status = case when p_status = 'PAID' then 'PAID'::public.payment_status else payment_status end
  where id = p_order_id returning * into v_order;
  insert into public.order_status_history (order_id, status, author_id)
  values (v_order.id, v_order.status, auth.uid());
  return v_order;
end;
$$;
