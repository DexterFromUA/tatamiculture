alter table public.products
  add column size_guide text not null default '',
  add column composition text not null default '',
  add column care_instructions text not null default '';
