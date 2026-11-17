create function public.update_crm_customer_details(
  p_store_id uuid, p_customer_id uuid, p_name text, p_notes text, p_tags text[]
) returns void language plpgsql security definer set search_path = '' as $$
declare
  customer public.crm_customers;
  account_ids uuid[];
  next_name text := trim(p_name);
begin
  if not coalesce(public.is_store_member(p_store_id),false) then
    raise exception 'Access denied' using errcode = '42501';
  end if;
  if next_name is null or next_name = '' or char_length(next_name) > 100 then
    raise exception 'Enter a name between 1 and 100 characters.' using errcode = '22023';
  end if;
  -- Serialize with customer merges and account deletion before resolving linked accounts.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_store_id::text,0));
  select * into customer from public.crm_customers where id = p_customer_id and store_id = p_store_id for update;
  if not found then raise exception 'Customer not found'; end if;
  if customer.name is distinct from next_name then
    if not exists (select 1 from public.store_members m where m.store_id = p_store_id
      and m.user_id = auth.uid() and m.role in ('OWNER','MANAGER')) then
      raise exception 'Manager access required' using errcode = '42501';
    end if;
    select array_agg(u.id order by u.id) into account_ids
    from public.crm_customer_keys k join auth.users u on k.key = 'user:' || u.id::text
    where k.store_id = p_store_id and k.customer_id = p_customer_id and u.deleted_at is null;
    update auth.users set raw_user_meta_data = coalesce(raw_user_meta_data,'{}'::jsonb) || jsonb_build_object('name',next_name)
      where id = any(account_ids);
    update public.profiles set name = next_name where id = any(account_ids);
  end if;
  update public.crm_customers set name = next_name, notes = p_notes, tags = p_tags where id = customer.id;
end;
$$;
revoke all on function public.update_crm_customer_details(uuid,uuid,text,text,text[]) from public,anon;
grant execute on function public.update_crm_customer_details(uuid,uuid,text,text,text[]) to authenticated;
