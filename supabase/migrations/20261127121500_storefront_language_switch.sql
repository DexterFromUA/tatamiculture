alter table public.storefront_theme_settings
  add column if not exists show_language_switch boolean not null default true;

notify pgrst, 'reload schema';
