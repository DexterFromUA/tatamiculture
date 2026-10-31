-- Demo catalogue for a fresh Tatami project. Prices are stored in kopecks.
insert into public.stores (id, slug, name, description, contact_email, contact_phone, contact_city, currency, primary_color)
values ('11111111-1111-4111-8111-111111111111', 'tatami', 'Tatami', 'Спортивний одяг для тренувань, руху та щоденного ритму.', 'hello@tatami.store', '+380 50 123 4567', 'Kyiv', 'UAH', '#203f36')
on conflict (slug) do update set name = excluded.name, description = excluded.description, currency = excluded.currency;

insert into public.categories (id, store_id, name, slug, position) values
  ('22222222-2222-4222-8222-222222222221', '11111111-1111-4111-8111-111111111111', 'Hoodies', 'hoodies', 1),
  ('22222222-2222-4222-8222-222222222222', '11111111-1111-4111-8111-111111111111', 'T-shirts', 't-shirts', 2),
  ('22222222-2222-4222-8222-222222222223', '11111111-1111-4111-8111-111111111111', 'Bottoms', 'bottoms', 3)
on conflict (store_id, slug) do nothing;

insert into public.products (id, store_id, category_id, name, description, is_active, position) values
  ('33333333-3333-4333-8333-333333333331', '11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222221', 'Training hoodie', 'Щільне худі вільного крою для розминки та відновлення після тренування.', true, 1),
  ('33333333-3333-4333-8333-333333333332', '11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222', 'Performance T-shirt', 'Легка футболка, що відводить вологу та не сковує рухи.', true, 2),
  ('33333333-3333-4333-8333-333333333333', '11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222223', 'Everyday joggers', 'М’які джогери із високою посадкою для залу й міста.', true, 3)
on conflict (id) do update set name = excluded.name, description = excluded.description, is_active = excluded.is_active;

insert into public.product_variants (id, product_id, name, sku, price, compare_at_price, stock_quantity, position) values
  ('44444444-4444-4444-8444-444444444411', '33333333-3333-4333-8333-333333333331', 'S', 'TAT-HOOD-S', 249000, null, 4, 1),
  ('44444444-4444-4444-8444-444444444412', '33333333-3333-4333-8333-333333333331', 'M', 'TAT-HOOD-M', 249000, null, 6, 2),
  ('44444444-4444-4444-8444-444444444421', '33333333-3333-4333-8333-333333333332', 'S', 'TAT-TEE-S', 129000, null, 12, 1),
  ('44444444-4444-4444-8444-444444444422', '33333333-3333-4333-8333-333333333332', 'M', 'TAT-TEE-M', 129000, null, 20, 2),
  ('44444444-4444-4444-8444-444444444431', '33333333-3333-4333-8333-333333333333', 'S', 'TAT-JOG-S', 219000, null, 5, 1),
  ('44444444-4444-4444-8444-444444444432', '33333333-3333-4333-8333-333333333333', 'M', 'TAT-JOG-M', 219000, null, 8, 2)
on conflict (id) do update set price = excluded.price, stock_quantity = excluded.stock_quantity;

insert into public.product_images (product_id, storage_path, public_url, alt, position) values
  ('33333333-3333-4333-8333-333333333331', 'demo/training-hoodie.jpg', 'https://images.unsplash.com/photo-1517836357463-d25dfeac3438?auto=format&fit=crop&w=800&q=80', 'Training hoodie', 1),
  ('33333333-3333-4333-8333-333333333332', 'demo/performance-tshirt.jpg', 'https://images.unsplash.com/photo-1574680096145-d05b474e2155?auto=format&fit=crop&w=800&q=80', 'Performance T-shirt', 1),
  ('33333333-3333-4333-8333-333333333333', 'demo/joggers.jpg', 'https://images.unsplash.com/photo-1518611012118-696072aa579a?auto=format&fit=crop&w=800&q=80', 'Everyday joggers', 1)
on conflict do nothing;

insert into public.short_links (store_id, product_id, code)
values ('11111111-1111-4111-8111-111111111111', '33333333-3333-4333-8333-333333333331', 'hoodie24')
on conflict (code) do nothing;
