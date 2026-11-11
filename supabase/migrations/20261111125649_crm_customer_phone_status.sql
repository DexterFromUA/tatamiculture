create function public.crm_customer_phone_confirmed(p_store_id uuid, p_customer_id uuid)
returns boolean
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise exception 'Store staff access required' using errcode = '42501';
  end if;

  return exists (
    select 1
    from public.crm_customers customer
    join public.crm_customer_keys identity
      on identity.store_id = customer.store_id and identity.customer_id = customer.id
    join auth.users account on identity.key = 'user:' || account.id::text
    cross join lateral (select regexp_replace(customer.phone, '[^0-9]', '', 'g') as digits) phone
    where customer.id = p_customer_id and customer.store_id = p_store_id
      and account.deleted_at is null and not account.is_anonymous
      and account.phone_confirmed_at is not null
      and phone.digits <> ''
      and ltrim(account.phone, '+') = case
        when phone.digits ~ '^0[0-9]{9}$' then '38' || phone.digits
        else phone.digits
      end
  );
end;
$$;

revoke all on function public.crm_customer_phone_confirmed(uuid, uuid) from public, anon, authenticated;
grant execute on function public.crm_customer_phone_confirmed(uuid, uuid) to authenticated;
