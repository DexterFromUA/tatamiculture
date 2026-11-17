-- Administrators are existing registered accounts linked to the selected CRM card.
create function public.crm_customer_staff_access(p_store_id uuid, p_customer_id uuid)
returns table(user_id uuid, display_name text, email text, phone_suffix text, role public.staff_role, is_self boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.store_members m where m.store_id = p_store_id
    and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;
  return query
    select a.id, p.name, nullif(a.email::text, ''), right(coalesce(a.phone, ''), 4), m.role, a.id = auth.uid()
    from public.crm_customer_keys k
    join auth.users a on k.key = 'user:' || a.id::text
    join public.profiles p on p.id = a.id
    left join public.store_members m on m.store_id = k.store_id and m.user_id = a.id
    where k.store_id = p_store_id and k.customer_id = p_customer_id
      and a.deleted_at is null and not a.is_anonymous
    order by a.created_at, a.id;
end;
$$;

create function public.set_crm_administrator(p_store_id uuid, p_customer_id uuid, p_user_id uuid, p_grant boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare target_role public.staff_role;
begin
  if p_grant is null then raise exception 'Invalid access setting' using errcode = '22023'; end if;
  -- Shared with CRM merges and account deletion, and serializes concurrent access changes.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_store_id::text, 0));
  if not exists (select 1 from public.store_members m where m.store_id = p_store_id
    and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;
  if p_user_id = auth.uid() then raise exception 'You cannot change your own administrator access' using errcode = '42501'; end if;
  if not exists (select 1 from public.crm_customer_keys k join auth.users a on k.key = 'user:' || a.id::text
    join public.profiles p on p.id = a.id
    where k.store_id = p_store_id and k.customer_id = p_customer_id and a.id = p_user_id
      and a.deleted_at is null and not a.is_anonymous) then
    raise exception 'The registered account is no longer linked to this customer' using errcode = '22023';
  end if;
  select m.role into target_role from public.store_members m where m.store_id = p_store_id and m.user_id = p_user_id for update;
  if target_role = 'OWNER' then raise exception 'Owner access cannot be changed here' using errcode = '42501'; end if;
  if p_grant then
    insert into public.store_members(store_id, user_id, role) values(p_store_id, p_user_id, 'MANAGER')
    on conflict (store_id, user_id) do update set role = 'MANAGER';
  else
    delete from public.store_members where store_id = p_store_id and user_id = p_user_id and role in ('MANAGER', 'CONTENT');
  end if;
end;
$$;
revoke all on function public.crm_customer_staff_access(uuid,uuid), public.set_crm_administrator(uuid,uuid,uuid,boolean) from public, anon;
grant execute on function public.crm_customer_staff_access(uuid,uuid), public.set_crm_administrator(uuid,uuid,uuid,boolean) to authenticated;
