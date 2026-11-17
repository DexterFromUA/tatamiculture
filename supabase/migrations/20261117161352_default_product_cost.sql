-- Keep supplier costs out of public catalogue responses.
create table public.product_costs (
  product_id uuid primary key references public.products(id) on delete cascade,
  cost_amount integer not null check (cost_amount >= 0)
);

alter table public.product_costs enable row level security;
revoke all on public.product_costs from public, anon;
grant select, insert, update, delete on public.product_costs to authenticated;

create policy "staff manage product costs"
  on public.product_costs for all to authenticated
  using (exists (
    select 1 from public.products p
    where p.id = product_id and public.is_store_member(p.store_id)
  ))
  with check (exists (
    select 1 from public.products p
    where p.id = product_id and public.is_store_member(p.store_id)
  ));

create function public.save_catalog_costs(
  p_product_id uuid, p_update_default boolean, p_default_cost integer, p_variant_costs jsonb
)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  perform 1 from public.products p
  where p.id = p_product_id and public.is_store_member(p.store_id)
  for update;
  if not found then raise exception 'Manager access required'; end if;

  if exists (
    select 1 from jsonb_to_recordset(p_variant_costs) as costs(variant_id uuid, cost_amount integer)
    where not exists (
      select 1 from public.product_variants v
      where v.id = costs.variant_id and v.product_id = p_product_id
    )
  ) then
    raise exception 'Variant does not belong to this product';
  end if;

  if p_update_default then
    if p_default_cost is null then
      delete from public.product_costs where product_id = p_product_id;
    else
      insert into public.product_costs (product_id, cost_amount)
      values (p_product_id, p_default_cost)
      on conflict (product_id) do update set cost_amount = excluded.cost_amount;
    end if;
  end if;

  delete from public.variant_costs v
  using jsonb_to_recordset(p_variant_costs) as costs(variant_id uuid, cost_amount integer)
  where v.variant_id = costs.variant_id and costs.cost_amount is null;

  insert into public.variant_costs (variant_id, cost_amount)
  select costs.variant_id, costs.cost_amount
  from jsonb_to_recordset(p_variant_costs) as costs(variant_id uuid, cost_amount integer)
  where costs.cost_amount is not null
  on conflict (variant_id) do update set cost_amount = excluded.cost_amount;
end;
$$;

revoke all on function public.save_catalog_costs(uuid, boolean, integer, jsonb) from public, anon;
grant execute on function public.save_catalog_costs(uuid, boolean, integer, jsonb) to authenticated;

create or replace function public.snapshot_item_cost()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.order_item_costs (item_id, unit_cost)
  values (new.id, coalesce(
    (select cost_amount from public.variant_costs where variant_id = new.variant_id),
    (select cost_amount from public.product_costs where product_id = new.product_id)
  ));
  return new;
end;
$$;
