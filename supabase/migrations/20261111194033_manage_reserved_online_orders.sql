alter table public.orders add column reserved_in_profile boolean not null default false;

alter table public.payments
  add column checkout_url text,
  add column checkout_managed boolean not null default false,
  add column checkout_started boolean not null default false,
  add column checkout_operation uuid,
  add column checkout_operation_until timestamptz;

-- Reserve stock and save the payment reference in the same transaction.
create function public.create_reserved_online_order(
  p_provider text, p_user_id uuid, p_store_id uuid, p_items jsonb,
  p_customer_name text, p_customer_email text, p_customer_phone text,
  p_delivery_city text, p_delivery_address text, p_note text,
  p_delivery_city_ref text, p_delivery_address_ref text, p_delivery_service_type text,
  p_monobank_test_mode boolean
) returns public.orders
language plpgsql security definer set search_path = '' as $$
declare
  v_order public.orders;
begin
  if p_user_id is null or p_provider not in ('LIQPAY', 'MONOBANK') then
    raise exception 'Invalid reservation';
  end if;
  v_order := public.create_order_with_payment(
    p_provider, p_user_id, p_store_id, p_items, p_customer_name, p_customer_email, p_customer_phone,
    p_delivery_city, p_delivery_address, p_note, p_delivery_city_ref, p_delivery_address_ref,
    p_delivery_service_type, p_monobank_test_mode
  );
  insert into public.payments (order_id, provider, provider_order_id, checkout_managed)
  values (v_order.id, p_provider, v_order.id::text, true);
  update public.orders set reserved_in_profile = true where id = v_order.id returning * into v_order;
  return v_order;
end;
$$;

create function public.begin_reserved_order_action(p_order_id uuid, p_user_id uuid, p_operation uuid)
returns public.payments
language plpgsql security definer set search_path = '' as $$
declare
  v_order public.orders;
  v_payment public.payments;
begin
  select * into v_order from public.orders
  where id = p_order_id and user_id = p_user_id for update;
  if not found or v_order.payment_method <> 'ONLINE' then
    raise sqlstate 'PT404' using message = 'Order not found';
  end if;
  if v_order.status <> 'PENDING' or v_order.payment_status not in ('PENDING', 'FAILED') then
    raise sqlstate 'PT409' using message = 'This reservation is no longer awaiting payment.';
  end if;

  select * into v_payment from public.payments where order_id = p_order_id for update;
  if not found or v_payment.status not in ('PENDING', 'FAILED') then
    raise sqlstate 'PT409' using message = 'This reservation is no longer awaiting payment.';
  end if;
  if v_payment.checkout_operation_until > now() then
    raise sqlstate 'PT409' using message = 'Another payment action is in progress. Try again shortly.';
  end if;

  update public.payments
  set checkout_operation = p_operation, checkout_operation_until = now() + interval '90 seconds'
  where id = v_payment.id returning * into v_payment;
  return v_payment;
end;
$$;

create function public.cancel_customer_reservation(
  p_order_id uuid, p_user_id uuid, p_operation uuid, p_provider_order_id text
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_order public.orders;
  v_payment public.payments;
  v_item record;
begin
  select * into v_order from public.orders where id = p_order_id and user_id = p_user_id for update;
  if not found or v_order.status <> 'PENDING' or v_order.payment_method <> 'ONLINE'
      or v_order.payment_status not in ('PENDING', 'FAILED') then
    raise sqlstate 'PT409' using message = 'This reservation is no longer awaiting payment.';
  end if;

  select * into v_payment from public.payments where order_id = p_order_id for update;
  if not found or v_payment.status not in ('PENDING', 'FAILED')
      or v_payment.provider_order_id is distinct from p_provider_order_id
      or v_payment.checkout_operation is distinct from p_operation or p_operation is null
      or v_payment.checkout_operation_until <= now() then
    raise sqlstate 'PT409' using message = 'This reservation is no longer awaiting payment.';
  end if;

  if not coalesce(v_order.payment_test_mode, v_order.monobank_test_mode) then
    for v_item in
      select variant_id, sum(quantity)::integer as quantity from public.order_items
      where order_id = p_order_id and not is_preorder and variant_id is not null
      group by variant_id order by variant_id
    loop
      update public.product_variants set stock_quantity = stock_quantity + v_item.quantity where id = v_item.variant_id;
    end loop;
  end if;

  update public.orders set status = 'CANCELLED_BY_USER', payment_status = 'FAILED' where id = p_order_id;
  update public.payments set status = 'FAILED', checkout_url = null,
    checkout_operation = null, checkout_operation_until = null where id = v_payment.id;
  insert into public.order_status_history (order_id, status, author_id)
  values (p_order_id, 'CANCELLED_BY_USER', p_user_id);
end;
$$;

-- Take locks in the same order as cancellation and CRM status changes.
create function public.apply_online_payment_callback(
  p_provider text, p_reference text, p_paid boolean, p_payment_id text, p_callback jsonb
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_order public.orders;
  v_payment public.payments;
  v_status public.payment_status := case when p_paid then 'PAID' else 'FAILED' end;
begin
  select o.* into v_order from public.orders o
  join public.payments p on p.order_id = o.id
  where p.provider = p_provider and p.provider_order_id = p_reference
  for update of o;
  if not found or v_order.status = 'CANCELLED_BY_USER' then return; end if;

  select * into v_payment from public.payments
  where order_id = v_order.id and provider = p_provider and provider_order_id = p_reference for update;
  if not found or v_payment.status = 'REFUNDED' or (not p_paid and v_payment.status = 'PAID') then return; end if;

  update public.payments set status = v_status,
    provider_payment_id = coalesce(p_payment_id, provider_payment_id), raw_callback = p_callback
  where id = v_payment.id;

  if v_order.payment_status in ('PENDING', 'FAILED') or (p_paid and v_order.payment_status = 'PAID' and v_order.status = 'PENDING') then
    update public.orders set payment_status = v_status,
      status = case when p_paid and status = 'PENDING' then 'PAID'::public.order_status else status end
    where id = v_order.id;
  end if;
end;
$$;

revoke all on function public.create_reserved_online_order(text, uuid, uuid, jsonb, text, text, text, text, text, text, text, text, text, boolean) from public, anon, authenticated;
revoke all on function public.begin_reserved_order_action(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.cancel_customer_reservation(uuid, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.apply_online_payment_callback(text, text, boolean, text, jsonb) from public, anon, authenticated;
grant execute on function public.create_reserved_online_order(text, uuid, uuid, jsonb, text, text, text, text, text, text, text, text, text, boolean) to service_role;
grant execute on function public.begin_reserved_order_action(uuid, uuid, uuid) to service_role;
grant execute on function public.cancel_customer_reservation(uuid, uuid, uuid, text) to service_role;
grant execute on function public.apply_online_payment_callback(text, text, boolean, text, jsonb) to service_role;
