alter table public.product_variants
  add column low_stock_threshold integer not null default 3 check (low_stock_threshold >= 0);

create table public.stock_movements (
  id bigint generated always as identity primary key,
  store_id uuid not null references public.stores(id) on delete cascade,
  variant_id uuid not null,
  previous_quantity integer not null,
  quantity integer not null,
  kind text not null,
  reason text,
  author_id uuid,
  created_at timestamptz not null default now()
);
create index stock_movements_variant_history on public.stock_movements(variant_id, id desc);
alter table public.stock_movements enable row level security;
create policy "staff read stock movements" on public.stock_movements for select to authenticated
  using (public.is_store_member(store_id));
grant select on public.stock_movements to authenticated;

create function public.capture_stock_movement() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.stock_movements(store_id, variant_id, previous_quantity, quantity, kind, reason, author_id)
  select p.store_id, new.id, old.stock_quantity, new.stock_quantity,
    coalesce(nullif(current_setting('tatami.stock_kind', true), ''), 'automatic'),
    nullif(current_setting('tatami.stock_reason', true), ''), auth.uid()
  from public.products p where p.id = new.product_id;
  return new;
end;
$$;

create trigger capture_stock_movement after update of stock_quantity on public.product_variants
for each row when (old.stock_quantity is distinct from new.stock_quantity)
execute function public.capture_stock_movement();

create table public.stock_adjustment_requests (
 id uuid primary key, variant_id uuid not null references public.product_variants(id),
 kind text not null, quantity integer not null, reason text not null
);
alter table public.stock_adjustment_requests enable row level security;
create policy "staff manage stock requests" on public.stock_adjustment_requests for all to authenticated
 using(exists(select 1 from public.product_variants v join public.products p on p.id=v.product_id where v.id=variant_id and public.is_store_member(p.store_id)))
 with check(exists(select 1 from public.product_variants v join public.products p on p.id=v.product_id where v.id=variant_id and public.is_store_member(p.store_id)));
grant select,insert on public.stock_adjustment_requests to authenticated;

create function public.adjust_catalog_stock(p_variant uuid, p_kind text, p_quantity integer, p_reason text, p_request uuid default null)
returns void language plpgsql security invoker set search_path = '' as $$
declare
  target_store uuid;
begin
  select p.store_id into target_store from public.product_variants v
    join public.products p on p.id = v.product_id where v.id = p_variant;
  if target_store is null or not coalesce(public.is_store_member(target_store), false) then
    raise exception 'Manager access required';
  end if;
  if p_kind is null or p_kind not in ('receipt', 'writeoff', 'correction')
      or p_quantity is null or p_quantity < 0 or (p_kind <> 'correction' and p_quantity = 0)
      or coalesce(length(trim(p_reason)), 0) not between 1 and 500 then
    raise exception 'Invalid stock operation';
  end if;
  if p_request is not null then
    insert into public.stock_adjustment_requests(id,variant_id,kind,quantity,reason)
      values(p_request,p_variant,p_kind,p_quantity,trim(p_reason)) on conflict(id) do nothing;
    if not found then
      if not exists(select 1 from public.stock_adjustment_requests where id=p_request and variant_id=p_variant and kind=p_kind and quantity=p_quantity and reason=trim(p_reason)) then
        raise exception 'Request was already used for another operation';
      end if;
      return;
    end if;
  end if;
  perform set_config('tatami.stock_kind', p_kind, true);
  perform set_config('tatami.stock_reason', trim(p_reason), true);
  update public.product_variants set stock_quantity = case p_kind
    when 'receipt' then stock_quantity + p_quantity
    when 'writeoff' then stock_quantity - p_quantity
    else p_quantity end
  where id = p_variant;
  if not found then raise exception 'Variant unavailable'; end if;
end;
$$;

revoke all on function public.adjust_catalog_stock(uuid,text,integer,text,uuid) from public;
grant execute on function public.adjust_catalog_stock(uuid,text,integer,text,uuid) to authenticated;

create function public.duplicate_catalog_product(p_product uuid)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  source public.products;
  copy_id uuid;
begin
  select * into source from public.products where id = p_product;
  if not found or not coalesce(public.is_store_member(source.store_id), false) then
    raise exception 'Manager access required';
  end if;
  insert into public.products(store_id, category_id, name, description, is_active, position)
  values (source.store_id, source.category_id, source.name, source.description, false, source.position)
  returning id into copy_id;
  insert into public.product_variants(product_id, name, sku, price, compare_at_price, stock_quantity, is_preorder, position, low_stock_threshold)
  select copy_id, name, null, price, compare_at_price, 0, is_preorder, position, low_stock_threshold
    from public.product_variants where product_id = p_product;
  insert into public.product_images(product_id, public_url, storage_path, position)
  select copy_id, public_url, storage_path, position from public.product_images where product_id = p_product;
  return copy_id;
end;
$$;

revoke all on function public.duplicate_catalog_product(uuid) from public;
grant execute on function public.duplicate_catalog_product(uuid) to authenticated;
