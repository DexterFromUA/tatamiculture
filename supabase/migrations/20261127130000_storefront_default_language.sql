alter table public.storefront_theme_settings
  add column default_language text not null default 'auto'
    check (default_language in ('auto', 'uk', 'en'));

notify pgrst, 'reload schema';
