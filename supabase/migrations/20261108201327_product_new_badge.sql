alter table public.products add column is_new boolean not null default false;

notify pgrst, 'reload schema';
