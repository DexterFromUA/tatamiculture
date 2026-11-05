create table public.store_payment_methods (
  store_id uuid primary key references public.stores(id) on delete cascade,
  cash_on_delivery boolean not null default true,
  liqpay boolean not null default true,
  monobank boolean not null default true
);
alter table public.store_payment_methods enable row level security;
revoke all on public.store_payment_methods from public, anon, authenticated;
grant select on public.store_payment_methods to anon, authenticated;
grant insert, update on public.store_payment_methods to authenticated;
create policy "public read payment methods" on public.store_payment_methods for select using (true);
create policy "staff insert payment methods" on public.store_payment_methods for insert to authenticated
  with check (public.is_store_member(store_id));
create policy "staff update payment methods" on public.store_payment_methods for update to authenticated
  using (public.is_store_member(store_id)) with check (public.is_store_member(store_id));

-- Only the payment edge functions may select an online provider and pass a verified customer ID.
create function public.create_order_with_payment(
  p_provider text,
  p_user_id uuid,
  p_store_id uuid,
  p_items jsonb,
  p_customer_name text,
  p_customer_email text,
  p_customer_phone text,
  p_delivery_city text,
  p_delivery_address text,
  p_note text default '',
  p_delivery_city_ref text default null,
  p_delivery_address_ref text default null,
  p_delivery_service_type text default null
) returns public.orders
language plpgsql security definer set search_path = public as $$
declare
  v_order public.orders;
  v_item jsonb;
  v_variant public.product_variants;
  v_product public.products;
  v_quantity integer;
  v_total integer := 0;
  v_unit_price integer;
begin
  if p_provider is null or p_provider not in ('CASH_ON_DELIVERY', 'LIQPAY', 'MONOBANK') then
    raise exception 'Invalid payment method';
  end if;
  if not coalesce((
    select case p_provider
      when 'CASH_ON_DELIVERY' then cash_on_delivery
      when 'LIQPAY' then liqpay
      when 'MONOBANK' then monobank
    end
    from public.store_payment_methods where store_id = p_store_id
  ), true) then
    raise sqlstate 'PT409' using message = 'This payment method is no longer available.';
  end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Cart is empty';
  end if;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_quantity := (v_item ->> 'quantity')::integer;
    if v_quantity is null or v_quantity < 1 or v_quantity > 20 then
      raise exception 'Invalid item quantity';
    end if;
    select pv.* into v_variant
    from public.product_variants pv
    join public.products p on p.id = pv.product_id
    where pv.id = (v_item ->> 'variantId')::uuid and p.store_id = p_store_id and p.is_active
    for update of pv;
    if not found then raise exception 'Product is no longer available'; end if;
    select * into v_product from public.products where id = v_variant.product_id;
    if not v_variant.is_preorder and v_variant.stock_quantity < v_quantity then
      raise exception 'Insufficient stock for %', v_product.name;
    end if;
    v_unit_price := v_variant.price;
    v_total := v_total + v_unit_price * v_quantity;
  end loop;

  insert into public.orders (
    store_id, user_id, customer_name, customer_email, customer_phone,
    delivery_city, delivery_address, note, total_price, currency,
    delivery_city_ref, delivery_address_ref, delivery_service_type, payment_method
  )
  select p_store_id, p_user_id, trim(p_customer_name), lower(trim(p_customer_email)), trim(p_customer_phone),
    trim(p_delivery_city), trim(p_delivery_address), trim(p_note), v_total, s.currency,
    nullif(trim(p_delivery_city_ref), ''), nullif(trim(p_delivery_address_ref), ''),
    case when p_delivery_service_type in ('WarehouseWarehouse', 'WarehousePostomat') then p_delivery_service_type else null end,
    case when p_provider = 'CASH_ON_DELIVERY' then 'CASH_ON_DELIVERY' else 'ONLINE' end
  from public.stores s where s.id = p_store_id
  returning * into v_order;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_quantity := (v_item ->> 'quantity')::integer;
    select * into v_variant from public.product_variants where id = (v_item ->> 'variantId')::uuid for update;
    select * into v_product from public.products where id = v_variant.product_id;
    insert into public.order_items (order_id, product_id, variant_id, product_name, variant_name, quantity, unit_price, compare_at_price, line_total, is_preorder)
    values (v_order.id, v_product.id, v_variant.id, v_product.name, v_variant.name, v_quantity, v_variant.price, v_variant.compare_at_price, v_variant.price * v_quantity, v_variant.is_preorder);
    if not v_variant.is_preorder then
      update public.product_variants set stock_quantity = stock_quantity - v_quantity where id = v_variant.id;
    end if;
  end loop;

  insert into public.order_status_history (order_id, status, author_id) values (v_order.id, v_order.status, p_user_id);
  return v_order;
end;
$$;

revoke all on function public.create_order_with_payment(text, uuid, uuid, jsonb, text, text, text, text, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.create_order_with_payment(text, uuid, uuid, jsonb, text, text, text, text, text, text, text, text, text)
  to service_role;

-- Keep the existing storefront RPC and its arguments for cash on delivery.
create or replace function public.create_store_order(
  p_store_id uuid,
  p_items jsonb,
  p_customer_name text,
  p_customer_email text,
  p_customer_phone text,
  p_delivery_city text,
  p_delivery_address text,
  p_note text default '',
  p_delivery_city_ref text default null,
  p_delivery_address_ref text default null,
  p_delivery_service_type text default null
) returns public.orders
language sql security definer set search_path = '' as $$
  select public.create_order_with_payment(
    'CASH_ON_DELIVERY', auth.uid(), p_store_id, p_items, p_customer_name, p_customer_email,
    p_customer_phone, p_delivery_city, p_delivery_address, p_note, p_delivery_city_ref,
    p_delivery_address_ref, p_delivery_service_type
  );
$$;
