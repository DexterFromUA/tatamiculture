-- All fixtures and changes are rolled back. Run after the CRM migrations.
begin;
do $$
declare
 manager uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); shop uuid; product uuid; variant uuid; replacement uuid;
 ord uuid; item uuid; ret uuid:=gen_random_uuid(); copy uuid; source_customer uuid; target_customer uuid; guest_order uuid;
begin
 insert into auth.users(id,raw_user_meta_data) values(manager,'{"name":"CRM verification"}'),(outsider,'{"name":"CRM outsider"}');
 insert into public.stores(slug,name,contact_email,contact_phone,contact_city) values('verify-'||substr(manager::text,1,8),'Verification','test@example.invalid','000','Test') returning id into shop;
 insert into public.store_members(store_id,user_id,role) values(shop,manager,'OWNER');
 perform set_config('request.jwt.claim.sub',manager::text,true);
 insert into public.products(store_id,name) values(shop,'Test product') returning id into product;
 insert into public.product_variants(product_id,name,price,stock_quantity) values(product,'M',10000,2) returning id into variant;
 insert into public.product_variants(product_id,name,price,stock_quantity) values(product,'L',10000,2) returning id into replacement;
 insert into public.variant_costs values(variant,4000);
 execute 'set local role authenticated';
 perform public.adjust_catalog_stock(variant,'receipt',2,'test receipt',ret);
 perform public.adjust_catalog_stock(variant,'receipt',2,'test receipt',ret);
 if (select stock_quantity from public.product_variants where id=variant)<>4 then raise exception 'Stock receipt failed'; end if;
 begin
  perform public.adjust_catalog_stock(variant,'writeoff',99,'invalid');
  raise exception 'Overdraw accepted';
 exception when check_violation then null; end;
 if (select count(*) from public.stock_movements where variant_id=variant)<>1 then raise exception 'Stock history failed'; end if;
 copy:=public.duplicate_catalog_product(product);
 if (select is_active from public.products where id=copy) or (select sum(stock_quantity) from public.product_variants where product_id=copy)<>0 then raise exception 'Unsafe duplicate'; end if;
 execute 'reset role';
 insert into public.orders(store_id,user_id,customer_name,customer_email,customer_phone,delivery_city,delivery_address,total_price,currency,status)
 values(shop,manager,'Test','test@example.invalid','+380990001111','Test','Test',30000,'UAH','DELIVERED') returning id,crm_customer_id into ord,target_customer;
 insert into public.order_items(order_id,product_id,variant_id,product_name,variant_name,quantity,unit_price,line_total) values(ord,product,variant,'Test product','M',3,10000,30000) returning id into item;
 set constraints aggregate_order_cost immediate;
 if (select cost_amount from public.order_financials where order_id=ord)<>12000 then raise exception 'Cost aggregation failed'; end if;
 update public.variant_costs set cost_amount=5000 where variant_id=variant;
 if (select unit_cost from public.order_item_costs where item_id=item)<>4000 then raise exception 'Historical cost changed'; end if;
 insert into public.orders(store_id,customer_name,customer_email,customer_phone,delivery_city,delivery_address,total_price,currency)
 values(shop,'Guest','guest@example.invalid','+380990001111','Test','Test',0,'UAH') returning id,crm_customer_id into guest_order,source_customer;
 perform public.merge_crm_customers(source_customer,target_customer);
 if (select crm_customer_id from public.orders where id=guest_order)<>target_customer or (select user_id from public.orders where id=guest_order) is not null then raise exception 'Merge altered account access'; end if;
 execute 'set local role authenticated';
 perform public.request_item_return(ret,item,1,'size',true,replacement);
 perform public.request_item_return(ret,item,1,'size',true,replacement);
 perform public.advance_item_return(ret,'received');
 perform public.advance_item_return(ret,'received');
 if (select stock_quantity from public.product_variants where id=variant)<>5 then raise exception 'Restock not idempotent'; end if;
 perform public.advance_item_return(ret,'completed');
 perform public.advance_item_return(ret,'completed');
 if (select stock_quantity from public.product_variants where id=replacement)<>1 then raise exception 'Exchange not idempotent'; end if;
 ret:=gen_random_uuid();
 perform public.request_item_return(ret,item,1,'refund',false,null);
 perform public.advance_item_return(ret,'received');
 perform public.advance_item_return(ret,'completed');
 perform public.advance_item_return(ret,'completed');
 if (select sum(amount) from public.order_returns where order_id=ord)<>10000 then raise exception 'Refund accounting duplicated'; end if;
 update public.product_variants set stock_quantity=0 where id=variant;
 perform public.subscribe_restock(variant,true);
 perform public.adjust_catalog_stock(variant,'receipt',1,'restock');
 if not exists(select 1 from public.restock_subscriptions where variant_id=variant and notified_at is not null) then raise exception 'Restock notice missing'; end if;
 perform set_config('request.jwt.claim.sub',outsider::text,true);
 if exists(select 1 from public.variant_costs) or exists(select 1 from public.crm_customers) then raise exception 'Private data leaked'; end if;
 begin
  perform public.advance_item_return(ret,'completed');
  raise exception 'Unauthorized access allowed';
 exception when raise_exception then
  if SQLERRM<>'Access denied' then raise; end if;
 end;
 execute 'reset role';
end; $$;
select 'CRM workflow checks passed' as result;

rollback;
