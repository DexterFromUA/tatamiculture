create table public.storefront_banners (
  store_id uuid primary key references public.stores(id) on delete cascade,
  image_url text not null default '',
  image_path text not null default '',
  kicker_uk text not null default '', kicker_en text not null default '',
  title_uk text not null default '', title_en text not null default '',
  description_uk text not null default '', description_en text not null default ''
);
alter table public.storefront_banners enable row level security;
create policy "public read storefront banners" on public.storefront_banners for select using (true);
create policy "staff manage storefront banners" on public.storefront_banners for all to authenticated
  using (public.is_store_member(store_id)) with check (public.is_store_member(store_id));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('storefront-banners', 'storefront-banners', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;
create policy "public read storefront banner images" on storage.objects for select using (bucket_id = 'storefront-banners');
create policy "staff upload storefront banner images" on storage.objects for insert to authenticated with check (
  bucket_id = 'storefront-banners' and public.is_store_member(case when split_part(name, '/', 1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(name, '/', 1)::uuid else null end)
);
create policy "staff delete storefront banner images" on storage.objects for delete to authenticated using (
  bucket_id = 'storefront-banners' and public.is_store_member(case when split_part(name, '/', 1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(name, '/', 1)::uuid else null end)
);
