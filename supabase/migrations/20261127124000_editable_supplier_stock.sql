create table public.variant_supplier_stock (
  variant_id uuid primary key references public.product_variants(id) on delete cascade,
  quantity integer check (quantity >= 0)
);

alter table public.variant_supplier_stock enable row level security;
revoke all on public.variant_supplier_stock from public, anon, authenticated;
grant select, insert, update on public.variant_supplier_stock to authenticated;

create policy "staff manage variant supplier stock" on public.variant_supplier_stock
  for all to authenticated using (exists (
    select from public.product_variants as variant
    join public.products as product on product.id = variant.product_id
    where variant.id = variant_supplier_stock.variant_id and public.is_store_member(product.store_id)
  ));

insert into public.variant_supplier_stock (variant_id, quantity)
select variant.id, (snapshot_variant.value->'quantity')::integer
from public.manto_product_sources as source
join public.product_variants as variant on variant.product_id = source.product_id
cross join lateral jsonb_array_elements(source.snapshot->'variants') as snapshot_variant(value)
where variant.manto_variant_key = snapshot_variant.value->>'key'
  and case when jsonb_typeof(snapshot_variant.value->'quantity') = 'number' then
    (snapshot_variant.value->'quantity')::numeric between 0 and 2147483647
    and (snapshot_variant.value->'quantity')::numeric = trunc((snapshot_variant.value->'quantity')::numeric)
  else false end
on conflict (variant_id) do nothing;

create or replace function public.refresh_manto_stock(
  p_store_id uuid,
  p_product_id uuid,
  p_manto_product_id text,
  p_quantities jsonb,
  p_checked_at timestamptz
) returns jsonb
language plpgsql security invoker strict set search_path = '' as $$
declare
  current_snapshot jsonb;
  updated_variants jsonb;
begin
  select source.snapshot into current_snapshot
  from public.manto_product_sources as source
  where source.store_id = p_store_id and source.product_id = p_product_id
    and source.manto_product_id = p_manto_product_id
  for update;

  if not found or (current_snapshot->>'checkedAt')::timestamptz > p_checked_at then
    return current_snapshot;
  end if;

  with quantities as (
    select key, value
    from jsonb_each(p_quantities)
    where case when jsonb_typeof(value) = 'number' then
      value::numeric between 0 and 2147483647 and value::numeric = trunc(value::numeric)
    else false end
  ), updated_supplier_stock as (
    insert into public.variant_supplier_stock as saved (variant_id, quantity)
    select variant.id, quantity.value::integer
    from public.product_variants as variant
    join quantities as quantity on quantity.key = variant.manto_variant_key
    where variant.product_id = p_product_id
    on conflict (variant_id) do update set quantity = excluded.quantity
    where saved.quantity is distinct from excluded.quantity
  )
  select coalesce(jsonb_agg(
    case when quantity.value is not null then jsonb_set(variant.value, '{quantity}', quantity.value)
      else variant.value end
    order by variant.position
  ), '[]'::jsonb)
  into updated_variants
  from jsonb_array_elements(current_snapshot->'variants') with ordinality as variant(value, position)
  left join quantities as quantity on quantity.key = variant.value->>'key';

  current_snapshot := jsonb_set(
    jsonb_set(current_snapshot, '{variants}', updated_variants),
    '{checkedAt}', to_jsonb(p_checked_at)
  );
  update public.manto_product_sources
  set snapshot = current_snapshot
  where product_id = p_product_id and store_id = p_store_id and manto_product_id = p_manto_product_id;

  return current_snapshot;
end;
$$;

create or replace function public.crm_catalog_page(
  p_store_id uuid, p_page integer, p_page_size integer, p_search text default '',
  p_filter text default 'all', p_category_id uuid default null
) returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare search text := lower(btrim(coalesce(p_search, '')));
begin
  if not public.is_store_member(p_store_id) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  return (
    with matches as materialized (
      select p.id, p.created_at from public.products p
      where p.store_id = p_store_id
        and (p_category_id is null or p.category_id = p_category_id or exists (
          select from public.product_categories c where c.product_id = p.id and c.store_id = p_store_id and c.category_id = p_category_id
        ))
        and (search = '' or strpos(lower(p.name), search) > 0 or strpos(lower(p.name_uk), search) > 0
          or strpos(lower(p.name_en), search) > 0 or exists (
            select from public.product_variants v where v.product_id = p.id and strpos(lower(v.sku), search) > 0
          ))
        and (case p_filter
          when 'all' then true
          when 'published' then p.is_active
          when 'hidden' then not p.is_active
          when 'stock' then exists (select from public.product_variants v where v.product_id = p.id)
          when 'low-stock' then exists (select from public.product_variants v where v.product_id = p.id and v.stock_quantity < v.low_stock_threshold)
          when 'out-of-stock' then exists (select from public.product_variants v where v.product_id = p.id and v.stock_quantity = 0)
          else false end)
    ), totals as (select count(*) as matches from matches),
    paging as (
      select totals.matches, w.* from totals cross join lateral public.crm_page_window(totals.matches, p_page, p_page_size) w
    ), page_ids as (
      select id, created_at from matches order by created_at desc, id desc
      limit (select page_size from paging) offset (select row_offset from paging)
    )
    select jsonb_build_object('total', paging.matches, 'page', paging.page, 'rows', coalesce((
      select jsonb_agg(to_jsonb(p) || jsonb_build_object(
        'product_costs', (select to_jsonb(c) from public.product_costs c where c.product_id = p.id),
        'product_categories', coalesce((select jsonb_agg(jsonb_build_object('category_id', c.category_id))
          from public.product_categories c where c.product_id = p.id and c.store_id = p_store_id), '[]'::jsonb),
        'product_images', coalesce((select jsonb_agg(to_jsonb(i) order by i.position, i.id)
          from public.product_images i where i.product_id = p.id), '[]'::jsonb),
        'product_variants', coalesce((select jsonb_agg(to_jsonb(v) || jsonb_build_object(
          'variant_costs', (select to_jsonb(c) from public.variant_costs c where c.variant_id = v.id),
          'variant_supplier_stock', (select jsonb_build_object('quantity', s.quantity)
            from public.variant_supplier_stock s where s.variant_id = v.id)
        ) order by v.position, v.id) from public.product_variants v where v.product_id = p.id), '[]'::jsonb)
      ) order by p.created_at desc, p.id desc)
      from page_ids ids join public.products p on p.id = ids.id
    ), '[]'::jsonb)) from paging
  );
end;
$$;

notify pgrst, 'reload schema';
