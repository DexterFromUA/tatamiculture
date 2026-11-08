create function public.delete_catalog_product(p_store_id uuid, p_product_id uuid)
returns boolean language plpgsql security invoker set search_path = '' as $$
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise exception 'Manager access required' using errcode = '42501';
  end if;

  perform 1 from public.products
  where id = p_product_id and store_id = p_store_id for update;
  if not found then return false; end if;

  -- Prevent checkout or stock updates from changing a variant while we check its history.
  perform 1 from public.product_variants
  where product_id = p_product_id order by id for update;

  if exists (select 1 from public.order_items where product_id = p_product_id)
    or exists (
      select 1 from public.product_variants v
      where v.product_id = p_product_id and (
        exists (select 1 from public.order_items i where i.variant_id = v.id)
        or exists (select 1 from public.stock_movements m where m.variant_id = v.id)
      )
    ) then
    raise exception 'Product is used in order or stock history' using errcode = '23503';
  end if;

  delete from public.products where id = p_product_id and store_id = p_store_id;
  return found;
end;
$$;

revoke all on function public.delete_catalog_product(uuid, uuid) from public, anon, authenticated;
grant execute on function public.delete_catalog_product(uuid, uuid) to authenticated;
notify pgrst, 'reload schema';
