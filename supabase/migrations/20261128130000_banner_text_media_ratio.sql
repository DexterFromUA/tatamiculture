alter table public.storefront_banners
  add column desktop_text_percent smallint check (desktop_text_percent between 20 and 80),
  add column mobile_text_percent smallint check (mobile_text_percent between 20 and 80);

notify pgrst, 'reload schema';
