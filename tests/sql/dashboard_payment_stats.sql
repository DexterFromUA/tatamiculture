-- The dashboard sees its store's payment attempts in both acquiring modes, grouped by Kyiv calendar dates.
begin;
-- The production singleton is restored when the fixtures roll back.
drop index public.shop_settings_single_row_idx;
do $$
declare
  manager uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); shop uuid; other_shop uuid; stats jsonb;
  refunded_order uuid:=gen_random_uuid(); refunded_payment uuid:=gen_random_uuid();
  partial_split uuid:=gen_random_uuid(); full_split uuid:=gen_random_uuid(); full_split_child uuid:=gen_random_uuid();
begin
  insert into auth.users(id,raw_user_meta_data) values(manager,'{}'),(outsider,'{}');
  insert into public.shop_settings (name)
    values('Check') returning id into shop;
  insert into public.shop_settings (name)
    values('Other') returning id into other_shop;
  insert into public.store_members(store_id,user_id,role) values(shop,manager,'OWNER');
  insert into public.online_checkouts(store_id,provider,test_mode,total_price,currency,status,created_at) values
    (shop,'LIQPAY',false,100,'UAH','PAID','2026-10-24T21:00:00Z'),
    (shop,'LIQPAY',false,100,'UAH','FAILED','2026-10-25T21:59:59Z'),
    (shop,'LIQPAY',false,100,'UAH','FAILED',null),
    (shop,'LIQPAY',false,100,'UAH','PAID','2026-10-25T22:00:00Z'),
    (shop,'LIQPAY',true,100,'UAH','PAID','2026-10-25T15:00:00Z'),
    (shop,'LIQPAY',false,100,'EUR','PAID','2026-10-25T15:00:00Z'),
    (other_shop,'LIQPAY',false,100,'UAH','PAID','2026-10-25T15:00:00Z');
  insert into public.online_checkouts(store_id,provider,test_mode,total_price,currency,status,created_at,expires_at) values
    (shop,'MONOBANK',false,100,'UAH','PENDING','2026-10-25T15:00:00Z',now() + interval '1 hour'),
    (shop,'MONOBANK',false,100,'UAH','PENDING','2026-10-25T16:00:00Z',now());
  insert into public.online_checkouts(id,store_id,provider,test_mode,total_price,currency,status,created_at)
  select attempt.id,shop,'LIQPAY',false,100,'UAH','PAID','2026-10-25T15:00:00Z'::timestamptz
  from (values (refunded_order), (refunded_payment), (partial_split), (full_split)) attempt(id);
  insert into public.orders(id,store_id,customer_name,customer_email,customer_phone,delivery_city,delivery_address,
    total_price,currency,status,payment_status,payment_method,split_origin_id)
  select part.id,shop,'Buyer','','+380671234567','Київ','10',part.amount,'UAH','IN_PROGRESS',
    part.payment_status::public.payment_status,'ONLINE',part.origin_id
  from (values
    (refunded_order,100,'REFUNDED',null::uuid), (refunded_payment,100,'PAID',null),
    (partial_split,40,'REFUNDED',partial_split), (gen_random_uuid(),60,'PAID',partial_split),
    (full_split,40,'PAID',full_split), (full_split_child,60,'PAID',full_split)
  ) part(id,amount,payment_status,origin_id);
  insert into public.payments(order_id,provider,provider_order_id,status)
    values (refunded_payment,'LIQPAY',refunded_payment::text,'REFUNDED');
  insert into public.order_returns(order_id,amount,reason) values
    (full_split,40,'Returned first part'), (full_split_child,60,'Returned remaining part');
  perform set_config('request.jwt.claim.sub',manager::text,true);
  execute 'set local role authenticated';
  stats := public.crm_dashboard_payment_stats(shop,'2026-10-25','2026-10-25','UAH');
  if stats <> '{"paid":3,"failed":1,"pending":1,"expired":1,"undated":1}'::jsonb then raise exception 'Wrong payment stats: %',stats; end if;
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
select 'Payment dashboard refunds, split orders, expiration, dates, currency, acquiring modes and access checks passed; fixtures rolled back' as result;
