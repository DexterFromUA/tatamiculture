create table public.online_checkouts (
  id uuid primary key default gen_random_uuid(),
  receipt_code text not null unique default replace(gen_random_uuid()::text, '-', ''),
  store_id uuid not null references public.stores(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete set null,
  provider text not null check (provider in ('LIQPAY', 'MONOBANK')),
  provider_order_id text unique,
  test_mode boolean not null,
  total_price integer not null check (total_price > 0),
  currency text not null,
  checkout jsonb,
  items jsonb,
  status public.payment_status not null default 'PENDING'
);

alter table public.online_checkouts enable row level security;
revoke all on table public.online_checkouts from public, anon, authenticated;
grant select, update on table public.online_checkouts to service_role;

create function public.prepare_online_checkout(
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
      and (v.is_preorder or v.stock_quantity >= requested.quantity)
  )
  select jsonb_agg(to_jsonb(priced) order by priced.variant_id), sum(priced.line_total)
  into v_items, v_total from priced
  having count(*) = (select count(*) from requested);

  if v_items is null then
    raise sqlstate 'PT409' using message = 'A product is no longer available in the requested quantity.';
  end if;
  if v_total <= 0 then raise exception 'Online checkout requires a positive amount'; end if;

  v_attempt.id := gen_random_uuid();
  insert into public.online_checkouts (id, store_id, user_id, provider, provider_order_id, test_mode, total_price, currency, checkout, items)
  values (v_attempt.id, p_store_id, p_user_id, p_provider,
    case when p_provider = 'LIQPAY' then v_attempt.id::text end, p_test_mode, v_total, v_currency,
    jsonb_build_object(
      'name', p_checkout->>'name', 'email', p_checkout->>'email', 'phone', p_checkout->>'phone',
      'city', p_checkout->>'city', 'address', p_checkout->>'address', 'note', p_checkout->>'note',
      'cityRef', p_checkout->>'cityRef', 'addressRef', p_checkout->>'addressRef',
      'deliveryServiceType', p_checkout->>'deliveryServiceType'
    ), v_items)
  returning * into v_attempt;
  return v_attempt;
end;
$$;

create function public.confirm_online_checkout(
  p_provider text, p_reference text, p_amount integer, p_currency text, p_payment_id text, p_callback jsonb
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_attempt public.online_checkouts;
  v_item public.order_items;
  v_preorder boolean;
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
    -- A paid order must survive concurrent sales of the last unit.
    v_preorder := v_item.is_preorder;
    if not v_preorder and not v_attempt.test_mode then
      update public.product_variants set stock_quantity = stock_quantity - v_item.quantity
      where id = v_item.variant_id and stock_quantity >= v_item.quantity;
      v_preorder := not found;
    end if;
    insert into public.order_items (
      order_id, product_id, variant_id, product_name, variant_name, quantity,
      unit_price, compare_at_price, line_total, is_preorder
    ) values (
      v_attempt.id,
      (select id from public.products where id = v_item.product_id for key share),
      (select id from public.product_variants where id = v_item.variant_id for key share),
      v_item.product_name, v_item.variant_name, v_item.quantity,
      v_item.unit_price, v_item.compare_at_price, v_item.line_total, v_preorder
    );
  end loop;

  insert into public.order_status_history (order_id, status) values (v_attempt.id, 'PAID');
  insert into public.payments (order_id, provider, provider_order_id, provider_payment_id, status, raw_callback)
  values (v_attempt.id, p_provider, p_reference, p_payment_id, 'PAID', p_callback);
  update public.online_checkouts set status = 'PAID', checkout = null, items = null where id = v_attempt.id;
end;
$$;

create function public.get_online_checkout_status(p_receipt_code text)
returns public.payment_status
language sql stable security definer set search_path = '' as $$
  select status from public.online_checkouts where receipt_code = lower(trim(p_receipt_code));
$$;

revoke all on function public.prepare_online_checkout(text, uuid, uuid, jsonb, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.confirm_online_checkout(text, text, integer, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.get_online_checkout_status(text) from public;
grant execute on function public.prepare_online_checkout(text, uuid, uuid, jsonb, jsonb, boolean) to service_role;
grant execute on function public.confirm_online_checkout(text, text, integer, text, text, jsonb) to service_role;
grant execute on function public.get_online_checkout_status(text) to anon, authenticated;
