-- Product image storage. Apply this migration after the initial store migration.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'product-images',
  'product-images',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create policy "public can read product image files"
on storage.objects for select
using (bucket_id = 'product-images');

create policy "staff can upload own store product images"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'product-images'
  and exists (
    select 1
    from public.products p
    where p.id = case
      when split_part(name, '/', 2) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then split_part(name, '/', 2)::uuid
      else null
    end
    and public.is_store_member(p.store_id)
  )
);

create policy "staff can update own store product images"
on storage.objects for update to authenticated
using (
  bucket_id = 'product-images'
  and exists (
    select 1
    from public.products p
    where p.id = case
      when split_part(name, '/', 2) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then split_part(name, '/', 2)::uuid
      else null
    end
    and public.is_store_member(p.store_id)
  )
)
with check (
  bucket_id = 'product-images'
);

create policy "staff can delete own store product images"
on storage.objects for delete to authenticated
using (
  bucket_id = 'product-images'
  and exists (
    select 1
    from public.products p
    where p.id = case
      when split_part(name, '/', 2) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then split_part(name, '/', 2)::uuid
      else null
    end
    and public.is_store_member(p.store_id)
  )
);
