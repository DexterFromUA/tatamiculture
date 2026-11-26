create table public.manto_product_sources (
  product_id uuid primary key,
  store_id uuid not null,
  manto_product_id text not null check (manto_product_id ~ '^[1-9][0-9]{0,11}$'),
  snapshot jsonb not null check (
    jsonb_typeof(snapshot) = 'object' and jsonb_typeof(snapshot->'variants') is not distinct from 'array'
  ),
  unique (store_id, manto_product_id),
  foreign key (product_id, store_id) references public.products (id, store_id) on delete cascade
);

alter table public.manto_product_sources enable row level security;
revoke all on public.manto_product_sources from public, anon, authenticated;
grant select, insert, update (snapshot) on public.manto_product_sources to authenticated;

create policy manto_product_sources_select on public.manto_product_sources for select to authenticated
  using (public.is_store_member(store_id));
create policy manto_product_sources_insert on public.manto_product_sources for insert to authenticated
  with check (public.is_store_member(store_id));
create policy manto_product_sources_update on public.manto_product_sources for update to authenticated
  using (public.is_store_member(store_id)) with check (public.is_store_member(store_id));

create trigger manto_product_sources_audit
  after insert or update or delete on public.manto_product_sources
  for each row execute function public.capture_crm_audit_change('catalog');

alter table public.product_variants
  add column manto_variant_key text check (manto_variant_key ~ '^(ean:[0-9]{8,14}|id:[a-zA-Z0-9_.-]{1,40})$');

create unique index product_variants_manto_key_idx on public.product_variants (product_id, manto_variant_key)
  where manto_variant_key is not null;

create function public.reserve_manto_product(
  p_store_id uuid, p_product_id uuid, p_manto_product_id text, p_name text, p_snapshot jsonb
) returns void
language plpgsql security invoker set search_path = '' as $$
begin
  if not public.is_store_member(p_store_id) then
    raise insufficient_privilege;
  end if;
  insert into public.products (id, store_id, name, is_active)
    values (p_product_id, p_store_id, p_name, false)
    on conflict (id) do nothing;

  insert into public.manto_product_sources (product_id, store_id, manto_product_id, snapshot)
    values (p_product_id, p_store_id, p_manto_product_id, p_snapshot)
    on conflict (product_id) do nothing;

  if not exists (
    select from public.manto_product_sources
    where product_id = p_product_id and store_id = p_store_id and manto_product_id = p_manto_product_id
  ) then
    raise unique_violation using message = 'This Manto product is already in the catalogue.';
  end if;
end;
$$;

revoke all on function public.reserve_manto_product(uuid, uuid, text, text, jsonb) from public, anon;
grant execute on function public.reserve_manto_product(uuid, uuid, text, text, jsonb) to authenticated;

notify pgrst, 'reload schema';
