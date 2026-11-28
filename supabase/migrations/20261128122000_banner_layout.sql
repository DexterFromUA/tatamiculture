alter table public.storefront_banners
  add column desktop_width_percent smallint check (desktop_width_percent between 50 and 100),
  add column desktop_height_px smallint check (desktop_height_px between 140 and 720),
  add column mobile_width_percent smallint check (mobile_width_percent between 50 and 100),
  add column mobile_height_px smallint check (mobile_height_px between 140 and 720),
  add column background_color text check (background_color ~ '^#[0-9a-fA-F]{6}$');

notify pgrst, 'reload schema';
