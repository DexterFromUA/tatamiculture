-- Exercise real RPCs with more than two pages, by staff and as an outsider.
begin;

do $$
declare
  staff uuid := gen_random_uuid();
  shop uuid := gen_random_uuid();
  category uuid := gen_random_uuid();
  root_order public.orders;
  child_order public.orders;
  flagged_product uuid;
  result jsonb;
  first_page jsonb;
  second_page jsonb;
begin
  insert into auth.users(id) values (staff);
  insert into public.stores(id, slug, name) values (shop, 'pagination-test-' || shop, 'Pagination test');
  insert into public.store_members(store_id, user_id, role) values (shop, staff, 'OWNER');
  insert into public.categories(id, store_id, name, slug) values (category, shop, 'Test category', 'page-category');

  insert into public.orders(store_id, customer_name, customer_email, customer_phone, delivery_city, delivery_address, total_price, currency)
    select shop, 'Customer ' || n, '', '+38099100' || lpad(n::text, 4, '0'), 'City', 'Branch', n, 'UAH'
    from generate_series(1, 101) as n;
  insert into public.products(store_id, name)
    select shop, 'Product ' || n from generate_series(1, 101) as n;
  select * into strict root_order from public.orders where store_id = shop and customer_name = 'Customer 1';
  select * into strict child_order from public.orders where store_id = shop and customer_name = 'Customer 2';
  select id into strict flagged_product from public.products where store_id = shop and name = 'Product 101';
  update public.crm_customers set notes = 'Приватна нотатка для перевірки', phone = root_order.customer_phone where id = child_order.crm_customer_id;
  update public.products set category_id = category, is_active = false where id = flagged_product;
  insert into public.product_categories(store_id, product_id, category_id) values (shop, flagged_product, category) on conflict do nothing;
  insert into public.product_variants(product_id, name, sku, price, stock_quantity) values (flagged_product, 'M', 'PAGINATION-SKU', 500, 0);

  perform set_config('request.jwt.claim.sub', staff::text, true);
  set local role authenticated;
  first_page := public.crm_orders_page(shop, 1, 50);
  second_page := public.crm_orders_page(shop, 2, 50);
  if (first_page->>'total')::integer <> 101 or jsonb_array_length(first_page->'rows') <> 50
     or (second_page->>'page')::integer <> 2 or jsonb_array_length(second_page->'rows') <> 50
     or exists (select from jsonb_array_elements(first_page->'rows') a
       join jsonb_array_elements(second_page->'rows') b on a->>'id' = b->>'id') then
    raise exception 'Orders page boundaries or ordering are incorrect';
  end if;

  foreach result in array array[
    public.crm_orders_page(shop, 99, 50),
    public.crm_customers_page(shop, 99, 50),
    public.crm_catalog_page(shop, 99, 50)
  ] loop
    if (result->>'total')::integer <> 101 or (result->>'page')::integer <> 3
       or jsonb_array_length(result->'rows') <> 1 then
      raise exception 'Filtered count or last-page clamping is incorrect';
    end if;
  end loop;

  result := public.crm_customers_page(shop, 1, 50, 'нотатка', 'duplicates');
  if (result->>'total')::integer <> 1 or result#>>'{rows,0,id}' <> child_order.crm_customer_id::text
     or (result#>>'{rows,0,order_count}')::integer <> 1 or (result#>>'{rows,0,totals,UAH}')::integer <> 2 then
    raise exception 'Customer search, duplicate filter or order totals are incorrect';
  end if;
  if (public.crm_customers_page(shop, 1, 50, '#' || child_order.receipt_code)->>'total')::integer <> 1 then
    raise exception 'Searching customers by receipt lost the related customer';
  end if;

  result := public.crm_catalog_page(shop, 1, 50, 'PAGINATION-SKU', 'out-of-stock', category);
  if (result->>'total')::integer <> 1 or result#>>'{rows,0,id}' <> flagged_product::text
     or jsonb_array_length(result#>'{rows,0,product_variants}') <> 1
     or (select product_count from public.crm_catalog_category_counts(shop) where category_id = category) <> 1 then
    raise exception 'Catalog search, filtered variants or category counts are incorrect';
  end if;

  reset role;
  insert into public.order_merge_members(order_id, root_id) values (root_order.id, root_order.id), (child_order.id, root_order.id);
  set local role authenticated;
  result := public.crm_orders_page(shop, 1, 50, '#' || child_order.receipt_code, p_customer_id => child_order.crm_customer_id);
  if (result->>'total')::integer <> 1 or result#>>'{rows,0,id}' <> root_order.id::text
     or jsonb_array_length(result#>'{rows,0,member_ids}') <> 2 or (result#>>'{rows,0,total_price}')::integer <> 3 then
    raise exception 'Merged orders were split or child-order search lost the group';
  end if;

  perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000000', true);
  begin
    perform public.crm_customers_page(shop, 1, 50);
    raise exception 'Non-staff could read CRM customers';
  exception when insufficient_privilege then null;
  end;
end;
$$;
rollback;

select 'CRM pagination checks passed' as result;
