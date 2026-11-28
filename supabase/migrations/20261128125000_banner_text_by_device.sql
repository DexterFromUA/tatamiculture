alter table public.storefront_banners
  add column show_desktop_text boolean,
  add column show_mobile_text boolean;

notify pgrst, 'reload schema';
