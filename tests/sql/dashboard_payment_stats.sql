-- The dashboard sees only its store's non-test attempts, grouped by Kyiv calendar dates.
begin;
do $$
declare manager uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); shop uuid; other_shop uuid; stats jsonb;
begin
  insert into auth.users(id,raw_user_meta_data) values(manager,'{}'),(outsider,'{}');
  insert into public.stores(slug,name,contact_email,contact_phone,contact_city)
    values('dashboard-check-'||substr(manager::text,1,8),'Check','','','') returning id into shop;
  insert into public.stores(slug,name,contact_email,contact_phone,contact_city)
    values('dashboard-other-'||substr(manager::text,1,8),'Other','','','') returning id into other_shop;
  insert into public.store_members(store_id,user_id,role) values(shop,manager,'OWNER');
  insert into public.online_checkouts(store_id,provider,test_mode,total_price,currency,status,created_at) values
    (shop,'LIQPAY',false,100,'UAH','PAID','2026-10-24T21:00:00Z'),
    (shop,'LIQPAY',false,100,'UAH','FAILED','2026-10-25T21:59:59Z'),
    (shop,'MONOBANK',false,100,'UAH','PENDING','2026-10-25T15:00:00Z'),
    (shop,'LIQPAY',false,100,'UAH','FAILED',null),
    (shop,'LIQPAY',false,100,'UAH','PAID','2026-10-25T22:00:00Z'),
    (shop,'LIQPAY',true,100,'UAH','PAID','2026-10-25T15:00:00Z'),
    (shop,'LIQPAY',false,100,'EUR','PAID','2026-10-25T15:00:00Z'),
    (other_shop,'LIQPAY',false,100,'UAH','PAID','2026-10-25T15:00:00Z');
  perform set_config('request.jwt.claim.sub',manager::text,true);
  execute 'set local role authenticated';
  stats := public.crm_dashboard_payment_stats(shop,'2026-10-25','2026-10-25','UAH');
  if stats <> '{"paid":1,"failed":1,"pending":1,"undated":1}'::jsonb then raise exception 'Wrong payment stats: %',stats; end if;
  begin
    perform public.crm_dashboard_payment_stats(other_shop,'2026-10-25','2026-10-25','UAH');
    raise exception 'Other store exposed';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',outsider::text,true);
  begin
    perform public.crm_dashboard_payment_stats(shop,'2026-10-25','2026-10-25','UAH');
    raise exception 'Outsider access accepted';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
end;
$$;
rollback;
select 'Payment dashboard dates, currency, test exclusions and access checks passed; fixtures rolled back' as result;
