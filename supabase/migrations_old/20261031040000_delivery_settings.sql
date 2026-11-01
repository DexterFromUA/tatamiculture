create table public.delivery_settings (
  store_id uuid primary key references public.stores(id) on delete cascade,
  sender_name text not null default '',
  sender_phone text not null default '',
  city_ref text not null default '',
  city_name text not null default '',
  warehouse_ref text not null default '',
  warehouse_name text not null default '',
  default_weight_grams integer not null default 1000 check (default_weight_grams > 0),
  length_cm integer not null default 20 check (length_cm > 0),
  width_cm integer not null default 20 check (width_cm > 0),
  height_cm integer not null default 10 check (height_cm > 0),
  declared_value integer not null default 50000 check (declared_value >= 0),
  delivery_payer text not null default 'RECIPIENT' check (delivery_payer in ('RECIPIENT', 'SENDER')),
  updated_at timestamptz not null default now()
);
create trigger delivery_settings_updated before update on public.delivery_settings for each row execute procedure public.touch_updated_at();
alter table public.delivery_settings enable row level security;
create policy "staff manage delivery settings" on public.delivery_settings for all using (public.is_store_member(store_id)) with check (public.is_store_member(store_id));
