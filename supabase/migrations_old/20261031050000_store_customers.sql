create table public.store_customers (
  store_id uuid not null references public.stores(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (store_id, user_id)
);
insert into public.store_customers (store_id, user_id, joined_at)
select store_id, user_id, min(created_at) from public.orders where user_id is not null group by store_id, user_id
on conflict do nothing;
alter table public.store_customers enable row level security;
create policy "customers join store" on public.store_customers for insert with check (user_id = auth.uid());
create policy "customers read own store membership" on public.store_customers for select using (user_id = auth.uid());
create policy "staff read store customers" on public.store_customers for select using (public.is_store_member(store_id));
