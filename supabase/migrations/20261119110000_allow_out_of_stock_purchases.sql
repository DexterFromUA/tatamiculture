begin;

alter table public.products
  add column allow_out_of_stock boolean not null default false;

-- Only regular variants already at zero can be sold without deducting stock.

create or replace function public.quote_catalog_cart(
  p_store_id uuid, p_items jsonb, p_customer_percent numeric, p_lock_stock boolean
) returns table(items jsonb, total integer, personal_savings integer)
language plpgsql set search_path = '' as $$
begin
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Cart is empty';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items) as item("variantId" uuid, quantity integer)
    where item."variantId" is null or item.quantity is null or item.quantity not between 1 and 20
  ) then
    raise exception 'Invalid cart item';
  end if;

  if p_lock_stock then
    perform v.id
    from public.product_variants v join public.products p on p.id = v.product_id
    where p.store_id = p_store_id and p.is_active and v.id in (
      select item."variantId" from jsonb_to_recordset(p_items) as item("variantId" uuid)
    )
    order by v.id for update of v;
  end if;

  return query
  with requested as (
    select item."variantId" as variant_id, sum(item.quantity)::integer as quantity
    from jsonb_to_recordset(p_items) as item("variantId" uuid, quantity integer)
    group by item."variantId"
  ), offers as (
    select p.id as product_id, v.id as variant_id, p.name as product_name, v.name as variant_name,
      r.quantity, v.is_preorder, v.price as stored_price,
      p.allow_out_of_stock and not v.is_preorder as allow_out_of_stock,
      v.stock_quantity >= r.quantity as stock_deducted,
      greatest(v.price, v.compare_at_price) as regular_price,
      coalesce(v.discount_percent, p.discount_percent) as catalog_percent,
      case when v.discount_percent is null then p.stack_customer_discount
        else v.stack_customer_discount end as allows_stacking
    from requested r
    join public.product_variants v on v.id = r.variant_id
    join public.products p on p.id = v.product_id
    where p.store_id = p_store_id and p.is_active
      and r.quantity <= 20
      and (v.stock_quantity >= r.quantity
        or (v.stock_quantity = 0 and p.allow_out_of_stock and not v.is_preorder))
  ), catalog_prices as (
    select offers.*, case when catalog_percent is null then stored_price
      else round(regular_price * (1 - catalog_percent / 100))::integer end as catalog_price
    from offers
  ), final_prices as (
    select catalog_prices.*, case
      when allows_stacking or (coalesce(catalog_percent, 0) = 0 and catalog_price = regular_price)
        then round(catalog_price * (1 - coalesce(p_customer_percent, 0) / 100))::integer
      else catalog_price end as unit_price
    from catalog_prices
  ), lines as (
    select product_id, variant_id, product_name, variant_name, quantity, is_preorder, allow_out_of_stock, stock_deducted, unit_price,
      case when regular_price > unit_price then regular_price end as compare_at_price,
      unit_price * quantity as line_total,
      (catalog_price - unit_price) * quantity as customer_savings
    from final_prices
  )
  select jsonb_agg(to_jsonb(lines) - 'customer_savings' order by variant_id),
    sum(line_total)::integer, sum(customer_savings)::integer
  from lines
  having count(*) = (select count(*) from requested);
  if not found then
    raise sqlstate 'PT409' using message = 'A product is no longer available in the requested quantity.';
  end if;
end;
$$;

create or replace function public.create_priced_catalog_order(
  p_provider text, p_user_id uuid, p_store_id uuid, p_items jsonb,
  p_customer_name text, p_customer_email text, p_customer_phone text,
  p_delivery_city text, p_delivery_address text, p_note text,
  p_delivery_city_ref text, p_delivery_address_ref text, p_delivery_service_type text,
  p_monobank_test_mode boolean, p_discount public.customer_discounts, p_expected_total integer
) returns public.orders
language plpgsql set search_path = '' as $$
declare
  created_order public.orders;
  line public.order_items;
  quote record;
  method_enabled boolean;
  monobank_mode boolean;
  shared_test_mode boolean;
  test_mode boolean;
  free_order boolean;
begin
  if p_provider is null or p_provider not in ('CASH_ON_DELIVERY', 'LIQPAY', 'MONOBANK') then
    raise exception 'Invalid payment method';
  end if;
  select case p_provider when 'CASH_ON_DELIVERY' then pm.cash_on_delivery
      when 'LIQPAY' then pm.liqpay when 'MONOBANK' then pm.monobank end,
    pm.monobank_test_mode, pm.payment_test_mode
  into method_enabled, monobank_mode, shared_test_mode
  from public.store_payment_methods pm where pm.store_id = p_store_id;

  test_mode := p_provider <> 'CASH_ON_DELIVERY' and coalesce(shared_test_mode,
    case p_provider when 'MONOBANK' then monobank_mode when 'LIQPAY' then p_monobank_test_mode end, false);
  if coalesce(p_monobank_test_mode, false) is distinct from test_mode
    or (p_monobank_test_mode is null and shared_test_mode is not null) then
    raise sqlstate 'PT409' using message = 'Payment settings changed. Please try again.';
  end if;

  select * into quote from public.quote_catalog_cart(p_store_id, p_items, p_discount.percent, true);
  if p_expected_total is not null and p_expected_total is distinct from quote.total then
    raise sqlstate 'PT409' using message = 'Cart prices changed. Review your cart and try again.';
  end if;
  free_order := p_provider = 'CASH_ON_DELIVERY' and quote.total = 0;
  if not free_order and not coalesce(method_enabled, true) then
    raise sqlstate 'PT409' using message = 'This payment method is no longer available.';
  end if;

  insert into public.orders (
    store_id, user_id, customer_name, customer_email, customer_phone,
    delivery_city, delivery_address, note, total_price, currency,
    delivery_city_ref, delivery_address_ref, delivery_service_type, payment_method,
    monobank_test_mode, payment_test_mode, status, payment_status,
    customer_discount_id, customer_discount_percent, customer_discount_amount
  )
  select p_store_id, p_user_id, trim(p_customer_name), lower(trim(p_customer_email)), trim(p_customer_phone),
    trim(p_delivery_city), trim(p_delivery_address), coalesce(trim(p_note), ''), quote.total, s.currency,
    nullif(trim(p_delivery_city_ref), ''), nullif(trim(p_delivery_address_ref), ''),
    case when p_delivery_service_type in ('WarehouseWarehouse', 'WarehousePostomat') then p_delivery_service_type end,
    case when p_provider = 'CASH_ON_DELIVERY' and not free_order then 'CASH_ON_DELIVERY' else 'ONLINE' end,
    p_provider = 'MONOBANK' and test_mode,
    case when p_provider = 'LIQPAY' and p_monobank_test_mode is null then null else test_mode end,
    case when free_order then 'PAID'::public.order_status else 'PENDING'::public.order_status end,
    case when free_order then 'PAID'::public.payment_status else 'PENDING'::public.payment_status end,
    case when quote.personal_savings > 0 then p_discount.id end,
    case when quote.personal_savings > 0 then p_discount.percent else 0 end,
    quote.personal_savings
  from public.stores s where s.id = p_store_id
  returning * into created_order;

  for line in select * from jsonb_populate_recordset(null::public.order_items, quote.items) order by variant_id loop
    insert into public.order_items (
      order_id, product_id, variant_id, product_name, variant_name, quantity,
      unit_price, compare_at_price, line_total, is_preorder, stock_deducted
    ) values (
      created_order.id, line.product_id, line.variant_id, line.product_name, line.variant_name, line.quantity,
      line.unit_price, line.compare_at_price, line.line_total, line.is_preorder, line.stock_deducted and not test_mode
    );
    if line.stock_deducted and not test_mode then
      update public.product_variants set stock_quantity = stock_quantity - line.quantity where id = line.variant_id;
    end if;
  end loop;

  insert into public.order_status_history (order_id, status, author_id)
  values (created_order.id, created_order.status, p_user_id);
  return created_order;
end;
$$;

create or replace function public.confirm_online_checkout(
  p_provider text, p_reference text, p_amount integer, p_currency text, p_payment_id text, p_callback jsonb
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_attempt public.online_checkouts;
  v_item record;
  v_preorder boolean;
  v_stock_deducted boolean;
begin
  select * into v_attempt from public.online_checkouts
  where provider = p_provider and provider_order_id = p_reference for update;
  if not found then raise exception 'Payment attempt not found'; end if;
  if v_attempt.total_price is distinct from p_amount or v_attempt.currency is distinct from p_currency then
    raise exception 'Payment amount or currency mismatch';
  end if;
  if v_attempt.status = 'PAID' then return; end if;

  insert into public.orders (
    id, store_id, user_id, receipt_code, status, payment_status, payment_method,
    customer_name, customer_email, customer_phone, delivery_city, delivery_address, note,
    total_price, currency, delivery_city_ref, delivery_address_ref, delivery_service_type,
    monobank_test_mode, payment_test_mode
  ) values (
    v_attempt.id, v_attempt.store_id, v_attempt.user_id, v_attempt.receipt_code, 'PAID', 'PAID', 'ONLINE',
    trim(v_attempt.checkout->>'name'), lower(trim(coalesce(v_attempt.checkout->>'email', ''))),
    trim(v_attempt.checkout->>'phone'), trim(v_attempt.checkout->>'city'), trim(v_attempt.checkout->>'address'),
    trim(coalesce(v_attempt.checkout->>'note', '')), v_attempt.total_price, v_attempt.currency,
    nullif(trim(v_attempt.checkout->>'cityRef'), ''), nullif(trim(v_attempt.checkout->>'addressRef'), ''),
    case when v_attempt.checkout->>'deliveryServiceType' in ('WarehouseWarehouse', 'WarehousePostomat')
      then v_attempt.checkout->>'deliveryServiceType' end,
    p_provider = 'MONOBANK' and v_attempt.test_mode, v_attempt.test_mode
  );

  for v_item in
    select line.*, (entry.data->>'allow_out_of_stock')::boolean as allow_out_of_stock
    from jsonb_array_elements(v_attempt.items) as entry(data)
    cross join lateral jsonb_populate_record(null::public.order_items, entry.data) as line
    order by line.variant_id
  loop
    -- Honor invoices already issued before pre-orders began counting stock.
    v_preorder := v_item.is_preorder;
    v_stock_deducted := false;
    if not v_attempt.test_mode and (not v_preorder or v_attempt.track_preorder_stock) then
      update public.product_variants set stock_quantity = stock_quantity - v_item.quantity
      where id = v_item.variant_id and stock_quantity >= v_item.quantity;
      v_stock_deducted := found;
      -- Record the paid order for fulfillment even if stock ran out during payment.
      v_preorder := v_preorder or (not v_stock_deducted and not coalesce(v_item.allow_out_of_stock, false));
    end if;
    insert into public.order_items (
      order_id, product_id, variant_id, product_name, variant_name, quantity,
      unit_price, compare_at_price, line_total, is_preorder, stock_deducted
    ) values (
      v_attempt.id,
      (select id from public.products where id = v_item.product_id for key share),
      (select id from public.product_variants where id = v_item.variant_id for key share),
      v_item.product_name, v_item.variant_name, v_item.quantity,
      v_item.unit_price, v_item.compare_at_price, v_item.line_total, v_preorder, v_stock_deducted
    );
  end loop;

  insert into public.order_status_history (order_id, status) values (v_attempt.id, 'PAID');
  insert into public.payments (order_id, provider, provider_order_id, provider_payment_id, status, raw_callback)
  values (v_attempt.id, p_provider, p_reference, p_payment_id, 'PAID', p_callback);
  update public.online_checkouts set status = 'PAID', checkout = null, items = null where id = v_attempt.id;
end;
$$;

create or replace function public.create_crm_order(
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
    line.unit_price, line.compare_at_price, line.line_total, line.is_preorder, line.stock_deducted
  from jsonb_populate_recordset(null::public.order_items, quote.items) as line;

  update public.product_variants v set stock_quantity = v.stock_quantity - line.quantity
  from jsonb_populate_recordset(null::public.order_items, quote.items) as line
  where v.id = line.variant_id and line.stock_deducted;

  insert into public.order_status_history (order_id, status, author_id)
  values (created_order.id, created_order.status, auth.uid());
  return created_order;
end;
$$;

create or replace function public.duplicate_catalog_product(p_product uuid)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  source public.products;
  copy_id uuid;
begin
  select * into source from public.products where id = p_product;
  if not found or not coalesce(public.is_store_member(source.store_id), false) then
    raise exception 'Manager access required';
  end if;

  insert into public.products (
    store_id, category_id, name, description, is_active, position,
    size_guide, composition, care_instructions, size_guide_image_url,
    name_uk, name_en, description_uk, description_en, weight_grams,
    size_guide_en, composition_en, care_instructions_en,
    size_guide_extra_image_urls, discount_percent, stack_customer_discount, allow_out_of_stock
  ) values (
    source.store_id, source.category_id, source.name, source.description, false, source.position,
    source.size_guide, source.composition, source.care_instructions, source.size_guide_image_url,
    source.name_uk, source.name_en, source.description_uk, source.description_en, source.weight_grams,
    source.size_guide_en, source.composition_en, source.care_instructions_en,
    source.size_guide_extra_image_urls, source.discount_percent, source.stack_customer_discount, source.allow_out_of_stock
  )
  returning id into copy_id;

  perform public.set_catalog_product_categories(array[copy_id], array(
    select pc.category_id from public.product_categories pc
    where pc.product_id = p_product
    order by (pc.category_id = source.category_id) desc nulls last, pc.category_id
  ));

  insert into public.product_variants (product_id, name, sku, price, compare_at_price, stock_quantity, is_preorder, position, low_stock_threshold, discount_percent, stack_customer_discount)
  select copy_id, name, null, price, compare_at_price, 0, is_preorder, position, low_stock_threshold, discount_percent, stack_customer_discount
  from public.product_variants where product_id = p_product;
  insert into public.product_images (product_id, public_url, storage_path, position)
  select copy_id, public_url, storage_path, position from public.product_images where product_id = p_product;
  return copy_id;
end;
$$;

notify pgrst, 'reload schema';

commit;
