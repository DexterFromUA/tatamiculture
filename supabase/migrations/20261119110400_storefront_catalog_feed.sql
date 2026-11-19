begin;

create index products_store_updated_feed_idx
  on public.products (store_id, updated_at desc, id) where is_active;

create view public.storefront_variant_prices with (security_invoker = true) as
  select v.id, v.product_id, v.name, offer.price, offer.price < regular.price as is_discount
  from public.product_variants v join public.products p on p.id = v.product_id
  cross join lateral (select greatest(v.price, v.compare_at_price) as price) regular
  cross join lateral (select case when coalesce(v.discount_percent, p.discount_percent) is null then v.price
    else round(regular.price * (1 - coalesce(v.discount_percent, p.discount_percent) / 100))::integer end as price) offer
  where p.is_active;

create view public.storefront_category_links with (security_invoker = true) as
  select p.store_id, p.id as product_id, c.category_id
  from public.products p join public.product_categories c on c.product_id = p.id and c.store_id = p.store_id
  where p.is_active
  union all
  select p.store_id, p.id, p.category_id
  from public.products p
  where p.is_active and p.category_id is not null
    and not exists (select from public.product_categories c where c.product_id = p.id and c.store_id = p.store_id);

revoke all on public.storefront_variant_prices, public.storefront_category_links from public, anon, authenticated;
grant select on public.storefront_variant_prices, public.storefront_category_links to anon, authenticated;

create function public.storefront_product_payload(p_product_id uuid)
returns jsonb language sql stable set search_path = ''
as $$
  select to_jsonb(p) || jsonb_build_object(
    'categories', (select to_jsonb(c) from public.categories c where c.id = p.category_id and c.store_id = p.store_id),
    'product_categories', coalesce((
      select jsonb_agg(jsonb_build_object('categories', to_jsonb(c)))
      from public.product_categories link join public.categories c on c.id = link.category_id and c.store_id = link.store_id
      where link.product_id = p.id and link.store_id = p.store_id
    ), '[]'::jsonb),
    'product_images', coalesce((select jsonb_agg(jsonb_build_object('public_url', i.public_url, 'position', i.position) order by i.position, i.id)
      from public.product_images i where i.product_id = p.id), '[]'::jsonb),
    'product_variants', coalesce((select jsonb_agg(to_jsonb(v) order by v.position, v.id)
      from public.product_variants v where v.product_id = p.id), '[]'::jsonb)
  )
  from public.products p where p.id = p_product_id and p.is_active;
$$;

create function public.storefront_catalog_page(
  p_store_id uuid, p_search text default '', p_size text default '', p_sort text default 'recently-updated',
  p_category_id uuid default null, p_collection text default 'all', p_limit integer default 24,
  p_after_price bigint default null, p_after_updated_at timestamptz default null, p_after_id uuid default null
) returns jsonb language sql stable set search_path = ''
as $$
  with settings as (
    select lower(btrim(coalesce(p_search, ''))) as search, btrim(coalesce(p_size, '')) as size,
      greatest(1, least(48, coalesce(p_limit, 24))) as batch_size
  ), matches as materialized (
    select p.id, p.updated_at,
      case p_sort
        when 'price-low' then coalesce(prices.lowest::bigint, 2147483648)
        when 'price-high' then coalesce(-prices.lowest::bigint, 2147483648)
        else 0 end as price_key
    from public.products p cross join settings s
    left join lateral (
      select min(v.price) as lowest from public.storefront_variant_prices v
      where v.product_id = p.id and p_sort in ('price-low', 'price-high')
    ) prices on true
    where p.store_id = p_store_id and p.is_active
      and (p_collection <> 'new' or p.is_new)
      and (p_category_id is null or exists (
        select from public.storefront_category_links c where c.store_id = p_store_id
          and c.product_id = p.id and c.category_id = p_category_id
      ))
      and (s.search = '' or strpos(lower(p.name), s.search) > 0 or strpos(lower(p.name_uk), s.search) > 0 or strpos(lower(p.name_en), s.search) > 0)
      and ((s.size = '' and p_collection <> 'sale') or exists (
        select from public.storefront_variant_prices v where v.product_id = p.id
          and (s.size = '' or btrim(v.name) = s.size)
          and (p_collection <> 'sale' or v.is_discount)
      ))
  ), windowed as materialized (
    select matches.*
    from matches
    where p_after_id is null or price_key > p_after_price or (price_key = p_after_price and (
      updated_at < p_after_updated_at or (updated_at = p_after_updated_at and id > p_after_id)
    ))
    order by price_key, updated_at desc, id
    limit (select batch_size + 1 from settings)
  ), page_ids as materialized (
    select * from windowed order by price_key, updated_at desc, id limit (select batch_size from settings)
  )
  select jsonb_build_object(
    'total', (select count(*) from matches),
    'rows', coalesce((select jsonb_agg(public.storefront_product_payload(id) order by price_key, updated_at desc, id) from page_ids), '[]'::jsonb),
    'next_cursor', case when (select count(*) from windowed) > (select batch_size from settings) then (
      select jsonb_build_object('price', price_key, 'updatedAt', updated_at, 'id', id)
      from page_ids order by price_key desc, updated_at, id desc limit 1
    ) end
  );
$$;

create function public.storefront_catalog_metadata(p_store_id uuid)
returns jsonb language sql stable set search_path = ''
as $$
  with published as materialized (
    select p.id, p.name, p.name_uk, p.name_en, p.is_new, p.created_at,
      exists (select from public.storefront_variant_prices v where v.product_id = p.id and v.is_discount) as on_sale
    from public.products p where p.store_id = p_store_id and p.is_active
  )
  select jsonb_build_object(
    'categories', coalesce((
      select jsonb_agg(to_jsonb(c) order by c.position, c.id) from public.categories c
      where c.store_id = p_store_id and exists (
        select from public.storefront_category_links link where link.store_id = p_store_id and link.category_id = c.id
      )
    ), '[]'::jsonb),
    'sizes', coalesce((select jsonb_agg(distinct btrim(v.name))
      from published p join public.product_variants v on v.product_id = p.id where btrim(v.name) <> ''), '[]'::jsonb),
    'hasNewArrivals', exists (select from published where is_new),
    'hasDiscountedProducts', exists (select from published where on_sale),
    'bannerProducts', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'name_uk', p.name_uk, 'name_en', p.name_en, 'url', img.public_url)
        order by p.is_new desc, p.created_at desc, p.id)
      from published p cross join lateral (
        select i.public_url from public.product_images i where i.product_id = p.id order by i.position, i.id limit 1
      ) img where (p.is_new or p.on_sale) and img.public_url <> ''
    ), '[]'::jsonb)
  );
$$;

create function public.storefront_related_products(p_store_id uuid, p_product_id uuid)
returns jsonb language sql stable set search_path = ''
as $$
  with ranked as (
    select candidate.product_id, p.created_at,
      count(*) filter (where c.parent_id is not null) as subcategories, count(*) as shared
    from public.storefront_category_links original
    join public.storefront_category_links candidate on candidate.category_id = original.category_id and candidate.store_id = original.store_id
    join public.categories c on c.id = candidate.category_id
    join public.products p on p.id = candidate.product_id
    where original.store_id = p_store_id and original.product_id = p_product_id and candidate.product_id <> p_product_id
      and exists (select from public.product_variants v where v.product_id = candidate.product_id)
    group by candidate.product_id, p.created_at
    order by subcategories desc, shared desc, p.created_at desc, candidate.product_id
    limit 4
  )
  select coalesce(jsonb_agg(public.storefront_product_payload(product_id) order by subcategories desc, shared desc, created_at desc, product_id), '[]'::jsonb)
  from ranked;
$$;

revoke all on function public.storefront_product_payload(uuid),
  public.storefront_catalog_page(uuid, text, text, text, uuid, text, integer, bigint, timestamptz, uuid),
  public.storefront_catalog_metadata(uuid), public.storefront_related_products(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.storefront_product_payload(uuid),
  public.storefront_catalog_page(uuid, text, text, text, uuid, text, integer, bigint, timestamptz, uuid),
  public.storefront_catalog_metadata(uuid), public.storefront_related_products(uuid, uuid)
  to anon, authenticated;

notify pgrst, 'reload schema';
commit;
