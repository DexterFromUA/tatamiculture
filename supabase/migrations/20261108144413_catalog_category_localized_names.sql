-- Keep the original name as the fallback for categories created before localization.
alter table public.categories
  add column name_uk text check (char_length(btrim(name_uk)) between 1 and 100),
  add column name_en text check (char_length(btrim(name_en)) between 1 and 100);

-- Check the names visitors actually see, including the fallback language.
create unique index categories_unique_sibling_name_uk
  on public.categories (store_id, parent_id, lower(btrim(coalesce(name_uk, name_en, name)))) nulls not distinct;
create unique index categories_unique_sibling_name_en
  on public.categories (store_id, parent_id, lower(btrim(coalesce(name_en, name_uk, name)))) nulls not distinct;

notify pgrst, 'reload schema';
