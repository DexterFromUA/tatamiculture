alter table public.storefront_banners
  drop constraint storefront_banners_desktop_height_px_check,
  drop constraint storefront_banners_mobile_height_px_check,
  add constraint storefront_banners_desktop_height_px_check check (desktop_height_px between 140 and 1600),
  add constraint storefront_banners_mobile_height_px_check check (mobile_height_px between 140 and 1600);
