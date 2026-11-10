alter table public.orders add column payment_status_set_by_admin boolean not null default false;

-- Payment webhooks write as service_role. Keep their provider records intact,
-- but prevent their order updates from overwriting an explicit admin decision.
create function public.protect_manual_order_payment()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.status := old.status;
  new.payment_status := old.payment_status;
  return new;
end;
$$;

create trigger protect_manual_order_payment
before update of status, payment_status on public.orders
for each row
when (old.payment_status_set_by_admin and current_user = 'service_role')
execute function public.protect_manual_order_payment();

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
      payment_status = case p_status
        when 'PAID' then 'PAID'::public.payment_status
        when 'PENDING' then 'PENDING'::public.payment_status
        else payment_status
      end,
      payment_status_set_by_admin = payment_status_set_by_admin or p_status in ('PAID', 'PENDING')
  where id = p_order_id returning * into v_order;
  insert into public.order_status_history (order_id, status, author_id)
  values (v_order.id, v_order.status, auth.uid());
  return v_order;
end;
$$;
