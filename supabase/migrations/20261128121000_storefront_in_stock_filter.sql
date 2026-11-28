create function public.storefront_catalog_page_filtered(
  p_store_id uuid, p_search text default '', p_size text default '', p_sort text default 'recently-updated',
  p_category_id uuid default null, p_collection text default 'all', p_limit integer default 24,
  p_after_price bigint default null, p_after_updated_at timestamptz default null, p_after_id uuid default null,
  p_in_stock boolean default false
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
      and ((s.size = '' and p_collection <> 'sale' and not coalesce(p_in_stock, false)) or exists (
        select from public.storefront_variant_prices v where v.product_id = p.id
          and (s.size = '' or btrim(v.name) = s.size)
          and (p_collection <> 'sale' or v.is_discount)
          and (not coalesce(p_in_stock, false) or exists (
            select from public.product_variants stock where stock.id = v.id and public.catalog_stock_quantity(stock) > 0
          ))
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

revoke all on function public.storefront_catalog_page_filtered(uuid, text, text, text, uuid, text, integer, bigint, timestamptz, uuid, boolean) from public, anon, authenticated;
grant execute on function public.storefront_catalog_page_filtered(uuid, text, text, text, uuid, text, integer, bigint, timestamptz, uuid, boolean) to anon, authenticated;
notify pgrst, 'reload schema';
