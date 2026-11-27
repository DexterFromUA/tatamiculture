alter table public.variant_supplier_stock
  add column revision uuid not null default gen_random_uuid();

alter table public.order_items
  add column supplier_stock_deducted integer not null default 0,
  add column supplier_stock_revision uuid,
  add constraint order_items_supplier_stock_check check (
    supplier_stock_deducted between 0 and quantity
    and (supplier_stock_deducted = 0) = (supplier_stock_revision is null)
  );

-- Expose the total through PostgREST without making the supplier table public.
create function public.catalog_stock_quantity(variant public.product_variants)
returns bigint language sql stable security definer set search_path = '' as $$
  select v.stock_quantity::bigint + coalesce(s.quantity, 0)
  from public.product_variants v
  join public.products p on p.id = v.product_id
  left join public.variant_supplier_stock s on s.variant_id = v.id
  where v.id = variant.id and (p.is_active or public.is_store_member(p.store_id));
$$;
revoke all on function public.catalog_stock_quantity(public.product_variants) from public;
grant execute on function public.catalog_stock_quantity(public.product_variants) to anon, authenticated;

-- A checkout locks both balances and draws from the shop warehouse first.
create function public.allocate_catalog_stock(p_variant_id uuid, p_quantity integer)
returns table(deducted boolean, supplier_quantity integer, supplier_revision uuid)
language plpgsql set search_path = '' as $$
declare
  warehouse_quantity integer;
  supplier public.variant_supplier_stock;
begin
  select v.stock_quantity into warehouse_quantity
  from public.product_variants v where v.id = p_variant_id for no key update;
  if p_quantity is null or p_quantity <= 0 or not found then
    return query select false, 0, null::uuid;
    return;
  end if;

  select * into supplier
  from public.variant_supplier_stock s where s.variant_id = p_variant_id for update;
  if warehouse_quantity::bigint + coalesce(supplier.quantity, 0) < p_quantity then
    return query select false, 0, null::uuid;
    return;
  end if;

  supplier_quantity := greatest(p_quantity - warehouse_quantity, 0);
  deducted := true;
  if warehouse_quantity > 0 then
    update public.product_variants
    set stock_quantity = warehouse_quantity - least(warehouse_quantity, p_quantity)
    where id = p_variant_id;
  end if;
  if supplier_quantity > 0 then
    update public.variant_supplier_stock
    set quantity = supplier.quantity - supplier_quantity where variant_id = p_variant_id;
    supplier_revision := supplier.revision;
  end if;
  return next;
end;
$$;
revoke all on function public.allocate_catalog_stock(uuid, integer) from public, anon, authenticated, service_role;

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
    order by v.id for no key update of v;
    perform s.variant_id
    from public.variant_supplier_stock s
    join public.product_variants v on v.id = s.variant_id
    join public.products p on p.id = v.product_id
    where p.store_id = p_store_id and p.is_active and v.id in (
      select item."variantId" from jsonb_to_recordset(p_items) as item("variantId" uuid)
    )
    order by s.variant_id for update of s;
  end if;

  return query
  with requested as (
    select item."variantId" as variant_id, sum(item.quantity)::integer as quantity
    from jsonb_to_recordset(p_items) as item("variantId" uuid, quantity integer)
    group by item."variantId"
  ), offers as (
    select p.id as product_id, v.id as variant_id, p.name as product_name, v.name as variant_name,
      r.quantity, v.is_preorder, v.price as stored_price,
      v.allow_out_of_stock,
      stock.quantity >= r.quantity as stock_deducted,
      greatest(v.price, v.compare_at_price) as regular_price,
      coalesce(v.discount_percent, p.discount_percent) as catalog_percent,
      case when v.discount_percent is null then p.stack_customer_discount
        else v.stack_customer_discount end as allows_stacking
    from requested r
    join public.product_variants v on v.id = r.variant_id
    join public.products p on p.id = v.product_id
    left join public.variant_supplier_stock s on s.variant_id = v.id
    cross join lateral (select v.stock_quantity::bigint + coalesce(s.quantity, 0) as quantity) stock
    where p.store_id = p_store_id and p.is_active
      and r.quantity <= 20
      and (stock.quantity >= r.quantity
        or (stock.quantity = 0 and v.allow_out_of_stock))
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

CREATE OR REPLACE FUNCTION public.create_priced_catalog_order(p_provider text, p_user_id uuid, p_store_id uuid, p_items jsonb, p_customer_name text, p_customer_email text, p_customer_phone text, p_delivery_city text, p_delivery_address text, p_note text, p_delivery_city_ref text, p_delivery_address_ref text, p_delivery_service_type text, p_monobank_test_mode boolean, p_discount public.customer_discounts, p_expected_total integer)
 RETURNS public.orders
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  created_order public.orders;
  line public.order_items;
  quote record;
  allocation record;
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
  from public.shop_settings s where s.id = p_store_id
  returning * into created_order;

  for line in select * from jsonb_populate_recordset(null::public.order_items, quote.items) order by variant_id loop
    select * into allocation from public.allocate_catalog_stock(line.variant_id, line.quantity);
    insert into public.order_items (
      order_id, product_id, variant_id, product_name, variant_name, quantity,
      unit_price, compare_at_price, line_total, is_preorder, stock_deducted, supplier_stock_deducted, supplier_stock_revision
    ) values (
      created_order.id, line.product_id, line.variant_id, line.product_name, line.variant_name, line.quantity,
      line.unit_price, line.compare_at_price, line.line_total, line.is_preorder, allocation.deducted,
      allocation.supplier_quantity, allocation.supplier_revision
    );
  end loop;

  if p_user_id is not null then
    update public.order_events
    set author_id = p_user_id
    where order_id = created_order.id and kind = 'status' and new_value = created_order.status::text
      and created_at = transaction_timestamp() and author_id is null;
  end if;
  return created_order;
end;
$function$;

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
  from public.shop_settings s where s.id = p_store_id
  returning * into created_order;

  insert into public.order_items (
    order_id, product_id, variant_id, product_name, variant_name, quantity,
    unit_price, compare_at_price, line_total, is_preorder, stock_deducted,
    supplier_stock_deducted, supplier_stock_revision
  )
  select created_order.id, line.product_id, line.variant_id, line.product_name, line.variant_name, line.quantity,
    line.unit_price, line.compare_at_price, line.line_total, line.is_preorder, allocation.deducted,
    allocation.supplier_quantity, allocation.supplier_revision
  from jsonb_populate_recordset(null::public.order_items, quote.items) as line
  cross join lateral public.allocate_catalog_stock(line.variant_id, line.quantity) as allocation;

  return created_order;
end;
$$;

CREATE OR REPLACE FUNCTION public.confirm_online_checkout(p_provider text, p_reference text, p_amount integer, p_currency text, p_payment_id text, p_callback jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_attempt public.online_checkouts;
  v_item record;
  v_preorder boolean;
  allocation record;
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
    select * into allocation from public.allocate_catalog_stock(
      case when not v_preorder or v_attempt.track_preorder_stock then v_item.variant_id end, v_item.quantity
    );
    -- Record the paid order for fulfillment even if stock ran out during payment.
    v_preorder := v_preorder or (not allocation.deducted and not coalesce(v_item.allow_out_of_stock, false));
    insert into public.order_items (
      order_id, product_id, variant_id, product_name, variant_name, quantity,
      unit_price, compare_at_price, line_total, is_preorder, stock_deducted, supplier_stock_deducted, supplier_stock_revision
    ) values (
      v_attempt.id,
      (select id from public.products where id = v_item.product_id for key share),
      (select id from public.product_variants where id = v_item.variant_id for key share),
      v_item.product_name, v_item.variant_name, v_item.quantity,
      v_item.unit_price, v_item.compare_at_price, v_item.line_total, v_preorder, allocation.deducted,
      allocation.supplier_quantity, allocation.supplier_revision
    );
  end loop;


  insert into public.payments (order_id, provider, provider_order_id, provider_payment_id, status, raw_callback)
  values (v_attempt.id, p_provider, p_reference, p_payment_id, 'PAID', p_callback);
  update public.online_checkouts set status = 'PAID', checkout = null, items = null where id = v_attempt.id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.release_order_fulfillment_stock(p_order_ids uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  released record;
  procured_credit bigint := 0;
begin
  for released in
    select i.variant_id, i.supplier_stock_revision,
      sum(greatest(i.quantity - returned.quantity, 0) - allocation.to_supplier) as warehouse_quantity,
      sum(allocation.to_supplier) as supplier_quantity,
      sum(greatest(i.supplier_stock_deducted - returned.quantity - allocation.to_supplier, 0)) as procured_quantity
    from public.order_items i
    join public.orders o on o.id = i.order_id
    cross join lateral (
      select coalesce(sum(r.quantity), 0) as quantity from public.item_returns r
      where r.item_id = i.id and r.restock and r.status in ('received', 'completed')
    ) returned
    -- Before procurement begins, put unused allocations back with the supplier.
    -- After that, a cancelled allocation is handled as a physical return.
    cross join lateral (
      select case when i.supplier_stock_deducted > returned.quantity
        and o.status in ('PENDING', 'IN_PROGRESS') and not o.shipment_was_dispatched
        and (o.reopened_procurement_progressed is false or not exists (
          select from public.order_events e where e.order_id = o.id and e.kind = 'status'
            and e.new_value in ('WAITING_FOR_STOCK', 'PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED', 'COMPLETED')
        ))
        then i.supplier_stock_deducted - returned.quantity else 0 end as to_supplier
    ) allocation
    where i.order_id = any(p_order_ids)
      and coalesce(i.stock_deducted, not i.is_preorder) and i.variant_id is not null
    group by i.variant_id, i.supplier_stock_revision order by i.variant_id, i.supplier_stock_revision
  loop
    perform v.id from public.product_variants v where v.id = released.variant_id for no key update;
    if released.warehouse_quantity > 0 then
      update public.product_variants v set stock_quantity = (v.stock_quantity + released.warehouse_quantity)::integer
      where v.id = released.variant_id;
    end if;
    if released.supplier_quantity > 0 then
      -- A newer supplier count supersedes earlier allocations.
      update public.variant_supplier_stock s set quantity = (s.quantity + released.supplier_quantity)::integer
      where s.variant_id = released.variant_id and s.revision = released.supplier_stock_revision;
    end if;
    procured_credit := procured_credit + released.procured_quantity;
  end loop;
  if procured_credit > 0 then
    perform set_config('tatami.procurement_credit',
      (coalesce(nullif(current_setting('tatami.procurement_credit', true), ''), '0')::bigint + procured_credit)::text, true);
  end if;

  -- A return may already have been opened before the cancellation. Whoever
  -- confirms receipt next can complete it without posting the stock twice.
  update public.item_returns r set restock = false
  from public.order_items i, public.orders o
  where r.item_id = i.id and o.id = i.order_id and i.order_id = any(p_order_ids)
    and coalesce(i.stock_deducted, not i.is_preorder) and r.status = 'requested' and r.restock;
  update public.order_items i
  set stock_deducted = false, supplier_stock_deducted = 0, supplier_stock_revision = null
  from public.orders o
  where o.id = i.order_id and i.order_id = any(p_order_ids)
    and coalesce(i.stock_deducted, not i.is_preorder);
  update public.orders set cancel_stock_pending = false
  where id = any(p_order_ids) and cancel_stock_pending;
end;
$function$;

CREATE OR REPLACE FUNCTION public.cancel_customer_reservation(p_order_id uuid, p_user_id uuid, p_operation uuid, p_provider_order_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_order public.orders;
  v_payment public.payments;
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

  perform public.release_order_fulfillment_stock(array[p_order_id]);

  update public.orders set status = 'CANCELLED_BY_USER', payment_status = 'FAILED' where id = p_order_id;
  update public.payments set status = 'FAILED', checkout_url = null,
    checkout_operation = null, checkout_operation_until = null where id = v_payment.id;
  update public.order_events
  set author_id = p_user_id
  where order_id = p_order_id and kind = 'status' and new_value = 'CANCELLED_BY_USER'
    and created_at = transaction_timestamp() and author_id is null;
end;
$function$;

create or replace function public.split_order_items(p_order_id uuid, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  source public.orders;
  created public.orders;
  source_store uuid;
  origin_id uuid;
  line record;
  inserted_item uuid;
  source_quantity bigint;
  moved_quantity bigint;
  source_total bigint;
  moved_total integer;
  moved_line_total integer;
  moved_supplier_quantity integer;
  value_basis bigint;
  moved_basis bigint;
  moved_discount integer;
  saved_cost integer;
  source_item_cost bigint;
  moved_item_cost bigint;
  moved_cost integer;
begin
  select store_id into source_store from public.orders where id = p_order_id;
  if source_store is null or not coalesce(public.is_store_member(source_store), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || source_store::text, 0));
  select * into source from public.orders where id = p_order_id and store_id = source_store for update;
  if not found then raise exception 'Order not found'; end if;

  if source.status not in ('IN_PROGRESS', 'WAITING_FOR_STOCK', 'PREPARING_SHIPMENT') or source.shipment_was_dispatched then
    raise sqlstate 'PT409' using message = 'Only orders that have not been shipped can be split.';
  end if;
  if source.nova_poshta_ttn is not null or source.nova_poshta_document_ref is not null then
    raise sqlstate 'PT409' using message = 'Unlink the TTN before splitting the order.';
  end if;
  if exists (select from public.order_ttn_reservations where order_id = source.id) then
    raise sqlstate 'PT409' using message = 'Resolve the TTN attempt before splitting the order.';
  end if;
  if exists (select from public.order_merge_members where order_id = source.id or root_id = source.id) then
    raise sqlstate 'PT409' using message = 'Combined shipments cannot be split into separate orders here.';
  end if;
  if source.payment_status <> 'PAID' and (source.payment_method <> 'CASH_ON_DELIVERY' or source.payment_status <> 'PENDING') then
    raise sqlstate 'PT409' using message = 'Only paid orders and unpaid cash-on-delivery orders can be split.';
  end if;
  if exists (select from public.item_returns where order_id = source.id)
    or exists (select from public.order_returns where order_id = source.id)
    or exists (select from public.order_cancellation_refunds where order_id = source.id) then
    raise sqlstate 'PT409' using message = 'An order with a return or refund cannot be split.';
  end if;
  if coalesce(jsonb_typeof(p_items), '') <> 'array' then
    raise exception 'Choose the items and quantities to move.';
  end if;
  if jsonb_array_length(p_items) = 0 then raise exception 'Choose the items and quantities to move.'; end if;

  perform 1 from public.order_items where order_id = source.id order by id for update;
  if (
    select count(distinct r.item_id) <> count(*) or coalesce(bool_or(
      i.id is null or r.quantity is null or r.quantity < 1 or r.quantity > i.quantity
      or r.expected_quantity is distinct from i.quantity or r.expected_line_total is distinct from i.line_total
    ), true)
    from jsonb_to_recordset(p_items) as r(item_id uuid, quantity integer, expected_quantity integer, expected_line_total integer)
    left join public.order_items i on i.id = r.item_id and i.order_id = source.id
  ) then
    raise sqlstate 'PT409' using message = 'The selected items have changed. Refresh the order and try again.';
  end if;

  select sum(i.quantity), sum(i.line_total), sum(i.quantity::bigint * greatest(i.unit_price, i.compare_at_price)),
    case when bool_and(c.unit_cost is not null) then sum(i.quantity::bigint * c.unit_cost) end
  into source_quantity, source_total, value_basis, source_item_cost
  from public.order_items i left join public.order_item_costs c on c.item_id = i.id
  where i.order_id = source.id;
  select sum(r.quantity), sum(round(i.line_total::numeric * r.quantity / i.quantity))::integer,
    sum(r.quantity::bigint * greatest(i.unit_price, i.compare_at_price)),
    case when bool_and(c.unit_cost is not null) then sum(r.quantity::bigint * c.unit_cost) end
  into moved_quantity, moved_total, moved_basis, moved_item_cost
  from jsonb_to_recordset(p_items) as r(item_id uuid, quantity integer)
  join public.order_items i on i.id = r.item_id and i.order_id = source.id
  left join public.order_item_costs c on c.item_id = i.id;

  if moved_quantity is null or moved_quantity >= source_quantity then
    raise exception 'Leave at least one item in the original order.';
  end if;
  if source_total is distinct from source.total_price::bigint then
    raise sqlstate 'PT409' using message = 'The order total does not match its items. It cannot be split.';
  end if;
  -- Historical lines already include discounts. Only the order-level summary is allocated proportionally.
  moved_discount := round(source.customer_discount_amount::numeric
    * case when value_basis > 0 then moved_basis::numeric / value_basis else moved_quantity::numeric / source_quantity end);
  select cost_amount into saved_cost from public.order_financials where order_id = source.id for update;
  if saved_cost is not null then
    moved_cost := round(saved_cost::numeric * case
      when source_item_cost > 0 then moved_item_cost::numeric / source_item_cost
      when value_basis > 0 then moved_basis::numeric / value_basis
      else moved_quantity::numeric / source_quantity end);
  end if;

  origin_id := coalesce(source.split_origin_id, source.id);
  insert into public.orders (
    store_id, user_id, crm_customer_id, status, payment_status, payment_method, customer_name, customer_email,
    customer_phone, delivery_city, delivery_address, delivery_city_ref, delivery_address_ref, delivery_service_type,
    note, total_price, currency, created_at, monobank_test_mode, payment_test_mode,
    customer_discount_id, customer_discount_percent, customer_discount_amount, reopened_procurement_progressed, split_origin_id
  ) values (
    source.store_id, source.user_id, source.crm_customer_id, source.status, source.payment_status, source.payment_method,
    source.customer_name, source.customer_email, source.customer_phone, source.delivery_city, source.delivery_address,
    source.delivery_city_ref, source.delivery_address_ref, source.delivery_service_type, source.note, moved_total,
    source.currency, source.created_at, source.monobank_test_mode, source.payment_test_mode,
    source.customer_discount_id, source.customer_discount_percent, moved_discount, source.reopened_procurement_progressed, origin_id
  ) returning * into created;
  -- Identity lookup on insert must not detach an existing CRM customer link.
  if created.crm_customer_id is distinct from source.crm_customer_id then
    update public.orders set crm_customer_id = source.crm_customer_id where id = created.id;
  end if;

  for line in
    select i.*, r.quantity as move_quantity, c.unit_cost
    from jsonb_to_recordset(p_items) as r(item_id uuid, quantity integer)
    join public.order_items i on i.id = r.item_id and i.order_id = source.id
    left join public.order_item_costs c on c.item_id = i.id
    order by i.id
  loop
    if line.move_quantity = line.quantity then
      update public.order_items set order_id = created.id where id = line.id;
    else
      moved_line_total := round(line.line_total::numeric * line.move_quantity / line.quantity);
      moved_supplier_quantity := least(line.supplier_stock_deducted, line.move_quantity);
      update public.order_items set quantity = line.quantity - line.move_quantity,
        line_total = line.line_total - moved_line_total,
        supplier_stock_deducted = line.supplier_stock_deducted - moved_supplier_quantity,
        supplier_stock_revision = case when line.supplier_stock_deducted > moved_supplier_quantity then line.supplier_stock_revision end
      where id = line.id;
      insert into public.order_items (
        order_id, product_id, variant_id, product_name, variant_name, quantity, unit_price, compare_at_price,
        line_total, is_preorder, stock_deducted, supplier_stock_deducted, supplier_stock_revision
      ) values (
        created.id, line.product_id, line.variant_id, line.product_name, line.variant_name, line.move_quantity,
        line.unit_price, line.compare_at_price, moved_line_total, line.is_preorder, line.stock_deducted,
        moved_supplier_quantity, case when moved_supplier_quantity > 0 then line.supplier_stock_revision end
      ) returning id into inserted_item;
      -- Inserts normally snapshot current catalog data. The split keeps the original snapshots.
      update public.order_items set weight_grams = line.weight_grams, procurement_restocked = line.procurement_restocked
        where id = inserted_item;
      insert into public.order_item_costs(item_id, unit_cost) values (inserted_item, line.unit_cost)
        on conflict (item_id) do update set unit_cost = excluded.unit_cost;
    end if;
  end loop;

  update public.orders set total_price = total_price - moved_total,
    customer_discount_amount = customer_discount_amount - moved_discount, split_origin_id = origin_id
    where id = source.id;
  if saved_cost is not null then
    update public.order_financials set cost_amount = saved_cost - moved_cost, updated_at = now()
      where order_id = source.id;
    insert into public.order_financials(order_id, cost_amount) values (created.id, moved_cost);
  else
    insert into public.order_financials(order_id, cost_amount)
    select i.order_id, sum(i.quantity::bigint * c.unit_cost)::integer
    from public.order_items i left join public.order_item_costs c on c.item_id = i.id
    where i.order_id in (source.id, created.id)
    group by i.order_id having bool_and(c.unit_cost is not null)
    on conflict (order_id) do nothing;
  end if;

  insert into public.order_events(order_id, kind, new_value, author_id) values
    (source.id, 'split_order', '#' || created.receipt_code, auth.uid()),
    (created.id, 'split_from', '#' || source.receipt_code, auth.uid());
  return jsonb_build_object('order_id', created.id, 'receipt_code', created.receipt_code);
end;
$$;

create or replace function public.storefront_product_payload(p_product_id uuid)
returns jsonb language sql stable set search_path = ''
as $$
  select to_jsonb(p) || jsonb_build_object(
    'categories', (select to_jsonb(c) from public.categories c where c.id = p.category_id and c.store_id = p.store_id),
    'product_categories', coalesce((
      select jsonb_agg(jsonb_build_object('categories', to_jsonb(c)))
      from public.product_categories link join public.categories c on c.id = link.category_id and c.store_id = link.store_id
      where link.product_id = p.id and link.store_id = p.store_id
    ), '[]'::jsonb),
    'product_images', coalesce((select jsonb_agg(jsonb_build_object('public_url', i.public_url, 'position', i.position) order by i.position, i.id)
      from public.product_images i where i.product_id = p.id), '[]'::jsonb),
    'product_variants', coalesce((select jsonb_agg(
      to_jsonb(v) || jsonb_build_object('catalog_stock_quantity', public.catalog_stock_quantity(v))
      order by v.position, v.id)
      from public.product_variants v where v.product_id = p.id), '[]'::jsonb)
  )
  from public.products p where p.id = p_product_id and p.is_active;
$$;

create or replace function public.crm_catalog_page(
  p_store_id uuid, p_page integer, p_page_size integer, p_search text default '',
  p_filter text default 'all', p_category_id uuid default null
) returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare search text := lower(btrim(coalesce(p_search, '')));
begin
  if not public.is_store_member(p_store_id) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  return (
    with matches as materialized (
      select p.id, p.created_at from public.products p
      where p.store_id = p_store_id
        and (p_category_id is null or p.category_id = p_category_id or exists (
          select from public.product_categories c where c.product_id = p.id and c.store_id = p_store_id and c.category_id = p_category_id
        ))
        and (search = '' or strpos(lower(p.name), search) > 0 or strpos(lower(p.name_uk), search) > 0
          or strpos(lower(p.name_en), search) > 0 or exists (
            select from public.product_variants v where v.product_id = p.id and strpos(lower(v.sku), search) > 0
          ))
        and (case p_filter
          when 'all' then true
          when 'published' then p.is_active
          when 'hidden' then not p.is_active
          when 'stock' then exists (select from public.product_variants v where v.product_id = p.id)
          when 'low-stock' then exists (select from public.product_variants v where v.product_id = p.id and v.stock_quantity::bigint + coalesce((select s.quantity from public.variant_supplier_stock s where s.variant_id = v.id), 0) < v.low_stock_threshold)
          when 'out-of-stock' then exists (select from public.product_variants v where v.product_id = p.id and v.stock_quantity = 0 and not exists (
            select from public.variant_supplier_stock s where s.variant_id = v.id and s.quantity > 0
          ))
          else false end)
    ), totals as (select count(*) as matches from matches),
    paging as (
      select totals.matches, w.* from totals cross join lateral public.crm_page_window(totals.matches, p_page, p_page_size) w
    ), page_ids as (
      select id, created_at from matches order by created_at desc, id desc
      limit (select page_size from paging) offset (select row_offset from paging)
    )
    select jsonb_build_object('total', paging.matches, 'page', paging.page, 'rows', coalesce((
      select jsonb_agg(to_jsonb(p) || jsonb_build_object(
        'product_costs', (select to_jsonb(c) from public.product_costs c where c.product_id = p.id),
        'product_categories', coalesce((select jsonb_agg(jsonb_build_object('category_id', c.category_id))
          from public.product_categories c where c.product_id = p.id and c.store_id = p_store_id), '[]'::jsonb),
        'product_images', coalesce((select jsonb_agg(to_jsonb(i) order by i.position, i.id)
          from public.product_images i where i.product_id = p.id), '[]'::jsonb),
        'product_variants', coalesce((select jsonb_agg(to_jsonb(v) || jsonb_build_object(
          'variant_costs', (select to_jsonb(c) from public.variant_costs c where c.variant_id = v.id),
          'variant_supplier_stock', (select jsonb_build_object('quantity', s.quantity)
            from public.variant_supplier_stock s where s.variant_id = v.id)
        ) order by v.position, v.id) from public.product_variants v where v.product_id = p.id), '[]'::jsonb)
      ) order by p.created_at desc, p.id desc)
      from page_ids ids join public.products p on p.id = ids.id
    ), '[]'::jsonb)) from paging
  );
end;
$$;

create or replace function public.refresh_manto_stock(
  p_store_id uuid,
  p_product_id uuid,
  p_manto_product_id text,
  p_quantities jsonb,
  p_checked_at timestamptz
) returns jsonb
language plpgsql security invoker strict set search_path = '' as $$
declare
  current_snapshot jsonb;
  updated_variants jsonb;
begin
  select source.snapshot into current_snapshot
  from public.manto_product_sources as source
  where source.store_id = p_store_id and source.product_id = p_product_id
    and source.manto_product_id = p_manto_product_id
  for update;

  if not found or (current_snapshot->>'checkedAt')::timestamptz > p_checked_at then
    return current_snapshot;
  end if;

  with quantities as (
    select key, value
    from jsonb_each(p_quantities)
    where case when jsonb_typeof(value) = 'number' then
      value::numeric between 0 and 2147483647 and value::numeric = trunc(value::numeric)
    else false end
  ), updated_supplier_stock as (
    insert into public.variant_supplier_stock (variant_id, quantity)
    select variant.id, quantity.value::integer
    from public.product_variants as variant
    join quantities as quantity on quantity.key = variant.manto_variant_key
    where variant.product_id = p_product_id
    order by variant.id
    on conflict (variant_id) do update set quantity = excluded.quantity, revision = excluded.revision
  )
  select coalesce(jsonb_agg(
    case when quantity.value is not null then jsonb_set(variant.value, '{quantity}', quantity.value)
      else variant.value end
    order by variant.position
  ), '[]'::jsonb)
  into updated_variants
  from jsonb_array_elements(current_snapshot->'variants') with ordinality as variant(value, position)
  left join quantities as quantity on quantity.key = variant.value->>'key';

  current_snapshot := jsonb_set(
    jsonb_set(current_snapshot, '{variants}', updated_variants),
    '{checkedAt}', to_jsonb(p_checked_at)
  );
  update public.manto_product_sources
  set snapshot = current_snapshot
  where product_id = p_product_id and store_id = p_store_id and manto_product_id = p_manto_product_id;

  return current_snapshot;
end;
$$;

create or replace function public.subscribe_restock(p_variant uuid, p_subscribe boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  candidate public.product_variants;
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  if not p_subscribe then
    delete from public.restock_subscriptions where user_id = auth.uid() and variant_id = p_variant;
    return;
  end if;
  select v.* into candidate
  from public.product_variants v join public.products p on p.id = v.product_id
  where v.id = p_variant and p.is_active for no key update of v;
  if not found or candidate.allow_out_of_stock then
    raise exception 'Variant is already available or unavailable for subscription';
  end if;
  perform s.variant_id from public.variant_supplier_stock s where s.variant_id = p_variant for share;
  if public.catalog_stock_quantity(candidate) > 0 then
    raise exception 'Variant is already available or unavailable for subscription';
  end if;
  insert into public.restock_subscriptions(user_id, variant_id) values (auth.uid(), p_variant)
  on conflict (user_id, variant_id) do update set notified_at = null;
end;
$$;

create or replace function public.notify_restock() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select from public.variant_supplier_stock s where s.variant_id = new.id and s.quantity > 0) then
    update public.restock_subscriptions set notified_at = now() where variant_id = new.id and notified_at is null;
  end if;
  return new;
end;
$$;

create function public.notify_supplier_restock() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.quantity > 0 and (tg_op = 'INSERT' or coalesce(old.quantity, 0) = 0) then
    update public.restock_subscriptions s set notified_at = now()
    where s.variant_id = new.variant_id and s.notified_at is null and exists (
      select from public.product_variants v join public.products p on p.id = v.product_id
      where v.id = new.variant_id and v.stock_quantity = 0 and p.is_active
    );
  end if;
  return new;
end;
$$;
revoke all on function public.notify_supplier_restock() from public, anon, authenticated;
create trigger notify_supplier_restock
after insert or update of quantity on public.variant_supplier_stock
for each row execute function public.notify_supplier_restock();

notify pgrst, 'reload schema';
