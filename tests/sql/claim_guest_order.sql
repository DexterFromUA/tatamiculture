-- Run after the migration. Fixtures and order changes are rolled back.
begin;
do $$
declare
  buyer uuid := gen_random_uuid();
  other_buyer uuid := gen_random_uuid();
  unverified uuid := gen_random_uuid();
  shop uuid;
  receipt text;
  second_receipt text;
  customer_key text := 'user:' || buyer::text;
begin
  insert into auth.users (id, phone, phone_confirmed_at)
  values (buyer, '380000110001', now()),
         (other_buyer, '380000110002', now()),
         (unverified, '380000110003', null);
  update public.profiles set phone = '+380000110001' where id = unverified;
  insert into public.stores (slug, name, contact_email, contact_phone, contact_city)
  values ('verify-claim-' || buyer, 'Claim verification', 'test@example.invalid', '000', 'Test')
  returning id into shop;
  insert into public.orders
    (store_id, customer_name, customer_email, customer_phone, delivery_city, delivery_address, total_price, currency)
  values (shop, 'Guest', 'test@example.invalid', '(000) 011-00-01', 'Test', 'Test', 10000, 'UAH')
  returning receipt_code into receipt;
  insert into public.orders
    (store_id, customer_name, customer_email, customer_phone, delivery_city, delivery_address, total_price, currency)
  values (shop, 'Guest', 'test@example.invalid', '+380000110001', 'Test', 'Test', 20000, 'UAH')
  returning receipt_code into second_receipt;

  execute 'set local role anon';
  begin
    perform public.claim_guest_order(shop, receipt);
    raise exception 'Anonymous claim was allowed';
  exception when insufficient_privilege then null;
  end;
  execute 'reset role';

  perform set_config('request.jwt.claim.sub', unverified::text, true);
  execute 'set local role authenticated';
  if public.claim_guest_order(shop, receipt) then raise exception 'Unverified profile phone was accepted'; end if;
  perform set_config('request.jwt.claim.sub', other_buyer::text, true);
  if public.claim_guest_order(shop, receipt) then raise exception 'Different verified phone was accepted'; end if;
  perform set_config('request.jwt.claim.sub', buyer::text, true);
  if public.claim_guest_order(gen_random_uuid(), receipt) then raise exception 'Wrong store was accepted'; end if;
  if not public.claim_guest_order(shop, upper(receipt)) then raise exception 'Matching verified phone was denied'; end if;
  if not public.claim_guest_order(shop, receipt) then raise exception 'Claim retry failed'; end if;
  if (select count(*) from public.orders where store_id = shop and user_id = buyer) <> 1 then
    raise exception 'Account history does not contain exactly the claimed order';
  end if;
  execute 'reset role';

  if (select user_id from public.orders where receipt_code = second_receipt) is not null then
    raise exception 'Another guest order was also claimed';
  end if;
  if not exists (
    select 1 from public.orders o
    join public.crm_customer_keys k on k.store_id = o.store_id and k.customer_id = o.crm_customer_id
    where o.receipt_code = receipt and k.key = customer_key
  ) then raise exception 'Claimed order was not associated with the CRM account'; end if;

  update auth.users set phone = '380000110004' where id = buyer;
  update auth.users set phone = '380000110001' where id = other_buyer;
  perform set_config('request.jwt.claim.sub', other_buyer::text, true);
  execute 'set local role authenticated';
  if public.claim_guest_order(shop, receipt) then raise exception 'Claimed order could be transferred'; end if;
  execute 'reset role';
end;
$$;
select 'Guest order claim checks passed' as result;
rollback;
