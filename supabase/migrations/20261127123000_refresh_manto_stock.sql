create function public.refresh_manto_stock(
  p_store_id uuid,
  p_product_id uuid,
  p_manto_product_id text,
  p_quantities jsonb,
  p_checked_at timestamptz
) returns jsonb
language plpgsql security invoker strict set search_path = '' as $$
declare
  current_snapshot jsonb;
  updated_variants jsonb;
begin
  select source.snapshot into current_snapshot
  from public.manto_product_sources as source
  where source.store_id = p_store_id and source.product_id = p_product_id
    and source.manto_product_id = p_manto_product_id
  for update;

  if not found or (current_snapshot->>'checkedAt')::timestamptz > p_checked_at then
    return current_snapshot;
  end if;

  with quantities as (
    select key, value
    from jsonb_each(p_quantities)
    where case when jsonb_typeof(value) = 'number' then
      value::numeric between 0 and 2147483647 and value::numeric = trunc(value::numeric)
    else false end
  )
  select coalesce(jsonb_agg(
    case when quantity.value is not null then jsonb_set(variant.value, '{quantity}', quantity.value)
      else variant.value end
    order by variant.position
  ), '[]'::jsonb)
  into updated_variants
  from jsonb_array_elements(current_snapshot->'variants') with ordinality as variant(value, position)
  left join quantities as quantity on quantity.key = variant.value->>'key';

  current_snapshot := jsonb_set(
    jsonb_set(current_snapshot, '{variants}', updated_variants),
    '{checkedAt}', to_jsonb(p_checked_at)
  );
  update public.manto_product_sources
  set snapshot = current_snapshot
  where product_id = p_product_id and store_id = p_store_id and manto_product_id = p_manto_product_id;

  return current_snapshot;
end;
$$;

revoke all on function public.refresh_manto_stock(uuid, uuid, text, jsonb, timestamptz) from public, anon;
grant execute on function public.refresh_manto_stock(uuid, uuid, text, jsonb, timestamptz) to authenticated;

notify pgrst, 'reload schema';
