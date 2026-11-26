create table public.catalog_import_settings (
  store_id uuid primary key references public.shop_settings(id) on delete cascade,
  auto_fill_cost boolean not null default false,
  cost_discount_percent numeric(5,2) not null default 20
    check (cost_discount_percent between 0 and 100)
);

alter table public.catalog_import_settings enable row level security;
revoke all on public.catalog_import_settings from public, anon, authenticated;
grant select, insert, update on public.catalog_import_settings to authenticated;

create policy catalog_import_settings_select on public.catalog_import_settings for select to authenticated
  using (public.is_store_member(store_id));
create policy catalog_import_settings_insert on public.catalog_import_settings for insert to authenticated
  with check (public.is_store_member(store_id));
create policy catalog_import_settings_update on public.catalog_import_settings for update to authenticated
  using (public.is_store_member(store_id)) with check (public.is_store_member(store_id));

create trigger catalog_import_settings_audit
  after insert or update on public.catalog_import_settings
  for each row execute function public.capture_crm_audit_change('catalog');

notify pgrst, 'reload schema';
