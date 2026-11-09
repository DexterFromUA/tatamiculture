alter table public.products add column weight_grams integer check (weight_grams > 0);
alter table public.order_items add column weight_grams integer check (weight_grams > 0);

create function public.snapshot_order_item_weight()
returns trigger language plpgsql set search_path = '' as $$
begin
  select p.weight_grams into new.weight_grams
  from public.products p where p.id = new.product_id;
  return new;
end;
$$;

create trigger snapshot_order_item_weight before insert on public.order_items
for each row execute function public.snapshot_order_item_weight();

create function public.nova_poshta_order_weight_grams(p_order_id uuid)
returns bigint language sql stable set search_path = '' as $$
  select case when count(*) = count(item.weight)
    then sum(item.weight::bigint * item.quantity)::bigint end
  from (
    select coalesce(oi.weight_grams, p.weight_grams) as weight, oi.quantity
    from public.order_items oi
    left join public.products p on p.id = oi.product_id
    where oi.order_id = p_order_id
  ) item;
$$;

revoke all on function public.nova_poshta_order_weight_grams(uuid) from public, anon, authenticated;
grant execute on function public.nova_poshta_order_weight_grams(uuid) to service_role;

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

  insert into public.products (
    store_id, category_id, name, description, is_active, position,
    size_guide, composition, care_instructions, size_guide_image_url,
    name_uk, name_en, description_uk, description_en, weight_grams
  ) values (
    source.store_id, source.category_id, source.name, source.description, false, source.position,
    source.size_guide, source.composition, source.care_instructions, source.size_guide_image_url,
    source.name_uk, source.name_en, source.description_uk, source.description_en, source.weight_grams
  )
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
