drop policy if exists "staff can upload own store product images" on storage.objects;
drop policy if exists "staff can update own store product images" on storage.objects;
drop policy if exists "staff can delete own store product images" on storage.objects;

-- Qualify the file path because products also has a name column.
-- FOR ALL applies this condition to both old and new rows when updating.
create policy "staff manage own store product images"
on storage.objects for all to authenticated
using (
  bucket_id = 'product-images'
  and (storage.foldername(storage.objects.name))[1] = 'products'
  and exists (
    select 1
    from public.products p
    where p.id = case
      when (storage.foldername(storage.objects.name))[2] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (storage.foldername(storage.objects.name))[2]::uuid
    end
    and public.is_store_member(p.store_id)
  )
);
