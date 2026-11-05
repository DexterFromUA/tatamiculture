alter table public.storefront_banners
  add column images jsonb not null default '[]'::jsonb,
  add constraint storefront_banner_images_are_array check (jsonb_typeof(images) = 'array');
