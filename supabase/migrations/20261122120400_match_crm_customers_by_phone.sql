create function public.crm_normalize_phone(p_phone text)
returns text
language sql immutable strict
set search_path = ''
as $$
  select case
    when compact ~ '^0[0-9]{9}$' then '38' || compact
    when compact ~ '^\+?[1-9][0-9]{7,14}$' then ltrim(compact, '+')
  end
  from (select regexp_replace(p_phone, '[[:space:]()-]', '', 'g') as compact) phone;
$$;

create index crm_customers_normalized_phone_idx
  on public.crm_customers (store_id, public.crm_normalize_phone(phone));

create function public.crm_customer_for_order(p_order public.orders)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_phone text := public.crm_normalize_phone(p_order.customer_phone);
  v_phone_key text := 'phone:' || v_phone;
  v_local_phone_key text;
  v_key text;
  v_customer uuid;
begin
  if p_order.user_id is not null then
    v_key := 'user:' || p_order.user_id::text;
  elsif v_phone is not null then
    -- Use the same per-store lock as identity creation and customer merges.
    perform pg_advisory_xact_lock(hashtextextended(p_order.store_id::text, 0));
    if v_phone ~ '^380[0-9]{9}$' then
      v_local_phone_key := 'phone:' || substr(v_phone, 3);
    end if;

    with matching as (
      select c.id, c.created_at, exists (
        select from public.crm_customer_keys k
        where k.store_id = p_order.store_id and k.customer_id = c.id and k.key like 'user:%'
      ) as registered, k.key
      from public.crm_customers c
      left join public.crm_customer_keys k on k.store_id = c.store_id and k.customer_id = c.id
        and k.key in (v_phone_key, v_local_phone_key)
      where c.store_id = p_order.store_id
        and (public.crm_normalize_phone(c.phone) = v_phone or k.key is not null)
    ), candidates as (
      select id, created_at, registered, coalesce(bool_or(key = v_phone_key), false) as canonical_key
      from matching
      group by id, created_at, registered
    )
    select id into v_customer
    from candidates
    -- A shared number alone cannot select between two registered profiles.
    where not registered or canonical_key
      or (select count(*) from candidates where registered) = 1
    order by registered desc, canonical_key desc, created_at, id
    limit 1;

    if v_customer is not null then
      return v_customer;
    end if;
    v_key := v_phone_key;
  elsif trim(p_order.customer_email) <> '' then
    v_key := 'email:' || lower(trim(p_order.customer_email));
  else
    v_key := 'order:' || p_order.id::text;
  end if;

  return public.crm_identity(
    p_order.store_id, v_key, p_order.customer_name, p_order.customer_phone, p_order.customer_email
  );
end;
$$;

revoke all on function public.crm_customer_for_order(public.orders) from public, anon, authenticated, service_role;

create or replace function public.attach_crm_customer()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  new.crm_customer_id := public.crm_customer_for_order(new);
  return new;
end;
$$;

-- Repair missing links on legacy orders. Preserve links already assigned by staff.
do $$
declare
  v_order public.orders;
begin
  for v_order in
    select o.* from public.orders o
    where o.crm_customer_id is null and not exists (
      select from public.order_merge_members m where m.order_id = o.id and m.root_id <> o.id
    )
    order by o.store_id, o.created_at, o.id
  loop
    update public.orders
    set crm_customer_id = public.crm_customer_for_order(v_order)
    where id = v_order.id and crm_customer_id is null;
  end loop;
end;
$$;

update public.orders o
set crm_customer_id = root.crm_customer_id
from public.order_merge_members m
join public.orders root on root.id = m.root_id
where o.id = m.order_id and o.store_id = root.store_id
  and o.crm_customer_id is null and root.crm_customer_id is not null;
