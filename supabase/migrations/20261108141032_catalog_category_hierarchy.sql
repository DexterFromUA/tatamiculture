alter table public.categories
  add column parent_id uuid,
  add unique (id, store_id),
  add constraint categories_parent_same_store
    foreign key (parent_id, store_id) references public.categories (id, store_id) on delete restrict;

create unique index categories_unique_sibling_name
  on public.categories (store_id, parent_id, lower(btrim(name))) nulls not distinct;

create function public.check_category_parent()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    if new.parent_id is distinct from old.parent_id then
      raise exception 'Category parent cannot be changed' using errcode = '23514';
    end if;
  end if;
  if new.parent_id is not null and not exists (
    select 1 from public.categories
    where id = new.parent_id and store_id = new.store_id and parent_id is null
  ) then
    raise exception 'Choose a main category from this store' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger check_category_parent before insert or update of parent_id, store_id on public.categories
  for each row execute function public.check_category_parent();

alter table public.products add unique (id, store_id);

-- A separate primary key preserves the existing direct products -> categories
-- relationship for earlier storefronts and the primary category in reports.
create table public.product_categories (
  id bigint generated always as identity primary key,
  store_id uuid not null,
  product_id uuid not null,
  category_id uuid not null,
  unique (product_id, category_id),
  foreign key (product_id, store_id) references public.products (id, store_id) on delete cascade,
  foreign key (category_id, store_id) references public.categories (id, store_id) on delete restrict
);
create index product_categories_by_category on public.product_categories (category_id, store_id);
alter table public.product_categories enable row level security;
revoke all on public.product_categories from public, anon, authenticated;
grant select on public.product_categories to anon, authenticated;

create policy "read categories of visible products"
on public.product_categories for select to anon, authenticated
using (exists (
  select 1 from public.products p
  where p.id = product_categories.product_id and p.store_id = product_categories.store_id
));

insert into public.product_categories (store_id, product_id, category_id)
select store_id, id, category_id from public.products where category_id is not null;

-- A legacy write replaces its previous primary category and its subcategories.
create function public.sync_primary_product_category()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    if new.category_id is not distinct from old.category_id then return new; end if;
    delete from public.product_categories pc using public.categories c
    where pc.product_id = new.id and pc.category_id = c.id
      and (c.id = old.category_id or c.parent_id = old.category_id);
  end if;

  if new.category_id is not null then
    insert into public.product_categories (store_id, product_id, category_id)
    select new.store_id, new.id, selected.id
    from public.categories c
    cross join lateral (values (c.id), (c.parent_id)) as selected(id)
    where c.id = new.category_id and c.store_id = new.store_id and selected.id is not null
    on conflict (product_id, category_id) do nothing;
    if not found and not exists (
      select 1 from public.categories where id = new.category_id and store_id = new.store_id
    ) then
      raise exception 'Choose categories from this store' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.sync_primary_product_category() from public, anon, authenticated;

create trigger sync_primary_product_category after insert or update of category_id on public.products
  for each row execute function public.sync_primary_product_category();

create function public.set_catalog_product_categories(p_products uuid[], p_categories uuid[])
returns void language plpgsql security definer set search_path = '' as $$
declare
  shop uuid;
  primary_category uuid;
begin
  if auth.uid() is null or coalesce(cardinality(p_products), 0) = 0
    or array_position(p_products, null) is not null
    or p_categories is null or array_position(p_categories, null) is not null then
    raise exception 'Invalid product or category selection' using errcode = '22023';
  end if;

  select p.store_id into shop from public.products p where p.id = p_products[1];
  if shop is null or not public.is_store_member(shop) then
    raise exception 'Manager access required' using errcode = '42501';
  end if;

  perform 1 from public.products p
  where p.id = any(p_products) and p.store_id = shop order by p.id for update;
  if exists (
    select 1 from unnest(p_products) as requested(id)
    where not exists (select 1 from public.products p where p.id = requested.id and p.store_id = shop)
  ) then
    raise exception 'Choose products from this store' using errcode = '42501';
  end if;

  if exists (
    select 1 from unnest(p_categories) as requested(id)
    left join public.categories c on c.id = requested.id and c.store_id = shop
    where c.id is null or (c.parent_id is not null and not (c.parent_id = any(p_categories)))
  ) then
    raise exception 'Select a main category before its subcategories' using errcode = '23514';
  end if;

  select c.id into primary_category
  from unnest(p_categories) with ordinality as requested(id, position)
  join public.categories c on c.id = requested.id and c.store_id = shop
  where c.parent_id is null order by requested.position limit 1;

  update public.products set category_id = primary_category
  where id = any(p_products) and store_id = shop and category_id is distinct from primary_category;

  delete from public.product_categories
  where product_id = any(p_products) and store_id = shop and not (category_id = any(p_categories));

  insert into public.product_categories (store_id, product_id, category_id)
  select distinct shop, p.id, c.id
  from unnest(p_products) as p(id) cross join unnest(p_categories) as c(id)
  on conflict (product_id, category_id) do nothing;
end;
$$;

revoke all on function public.set_catalog_product_categories(uuid[], uuid[]) from public, anon, authenticated;
grant execute on function public.set_catalog_product_categories(uuid[], uuid[]) to authenticated;

create or replace function public.duplicate_catalog_product(p_product uuid)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  source public.products;
  copy_id uuid;
begin
  select * into source from public.products where id = p_product;
  if not found or not coalesce(public.is_store_member(source.store_id), false) then
    raise exception 'Manager access required';
  end if;

  insert into public.products (store_id, category_id, name, description, is_active, position, size_guide, composition, care_instructions)
  values (source.store_id, source.category_id, source.name, source.description, false, source.position, source.size_guide, source.composition, source.care_instructions)
  returning id into copy_id;

  perform public.set_catalog_product_categories(array[copy_id], array(
    select pc.category_id from public.product_categories pc
    where pc.product_id = p_product
    order by (pc.category_id = source.category_id) desc nulls last, pc.category_id
  ));

  insert into public.product_variants (product_id, name, sku, price, compare_at_price, stock_quantity, is_preorder, position, low_stock_threshold)
  select copy_id, name, null, price, compare_at_price, 0, is_preorder, position, low_stock_threshold
  from public.product_variants where product_id = p_product;
  insert into public.product_images (product_id, public_url, storage_path, position)
  select copy_id, public_url, storage_path, position from public.product_images where product_id = p_product;
  return copy_id;
end;
$$;

notify pgrst, 'reload schema';
