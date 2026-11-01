-- Tatami store: catalogue, orders and lightweight CRM.
-- Apply with: supabase db push
-- The migration is intentionally self-contained so a new Supabase project can
-- be prepared before the frontend is connected.

create extension if not exists pgcrypto;

create type public.order_status as enum (
  'PENDING', 'PAID', 'IN_PROGRESS', 'READY_FOR_PICKUP', 'DELIVERED',
  'CANCELLED_BY_USER', 'CANCELLED_BY_STORE'
);
create type public.payment_status as enum ('PENDING', 'PAID', 'FAILED', 'REFUNDED');
create type public.staff_role as enum ('OWNER', 'MANAGER', 'CONTENT');

create table public.stores (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9-]+$'),
  name text not null,
  description text not null default '',
  contact_email text not null,
  contact_phone text not null,
  contact_city text not null,
  currency text not null default 'UAH' check (char_length(currency) = 3),
  primary_color text not null default '#1f4d3a',
  created_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '',
  phone text not null default '',
  city text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.store_members (
  store_id uuid not null references public.stores(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role public.staff_role not null default 'MANAGER',
  primary key (store_id, user_id)
);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete cascade,
  name text not null,
  slug text not null,
  position integer not null default 0,
  unique (store_id, slug)
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete cascade,
  category_id uuid references public.categories(id) on delete set null,
  name text not null,
  description text not null default '',
  is_active boolean not null default true,
  position integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.product_variants (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  name text not null,
  sku text,
  price integer not null check (price >= 0), -- minor currency units (kopecks/cents)
  compare_at_price integer check (compare_at_price is null or compare_at_price >= price),
  stock_quantity integer not null default 0 check (stock_quantity >= 0),
  is_preorder boolean not null default false,
  position integer not null default 0,
  unique (product_id, sku)
);

create table public.product_images (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  storage_path text not null,
  public_url text not null,
  alt text not null default '',
  position integer not null default 0
);

create table public.short_links (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  code text not null unique check (code ~ '^[A-Za-z0-9_-]{4,64}$'),
  created_at timestamptz not null default now()
);

create table public.customer_tags (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete cascade,
  name text not null,
  color text not null default '#1f4d3a',
  unique (store_id, name)
);

create table public.customer_tag_assignments (
  tag_id uuid not null references public.customer_tags(id) on delete cascade,
  customer_id uuid not null references public.profiles(id) on delete cascade,
  primary key (tag_id, customer_id)
);

create table public.customer_notes (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete cascade,
  customer_id uuid not null references public.profiles(id) on delete cascade,
  author_id uuid references public.profiles(id) on delete set null,
  body text not null check (char_length(body) between 1 and 4000),
  created_at timestamptz not null default now()
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete restrict,
  user_id uuid references public.profiles(id) on delete set null,
  status public.order_status not null default 'PENDING',
  payment_status public.payment_status not null default 'PENDING',
  receipt_code text not null unique default encode(gen_random_bytes(12), 'hex'),
  customer_name text not null,
  customer_email text not null,
  customer_phone text not null,
  delivery_city text not null,
  delivery_address text not null,
  note text not null default '',
  total_price integer not null check (total_price >= 0), -- minor currency units
  currency text not null check (char_length(currency) = 3),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  variant_id uuid references public.product_variants(id) on delete set null,
  product_name text not null,
  variant_name text not null,
  quantity integer not null check (quantity > 0),
  unit_price integer not null check (unit_price >= 0),
  compare_at_price integer,
  line_total integer not null check (line_total >= 0),
  is_preorder boolean not null default false
);

create table public.order_status_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  status public.order_status not null,
  author_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index orders_store_created_idx on public.orders (store_id, created_at desc);
create index orders_customer_idx on public.orders (user_id, created_at desc);
create index variants_product_idx on public.product_variants (product_id, position);

create or replace function public.is_store_member(target_store_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.store_members
    where store_id = target_store_id and user_id = auth.uid()
  );
$$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, phone)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'name', ''),
    coalesce(new.raw_user_meta_data ->> 'phone', '')
  );
  return new;
end;
$$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute procedure public.handle_new_user();

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

create trigger profiles_updated before update on public.profiles
  for each row execute procedure public.touch_updated_at();
create trigger products_updated before update on public.products
  for each row execute procedure public.touch_updated_at();
create trigger orders_updated before update on public.orders
  for each row execute procedure public.touch_updated_at();

alter table public.stores enable row level security;
alter table public.profiles enable row level security;
alter table public.store_members enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.product_variants enable row level security;
alter table public.product_images enable row level security;
alter table public.short_links enable row level security;
alter table public.customer_tags enable row level security;
alter table public.customer_tag_assignments enable row level security;
alter table public.customer_notes enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.order_status_history enable row level security;

-- Public storefront reads only active catalogue records. All writes go via the
-- admin role or server-side functions.
create policy "public can read stores" on public.stores for select using (true);
create policy "public can read categories" on public.categories for select using (true);
create policy "public can read active products" on public.products for select using (is_active);
create policy "public can read variants of active products" on public.product_variants for select using (
  exists (select 1 from public.products p where p.id = product_id and p.is_active)
);
create policy "public can read images of active products" on public.product_images for select using (
  exists (select 1 from public.products p where p.id = product_id and p.is_active)
);
create policy "public can read short links" on public.short_links for select using (true);
create policy "users read own profile" on public.profiles for select using (id = auth.uid());
create policy "users update own profile" on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
create policy "staff read own membership" on public.store_members for select using (user_id = auth.uid());
create policy "staff read customers" on public.profiles for select using (
  exists (
    select 1 from public.orders o
    where o.user_id = profiles.id and public.is_store_member(o.store_id)
  )
);
create policy "customers read own orders" on public.orders for select using (user_id = auth.uid());
create policy "customers read own order items" on public.order_items for select using (
  exists (select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid())
);

create policy "staff manage products" on public.products for all using (public.is_store_member(store_id)) with check (public.is_store_member(store_id));
create policy "staff manage categories" on public.categories for all using (public.is_store_member(store_id)) with check (public.is_store_member(store_id));
create policy "staff manage images" on public.product_images for all using (
  exists (select 1 from public.products p where p.id = product_id and public.is_store_member(p.store_id))
) with check (
  exists (select 1 from public.products p where p.id = product_id and public.is_store_member(p.store_id))
);
create policy "staff manage short links" on public.short_links for all using (public.is_store_member(store_id)) with check (public.is_store_member(store_id));
create policy "staff manage variants" on public.product_variants for all using (
  exists (select 1 from public.products p where p.id = product_id and public.is_store_member(p.store_id))
) with check (
  exists (select 1 from public.products p where p.id = product_id and public.is_store_member(p.store_id))
);
create policy "staff access orders" on public.orders for all using (public.is_store_member(store_id)) with check (public.is_store_member(store_id));
create policy "staff access order items" on public.order_items for all using (
  exists (select 1 from public.orders o where o.id = order_id and public.is_store_member(o.store_id))
) with check (
  exists (select 1 from public.orders o where o.id = order_id and public.is_store_member(o.store_id))
);
create policy "staff access CRM tags" on public.customer_tags for all using (public.is_store_member(store_id)) with check (public.is_store_member(store_id));
create policy "staff access CRM tag assignments" on public.customer_tag_assignments for all using (
  exists (select 1 from public.customer_tags t where t.id = tag_id and public.is_store_member(t.store_id))
) with check (
  exists (select 1 from public.customer_tags t where t.id = tag_id and public.is_store_member(t.store_id))
);
create policy "staff access CRM notes" on public.customer_notes for all using (public.is_store_member(store_id)) with check (public.is_store_member(store_id));
create policy "staff access status history" on public.order_status_history for all using (
  exists (select 1 from public.orders o where o.id = order_id and public.is_store_member(o.store_id))
) with check (
  exists (select 1 from public.orders o where o.id = order_id and public.is_store_member(o.store_id))
);

-- The browser passes only ids and quantities. This function takes a row lock on
-- each variant, obtains current prices in the database and reduces stock safely.
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

-- A receipt code is a 24-character random secret. The function exposes only a
-- single order, allowing guest buyers to reopen their receipt without opening
-- the complete order table to the public.
create or replace function public.get_order_receipt(p_receipt_code text)
returns jsonb language sql security definer set search_path = public as $$
  select to_jsonb(o) || jsonb_build_object(
    'items', coalesce((select jsonb_agg(to_jsonb(oi) order by oi.id) from public.order_items oi where oi.order_id = o.id), '[]'::jsonb)
  )
  from public.orders o
  where o.receipt_code = lower(trim(p_receipt_code));
$$;
grant execute on function public.get_order_receipt(text) to anon, authenticated;

-- Run once after you create your first account in Supabase:
-- insert into public.store_members (store_id, user_id, role)
-- values ('<store uuid>', '<your auth.users uuid>', 'OWNER');
