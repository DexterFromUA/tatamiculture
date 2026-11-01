alter table public.orders
  add column if not exists payment_method text not null default 'CASH_ON_DELIVERY'
    check (payment_method in ('ONLINE', 'CASH_ON_DELIVERY')),
  add column if not exists nova_poshta_status text,
  add column if not exists nova_poshta_status_code text,
  add column if not exists nova_poshta_status_updated_at timestamptz;

create table if not exists public.order_delivery_events (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  status_code text not null,
  status_text text not null,
  created_at timestamptz not null default now()
);
create index if not exists order_delivery_events_order_created_idx on public.order_delivery_events(order_id, created_at desc);
alter table public.order_delivery_events enable row level security;
create policy "staff access delivery events" on public.order_delivery_events for all
  using (exists (select 1 from public.orders o where o.id = order_id and public.is_store_member(o.store_id)))
  with check (exists (select 1 from public.orders o where o.id = order_id and public.is_store_member(o.store_id)));
