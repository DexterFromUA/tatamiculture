begin;

-- Manual orders use catalog prices and the normal inventory and CRM triggers.
create function public.create_crm_order(
  p_store_id uuid, p_request_id uuid, p_items jsonb, p_customer jsonb,
  p_delivery jsonb, p_note text, p_expected_total integer
) returns public.orders
language plpgsql security definer set search_path = '' as $$
declare
  created_order public.orders;
  quote record;
  buyer_name text := btrim(coalesce(p_customer->>'name', ''));
  buyer_phone text := btrim(coalesce(p_customer->>'phone', ''));
  buyer_email text := lower(btrim(coalesce(p_customer->>'email', '')));
  city_name text := btrim(coalesce(p_delivery->>'city', ''));
  address_name text := btrim(coalesce(p_delivery->>'address', ''));
  city_ref text := nullif(btrim(p_delivery->>'cityRef'), '');
  address_ref text := nullif(btrim(p_delivery->>'addressRef'), '');
  service_type text := p_delivery->>'serviceType';
  order_note text := btrim(coalesce(p_note, ''));
begin
  if not public.is_store_member(p_store_id) then
    raise insufficient_privilege using message = 'Manager access required';
  end if;
  if p_request_id is null then
    raise invalid_parameter_value using message = 'Invalid order request.';
  end if;

  -- Reuse the order ID on retries, including after a lost response.
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));
  select * into created_order from public.orders
  where id = p_request_id and store_id = p_store_id;
  if found then return created_order; end if;

  if buyer_name = '' or length(buyer_name) > 200
    or buyer_phone !~ '^\+[1-9][0-9]{7,14}$' or length(buyer_email) > 254 then
    raise invalid_parameter_value using message = 'Enter a valid customer name and phone number.';
  end if;
  if city_name = '' or address_name = '' or length(city_name) > 200 or length(address_name) > 500 then
    raise invalid_parameter_value using message = 'Enter the city and delivery address.';
  end if;
  if (city_ref is null) <> (address_ref is null)
    or (city_ref is not null and coalesce(service_type, '') not in ('WarehouseWarehouse', 'WarehousePostomat')) then
    raise invalid_parameter_value using message = 'Choose a city and Nova Poshta branch';
  end if;
  if length(order_note) > 2000 then
    raise invalid_parameter_value using message = 'The order note is too long.';
  end if;

  select * into quote from public.quote_catalog_cart(p_store_id, p_items, null, true);
  if p_expected_total is distinct from quote.total then
    raise sqlstate 'PT409' using message = 'Order prices changed. Review the total and try again.';
  end if;

  insert into public.orders (
    id, store_id, customer_name, customer_phone, customer_email, delivery_city, delivery_address,
    delivery_city_ref, delivery_address_ref, delivery_service_type, note, total_price, currency,
    payment_method, payment_test_mode, status, payment_status
  )
  select p_request_id, s.id, buyer_name, buyer_phone, buyer_email, city_name, address_name,
    city_ref, address_ref, case when city_ref is not null then service_type end, order_note, quote.total, s.currency,
    'CASH_ON_DELIVERY', false,
    case when quote.total = 0 then 'PAID'::public.order_status else 'PENDING'::public.order_status end,
    case when quote.total = 0 then 'PAID'::public.payment_status else 'PENDING'::public.payment_status end
  from public.stores s where s.id = p_store_id
  returning * into created_order;

  insert into public.order_items (
    order_id, product_id, variant_id, product_name, variant_name, quantity,
    unit_price, compare_at_price, line_total, is_preorder, stock_deducted
  )
  select created_order.id, line.product_id, line.variant_id, line.product_name, line.variant_name, line.quantity,
    line.unit_price, line.compare_at_price, line.line_total, line.is_preorder, true
  from jsonb_populate_recordset(null::public.order_items, quote.items) as line;

  update public.product_variants v set stock_quantity = v.stock_quantity - line.quantity
  from jsonb_populate_recordset(null::public.order_items, quote.items) as line
  where v.id = line.variant_id;

  insert into public.order_status_history (order_id, status, author_id)
  values (created_order.id, created_order.status, auth.uid());
  return created_order;
end;
$$;

revoke all on function public.create_crm_order(uuid, uuid, jsonb, jsonb, jsonb, text, integer) from public, anon, authenticated, service_role;
grant execute on function public.create_crm_order(uuid, uuid, jsonb, jsonb, jsonb, text, integer) to authenticated;

notify pgrst, 'reload schema';

commit;
