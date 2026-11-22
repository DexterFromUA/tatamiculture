-- Keep the checkout rule in sync with normalizeCheckoutPhone in src/lib/phone.ts.
-- The Ukrainian prefixes cover national geographic and subscriber network codes.
create function public.validate_checkout_phone(p_phone text)
returns text
language plpgsql immutable set search_path = ''
as $$
declare
  v_compact text := regexp_replace(translate(p_phone, chr(160) || chr(8239), '  '), '[[:space:]()-]', '', 'g');
  v_phone text;
begin
  v_phone := case
    when v_compact ~ '^0[0-9]{9}$' then '+38' || v_compact
    when v_compact ~ '^380[0-9]{9}$' then '+' || v_compact
    when v_compact ~ '^\+[1-9][0-9]{7,14}$' then v_compact
  end;
  if v_phone is null or (v_phone like '+380%' and v_phone !~ '^\+380(3[1-8]|4[13-8]|5[0-7]|6[1-9]|7[3-9]|8[1-59]|9[1-9])[0-9]{7}$') then
    raise invalid_parameter_value using message = 'Enter a valid phone number, for example +380 67 123 45 67.';
  end if;
  return v_phone;
end;
$$;
revoke all on function public.validate_checkout_phone(text) from public, anon, authenticated;

create or replace function public.create_discounted_store_order(
  p_store_id uuid, p_items jsonb, p_customer_name text, p_customer_email text, p_customer_phone text,
  p_delivery_city text, p_delivery_address text, p_note text default '', p_delivery_city_ref text default null,
  p_delivery_address_ref text default null, p_delivery_service_type text default null,
  p_expected_discount_percent numeric default null, p_expected_total integer default null
) returns public.orders
language plpgsql security definer set search_path = '' as $$
declare
  discount public.customer_discounts;
  v_phone text := public.validate_checkout_phone(p_customer_phone);
begin
  discount := public.active_customer_discount(p_store_id, auth.uid());
  if p_expected_discount_percent is not null and p_expected_discount_percent is distinct from coalesce(discount.percent, 0) then
    raise sqlstate 'PT409' using message = 'Your discount changed. Review your cart and try again.';
  end if;
  return public.create_priced_catalog_order('CASH_ON_DELIVERY', auth.uid(), p_store_id, p_items,
    p_customer_name, p_customer_email, v_phone, p_delivery_city, p_delivery_address, p_note,
    p_delivery_city_ref, p_delivery_address_ref, p_delivery_service_type, false, discount, p_expected_total);
end;
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
  v_phone text := public.validate_checkout_phone(p_checkout->>'phone');
  discount public.customer_discounts;
  quote record;
begin
  if p_provider is null or p_provider not in ('LIQPAY', 'MONOBANK') then
    raise exception 'Invalid payment method';
  end if;
  select s.currency, case p_provider when 'LIQPAY' then pm.liqpay else pm.monobank end,
    coalesce(pm.payment_test_mode, case p_provider when 'LIQPAY' then p_test_mode else pm.monobank_test_mode end, false)
  into v_currency, v_enabled, v_test_mode
  from public.shop_settings s left join public.store_payment_methods pm on pm.store_id = s.id
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
  if nullif(trim(p_checkout->>'name'), '') is null
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
      'name', p_checkout->>'name', 'email', p_checkout->>'email', 'phone', v_phone,
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
