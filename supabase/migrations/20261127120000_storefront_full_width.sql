alter table public.storefront_theme_settings
  add column if not exists full_width boolean not null default false;

notify pgrst, 'reload schema';
