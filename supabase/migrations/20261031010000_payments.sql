-- Payment records are separate from orders so provider callbacks stay auditable.
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders(id) on delete cascade,
  provider text not null check (provider in ('LIQPAY')),
  provider_order_id text not null unique,
  provider_payment_id text,
  status public.payment_status not null default 'PENDING',
  raw_callback jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger payments_updated before update on public.payments
  for each row execute procedure public.touch_updated_at();

alter table public.payments enable row level security;

create policy "customers read own payments" on public.payments for select using (
  exists (select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid())
);
create policy "staff access store payments" on public.payments for all using (
  exists (select 1 from public.orders o where o.id = order_id and public.is_store_member(o.store_id))
) with check (
  exists (select 1 from public.orders o where o.id = order_id and public.is_store_member(o.store_id))
);
