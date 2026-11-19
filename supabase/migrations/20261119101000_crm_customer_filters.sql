begin;

create function public.list_crm_customers(p_store_id uuid)
returns table (
  id uuid, name text, phone text, email text, notes text, tags text[], created_at timestamptz,
  phone_confirmed boolean, is_administrator boolean, has_active_discount boolean
)
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if not public.is_store_member(p_store_id) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;

  return query
  with account_flags as (
    select k.customer_id,
      bool_or(a.phone_confirmed_at is not null
        and number.digits <> ''
        and ltrim(a.phone, '+') = case when number.digits ~ '^0[0-9]{9}$' then '38' || number.digits else number.digits end
      ) as phone_confirmed,
      bool_or(m.role in ('OWNER', 'MANAGER')) as is_administrator,
      bool_or(case d.mode
        when 'unlimited' then true
        when 'period' then (now() at time zone 'Europe/Kyiv')::date between d.starts_on and d.ends_on
        when 'orders' then public.customer_discount_usage(d.id) < d.order_limit
        else false
      end) as has_active_discount
    from public.crm_customer_keys k
    join public.crm_customers c on c.id = k.customer_id and c.store_id = k.store_id
    join auth.users a on k.key = 'user:' || a.id::text
    cross join lateral (select regexp_replace(c.phone, '[^0-9]', '', 'g') as digits) number
    left join public.store_members m on m.store_id = k.store_id and m.user_id = a.id
    left join public.customer_discounts d on d.store_id = k.store_id and d.user_id = a.id and d.enabled
    where k.store_id = p_store_id and a.deleted_at is null and not a.is_anonymous
    group by k.customer_id
  )
  select c.id, c.name, c.phone, c.email, c.notes, c.tags, c.created_at,
    coalesce(f.phone_confirmed, false), coalesce(f.is_administrator, false), coalesce(f.has_active_discount, false)
  from public.crm_customers c
  left join account_flags f on f.customer_id = c.id
  where c.store_id = p_store_id;
end;
$$;

revoke all on function public.list_crm_customers(uuid) from public, anon, authenticated, service_role;
grant execute on function public.list_crm_customers(uuid) to authenticated;

notify pgrst, 'reload schema';

commit;
