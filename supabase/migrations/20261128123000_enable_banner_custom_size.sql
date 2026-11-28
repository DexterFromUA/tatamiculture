alter table public.storefront_banners
  add column custom_size_enabled boolean not null default false;

notify pgrst, 'reload schema';
