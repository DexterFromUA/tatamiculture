-- Keep Nova Poshta references selected at checkout.  Names alone are not
-- sufficient to issue an InternetDocument reliably.
alter table public.orders
  add column delivery_city_ref text,
  add column delivery_address_ref text,
  add column delivery_service_type text,
  add column nova_poshta_ttn text unique,
  add column nova_poshta_document_ref text unique,
  add column nova_poshta_ttn_created_at timestamptz;

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
    delivery_city_ref, delivery_address_ref, delivery_service_type
  )
  select p_store_id, auth.uid(), trim(p_customer_name), lower(trim(p_customer_email)), trim(p_customer_phone),
    trim(p_delivery_city), trim(p_delivery_address), trim(p_note), v_total, s.currency,
    nullif(trim(p_delivery_city_ref), ''), nullif(trim(p_delivery_address_ref), ''),
    case when p_delivery_service_type in ('WarehouseWarehouse', 'WarehousePostomat') then p_delivery_service_type else null end
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

  insert into public.order_status_history (order_id, status, author_id) values (v_order.id, v_order.status, auth.uid());
  return v_order;
end;
$$;

-- PostgREST sees overloads by their exact argument list.  Remove the former
-- eight-argument variant so it does not become ambiguous for checkout.
drop function if exists public.create_store_order(uuid, jsonb, text, text, text, text, text, text);
grant execute on function public.create_store_order(uuid, jsonb, text, text, text, text, text, text, text, text, text) to anon, authenticated;
