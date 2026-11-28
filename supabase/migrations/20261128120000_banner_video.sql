alter table public.storefront_banners add column show_text boolean not null default true;

update storage.buckets set file_size_limit = 52428800,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'video/mp4', 'video/webm', 'video/quicktime']
where id = 'storefront-banners';

notify pgrst, 'reload schema';
