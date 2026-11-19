begin;

lock table public.products in share row exclusive mode;

alter table public.product_variants
  add column allow_out_of_stock boolean not null default false;

-- Preserve any existing opt-ins when moving the setting from the product to its sizes.
update public.product_variants v
set allow_out_of_stock = true
from public.products p
where p.id = v.product_id and p.allow_out_of_stock;

create or replace function public.quote_catalog_cart(
  p_store_id uuid, p_items jsonb, p_customer_percent numeric, p_lock_stock boolean
) returns table(items jsonb, total integer, personal_savings integer)
language plpgsql set search_path = '' as $$
begin
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Cart is empty';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items) as item("variantId" uuid, quantity integer)
    where item."variantId" is null or item.quantity is null or item.quantity not between 1 and 20
  ) then
    raise exception 'Invalid cart item';
  end if;

  if p_lock_stock then
    perform v.id
    from public.product_variants v join public.products p on p.id = v.product_id
    where p.store_id = p_store_id and p.is_active and v.id in (
      select item."variantId" from jsonb_to_recordset(p_items) as item("variantId" uuid)
    )
    order by v.id for update of v;
  end if;

  return query
  with requested as (
    select item."variantId" as variant_id, sum(item.quantity)::integer as quantity
    from jsonb_to_recordset(p_items) as item("variantId" uuid, quantity integer)
    group by item."variantId"
  ), offers as (
    select p.id as product_id, v.id as variant_id, p.name as product_name, v.name as variant_name,
      r.quantity, v.is_preorder, v.price as stored_price,
      v.allow_out_of_stock,
      v.stock_quantity >= r.quantity as stock_deducted,
      greatest(v.price, v.compare_at_price) as regular_price,
      coalesce(v.discount_percent, p.discount_percent) as catalog_percent,
      case when v.discount_percent is null then p.stack_customer_discount
        else v.stack_customer_discount end as allows_stacking
    from requested r
    join public.product_variants v on v.id = r.variant_id
    join public.products p on p.id = v.product_id
    where p.store_id = p_store_id and p.is_active
      and r.quantity <= 20
      and (v.stock_quantity >= r.quantity
        or (v.stock_quantity = 0 and v.allow_out_of_stock))
  ), catalog_prices as (
    select offers.*, case when catalog_percent is null then stored_price
      else round(regular_price * (1 - catalog_percent / 100))::integer end as catalog_price
    from offers
  ), final_prices as (
    select catalog_prices.*, case
      when allows_stacking or (coalesce(catalog_percent, 0) = 0 and catalog_price = regular_price)
        then round(catalog_price * (1 - coalesce(p_customer_percent, 0) / 100))::integer
      else catalog_price end as unit_price
    from catalog_prices
  ), lines as (
    select product_id, variant_id, product_name, variant_name, quantity, is_preorder, allow_out_of_stock, stock_deducted, unit_price,
      case when regular_price > unit_price then regular_price end as compare_at_price,
      unit_price * quantity as line_total,
      (catalog_price - unit_price) * quantity as customer_savings
    from final_prices
  )
  select jsonb_agg(to_jsonb(lines) - 'customer_savings' order by variant_id),
    sum(line_total)::integer, sum(customer_savings)::integer
  from lines
  having count(*) = (select count(*) from requested);
  if not found then
    raise sqlstate 'PT409' using message = 'A product is no longer available in the requested quantity.';
  end if;
end;
$$;

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

  insert into public.product_variants (product_id, name, sku, price, compare_at_price, stock_quantity, is_preorder, position, low_stock_threshold, discount_percent, stack_customer_discount, allow_out_of_stock)
  select copy_id, name, null, price, compare_at_price, 0, is_preorder, position, low_stock_threshold, discount_percent, stack_customer_discount, allow_out_of_stock
  from public.product_variants where product_id = p_product;
  insert into public.product_images (product_id, public_url, storage_path, position)
  select copy_id, public_url, storage_path, position from public.product_images where product_id = p_product;
  return copy_id;
end;
$$;

alter table public.products drop column allow_out_of_stock;

notify pgrst, 'reload schema';

commit;
