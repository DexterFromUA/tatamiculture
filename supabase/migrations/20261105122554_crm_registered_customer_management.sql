-- Resolve real Auth identities through CRM links, including cards merged by staff.
create function public.crm_customer_accounts(p_store_id uuid, p_customer_id uuid)
returns table(user_id uuid, email text, email_confirmed boolean, can_delete boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  caller_role public.staff_role;
begin
  select member.role into caller_role
  from public.store_members member
  where member.store_id = p_store_id and member.user_id = auth.uid();

  if caller_role is null or caller_role not in ('OWNER', 'MANAGER') then
    raise exception 'Manager access required' using errcode = '42501';
  end if;

  return query
  select account.id, account.email::text, account.email_confirmed_at is not null,
    caller_role = 'OWNER'
      and account.id <> auth.uid()
      and not exists (select 1 from public.store_members staff where staff.user_id = account.id)
      and not exists (select 1 from public.store_customers registered
        where registered.user_id = account.id and registered.store_id <> p_store_id)
      and not exists (select 1 from public.crm_customer_keys other
        where other.key = 'user:' || account.id::text and other.store_id <> p_store_id)
      and not exists (select 1 from public.orders purchase
        where purchase.user_id = account.id and purchase.store_id <> p_store_id)
  from public.crm_customer_keys identity
  join auth.users account on identity.key = 'user:' || account.id::text
  where identity.store_id = p_store_id and identity.customer_id = p_customer_id
    and account.deleted_at is null and not account.is_anonymous
  order by account.created_at, account.id;
end;
$$;

create function public.delete_crm_customer_account(p_store_id uuid, p_customer_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  -- Prevent merges or new account links from changing the target during deletion.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_store_id::text, 0));
  perform 1 from auth.users account where account.id = p_user_id for update;
  perform 1 from public.profiles profile where profile.id = p_user_id for update;

  if not exists (select 1 from public.crm_customer_accounts(p_store_id, p_customer_id) account
    where account.user_id = p_user_id and account.can_delete) then
    raise exception 'This account cannot be deleted from this store' using errcode = '42501';
  end if;

  -- FK actions unlink orders and remove the profile. The CRM card and orders remain.
  delete from auth.users where id = p_user_id;
  delete from public.crm_customer_keys where store_id = p_store_id and key = 'user:' || p_user_id::text;
end;
$$;

revoke all on function public.crm_customer_accounts(uuid,uuid), public.delete_crm_customer_account(uuid,uuid,uuid) from public, anon, authenticated;
grant execute on function public.crm_customer_accounts(uuid,uuid), public.delete_crm_customer_account(uuid,uuid,uuid) to authenticated;
