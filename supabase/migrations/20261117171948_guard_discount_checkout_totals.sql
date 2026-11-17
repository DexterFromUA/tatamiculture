create or replace function public.my_customer_discount(p_store_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare d public.customer_discounts;
begin
  select * into d from public.customer_discounts where store_id = p_store_id and user_id = auth.uid() and enabled;
  if not found then return null; end if;
  return to_jsonb(d) || jsonb_build_object('pending',
    d.mode = 'orders' and public.customer_discount_usage(d.id) >= d.order_limit and exists (
      select 1 from public.online_checkouts c where c.customer_discount_id = d.id and c.status = 'PENDING'), 'used', public.customer_discount_usage(d.id), 'active',
    (d.mode <> 'period' or (now() at time zone 'Europe/Kyiv')::date between d.starts_on and d.ends_on)
    and (d.mode <> 'orders' or public.customer_discount_usage(d.id) < d.order_limit));
end;
$$;

create or replace function public.prepare_online_checkout(
  p_provider text, p_user_id uuid, p_store_id uuid, p_items jsonb, p_checkout jsonb, p_test_mode boolean
) returns public.online_checkouts language plpgsql security definer set search_path = '' as $$
declare d public.customer_discounts; c public.online_checkouts; priced jsonb; total integer;
begin
  d := public.active_customer_discount(p_store_id, p_user_id);
  if p_checkout ? 'expectedDiscountPercent' and
      (p_checkout->>'expectedDiscountPercent')::numeric is distinct from coalesce(d.percent,0) then
    raise exception 'Your discount changed. Review your cart and try again.' using errcode = 'PT409';
  end if;
  -- A limited entitlement already in payment must not silently turn into a full-price retry.
  if d.id is null and exists (select 1 from public.customer_discounts x
    join public.online_checkouts a on a.customer_discount_id = x.id
    where x.store_id = p_store_id and x.user_id = p_user_id and x.enabled and x.mode = 'orders' and a.status = 'PENDING') then
    raise exception 'A discounted payment is still pending. Complete it or wait for its status to update.';
  end if;
  c := public.prepare_online_checkout_before_discounts(p_provider,p_user_id,p_store_id,p_items,p_checkout,p_test_mode);
  if d.id is not null then
    select jsonb_agg(item || jsonb_build_object(
      'compare_at_price', coalesce(nullif(item->'compare_at_price','null'::jsonb),item->'unit_price'),
      'unit_price', round((item->>'unit_price')::numeric * (1 - d.percent / 100))::integer,
      'line_total', round((item->>'unit_price')::numeric * (1 - d.percent / 100))::integer * (item->>'quantity')::integer)),
      sum(round((item->>'unit_price')::numeric * (1 - d.percent / 100))::integer * (item->>'quantity')::integer)
    into priced,total from jsonb_array_elements(c.items) item;
    if total <= 0 then raise exception 'Use cash on delivery for a free order.'; end if;
    update public.online_checkouts set items = priced, total_price = total,
      customer_discount_id = d.id, customer_discount_percent = d.percent,
      customer_discount_amount = c.total_price - total where id = c.id returning * into c;
  end if;
  return c;
end;
$$;

create function public.create_discounted_store_order(
  p_store_id uuid, p_items jsonb, p_customer_name text, p_customer_email text, p_customer_phone text,
  p_delivery_city text, p_delivery_address text, p_note text default '', p_delivery_city_ref text default null,
  p_delivery_address_ref text default null, p_delivery_service_type text default null,
  p_expected_discount_percent numeric default null
) returns public.orders language plpgsql security definer set search_path = '' as $$
declare d public.customer_discounts;
begin
  d := public.active_customer_discount(p_store_id,auth.uid());
  if p_expected_discount_percent is not null and p_expected_discount_percent is distinct from coalesce(d.percent,0) then
    raise exception 'Your discount changed. Review your cart and try again.' using errcode = 'PT409';
  end if;
  return public.create_store_order(p_store_id,p_items,p_customer_name,p_customer_email,p_customer_phone,
    p_delivery_city,p_delivery_address,p_note,p_delivery_city_ref,p_delivery_address_ref,p_delivery_service_type);
end;
$$;
revoke all on function public.create_discounted_store_order(uuid,jsonb,text,text,text,text,text,text,text,text,text,numeric) from public;
grant execute on function public.create_discounted_store_order(uuid,jsonb,text,text,text,text,text,text,text,text,text,numeric) to anon,authenticated;
