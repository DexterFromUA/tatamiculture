begin;

-- Customer notes and tags live on crm_customers. Stop if legacy clients have
-- added data since the audit, so it can be reconciled before removing the tables.
lock table public.customer_notes, public.customer_tag_assignments, public.customer_tags in access exclusive mode;
do $$
begin
  if exists (select from public.customer_notes)
    or exists (select from public.customer_tag_assignments)
    or exists (select from public.customer_tags) then
    raise exception 'Reconcile legacy customer notes and tags before cleanup';
  end if;
end;
$$;

drop table public.customer_tag_assignments, public.customer_tags, public.customer_notes;
drop table public.short_links;

alter table public.delivery_settings
  drop column nova_post_test_mode,
  drop column declared_value;

alter table public.stores
  drop column description,
  drop column contact_email,
  drop column contact_phone,
  drop column contact_city,
  drop column primary_color;

alter table public.product_images drop column alt;

-- Preserve the main image previously shown via the language fallback.
update public.products
set size_guide_image_url = size_guide_image_url_en
where size_guide_image_url = '' and btrim(size_guide_image_url_en) <> '';

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
    name_uk, name_en, description_uk, description_en, weight_grams,
    size_guide_en, composition_en, care_instructions_en,
    size_guide_extra_image_urls, discount_percent, stack_customer_discount
  ) values (
    source.store_id, source.category_id, source.name, source.description, false, source.position,
    source.size_guide, source.composition, source.care_instructions, source.size_guide_image_url,
    source.name_uk, source.name_en, source.description_uk, source.description_en, source.weight_grams,
    source.size_guide_en, source.composition_en, source.care_instructions_en,
    source.size_guide_extra_image_urls, source.discount_percent, source.stack_customer_discount
  )
  returning id into copy_id;

  perform public.set_catalog_product_categories(array[copy_id], array(
    select pc.category_id from public.product_categories pc
    where pc.product_id = p_product
    order by (pc.category_id = source.category_id) desc nulls last, pc.category_id
  ));

  insert into public.product_variants (product_id, name, sku, price, compare_at_price, stock_quantity, is_preorder, position, low_stock_threshold, discount_percent, stack_customer_discount)
  select copy_id, name, null, price, compare_at_price, 0, is_preorder, position, low_stock_threshold, discount_percent, stack_customer_discount
  from public.product_variants where product_id = p_product;
  insert into public.product_images (product_id, public_url, storage_path, position)
  select copy_id, public_url, storage_path, position from public.product_images where product_id = p_product;
  return copy_id;
end;
$$;

alter table public.products drop column size_guide_image_url_en;

notify pgrst, 'reload schema';

commit;
