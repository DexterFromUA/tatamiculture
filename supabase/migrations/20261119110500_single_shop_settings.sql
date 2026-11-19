begin;

set local lock_timeout = '5s';
lock table public.stores, public.orders, public.products, public.product_variants, public.product_images
  in share row exclusive mode;

create temporary view current_primary_catalog as
with primary_products as (
  select p.* from public.products p join public.stores s on s.id = p.store_id where s.slug = 'tatami'
)
select 'product' as kind, to_jsonb(p) as data from primary_products p
union all
select 'variant', to_jsonb(v) from public.product_variants v join primary_products p on p.id = v.product_id
union all
select 'image', to_jsonb(i) from public.product_images i join primary_products p on p.id = i.product_id;

create temporary table primary_catalog_snapshot on commit drop as
select * from current_primary_catalog;

do $$
declare
  sandbox_id uuid;
begin
  if not exists (select from public.stores where slug = 'tatami')
    or exists (select from public.stores where slug not in ('tatami', 'tatami-mono-test-724c7075')) then
    raise exception 'Expected Tatami and, optionally, the known Monobank test store';
  end if;

  select id into sandbox_id from public.stores where slug = 'tatami-mono-test-724c7075';
  if sandbox_id is not null then
    if exists (
      select from public.order_items i
      join public.orders o on o.id = i.order_id
      left join public.products p on p.id = i.product_id
      left join public.product_variants v on v.id = i.variant_id
      left join public.products vp on vp.id = v.product_id
      where o.store_id <> sandbox_id and (p.store_id = sandbox_id or vp.store_id = sandbox_id)
    ) then
      raise exception 'A live order refers to the test catalog';
    end if;

    delete from public.orders where store_id = sandbox_id;
    delete from public.crm_customer_keys where store_id = sandbox_id;
    delete from public.crm_customers where store_id = sandbox_id;
    delete from public.stores where id = sandbox_id;
  end if;

  if exists (
    (select * from current_primary_catalog except all select * from primary_catalog_snapshot)
    union all
    (select * from primary_catalog_snapshot except all select * from current_primary_catalog)
  ) then
    raise exception 'The primary catalog changed during the migration';
  end if;
end;
$$;

drop view current_primary_catalog;

alter table public.stores rename to shop_settings;
alter table public.shop_settings drop column slug;
alter table public.shop_settings rename constraint stores_pkey to shop_settings_pkey;
alter table public.shop_settings rename constraint stores_currency_check to shop_settings_currency_check;
alter policy "public can read stores" on public.shop_settings rename to "public can read shop settings";
create unique index shop_settings_single_row_idx on public.shop_settings ((true));
revoke all on public.shop_settings from anon, authenticated;
grant select on public.shop_settings to anon, authenticated;

-- Static SQL dependencies follow the table OID. PL/pgSQL source needs the new name.
do $$
declare
  routine record;
begin
  for routine in
    select pg_get_functiondef(p.oid) as definition
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('create_crm_order', 'create_priced_catalog_order', 'prepare_online_checkout', 'set_sms_notifications_enabled')
      and p.prosrc like '%public.stores%'
  loop
    execute replace(routine.definition, 'public.stores', 'public.shop_settings');
  end loop;
end;
$$;

-- Keep cached frontend bundles working while the new bundle is deployed.
create view public.stores with (security_invoker = true) as
  select id, 'tatami'::text as slug, name, currency, created_at, sms_notifications_enabled
  from public.shop_settings;
revoke all on public.stores from public, anon, authenticated, service_role;
grant select on public.stores to anon, authenticated, service_role;

notify pgrst, 'reload schema';
commit;
