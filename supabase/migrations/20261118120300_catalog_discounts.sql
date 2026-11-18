alter table public.products
  add column discount_percent numeric(5,2) check (discount_percent between 0 and 100),
  add column stack_customer_discount boolean not null default false;

alter table public.product_variants
  add column discount_percent numeric(5,2) check (discount_percent between 0 and 100),
  add column stack_customer_discount boolean not null default false;

-- Both payment routes use the same line prices and only count a personal discount
-- as used when it actually reduces the amount. Prices are rounded per unit.
create function public.quote_catalog_cart(
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
      greatest(v.price, v.compare_at_price) as regular_price,
      coalesce(v.discount_percent, p.discount_percent) as catalog_percent,
      case when v.discount_percent is null then p.stack_customer_discount
        else v.stack_customer_discount end as allows_stacking
    from requested r
    join public.product_variants v on v.id = r.variant_id
    join public.products p on p.id = v.product_id
    where p.store_id = p_store_id and p.is_active
      and r.quantity <= 20 and v.stock_quantity >= r.quantity
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
    select product_id, variant_id, product_name, variant_name, quantity, is_preorder, unit_price,
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

revoke all on function public.quote_catalog_cart(uuid, jsonb, numeric, boolean) from public, anon, authenticated;

create function public.create_priced_catalog_order(
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
      line.unit_price, line.compare_at_price, line.line_total, line.is_preorder, not test_mode
    );
    if not test_mode then
      update public.product_variants set stock_quantity = stock_quantity - line.quantity where id = line.variant_id;
    end if;
  end loop;

  insert into public.order_status_history (order_id, status, author_id)
  values (created_order.id, created_order.status, p_user_id);
  return created_order;
end;
$$;

revoke all on function public.create_priced_catalog_order(text, uuid, uuid, jsonb, text, text, text, text, text, text, text, text, text, boolean, public.customer_discounts, integer)
  from public, anon, authenticated;

-- Keep the existing endpoints for legacy service callers and clients.
create or replace function public.create_order_with_payment(
  p_provider text, p_user_id uuid, p_store_id uuid, p_items jsonb,
  p_customer_name text, p_customer_email text, p_customer_phone text,
  p_delivery_city text, p_delivery_address text, p_note text,
  p_delivery_city_ref text, p_delivery_address_ref text, p_delivery_service_type text,
  p_monobank_test_mode boolean
) returns public.orders
language sql security definer set search_path = '' as $$
  select public.create_priced_catalog_order(p_provider, p_user_id, p_store_id, p_items,
    p_customer_name, p_customer_email, p_customer_phone, p_delivery_city, p_delivery_address, p_note,
    p_delivery_city_ref, p_delivery_address_ref, p_delivery_service_type, p_monobank_test_mode, null, null);
$$;

drop function public.create_discounted_store_order(uuid,jsonb,text,text,text,text,text,text,text,text,text,numeric);
create function public.create_discounted_store_order(
  p_store_id uuid, p_items jsonb, p_customer_name text, p_customer_email text, p_customer_phone text,
  p_delivery_city text, p_delivery_address text, p_note text default '', p_delivery_city_ref text default null,
  p_delivery_address_ref text default null, p_delivery_service_type text default null,
  p_expected_discount_percent numeric default null, p_expected_total integer default null
) returns public.orders
language plpgsql security definer set search_path = '' as $$
declare
  discount public.customer_discounts;
begin
  discount := public.active_customer_discount(p_store_id, auth.uid());
  if p_expected_discount_percent is not null and p_expected_discount_percent is distinct from coalesce(discount.percent, 0) then
    raise sqlstate 'PT409' using message = 'Your discount changed. Review your cart and try again.';
  end if;
  return public.create_priced_catalog_order('CASH_ON_DELIVERY', auth.uid(), p_store_id, p_items,
    p_customer_name, p_customer_email, p_customer_phone, p_delivery_city, p_delivery_address, p_note,
    p_delivery_city_ref, p_delivery_address_ref, p_delivery_service_type, false, discount, p_expected_total);
end;
$$;
revoke all on function public.create_discounted_store_order(uuid,jsonb,text,text,text,text,text,text,text,text,text,numeric,integer) from public;
grant execute on function public.create_discounted_store_order(uuid,jsonb,text,text,text,text,text,text,text,text,text,numeric,integer) to anon, authenticated;

create or replace function public.create_store_order(
  p_store_id uuid, p_items jsonb, p_customer_name text, p_customer_email text, p_customer_phone text,
  p_delivery_city text, p_delivery_address text, p_note text default '', p_delivery_city_ref text default null,
  p_delivery_address_ref text default null, p_delivery_service_type text default null
) returns public.orders
language sql security definer set search_path = '' as $$
  select public.create_discounted_store_order(p_store_id, p_items, p_customer_name, p_customer_email,
    p_customer_phone, p_delivery_city, p_delivery_address, p_note,
    p_delivery_city_ref, p_delivery_address_ref, p_delivery_service_type);
$$;

create or replace function public.prepare_online_checkout(
  p_provider text, p_user_id uuid, p_store_id uuid, p_items jsonb, p_checkout jsonb, p_test_mode boolean
) returns public.online_checkouts
language plpgsql security definer set search_path = '' as $$
declare
  v_attempt public.online_checkouts;
  v_enabled boolean;
  v_test_mode boolean;
  v_currency text;
  discount public.customer_discounts;
  quote record;
begin
  if p_provider is null or p_provider not in ('LIQPAY', 'MONOBANK') then
    raise exception 'Invalid payment method';
  end if;
  select s.currency, case p_provider when 'LIQPAY' then pm.liqpay else pm.monobank end,
    coalesce(pm.payment_test_mode, case p_provider when 'LIQPAY' then p_test_mode else pm.monobank_test_mode end, false)
  into v_currency, v_enabled, v_test_mode
  from public.stores s left join public.store_payment_methods pm on pm.store_id = s.id
  where s.id = p_store_id;

  if not found or not coalesce(v_enabled, true) then
    raise sqlstate 'PT409' using message = 'This payment method is no longer available.';
  end if;
  if v_test_mode is distinct from p_test_mode then
    raise sqlstate 'PT409' using message = 'Payment settings changed. Please try again.';
  end if;
  if p_provider = 'MONOBANK' and v_currency <> 'UAH' then
    raise exception 'Monobank checkout requires UAH';
  end if;
  if nullif(trim(p_checkout->>'name'), '') is null or nullif(trim(p_checkout->>'phone'), '') is null
      or nullif(trim(p_checkout->>'city'), '') is null or nullif(trim(p_checkout->>'address'), '') is null then
    raise exception 'Missing customer or delivery details';
  end if;

  discount := public.active_customer_discount(p_store_id, p_user_id);
  if p_checkout ? 'expectedDiscountPercent' and
      (p_checkout->>'expectedDiscountPercent')::numeric is distinct from coalesce(discount.percent,0) then
    raise exception 'Your discount changed. Review your cart and try again.' using errcode = 'PT409';
  end if;
  -- A limited entitlement already in payment must not silently turn into a full-price retry.
  if discount.id is null and exists (select 1 from public.customer_discounts x
    join public.online_checkouts a on a.customer_discount_id = x.id
    where x.store_id = p_store_id and x.user_id = p_user_id and x.enabled and x.mode = 'orders' and a.status = 'PENDING') then
    raise exception 'A discounted payment is still pending. Complete it or wait for its status to update.';
  end if;
  select * into quote from public.quote_catalog_cart(p_store_id, p_items, discount.percent, false);
  if p_checkout ? 'expectedTotal' and (p_checkout->>'expectedTotal')::integer is distinct from quote.total then
    raise sqlstate 'PT409' using message = 'Cart prices changed. Review your cart and try again.';
  end if;
  if quote.total <= 0 then raise exception 'Online checkout requires a positive amount'; end if;

  v_attempt.id := gen_random_uuid();
  insert into public.online_checkouts (id, store_id, user_id, provider, provider_order_id, test_mode, total_price, currency, checkout, items,
    track_preorder_stock, customer_discount_id, customer_discount_percent, customer_discount_amount)
  values (v_attempt.id, p_store_id, p_user_id, p_provider,
    case when p_provider = 'LIQPAY' then v_attempt.id::text end, p_test_mode, quote.total, v_currency,
    jsonb_build_object(
      'name', p_checkout->>'name', 'email', p_checkout->>'email', 'phone', p_checkout->>'phone',
      'city', p_checkout->>'city', 'address', p_checkout->>'address', 'note', p_checkout->>'note',
      'cityRef', p_checkout->>'cityRef', 'addressRef', p_checkout->>'addressRef',
      'deliveryServiceType', p_checkout->>'deliveryServiceType'
    ), quote.items, true,
    case when quote.personal_savings > 0 then discount.id end,
    case when quote.personal_savings > 0 then discount.percent else 0 end,
    quote.personal_savings)
  returning * into v_attempt;
  return v_attempt;
end;
$$;

-- These old internal routes have no callers after the new pricing flow is in place.
drop function public.prepare_online_checkout_before_discounts(text, uuid, uuid, jsonb, jsonb, boolean);
drop function public.create_free_customer_order(uuid, jsonb, jsonb, uuid);

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
    size_guide_en, size_guide_image_url_en, composition_en, care_instructions_en,
    size_guide_extra_image_urls, discount_percent, stack_customer_discount
  ) values (
    source.store_id, source.category_id, source.name, source.description, false, source.position,
    source.size_guide, source.composition, source.care_instructions, source.size_guide_image_url,
    source.name_uk, source.name_en, source.description_uk, source.description_en, source.weight_grams,
    source.size_guide_en, source.size_guide_image_url_en, source.composition_en, source.care_instructions_en,
    source.size_guide_extra_image_urls, source.discount_percent, source.stack_customer_discount
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
