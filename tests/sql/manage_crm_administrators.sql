-- Verify authorization and account ownership without leaving fixture data.
begin;
-- The production singleton is restored when the fixtures roll back.
drop index public.shop_settings_single_row_idx;
do $$
declare owner_id uuid:=gen_random_uuid(); manager_id uuid:=gen_random_uuid(); buyer_id uuid:=gen_random_uuid(); outsider_id uuid:=gen_random_uuid(); other_id uuid:=gen_random_uuid(); shop uuid; other_shop uuid; customer uuid;
begin
  insert into auth.users(id,raw_user_meta_data) values(owner_id,'{"name":"Owner"}'),(manager_id,'{"name":"Manager"}'),(buyer_id,'{"name":"Buyer"}'),(outsider_id,'{}'),(other_id,'{}');
  insert into public.shop_settings (name) values('Check') returning id into shop;
  insert into public.shop_settings (name) values('Other') returning id into other_shop;
  insert into public.store_members(store_id,user_id,role) values(shop,owner_id,'OWNER'),(shop,manager_id,'MANAGER'),(other_shop,other_id,'OWNER');
  insert into public.store_customers(store_id,user_id) values(shop,buyer_id),(shop,owner_id),(shop,manager_id),(other_shop,other_id);
  select customer_id into customer from public.crm_customer_keys where store_id=shop and key='user:'||buyer_id::text;
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  execute 'set local role authenticated';
  perform public.set_crm_administrator(shop,customer,buyer_id,true);
  if not exists (select 1 from public.crm_customer_staff_access(shop,customer) a where a.user_id=buyer_id and a.role='MANAGER') then raise exception 'Grant failed'; end if;
  perform public.set_crm_administrator(shop,customer,buyer_id,true);
  perform set_config('request.jwt.claim.sub',buyer_id::text,true);
  if not public.is_store_member(shop) then raise exception 'Granted user cannot access CRM'; end if;
  perform set_config('request.jwt.claim.sub',manager_id::text,true);
  perform public.set_crm_administrator(shop,customer,buyer_id,false);
  if exists (select 1 from public.crm_customer_staff_access(shop,customer) a where a.user_id=buyer_id and a.role is not null) then raise exception 'Revoke failed'; end if;
  perform set_config('request.jwt.claim.sub',buyer_id::text,true);
  if public.is_store_member(shop) then raise exception 'Revoked user still has CRM access'; end if;
  perform set_config('request.jwt.claim.sub',manager_id::text,true);
  begin
    perform public.set_crm_administrator(shop,(select customer_id from public.crm_customer_keys where store_id=shop and key='user:'||manager_id::text),manager_id,false);
    raise exception 'Self removal accepted';
  exception when insufficient_privilege then null; end;
  begin
    perform public.set_crm_administrator(shop,(select customer_id from public.crm_customer_keys where store_id=shop and key='user:'||owner_id::text),owner_id,false);
    raise exception 'Owner removal accepted';
  exception when insufficient_privilege then null; end;
  begin
    perform public.set_crm_administrator(shop,customer,other_id,true);
    raise exception 'Unlinked user accepted';
  exception when invalid_parameter_value then null; end;
  perform set_config('request.jwt.claim.sub',outsider_id::text,true);
  begin
    perform public.set_crm_administrator(shop,customer,outsider_id,true);
    raise exception 'Outsider grant accepted';
  exception when insufficient_privilege then null; end;
  begin
    perform public.crm_customer_staff_access(shop,customer);
    raise exception 'Outsider read accepted';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
end;
$$;
rollback;
select 'Administrator access checks passed; fixtures rolled back' as result;
