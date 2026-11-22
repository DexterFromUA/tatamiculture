-- Phone verification belongs to the number. Account permissions still use the user key.
create function public.crm_verified_phone_customers(p_store_id uuid, p_phone text)
returns table(customer_id uuid)
language sql stable strict
set search_path = ''
as $$
  select distinct k.customer_id
  from auth.users a
  join public.crm_customer_keys k on k.store_id = p_store_id and k.key = 'user:' || a.id::text
  where a.phone in (p_phone, '+' || p_phone) and a.phone_confirmed_at is not null
    and a.deleted_at is null and not a.is_anonymous;
$$;

revoke all on function public.crm_verified_phone_customers(uuid, text) from public, anon, authenticated, service_role;

create or replace function public.crm_identity(p_store uuid, p_key text, p_name text, p_phone text, p_email text)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_customer uuid;
  v_verified_phone text;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_store::text, 0));

  select customer_id into v_customer
  from public.crm_customer_keys
  where store_id = p_store and key = p_key;
  if v_customer is not null then
    return v_customer;
  end if;

  if p_key like 'user:%' then
    select public.crm_normalize_phone(a.phone) into v_verified_phone
    from auth.users a
    where a.id = substr(p_key, 6)::uuid and a.phone_confirmed_at is not null
      and a.deleted_at is null and not a.is_anonymous;

    if v_verified_phone is not null then
      p_phone := '+' || v_verified_phone;
      -- A customer who registers after ordering as a guest keeps the same CRM card.
      select c.id into v_customer
      from public.crm_customers c
      where c.store_id = p_store and public.crm_normalize_phone(c.phone) = v_verified_phone
        and not exists (
          select from public.crm_customer_keys k
          where k.store_id = p_store and k.customer_id = c.id and k.key like 'user:%'
        )
      order by c.created_at, c.id
      limit 1;
    end if;
  end if;

  if v_customer is null then
    insert into public.crm_customers(store_id, name, phone, email)
    values (p_store, p_name, p_phone, p_email)
    returning id into v_customer;
  end if;

  insert into public.crm_customer_keys(store_id, key, customer_id) values (p_store, p_key, v_customer);
  return v_customer;
end;
$$;

revoke all on function public.crm_identity(uuid, text, text, text, text) from public, anon, authenticated;

create or replace function public.crm_customer_for_order(p_order public.orders)
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
    select (array_agg(customer_id))[1] into v_customer
    from public.crm_verified_phone_customers(p_order.store_id, v_phone)
    having count(*) = 1;
    if v_customer is not null then
      return v_customer;
    end if;

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

create or replace function public.crm_customer_phone_confirmed(p_store_id uuid, p_customer_id uuid)
returns boolean
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;

  return exists (
    select from public.crm_customers c
    cross join lateral public.crm_verified_phone_customers(p_store_id, public.crm_normalize_phone(c.phone))
    where c.id = p_customer_id and c.store_id = p_store_id
  );
end;
$$;

create or replace function public.list_crm_customers(p_store_id uuid)
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
    left join public.store_members m on m.store_id = k.store_id and m.user_id = a.id
    left join public.customer_discounts d on d.store_id = k.store_id and d.user_id = a.id and d.enabled
    where k.store_id = p_store_id and a.deleted_at is null and not a.is_anonymous
    group by k.customer_id
  )
  select c.id, c.name, c.phone, c.email, c.notes, c.tags, c.created_at,
    exists (select from public.crm_verified_phone_customers(p_store_id, public.crm_normalize_phone(c.phone))),
    coalesce(f.is_administrator, false), coalesce(f.has_active_discount, false)
  from public.crm_customers c
  left join account_flags f on f.customer_id = c.id
  where c.store_id = p_store_id;
end;
$$;

-- Consolidate old automatically generated phone-only duplicates with no independent
-- customer data. Keep the recipient name and account ownership on each order.
do $$
declare
  v_store uuid;
  v_duplicate record;
begin
  for v_store in select id from public.shop_settings order by id loop
    perform pg_advisory_xact_lock(hashtextextended(v_store::text, 0));
    for v_duplicate in
      select c.id, c.created_at, verified.id as target_id
      from public.crm_customers c
      cross join lateral (select public.crm_normalize_phone(c.phone) as value) phone
      cross join lateral (
        select (array_agg(customer_id))[1] as id
        from public.crm_verified_phone_customers(v_store, phone.value)
        having count(*) = 1
      ) verified
      where c.store_id = v_store and c.id <> verified.id
        and c.notes = '' and c.email = '' and cardinality(c.tags) = 0
        and exists (
          select from public.crm_customer_keys k
          where k.store_id = v_store and k.customer_id = c.id and k.key like 'phone:%'
            and public.crm_normalize_phone(substr(k.key, 7)) = phone.value
        )
        and not exists (
          select from public.crm_customer_keys k
          where k.customer_id = c.id and (k.store_id <> v_store or k.key not like 'phone:%'
            or public.crm_normalize_phone(substr(k.key, 7)) is distinct from phone.value)
        )
        and exists (
          select from public.orders o
          where o.crm_customer_id = c.id and o.customer_name = c.name and o.customer_email = c.email
        )
        and not exists (
          select from public.orders o
          where o.crm_customer_id = c.id
            and (o.store_id <> v_store or o.user_id is not null
              or public.crm_normalize_phone(o.customer_phone) is distinct from phone.value)
        )
      for update of c
    loop
      update public.orders set crm_customer_id = v_duplicate.target_id
      where crm_customer_id = v_duplicate.id;

      update public.crm_customer_keys set customer_id = v_duplicate.target_id
      where customer_id = v_duplicate.id;

      update public.crm_customers set created_at = least(created_at, v_duplicate.created_at)
      where id = v_duplicate.target_id;

      delete from public.crm_customers where id = v_duplicate.id;
    end loop;
  end loop;
end;
$$;
