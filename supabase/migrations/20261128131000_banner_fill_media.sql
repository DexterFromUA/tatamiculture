alter table public.storefront_banners
  add column show_full_media boolean not null default true;

notify pgrst, 'reload schema';
