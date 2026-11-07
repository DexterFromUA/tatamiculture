create function public.claim_guest_order(p_store_id uuid, p_receipt_code text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  account_id uuid := auth.uid();
  verified_phone text;
  receipt text := lower(trim(p_receipt_code));
  target public.orders%rowtype;
  order_phone text;
  customer_id uuid;
begin
  if account_id is null or receipt is null or receipt !~ '^[0-9a-f]{24}$' then
    return false;
  end if;

  select ltrim(u.phone, '+') into verified_phone
  from auth.users u
  where u.id = account_id and u.phone_confirmed_at is not null
    and u.deleted_at is null and not u.is_anonymous;

  if verified_phone is null or verified_phone = '' then
    return false;
  end if;

  -- Use the same lock order as CRM merges and account removal.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_store_id::text, 0));
  select * into target from public.orders
  where store_id = p_store_id and receipt_code = receipt
  for update;
  if not found then return false; end if;
  if target.user_id = account_id then return true; end if;
  if target.user_id is not null then return false; end if;

  order_phone := regexp_replace(target.customer_phone, '[[:space:]()-]', '', 'g');
  order_phone := case
    when order_phone ~ '^0[0-9]{9}$' then '38' || order_phone
    when order_phone ~ '^(380[0-9]{9}|\+[1-9][0-9]{7,14})$' then ltrim(order_phone, '+')
    else null
  end;
  if order_phone is distinct from verified_phone then return false; end if;

  customer_id := public.crm_identity(
    p_store_id, 'user:' || account_id::text, target.customer_name,
    '+' || verified_phone, target.customer_email
  );
  insert into public.store_customers (store_id, user_id)
  values (p_store_id, account_id) on conflict (store_id, user_id) do nothing;

  update public.orders set user_id = account_id, crm_customer_id = customer_id
  where id = target.id;
  return true;
end;
$$;

revoke all on function public.claim_guest_order(uuid, text) from public, anon, authenticated;
grant execute on function public.claim_guest_order(uuid, text) to authenticated;
