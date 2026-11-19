-- Keyset paging, filtered totals, and public access with rollback-only fixtures.
begin;

do $$
declare
  shop uuid := gen_random_uuid();
  category uuid := gen_random_uuid();
  sale_id uuid;
  first_page jsonb;
  second_page jsonb;
  last_page jsonb;
  cursor jsonb;
  result jsonb;
begin
  insert into public.stores(id, slug, name) values (shop, 'storefront-feed-test-' || shop, 'Feed test');
  insert into public.categories(id, store_id, name, slug) values (category, shop, 'Test category', 'feed-category');
  insert into public.products(store_id, category_id, name, name_uk, is_active, is_new, discount_percent, updated_at)
    select shop, category, 'Fixture ' || n, case when n = 1 then 'Футболка для тесту' end,
      n < 52, n = 1, case when n = 1 then 50 end,
      timestamptz '2026-11-01 12:00:00+00'
    from generate_series(1, 52) n;
  select id into strict sale_id from public.products where store_id = shop and name = 'Fixture 1';
  insert into public.product_variants(product_id, name, sku, price, stock_quantity)
    select id, case when id = sale_id then 'M' else 'L' end, 'SKU-' || id, 10000, 1
    from public.products where store_id = shop;

  set local role anon;
  first_page := public.storefront_catalog_page(shop);
  cursor := first_page->'next_cursor';
  second_page := public.storefront_catalog_page(shop, p_after_price => (cursor->>'price')::bigint,
    p_after_updated_at => (cursor->>'updatedAt')::timestamptz, p_after_id => (cursor->>'id')::uuid);
  cursor := second_page->'next_cursor';
  last_page := public.storefront_catalog_page(shop, p_after_price => (cursor->>'price')::bigint,
    p_after_updated_at => (cursor->>'updatedAt')::timestamptz, p_after_id => (cursor->>'id')::uuid);

  if (first_page->>'total')::integer <> 51 or jsonb_array_length(first_page->'rows') <> 24
    or jsonb_array_length(second_page->'rows') <> 24 or jsonb_array_length(last_page->'rows') <> 3
    or last_page->>'next_cursor' is not null
    or (select count(distinct item->>'id') from jsonb_array_elements(
      (first_page->'rows') || (second_page->'rows') || (last_page->'rows')) as item) <> 51 then
    raise exception 'Keyset paging skipped or repeated published products';
  end if;

  result := public.storefront_catalog_page(shop, p_search => 'футболка', p_size => 'M',
    p_category_id => category, p_collection => 'sale');
  if (result->>'total')::integer <> 1 or result#>>'{rows,0,id}' <> sale_id::text
    or jsonb_array_length(result#>'{rows,0,product_variants}') <> 1 then
    raise exception 'Catalog filters or product payload did not match the published result';
  end if;
  result := public.storefront_catalog_page(shop, p_sort => 'price-low', p_limit => 1);
  if result#>>'{rows,0,id}' <> sale_id::text then raise exception 'Sorting ignored the discounted price'; end if;
  result := public.storefront_catalog_metadata(shop);
  if (result->>'hasNewArrivals')::boolean is distinct from true
    or (result->>'hasDiscountedProducts')::boolean is distinct from true
    or jsonb_array_length(result->'categories') <> 1
    or jsonb_array_length(public.storefront_related_products(shop, sale_id)) <> 4 then
    raise exception 'Category metadata or related products are incorrect';
  end if;
end;
$$;
rollback;

select 'Storefront catalog feed checks passed' as result;
