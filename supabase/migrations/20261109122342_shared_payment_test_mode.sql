-- NULL preserves the separate provider modes until a manager sets the shared mode.
alter table public.store_payment_methods add column payment_test_mode boolean;

-- Older LiqPay orders have no stored mode. Their webhook continues to use the legacy pair.
alter table public.orders
  add column payment_test_mode boolean,
  add constraint test_payment_has_no_fulfilment check (
    payment_test_mode is not true or (
      nova_poshta_ttn is null and status in ('PENDING', 'PAID', 'CANCELLED_BY_USER', 'CANCELLED_BY_STORE')
    )
  );

update public.orders set payment_test_mode = true where monobank_test_mode;

-- Keep the deployed RPC argument name and the existing COD overload for compatibility.
create or replace function public.create_order_with_payment(
  p_provider text,
  p_user_id uuid,
  p_store_id uuid,
  p_items jsonb,
  p_customer_name text,
  p_customer_email text,
  p_customer_phone text,
  p_delivery_city text,
  p_delivery_address text,
  p_note text,
  p_delivery_city_ref text,
  p_delivery_address_ref text,
  p_delivery_service_type text,
  p_monobank_test_mode boolean
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
  v_monobank_test_mode boolean;
  v_shared_test_mode boolean;
  v_test_mode boolean;
  v_method_enabled boolean;
begin
  if p_provider is null or p_provider not in ('CASH_ON_DELIVERY', 'LIQPAY', 'MONOBANK') then
    raise exception 'Invalid payment method';
  end if;
  select case p_provider
    when 'CASH_ON_DELIVERY' then cash_on_delivery
    when 'LIQPAY' then liqpay
    when 'MONOBANK' then monobank
  end, monobank_test_mode, payment_test_mode
  into v_method_enabled, v_monobank_test_mode, v_shared_test_mode
  from public.store_payment_methods where store_id = p_store_id;

  if not coalesce(v_method_enabled, true) then
    raise sqlstate 'PT409' using message = 'This payment method is no longer available.';
  end if;
  v_test_mode := p_provider <> 'CASH_ON_DELIVERY' and coalesce(
    v_shared_test_mode,
    case when p_provider = 'MONOBANK' then v_monobank_test_mode
         when p_provider = 'LIQPAY' then p_monobank_test_mode end,
    false
  );
  if coalesce(p_monobank_test_mode, false) is distinct from v_test_mode
     or (p_monobank_test_mode is null and v_shared_test_mode is not null) then
    raise sqlstate 'PT409' using message = 'Payment settings changed. Please try again.';
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
    delivery_city_ref, delivery_address_ref, delivery_service_type, payment_method, monobank_test_mode, payment_test_mode
  )
  select p_store_id, p_user_id, trim(p_customer_name), lower(trim(p_customer_email)), trim(p_customer_phone),
    trim(p_delivery_city), trim(p_delivery_address), trim(p_note), v_total, s.currency,
    nullif(trim(p_delivery_city_ref), ''), nullif(trim(p_delivery_address_ref), ''),
    case when p_delivery_service_type in ('WarehouseWarehouse', 'WarehousePostomat') then p_delivery_service_type else null end,
    case when p_provider = 'CASH_ON_DELIVERY' then 'CASH_ON_DELIVERY' else 'ONLINE' end,
    p_provider = 'MONOBANK' and v_test_mode,
    case when p_provider = 'LIQPAY' and p_monobank_test_mode is null then null else v_test_mode end
  from public.stores s where s.id = p_store_id
  returning * into v_order;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_quantity := (v_item ->> 'quantity')::integer;
    select * into v_variant from public.product_variants where id = (v_item ->> 'variantId')::uuid for update;
    select * into v_product from public.products where id = v_variant.product_id;
    insert into public.order_items (order_id, product_id, variant_id, product_name, variant_name, quantity, unit_price, compare_at_price, line_total, is_preorder)
    values (v_order.id, v_product.id, v_variant.id, v_product.name, v_variant.name, v_quantity, v_variant.price, v_variant.compare_at_price, v_variant.price * v_quantity, v_variant.is_preorder);
    if not v_test_mode and not v_variant.is_preorder then
      update public.product_variants set stock_quantity = stock_quantity - v_quantity where id = v_variant.id;
    end if;
  end loop;

  insert into public.order_status_history (order_id, status, author_id) values (v_order.id, v_order.status, p_user_id);
  return v_order;
end;
$$;

create or replace function public.create_order_with_payment(
  p_provider text, p_user_id uuid, p_store_id uuid, p_items jsonb,
  p_customer_name text, p_customer_email text, p_customer_phone text,
  p_delivery_city text, p_delivery_address text, p_note text default '',
  p_delivery_city_ref text default null, p_delivery_address_ref text default null,
  p_delivery_service_type text default null
) returns public.orders
language sql security definer set search_path = '' as $$
  select public.create_order_with_payment(
    p_provider, p_user_id, p_store_id, p_items, p_customer_name, p_customer_email,
    p_customer_phone, p_delivery_city, p_delivery_address, p_note, p_delivery_city_ref,
    p_delivery_address_ref, p_delivery_service_type, case when p_provider = 'LIQPAY' then null else false end
  );
$$;

create or replace function public.attach_crm_customer() returns trigger language plpgsql security definer set search_path='' as $$
declare identity_key text;
begin
 if coalesce(new.payment_test_mode, new.monobank_test_mode) then return new; end if;
 identity_key := case when new.user_id is not null then 'user:'||new.user_id::text
  when length(regexp_replace(new.customer_phone,'[^0-9]','','g'))>=9 then 'phone:'||regexp_replace(new.customer_phone,'[^0-9]','','g')
  when trim(new.customer_email)<>'' then 'email:'||lower(trim(new.customer_email)) else 'order:'||new.id::text end;
 new.crm_customer_id := public.crm_identity(new.store_id,identity_key,new.customer_name,new.customer_phone,new.customer_email);
 return new;
end; $$;

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
    if not coalesce(v_order.payment_test_mode, v_order.monobank_test_mode) and not v_item.is_preorder and v_item.variant_id is not null then
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
