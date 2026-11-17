create table public.customer_discounts (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  percent numeric(5,2) not null check (percent > 0 and percent <= 100),
  mode text not null check (mode in ('unlimited', 'orders', 'period')),
  order_limit integer check (order_limit > 0),
  starts_on date,
  ends_on date,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  check ((mode = 'orders') = (order_limit is not null)),
  check ((mode = 'period') = (starts_on is not null and ends_on is not null)),
  check (starts_on is null or ends_on >= starts_on)
);
create unique index customer_discount_current on public.customer_discounts(store_id,user_id) where enabled;
alter table public.customer_discounts enable row level security;
grant select on public.customer_discounts to authenticated;
create policy "customer and staff read discounts" on public.customer_discounts for select to authenticated
  using (user_id = auth.uid() or public.is_store_member(store_id));

alter table public.orders
  add column customer_discount_id uuid references public.customer_discounts(id) on delete set null,
  add column customer_discount_percent numeric(5,2) not null default 0,
  add column customer_discount_amount integer not null default 0;
alter table public.online_checkouts
  add column customer_discount_id uuid references public.customer_discounts(id) on delete set null,
  add column customer_discount_percent numeric(5,2) not null default 0,
  add column customer_discount_amount integer not null default 0,
  add column expires_at timestamptz not null default (now() + interval '1 hour');
create index orders_customer_discount on public.orders(customer_discount_id) where customer_discount_id is not null;
create index online_customer_discount on public.online_checkouts(customer_discount_id) where customer_discount_id is not null;

-- In-flight invoices hold a limited use until the bank confirms payment or failure.
create function public.customer_discount_usage(p_discount uuid)
returns bigint language sql stable security definer set search_path = '' as $$
  select (select count(*) from public.orders o where o.customer_discount_id = p_discount
    and o.status not in ('CANCELLED_BY_USER', 'CANCELLED_BY_STORE'))
    + (select count(*) from public.online_checkouts c where c.customer_discount_id = p_discount
      and c.status = 'PENDING' and not exists (select 1 from public.orders o where o.id = c.id));
$$;

create function public.active_customer_discount(p_store uuid, p_user uuid)
returns public.customer_discounts language plpgsql security definer set search_path = '' as $$
declare d public.customer_discounts;
begin
  if p_user is null then return null; end if;
  -- Shared with CRM edits and both checkout methods, including first-time assignment.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_store::text || p_user::text, 1));
  select * into d from public.customer_discounts
  where store_id = p_store and user_id = p_user and enabled for update;
  if not found or (d.mode = 'period' and (now() at time zone 'Europe/Kyiv')::date not between d.starts_on and d.ends_on)
    or (d.mode = 'orders' and public.customer_discount_usage(d.id) >= d.order_limit) then return null; end if;
  return d;
end;
$$;

create function public.my_customer_discount(p_store_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare d public.customer_discounts;
begin
  select * into d from public.customer_discounts where store_id = p_store_id and user_id = auth.uid() and enabled;
  if not found then return null; end if;
  return to_jsonb(d) || jsonb_build_object('used', public.customer_discount_usage(d.id), 'active',
    (d.mode <> 'period' or (now() at time zone 'Europe/Kyiv')::date between d.starts_on and d.ends_on)
    and (d.mode <> 'orders' or public.customer_discount_usage(d.id) < d.order_limit));
end;
$$;

create function public.set_customer_discount(p_store_id uuid, p_customer_id uuid, p_user_id uuid,
  p_percent numeric, p_mode text, p_order_limit integer default null, p_starts_on date default null, p_ends_on date default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.crm_customer_accounts(p_store_id, p_customer_id) a where a.user_id = p_user_id) then
    raise exception 'Registered customer account required' using errcode = '42501';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_store_id::text || p_user_id::text, 1));
  update public.customer_discounts set enabled = false where store_id = p_store_id and user_id = p_user_id and enabled;
  if p_percent is not null then
    insert into public.customer_discounts(store_id, user_id, percent, mode, order_limit, starts_on, ends_on)
    values (p_store_id, p_user_id, p_percent, p_mode,
      case when p_mode = 'orders' then p_order_limit end,
      case when p_mode = 'period' then p_starts_on end, case when p_mode = 'period' then p_ends_on end);
  end if;
end;
$$;

-- Zero-value orders bypass acquiring and still validate and deduct stock atomically.
create function public.create_free_customer_order(p_store uuid, p_items jsonb, p_checkout jsonb, p_discount uuid)
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
    if not found or quantity > 20 or (not v.is_preorder and v.stock_quantity < quantity) then raise exception 'Product is no longer available'; end if;
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
    insert into public.order_items(order_id,product_id,variant_id,product_name,variant_name,quantity,unit_price,compare_at_price,line_total,is_preorder)
      values(o.id,v.product_id,v.id,v.product_name,v.name,quantity,0,coalesce(v.compare_at_price,v.price),0,v.is_preorder);
    if not v.is_preorder then update public.product_variants set stock_quantity = stock_quantity - quantity where id = v.id; end if;
  end loop;
  insert into public.order_status_history(order_id,status,author_id) values(o.id,'PAID',auth.uid());
  return o;
end;
$$;
revoke all on function public.create_free_customer_order(uuid,jsonb,jsonb,uuid) from public,anon,authenticated;

-- The existing COD path keeps all delivery, stock and payment-method validation.
create or replace function public.create_store_order(
  p_store_id uuid, p_items jsonb, p_customer_name text, p_customer_email text, p_customer_phone text,
  p_delivery_city text, p_delivery_address text, p_note text default '', p_delivery_city_ref text default null,
  p_delivery_address_ref text default null, p_delivery_service_type text default null
) returns public.orders language plpgsql security definer set search_path = '' as $$
declare d public.customer_discounts; o public.orders; original_total integer;
begin
  d := public.active_customer_discount(p_store_id, auth.uid());
  if d.percent = 100 then
    return public.create_free_customer_order(p_store_id,p_items,jsonb_build_object(
      'name',p_customer_name,'email',p_customer_email,'phone',p_customer_phone,'city',p_delivery_city,
      'address',p_delivery_address,'note',p_note,'cityRef',p_delivery_city_ref,'addressRef',p_delivery_address_ref,
      'deliveryServiceType',p_delivery_service_type),d.id);
  end if;
  o := public.create_order_with_payment('CASH_ON_DELIVERY', auth.uid(), p_store_id, p_items, p_customer_name,
    p_customer_email, p_customer_phone, p_delivery_city, p_delivery_address, p_note,
    p_delivery_city_ref, p_delivery_address_ref, p_delivery_service_type);
  if d.id is not null then
    original_total := o.total_price;
    update public.order_items set compare_at_price = coalesce(compare_at_price, unit_price),
      unit_price = round(unit_price * (1 - d.percent / 100))::integer,
      line_total = round(unit_price * (1 - d.percent / 100))::integer * quantity where order_id = o.id;
    update public.orders set total_price = (select sum(line_total) from public.order_items where order_id = o.id),
      customer_discount_id = d.id, customer_discount_percent = d.percent,
      customer_discount_amount = original_total - (select sum(line_total) from public.order_items where order_id = o.id)
      where id = o.id returning * into o;
  end if;
  return o;
end;
$$;

alter function public.prepare_online_checkout(text,uuid,uuid,jsonb,jsonb,boolean) rename to prepare_online_checkout_before_discounts;
create function public.prepare_online_checkout(
  p_provider text, p_user_id uuid, p_store_id uuid, p_items jsonb, p_checkout jsonb, p_test_mode boolean
) returns public.online_checkouts language plpgsql security definer set search_path = '' as $$
declare d public.customer_discounts; c public.online_checkouts; priced jsonb; total integer;
begin
  d := public.active_customer_discount(p_store_id, p_user_id);
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

-- Copy the signed invoice's discount snapshot even if staff changes the discount before payment.
create function public.snapshot_online_customer_discount()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.payment_method = 'ONLINE' and exists (select 1 from public.online_checkouts c where c.id = new.id) then
    select c.customer_discount_id, c.customer_discount_percent, c.customer_discount_amount
    into new.customer_discount_id, new.customer_discount_percent, new.customer_discount_amount
    from public.online_checkouts c where c.id = new.id;
    new.customer_discount_percent := coalesce(new.customer_discount_percent,0);
    new.customer_discount_amount := coalesce(new.customer_discount_amount,0);
  end if;
  return new;
end;
$$;
create trigger snapshot_online_customer_discount before insert on public.orders
for each row execute function public.snapshot_online_customer_discount();

revoke all on function public.customer_discount_usage(uuid), public.active_customer_discount(uuid,uuid),
  public.my_customer_discount(uuid), public.set_customer_discount(uuid,uuid,uuid,numeric,text,integer,date,date),
  public.prepare_online_checkout(text,uuid,uuid,jsonb,jsonb,boolean) from public, anon, authenticated;
grant execute on function public.my_customer_discount(uuid), public.set_customer_discount(uuid,uuid,uuid,numeric,text,integer,date,date) to authenticated;
grant execute on function public.prepare_online_checkout(text,uuid,uuid,jsonb,jsonb,boolean) to service_role;

create function public.crm_customer_discount_usage(p_discount_id uuid)
returns bigint language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.customer_discounts d where d.id = p_discount_id
    and public.is_store_member(d.store_id)) then raise exception 'Access denied' using errcode = '42501'; end if;
  return public.customer_discount_usage(p_discount_id);
end;
$$;
revoke all on function public.crm_customer_discount_usage(uuid) from public,anon;
grant execute on function public.crm_customer_discount_usage(uuid) to authenticated;
