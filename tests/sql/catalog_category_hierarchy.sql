-- Run after applying catalog_category_localized_names. The fixtures are rolled back.
begin;
do $$
declare
  staff uuid := gen_random_uuid();
  shop uuid;
  other_shop uuid;
  root_a uuid := gen_random_uuid();
  root_b uuid := gen_random_uuid();
  leaf_a uuid := gen_random_uuid();
  foreign_root uuid := gen_random_uuid();
  item uuid := gen_random_uuid();
  other_item uuid := gen_random_uuid();
  copied_item uuid;
begin
  if exists (
    select 1 from public.products p where p.category_id is not null
    and not exists (
      select 1 from public.product_categories pc
      where pc.product_id = p.id and pc.category_id = p.category_id
    )
  ) then raise exception 'Existing primary categories were not preserved'; end if;

  insert into auth.users (id, email) values (staff, staff || '@example.invalid');
  insert into public.stores (slug, name, contact_email, contact_phone, contact_city)
  values ('category-test-' || staff, 'Category test', '', '', '') returning id into shop;
  insert into public.stores (slug, name, contact_email, contact_phone, contact_city)
  values ('other-category-test-' || staff, 'Other category test', '', '', '') returning id into other_shop;
  insert into public.store_members (store_id, user_id, role) values (shop, staff, 'MANAGER');
  insert into public.categories (id, store_id, name, slug) values (foreign_root, other_shop, 'Foreign', 'foreign');
  insert into public.products (id, store_id, name) values (other_item, other_shop, 'Foreign product');

  perform set_config('request.jwt.claim.sub', staff::text, true);
  execute 'set local role authenticated';
  insert into public.categories (id, store_id, name, slug, parent_id) values
    (root_a, shop, 'Gear', 'gear', null), (root_b, shop, 'Training', 'training', null);
  insert into public.categories (id, store_id, name, slug, parent_id)
  values (leaf_a, shop, 'Gloves', 'gloves', root_a);

  begin
    insert into public.categories (store_id, name, slug, parent_id) values (shop, 'Nested', 'nested', leaf_a);
    raise exception 'Third category level accepted';
  exception when check_violation then null;
  end;
  begin
    insert into public.categories (store_id, name, slug, parent_id) values (shop, 'Foreign child', 'foreign-child', foreign_root);
    raise exception 'Foreign category parent accepted';
  exception when check_violation then null;
  end;
  begin
    insert into public.categories (store_id, name, slug, parent_id) values (shop, ' gloves ', 'same-name', root_a);
    raise exception 'Duplicate sibling name accepted';
  exception when unique_violation then null;
  end;

  update public.categories set name_uk = 'Екіпірування', name_en = 'Gear' where id = root_a;
  update public.categories set name_uk = 'Рукавички', name_en = 'Gloves' where id = leaf_a;
  begin
    insert into public.categories (store_id, name, name_uk, name_en, slug, parent_id)
    values (shop, 'Інші рукавички', 'Інші рукавички', ' gloves ', 'localized-duplicate', root_a);
    raise exception 'Duplicate English sibling name accepted';
  exception when unique_violation then null;
  end;
  begin
    insert into public.categories (store_id, name, name_en, slug, parent_id)
    values (shop, 'Рукавички', 'Рукавички', 'fallback-duplicate', root_a);
    raise exception 'Duplicate Ukrainian fallback accepted';
  exception when unique_violation then null;
  end;
  insert into public.categories (store_id, name, name_uk, name_en, slug, parent_id)
  values (shop, 'Рукавички', 'Рукавички', 'Gloves', 'other-branch-gloves', root_b);

  insert into public.products (id, store_id, name, category_id) values (item, shop, 'Test product', root_a);
  if not exists (select 1 from public.product_categories where product_id = item and category_id = root_a) then
    raise exception 'Legacy product insert did not assign the category';
  end if;

  begin
    perform public.set_catalog_product_categories(array[item], array[leaf_a]);
    raise exception 'Subcategory assigned without its parent';
  exception when check_violation then null;
  end;
  begin
    perform public.set_catalog_product_categories(array[item], array[foreign_root]);
    raise exception 'Foreign category assigned to product';
  exception when check_violation then null;
  end;
  begin
    perform public.set_catalog_product_categories(array[item, other_item], array[root_a]);
    raise exception 'Mixed-store bulk assignment accepted';
  exception when insufficient_privilege then null;
  end;

  perform public.set_catalog_product_categories(array[item], array[root_b, root_a, leaf_a, leaf_a]);
  if (select count(*) from public.product_categories where product_id = item) <> 3
    or (select category_id from public.products where id = item) is distinct from root_b then
    raise exception 'Multiple category assignments were not saved correctly';
  end if;
  copied_item := public.duplicate_catalog_product(item);
  if (select count(*) from public.product_categories where product_id = copied_item) <> 3 then
    raise exception 'Product duplicate lost categories';
  end if;

  begin
    delete from public.categories where id = leaf_a;
    raise exception 'Assigned subcategory deleted';
  exception when foreign_key_violation then null;
  end;
  begin
    delete from public.categories where id = root_a;
    raise exception 'Parent with subcategories deleted';
  exception when foreign_key_violation then null;
  end;

  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  execute 'set local role anon';
  if (select count(*) from public.product_categories where product_id = item) <> 3
    or exists (select 1 from public.product_categories where product_id = copied_item) then
    raise exception 'Category visibility does not match the visibility of its product';
  end if;
  if not exists (
    select 1 from public.product_categories pc join public.categories c on c.id = pc.category_id
    where pc.product_id = item and c.id = leaf_a and c.name_uk = 'Рукавички' and c.name_en = 'Gloves'
  ) or not exists (
    select 1 from public.categories where id = root_b and name = 'Training' and name_uk is null and name_en is null
  ) then
    raise exception 'Translated or legacy category names are not readable';
  end if;
  execute 'reset role';

  perform set_config('request.jwt.claim.sub', staff::text, true);
  execute 'set local role authenticated';
  perform public.set_catalog_product_categories(array[item, copied_item], array[]::uuid[]);
  if exists (select 1 from public.product_categories where product_id in (item, copied_item))
    or exists (select 1 from public.products where id in (item, copied_item) and category_id is not null) then
    raise exception 'Clearing categories left an assignment behind';
  end if;
  execute 'reset role';
end;
$$;
select 'Category hierarchy, localization, assignments and permissions passed' as result;
rollback;
