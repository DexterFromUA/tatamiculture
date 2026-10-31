-- Run this once only if the initial migration stopped at create_store_order.
-- It replaces the failed function and creates the two RPC functions below it.

create or replace function public.create_store_order(
  p_store_id uuid,
  p_items jsonb,
  p_customer_name text,
  p_customer_email text,
  p_customer_phone text,
  p_delivery_city text,
  p_delivery_address text,
  p_note text default ''
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
    delivery_city, delivery_address, note, total_price, currency
  )
  select p_store_id, auth.uid(), trim(p_customer_name), lower(trim(p_customer_email)), trim(p_customer_phone),
    trim(p_delivery_city), trim(p_delivery_address), trim(p_note), v_total, s.currency
  from public.stores s where s.id = p_store_id
  returning * into v_order;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_quantity := (v_item ->> 'quantity')::integer;
    select * into v_variant from public.product_variants
    where id = (v_item ->> 'variantId')::uuid for update;
    select * into v_product from public.products where id = v_variant.product_id;
    insert into public.order_items (
      order_id, product_id, variant_id, product_name, variant_name, quantity,
      unit_price, compare_at_price, line_total, is_preorder
    ) values (
      v_order.id, v_product.id, v_variant.id, v_product.name, v_variant.name,
      v_quantity, v_variant.price, v_variant.compare_at_price,
      v_variant.price * v_quantity, v_variant.is_preorder
    );
    if not v_variant.is_preorder then
      update public.product_variants set stock_quantity = stock_quantity - v_quantity where id = v_variant.id;
    end if;
  end loop;

  insert into public.order_status_history (order_id, status, author_id)
  values (v_order.id, v_order.status, auth.uid());
  return v_order;
end;
$$;

grant execute on function public.create_store_order(uuid, jsonb, text, text, text, text, text, text) to anon, authenticated;

create or replace function public.change_order_status(p_order_id uuid, p_status public.order_status)
returns public.orders language plpgsql security definer set search_path = public as $$
declare v_order public.orders;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found or not public.is_store_member(v_order.store_id) then
    raise exception 'You do not have access to this order';
  end if;
  update public.orders set status = p_status where id = p_order_id returning * into v_order;
  insert into public.order_status_history (order_id, status, author_id)
  values (v_order.id, v_order.status, auth.uid());
  return v_order;
end;
$$;
grant execute on function public.change_order_status(uuid, public.order_status) to authenticated;

create or replace function public.get_order_receipt(p_receipt_code text)
returns jsonb language sql security definer set search_path = public as $$
  select to_jsonb(o) || jsonb_build_object(
    'items', coalesce((select jsonb_agg(to_jsonb(oi) order by oi.id) from public.order_items oi where oi.order_id = o.id), '[]'::jsonb)
  )
  from public.orders o
  where o.receipt_code = lower(trim(p_receipt_code));
$$;
grant execute on function public.get_order_receipt(text) to anon, authenticated;
