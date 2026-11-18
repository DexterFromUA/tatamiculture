-- Financial and authorization regression checks. Every fixture is rolled back.
begin;
do $$
declare
  manager uuid := gen_random_uuid(); buyer uuid := gen_random_uuid(); outsider uuid := gen_random_uuid();
  shop uuid; product uuid; variant uuid; customer uuid; d uuid; o public.orders; c public.online_checkouts;
  cart jsonb; details jsonb := '{"name":"Test","phone":"+380990001111","city":"Test","address":"Test","email":""}';
  current_day date := (now() at time zone 'Europe/Kyiv')::date;
begin
  insert into auth.users(id,raw_user_meta_data) values(manager,'{"name":"Discount manager"}'),(buyer,'{"name":"Discount buyer"}'),(outsider,'{}');
  insert into public.stores(slug,name,currency)
    values('discount-check-'||substr(manager::text,1,8),'Discount check','UAH') returning id into shop;
  insert into public.store_members(store_id,user_id,role) values(shop,manager,'OWNER');
  insert into public.store_customers(store_id,user_id) values(shop,buyer);
  select customer_id into customer from public.crm_customer_keys where store_id=shop and key='user:'||buyer::text;
  insert into public.store_payment_methods(store_id,cash_on_delivery,liqpay,monobank,payment_test_mode) values(shop,true,true,true,false);
  insert into public.products(store_id,name) values(shop,'Discount fixture') returning id into product;
  insert into public.product_variants(product_id,name,price,stock_quantity) values(product,'M',10005,30) returning id into variant;
  cart := jsonb_build_array(jsonb_build_object('variantId',variant,'quantity',2));

  perform set_config('request.jwt.claim.sub',manager::text,true);
  execute 'set local role authenticated';
  perform public.set_customer_discount(shop,customer,buyer,12.5,'orders',1);
  execute 'reset role';
  select id into d from public.customer_discounts where store_id=shop and enabled;
  perform set_config('request.jwt.claim.sub',buyer::text,true);
  execute 'set local role authenticated';
  begin
    perform public.create_discounted_store_order(shop,cart,'Test','','+380990001111','Test','Test',p_expected_discount_percent => 20);
    raise exception 'Changed discount accepted';
  exception when sqlstate 'PT409' then null; end;
  o := public.create_discounted_store_order(shop,cart,'Test','','+380990001111','Test','Test',p_expected_discount_percent => 12.5);
  execute 'reset role';
  if o.total_price <> 17508 or o.customer_discount_amount <> 2502 or o.customer_discount_id <> d then raise exception 'COD calculation mismatch'; end if;
  if public.customer_discount_usage(d) <> 1 then raise exception 'COD use not counted'; end if;
  if (public.my_customer_discount(shop)->>'active')::boolean then raise exception 'Order limit not enforced'; end if;
  update public.orders set status='CANCELLED_BY_USER' where id=o.id;
  if public.customer_discount_usage(d) <> 0 then raise exception 'Cancelled use not restored'; end if;

  begin
    perform public.prepare_online_checkout('LIQPAY',buyer,shop,cart,details || '{"expectedDiscountPercent":20}',false);
    raise exception 'Changed invoice discount accepted';
  exception when sqlstate 'PT409' then null; end;
  c := public.prepare_online_checkout('LIQPAY',buyer,shop,cart,details || '{"expectedDiscountPercent":12.5}',false);
  if c.total_price <> 17508 then raise exception 'Invoice calculation mismatch'; end if;
  if exists(select 1 from public.orders where id=c.id) then raise exception 'Unpaid order created'; end if;
  if (public.active_customer_discount(shop,buyer)).id is not null then raise exception 'Concurrent payment can reuse last allowance'; end if;
  update public.online_checkouts set status='FAILED' where id=c.id;
  if public.customer_discount_usage(d) <> 0 then raise exception 'Failed payment consumed allowance'; end if;
  c := public.prepare_online_checkout('LIQPAY',buyer,shop,cart,details,false);
  perform public.confirm_online_checkout('LIQPAY',c.provider_order_id,c.total_price,'UAH','fixture','{}');
  perform public.confirm_online_checkout('LIQPAY',c.provider_order_id,c.total_price,'UAH','fixture','{}');
  if public.customer_discount_usage(d) <> 1 then raise exception 'Paid use counted twice'; end if;
  if (select customer_discount_percent from public.orders where id=c.id) <> 12.5 then raise exception 'Paid discount snapshot missing'; end if;
  if (select sum(line_total) from public.order_items where order_id=c.id) <> c.total_price then raise exception 'Paid lines mismatch'; end if;

  perform set_config('request.jwt.claim.sub',manager::text,true);
  perform public.set_customer_discount(shop,customer,buyer,10,'period',null,current_day,current_day);
  if (public.active_customer_discount(shop,buyer)).id is null then raise exception 'Inclusive period boundary failed'; end if;
  perform public.set_customer_discount(shop,customer,buyer,10,'period',null,current_day+1,current_day+2);
  if (public.active_customer_discount(shop,buyer)).id is not null then raise exception 'Future period active'; end if;
  perform public.set_customer_discount(shop,customer,buyer,10,'period',null,current_day-2,current_day-1);
  if (public.active_customer_discount(shop,buyer)).id is not null then raise exception 'Expired period active'; end if;
  perform public.set_customer_discount(shop,customer,buyer,100,'unlimited');
  perform set_config('request.jwt.claim.sub',buyer::text,true);
  o := public.create_store_order(shop,cart,'Test','','+380990001111','Test','Test');
  if o.total_price <> 0 or o.customer_discount_percent <> 100 or o.payment_status <> 'PAID' then raise exception 'Free order failed'; end if;
  if (select sum(line_total) from public.order_items where order_id=o.id) <> 0 then raise exception 'Free lines mismatch'; end if;
  perform set_config('request.jwt.claim.sub','',true);
  o := public.create_store_order(shop,cart,'Guest','','+380990001111','Test','Test');
  if o.total_price <> 20010 or o.customer_discount_percent <> 0 then raise exception 'Guest received personal discount'; end if;

  perform set_config('request.jwt.claim.sub',outsider::text,true);
  execute 'set local role authenticated';
  if public.my_customer_discount(shop) is not null then raise exception 'Other customer discount exposed'; end if;
  if exists(select 1 from public.customer_discounts where store_id=shop) then raise exception 'Discount RLS bypass'; end if;
  begin
    perform public.set_customer_discount(shop,customer,buyer,90,'unlimited');
    raise exception 'Unauthorized discount edit accepted';
  exception when insufficient_privilege then null; end;
  execute 'reset role';
end;
$$;
rollback;
select 'customer discount checks passed; fixtures rolled back' as result;
