create table public.storefront_theme_settings (
  store_id uuid primary key references public.shop_settings(id) on delete cascade,
  show_theme_switch boolean not null default true,
  default_theme text not null default 'system' check (default_theme in ('system', 'light', 'dark'))
);

alter table public.storefront_theme_settings enable row level security;
grant select on public.storefront_theme_settings to anon, authenticated;
grant insert, update, delete on public.storefront_theme_settings to authenticated;
create policy "public read storefront theme" on public.storefront_theme_settings for select to anon, authenticated using (true);
create policy "staff manage storefront theme" on public.storefront_theme_settings for all to authenticated
  using (public.is_store_member(store_id)) with check (public.is_store_member(store_id));

notify pgrst, 'reload schema';
