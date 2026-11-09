create function public.crm_order_activity(p_order_id uuid)
returns table (
  id uuid,
  kind text,
  old_value text,
  new_value text,
  created_at timestamptz,
  author_name text,
  is_system boolean
)
language sql stable security definer set search_path = '' as $$
  select e.id, e.kind, e.old_value, e.new_value, e.created_at,
         nullif(trim(p.name), ''), e.author_id is null
  from public.order_events e
  join public.orders o on o.id = e.order_id
  left join public.profiles p on p.id = e.author_id
  where o.id = p_order_id and public.is_store_member(o.store_id)
  order by e.created_at desc;
$$;

revoke all on function public.crm_order_activity(uuid) from public, anon;
grant execute on function public.crm_order_activity(uuid) to authenticated;
