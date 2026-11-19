begin;

create index crm_customers_store_page_idx on public.crm_customers (store_id, created_at desc, id);
create index products_store_page_idx on public.products (store_id, created_at desc, id desc);

-- The count and rows use the same snapshot. Clamp after deletes or filter changes.
create function public.crm_page_window(p_count bigint, p_page integer, p_page_size integer)
returns table (page integer, page_size integer, row_offset bigint)
language sql immutable set search_path = ''
as $$
  with bounds as (
    select least(500, greatest(1, coalesce(p_page_size, 50))) as size,
      greatest(1, coalesce(p_page, 1)) as requested
  ), page_bounds as (
    select least(requested, greatest(1, (p_count + size - 1) / size))::integer as page, size
    from bounds
  )
  select page, size, (page::bigint - 1) * size from page_bounds;
$$;

create function public.crm_orders_page(
  p_store_id uuid, p_page integer, p_page_size integer, p_search text default '',
  p_status text default 'ALL', p_from date default null, p_to date default null,
  p_order_ids uuid[] default null, p_customer_id uuid default null
) returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  search text := lower(btrim(coalesce(p_search, '')));
  order_search text := regexp_replace(search, '^#', '');
  phone_search text := case when search ~ '^[+0-9[:space:]().-]+$'
    then regexp_replace(search, '[^0-9]', '', 'g') else '' end;
begin
  if not public.is_store_member(p_store_id) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  return (
    with matches as materialized (
      select o.id, o.created_at
      from public.orders o
      left join public.order_merge_members membership on membership.order_id = o.id
      cross join lateral (select regexp_replace(o.customer_phone, '[^0-9]', '', 'g') as digits) phone
      where o.store_id = p_store_id
        and (membership.root_id is null or membership.root_id = o.id)
        and (p_status = 'ALL' or (p_status = 'NO_TTN' and coalesce(btrim(o.nova_poshta_ttn), '') = '') or o.status::text = p_status)
        and (p_from is null or o.created_at >= (p_from::timestamp at time zone 'Europe/Kyiv'))
        and (p_to is null or o.created_at < ((p_to + 1)::timestamp at time zone 'Europe/Kyiv'))
        and (p_order_ids is null or o.id = any(p_order_ids) or exists (
          select from public.order_merge_members m where m.root_id = o.id and m.order_id = any(p_order_ids)
        ))
        and (p_customer_id is null or o.crm_customer_id = p_customer_id or exists (
          select from public.order_merge_members m join public.orders child on child.id = m.order_id
          where m.root_id = o.id and child.store_id = p_store_id and child.crm_customer_id = p_customer_id
        ))
        and (search = '' or strpos(lower(o.customer_name), search) > 0
          or (phone_search <> '' and (strpos(phone.digits, phone_search) > 0 or (
            length(phone_search) between 9 and 12 and length(phone.digits) >= 9
            and right(phone.digits, 9) = right(phone_search, 9)
          )))
          or (order_search <> '' and (strpos(lower(o.receipt_code), order_search) > 0
            or strpos(lower(o.nova_poshta_ttn), order_search) > 0 or exists (
              select from public.order_merge_members m join public.orders child on child.id = m.order_id
              where m.root_id = o.id and child.store_id = p_store_id
                and (strpos(lower(child.receipt_code), order_search) > 0 or strpos(lower(child.nova_poshta_ttn), order_search) > 0)
            ))))
    ), totals as (select count(*) as matches from matches),
    paging as (
      select totals.matches, w.* from totals cross join lateral public.crm_page_window(totals.matches, p_page, p_page_size) w
    ), page_ids as (
      select id, created_at from matches order by created_at desc, id desc
      limit (select page_size from paging) offset (select row_offset from paging)
    )
    select jsonb_build_object('total', paging.matches, 'page', paging.page, 'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', o.id, 'user_id', o.user_id, 'crm_customer_id', o.crm_customer_id,
        'customer_discount_amount', o.customer_discount_amount, 'receipt_code', o.receipt_code,
        'customer_name', o.customer_name, 'customer_email', o.customer_email, 'customer_phone', o.customer_phone,
        'note', o.note, 'payment_test_mode', o.payment_test_mode, 'status', o.status, 'payment_status', o.payment_status,
        'total_price', coalesce(members.total, o.total_price), 'currency', o.currency, 'created_at', o.created_at,
        'nova_poshta_ttn', o.nova_poshta_ttn, 'nova_poshta_document_ref', o.nova_poshta_document_ref,
        'nova_poshta_status', o.nova_poshta_status, 'nova_poshta_status_code', o.nova_poshta_status_code,
        'payment_method', o.payment_method, 'delivery_city_ref', o.delivery_city_ref, 'delivery_address_ref', o.delivery_address_ref,
        'member_ids', coalesce(members.ids, array[o.id])
      ) order by o.created_at desc, o.id desc)
      from page_ids p join public.orders o on o.id = p.id
      cross join lateral (
        select array_agg(child.id order by child.id) as ids, sum(child.total_price) as total
        from public.order_merge_members m join public.orders child on child.id = m.order_id
        where m.root_id = o.id and child.store_id = p_store_id
      ) members
    ), '[]'::jsonb)) from paging
  );
end;
$$;

create function public.crm_customers_page(
  p_store_id uuid, p_page integer, p_page_size integer, p_search text default '', p_filter text default 'all'
) returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  search text := lower(btrim(coalesce(p_search, '')));
  order_search text := regexp_replace(search, '^#[[:space:]]*', '');
begin
  if not public.is_store_member(p_store_id) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  return (
    with customers as materialized (
      select c.*, regexp_replace(c.phone, '[^0-9]', '', 'g') as digits
      from public.list_crm_customers(p_store_id) c
    ), duplicates as (
      select case when digits ~ '^0[0-9]{9}$' then '38' || digits else digits end as phone
      from customers where p_filter = 'duplicates' and length(digits) >= 9
      group by 1 having count(*) > 1
    ), matches as materialized (
      select c.id, c.created_at from customers c
      where (case p_filter
        when 'all' then true
        when 'confirmed-phone' then c.phone_confirmed
        when 'unconfirmed-phone' then not c.phone_confirmed
        when 'administrators' then c.is_administrator
        when 'discount' then c.has_active_discount
        when 'duplicates' then exists (
          select from duplicates d where d.phone = case when c.digits ~ '^0[0-9]{9}$' then '38' || c.digits else c.digits end
        )
        else false end)
        and (search = '' or strpos(lower(concat_ws(' ', c.name, c.phone, c.email, array_to_string(c.tags, ' '))), search) > 0
          or strpos(lower(c.notes), search) > 0 or (order_search <> '' and exists (
            select from public.orders o where o.store_id = p_store_id and o.crm_customer_id = c.id
              and strpos(lower(o.receipt_code), order_search) > 0
          )))
    ), totals as (select count(*) as matches from matches),
    paging as (
      select totals.matches, w.* from totals cross join lateral public.crm_page_window(totals.matches, p_page, p_page_size) w
    ), page_ids as (
      select id, created_at from matches order by created_at desc, id asc
      limit (select page_size from paging) offset (select row_offset from paging)
    )
    select jsonb_build_object('total', paging.matches, 'page', paging.page, 'rows', coalesce((
      select jsonb_agg((to_jsonb(c) - 'digits') || jsonb_build_object(
        'order_count', coalesce(stats.order_count, 0), 'totals', coalesce(stats.totals, '{}'::jsonb)
      ) order by c.created_at desc, c.id asc)
      from page_ids p join customers c on c.id = p.id
      cross join lateral (
        select sum(grouped.units) as order_count, jsonb_object_agg(grouped.currency, grouped.amount) as totals
        from (
          select o.currency, count(*) as units, sum(o.total_price) as amount
          from public.orders o where o.store_id = p_store_id and o.crm_customer_id = c.id
            and o.status not in ('CANCELLED_BY_USER', 'CANCELLED_BY_STORE')
          group by o.currency
        ) grouped
      ) stats
    ), '[]'::jsonb)) from paging
  );
end;
$$;

create function public.crm_catalog_page(
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
          'variant_costs', (select to_jsonb(c) from public.variant_costs c where c.variant_id = v.id)
        ) order by v.position, v.id) from public.product_variants v where v.product_id = p.id), '[]'::jsonb)
      ) order by p.created_at desc, p.id desc)
      from page_ids ids join public.products p on p.id = ids.id
    ), '[]'::jsonb)) from paging
  );
end;
$$;

create function public.crm_catalog_category_counts(p_store_id uuid)
returns table (category_id uuid, product_count bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_store_member(p_store_id) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  return query
    select assigned.category_id, count(*)
    from (
      select p.category_id, p.id as product_id from public.products p
      where p.store_id = p_store_id and p.category_id is not null
      union
      select c.category_id, c.product_id from public.product_categories c where c.store_id = p_store_id
    ) assigned
    group by assigned.category_id;
end;
$$;

revoke all on function public.crm_page_window(bigint, integer, integer)
  from public, anon, authenticated, service_role;
revoke all on function public.crm_orders_page(uuid, integer, integer, text, text, date, date, uuid[], uuid),
  public.crm_customers_page(uuid, integer, integer, text, text),
  public.crm_catalog_page(uuid, integer, integer, text, text, uuid),
  public.crm_catalog_category_counts(uuid) from public, anon, authenticated, service_role;
grant execute on function public.crm_orders_page(uuid, integer, integer, text, text, date, date, uuid[], uuid),
  public.crm_customers_page(uuid, integer, integer, text, text),
  public.crm_catalog_page(uuid, integer, integer, text, text, uuid),
  public.crm_catalog_category_counts(uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
