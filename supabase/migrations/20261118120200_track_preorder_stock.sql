-- Legacy order lines used the pre-order flag to indicate whether stock was deducted.
-- Leave their snapshots null so cancellation can still use the historical rule.
alter table public.order_items add column stock_deducted boolean;
alter table public.online_checkouts add column track_preorder_stock boolean not null default false;

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

  for v_item in select value from jsonb_array_elements(p_items) order by (value->>'variantId')::uuid loop
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
    if v_variant.stock_quantity < v_quantity then
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
    insert into public.order_items (order_id, product_id, variant_id, product_name, variant_name, quantity, unit_price, compare_at_price, line_total, is_preorder, stock_deducted)
    values (v_order.id, v_product.id, v_variant.id, v_product.name, v_variant.name, v_quantity, v_variant.price, v_variant.compare_at_price, v_variant.price * v_quantity, v_variant.is_preorder, not v_test_mode);
    if not v_test_mode then
      update public.product_variants set stock_quantity = stock_quantity - v_quantity
      where id = v_variant.id and stock_quantity >= v_quantity;
      if not found then raise exception 'Insufficient stock for %', v_product.name; end if;
    end if;
  end loop;

  insert into public.order_status_history (order_id, status, author_id) values (v_order.id, v_order.status, p_user_id);
  return v_order;
end;
$$;

create or replace function public.prepare_online_checkout_before_discounts(
  p_provider text, p_user_id uuid, p_store_id uuid, p_items jsonb, p_checkout jsonb, p_test_mode boolean
) returns public.online_checkouts
language plpgsql security definer set search_path = '' as $$
declare
  v_attempt public.online_checkouts;
  v_enabled boolean;
  v_test_mode boolean;
  v_currency text;
  v_items jsonb;
  v_total integer;
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
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Cart is empty';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items) as item("variantId" uuid, quantity integer)
    where item."variantId" is null or item.quantity is null or item.quantity not between 1 and 20
  ) then
    raise exception 'Invalid cart item';
  end if;
  if nullif(trim(p_checkout->>'name'), '') is null or nullif(trim(p_checkout->>'phone'), '') is null
      or nullif(trim(p_checkout->>'city'), '') is null or nullif(trim(p_checkout->>'address'), '') is null then
    raise exception 'Missing customer or delivery details';
  end if;

  with requested as (
    select item."variantId" as variant_id, sum(item.quantity)::integer as quantity
    from jsonb_to_recordset(p_items) as item("variantId" uuid, quantity integer)
    group by item."variantId"
  ), priced as (
    select p.id as product_id, v.id as variant_id, p.name as product_name, v.name as variant_name,
      requested.quantity, v.price as unit_price, v.compare_at_price,
      v.price * requested.quantity as line_total, v.is_preorder
    from requested
    join public.product_variants v on v.id = requested.variant_id
    join public.products p on p.id = v.product_id
    where p.store_id = p_store_id and p.is_active and requested.quantity <= 20
      and v.stock_quantity >= requested.quantity
  )
  select jsonb_agg(to_jsonb(priced) order by priced.variant_id), sum(priced.line_total)
  into v_items, v_total from priced
  having count(*) = (select count(*) from requested);

  if v_items is null then
    raise sqlstate 'PT409' using message = 'A product is no longer available in the requested quantity.';
  end if;
  if v_total <= 0 then raise exception 'Online checkout requires a positive amount'; end if;

  v_attempt.id := gen_random_uuid();
  insert into public.online_checkouts (id, store_id, user_id, provider, provider_order_id, test_mode, total_price, currency, checkout, items, track_preorder_stock)
  values (v_attempt.id, p_store_id, p_user_id, p_provider,
    case when p_provider = 'LIQPAY' then v_attempt.id::text end, p_test_mode, v_total, v_currency,
    jsonb_build_object(
      'name', p_checkout->>'name', 'email', p_checkout->>'email', 'phone', p_checkout->>'phone',
      'city', p_checkout->>'city', 'address', p_checkout->>'address', 'note', p_checkout->>'note',
      'cityRef', p_checkout->>'cityRef', 'addressRef', p_checkout->>'addressRef',
      'deliveryServiceType', p_checkout->>'deliveryServiceType'
    ), v_items, true)
  returning * into v_attempt;
  return v_attempt;
end;
$$;

create or replace function public.confirm_online_checkout(
  p_provider text, p_reference text, p_amount integer, p_currency text, p_payment_id text, p_callback jsonb
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_attempt public.online_checkouts;
  v_item public.order_items;
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
    select * from jsonb_populate_recordset(null::public.order_items, v_attempt.items) order by variant_id
  loop
    -- Honor invoices already issued before pre-orders began counting stock.
    v_preorder := v_item.is_preorder;
    v_stock_deducted := false;
    if not v_attempt.test_mode and (not v_preorder or v_attempt.track_preorder_stock) then
      update public.product_variants set stock_quantity = stock_quantity - v_item.quantity
      where id = v_item.variant_id and stock_quantity >= v_item.quantity;
      v_stock_deducted := found;
      -- Record the paid order for fulfillment even if stock ran out during payment.
      v_preorder := v_preorder or not v_stock_deducted;
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

create or replace function public.create_free_customer_order(p_store uuid, p_items jsonb, p_checkout jsonb, p_discount uuid)
returns public.orders language plpgsql security definer set search_path = '' as $$
declare o public.orders; v record; entry jsonb; quantity integer; original_total integer := 0;
begin
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Cart is empty'; end if;
  if exists (select 1 from jsonb_to_recordset(p_items) as i("variantId" uuid, quantity integer)
    where i."variantId" is null or i.quantity is null or i.quantity not between 1 and 20) then raise exception 'Invalid cart item'; end if;
  for entry in select jsonb_build_object('variantId',i."variantId",'quantity',sum(i.quantity))
    from jsonb_to_recordset(p_items) as i("variantId" uuid, quantity integer) group by i."variantId" order by i."variantId"
  loop
    quantity := (entry->>'quantity')::integer;
    select pv.*, p.name as product_name into v from public.product_variants pv join public.products p on p.id = pv.product_id
      where pv.id = (entry->>'variantId')::uuid and p.store_id = p_store and p.is_active for update of pv;
    if not found or quantity > 20 or v.stock_quantity < quantity then raise exception 'Product is no longer available'; end if;
    original_total := original_total + v.price * quantity;
  end loop;
  insert into public.orders(store_id,user_id,customer_name,customer_email,customer_phone,delivery_city,delivery_address,note,
    total_price,currency,payment_method,payment_status,status,customer_discount_id,customer_discount_percent,customer_discount_amount,
    delivery_city_ref,delivery_address_ref,delivery_service_type)
  select p_store,auth.uid(),trim(p_checkout->>'name'),trim(p_checkout->>'email'),trim(p_checkout->>'phone'),
    trim(p_checkout->>'city'),trim(p_checkout->>'address'),coalesce(p_checkout->>'note',''),0,s.currency,'ONLINE','PAID','PAID',p_discount,100,original_total,
    nullif(p_checkout->>'cityRef',''),nullif(p_checkout->>'addressRef',''),nullif(p_checkout->>'deliveryServiceType','')
    from public.stores s where s.id = p_store returning * into o;
  for entry in select jsonb_build_object('variantId',i."variantId",'quantity',sum(i.quantity))
    from jsonb_to_recordset(p_items) as i("variantId" uuid, quantity integer) group by i."variantId" order by i."variantId"
  loop
    quantity := (entry->>'quantity')::integer;
    select pv.*,p.name as product_name into v from public.product_variants pv join public.products p on p.id = pv.product_id where pv.id = (entry->>'variantId')::uuid;
    insert into public.order_items(order_id,product_id,variant_id,product_name,variant_name,quantity,unit_price,compare_at_price,line_total,is_preorder,stock_deducted)
      values(o.id,v.product_id,v.id,v.product_name,v.name,quantity,0,coalesce(v.compare_at_price,v.price),0,v.is_preorder,true);
    update public.product_variants set stock_quantity = stock_quantity - quantity where id = v.id;
  end loop;
  insert into public.order_status_history(order_id,status,author_id) values(o.id,'PAID',auth.uid());
  return o;
end;
$$;

create or replace function public.restore_stock_and_cancel_order(p_order_id uuid)
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
    if not coalesce(v_order.payment_test_mode, v_order.monobank_test_mode) and coalesce(v_item.stock_deducted, not v_item.is_preorder) and v_item.variant_id is not null then
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

create or replace function public.cancel_customer_reservation(
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
      where order_id = p_order_id and coalesce(stock_deducted, not is_preorder) and variant_id is not null
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

create or replace function public.subscribe_restock(p_variant uuid,p_subscribe boolean) returns void language plpgsql security definer set search_path='' as $$
declare available integer;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if not p_subscribe then delete from public.restock_subscriptions where user_id=auth.uid() and variant_id=p_variant; return; end if;
 select v.stock_quantity into available from public.product_variants v join public.products p on p.id=v.product_id where v.id=p_variant and p.is_active for update of v;
 if not found or available>0 then raise exception 'Variant is already available or unavailable for subscription'; end if;
 insert into public.restock_subscriptions(user_id,variant_id) values(auth.uid(),p_variant)
 on conflict(user_id,variant_id) do update set notified_at=null;
end; $$;

notify pgrst, 'reload schema';
