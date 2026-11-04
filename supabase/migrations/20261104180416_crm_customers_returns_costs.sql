-- CRM identity is independent of account ownership and receipt access.
create table public.crm_customers (
 id uuid primary key default gen_random_uuid(),
 store_id uuid not null references public.stores(id),
 name text not null, phone text not null default '', email text not null default '',
 notes text not null default '' check(length(notes)<=20000), tags text[] not null default '{}' check(cardinality(tags)<=200),
 created_at timestamptz not null default now()
);
create table public.crm_customer_keys (
 store_id uuid not null references public.stores(id), key text not null,
 customer_id uuid not null references public.crm_customers(id),
 primary key(store_id,key)
);
alter table public.orders add column crm_customer_id uuid references public.crm_customers(id);
create index orders_crm_customer on public.orders(crm_customer_id);
alter table public.crm_customers enable row level security;
alter table public.crm_customer_keys enable row level security;
create policy "staff read CRM customers" on public.crm_customers for select to authenticated using(public.is_store_member(store_id));
create policy "staff edit CRM customers" on public.crm_customers for update to authenticated using(public.is_store_member(store_id)) with check(public.is_store_member(store_id));
create policy "staff read CRM identities" on public.crm_customer_keys for select to authenticated using(public.is_store_member(store_id));
grant select,update on public.crm_customers to authenticated;
grant select on public.crm_customer_keys to authenticated;

create function public.crm_identity(p_store uuid,p_key text,p_name text,p_phone text,p_email text) returns uuid
language plpgsql security definer set search_path='' as $$
declare customer uuid;
begin
 perform pg_advisory_xact_lock(hashtextextended(p_store::text,0));
 select customer_id into customer from public.crm_customer_keys where store_id=p_store and key=p_key;
 if customer is null then
  insert into public.crm_customers(store_id,name,phone,email) values(p_store,p_name,p_phone,p_email) returning id into customer;
  insert into public.crm_customer_keys values(p_store,p_key,customer);
 end if;
 return customer;
end; $$;
revoke all on function public.crm_identity(uuid,text,text,text,text) from public;
create function public.attach_crm_customer() returns trigger language plpgsql security definer set search_path='' as $$
declare identity_key text;
begin
 identity_key := case when new.user_id is not null then 'user:'||new.user_id::text
  when length(regexp_replace(new.customer_phone,'[^0-9]','','g'))>=9 then 'phone:'||regexp_replace(new.customer_phone,'[^0-9]','','g')
  when trim(new.customer_email)<>'' then 'email:'||lower(trim(new.customer_email)) else 'order:'||new.id::text end;
 new.crm_customer_id := public.crm_identity(new.store_id,identity_key,new.customer_name,new.customer_phone,new.customer_email);
 return new;
end; $$;
create trigger attach_crm_customer before insert on public.orders for each row execute function public.attach_crm_customer();
-- Populate registered customers, including those without orders.
do $$
declare c record; o record; identity_key text; customer uuid;
begin
 for c in select sc.store_id,sc.user_id,p.name,p.phone from public.store_customers sc join public.profiles p on p.id=sc.user_id loop
  customer := public.crm_identity(c.store_id,'user:'||c.user_id::text,c.name,c.phone,'');
  update public.crm_customers set notes=coalesce((select string_agg(n.body,E'\n\n' order by n.created_at) from public.customer_notes n where n.store_id=c.store_id and n.customer_id=c.user_id),''),
   tags=array(select t.name from public.customer_tags t join public.customer_tag_assignments a on a.tag_id=t.id where t.store_id=c.store_id and a.customer_id=c.user_id) where id=customer;
 end loop;
 for o in select * from public.orders order by created_at loop
  identity_key := case when o.user_id is not null then 'user:'||o.user_id::text
   when length(regexp_replace(o.customer_phone,'[^0-9]','','g'))>=9 then 'phone:'||regexp_replace(o.customer_phone,'[^0-9]','','g')
   when trim(o.customer_email)<>'' then 'email:'||lower(trim(o.customer_email)) else 'order:'||o.id::text end;
  customer := public.crm_identity(o.store_id,identity_key,o.customer_name,o.customer_phone,o.customer_email);
  update public.orders set crm_customer_id=customer where id=o.id;
  update public.crm_customers set created_at=least(created_at,o.created_at),email=case when email='' then o.customer_email else email end where id=customer;
 end loop;
end; $$;
create function public.register_crm_customer() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform public.crm_identity(new.store_id,'user:'||new.user_id::text,p.name,p.phone,'') from public.profiles p where p.id=new.user_id;
 return new;
end; $$;
create trigger register_crm_customer after insert on public.store_customers for each row execute function public.register_crm_customer();
create function public.merge_crm_customers(p_source uuid,p_target uuid) returns void language plpgsql security definer set search_path='' as $$
declare source public.crm_customers; target public.crm_customers;
begin
 select * into source from public.crm_customers where id=p_source;
 if not found or not coalesce(public.is_store_member(source.store_id),false) then raise exception 'Access denied'; end if;
 perform pg_advisory_xact_lock(hashtextextended(source.store_id::text,0));
 select * into source from public.crm_customers where id=p_source for update;
 select * into target from public.crm_customers where id=p_target for update;
 if source.id is null or target.id is null or source.id=target.id or source.store_id<>target.store_id then raise exception 'Invalid customer selection'; end if;
 update public.orders set crm_customer_id=p_target where crm_customer_id=p_source;
 update public.crm_customer_keys set customer_id=p_target where customer_id=p_source;
 update public.crm_customers set notes=concat_ws(E'\n\n',nullif(target.notes,''),nullif(source.notes,'')),
  tags=array(select distinct unnest(target.tags||source.tags)),created_at=least(target.created_at,source.created_at),
  phone=coalesce(nullif(target.phone,''),source.phone),email=coalesce(nullif(target.email,''),source.email) where id=p_target;
 delete from public.crm_customers where id=p_source;
end; $$;
revoke all on function public.merge_crm_customers(uuid,uuid) from public;
grant execute on function public.merge_crm_customers(uuid,uuid) to authenticated;

-- Costs are private. Public product and order-item reads never expose them.
create table public.variant_costs (
 variant_id uuid primary key references public.product_variants(id) on delete cascade,
 cost_amount integer not null check(cost_amount>=0)
);
create table public.order_item_costs (
 item_id uuid primary key references public.order_items(id) on delete cascade,
 unit_cost integer check(unit_cost>=0)
);
alter table public.variant_costs enable row level security;
alter table public.order_item_costs enable row level security;
create policy "staff manage variant costs" on public.variant_costs for all to authenticated
 using(exists(select 1 from public.product_variants v join public.products p on p.id=v.product_id where v.id=variant_id and public.is_store_member(p.store_id)))
 with check(exists(select 1 from public.product_variants v join public.products p on p.id=v.product_id where v.id=variant_id and public.is_store_member(p.store_id)));
create policy "staff read cost snapshots" on public.order_item_costs for select to authenticated using(exists(select 1 from public.order_items i join public.orders o on o.id=i.order_id where i.id=item_id and public.is_store_member(o.store_id)));
grant select,insert,update,delete on public.variant_costs to authenticated;
grant select on public.order_item_costs to authenticated;
create function public.snapshot_item_cost() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.order_item_costs(item_id,unit_cost) values(new.id,(select cost_amount from public.variant_costs where variant_id=new.variant_id));
 return new;
end; $$;
create trigger snapshot_item_cost after insert on public.order_items for each row execute function public.snapshot_item_cost();
create function public.aggregate_order_cost() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.order_items i left join public.order_item_costs c on c.item_id=i.id where i.order_id=new.order_id and c.unit_cost is null) then
  insert into public.order_financials(order_id,cost_amount)
   select new.order_id,sum(i.quantity::bigint*c.unit_cost)::integer from public.order_items i join public.order_item_costs c on c.item_id=i.id where i.order_id=new.order_id
   on conflict(order_id) do nothing;
 end if;
 return new;
end; $$;
create constraint trigger aggregate_order_cost after insert on public.order_items deferrable initially deferred for each row execute function public.aggregate_order_cost();

create table public.item_returns (
 id uuid primary key,
 order_id uuid not null references public.orders(id), item_id uuid not null references public.order_items(id),
 quantity integer not null check(quantity>0), reason text not null check(length(reason) between 1 and 1000),
 restock boolean not null, replacement_variant uuid references public.product_variants(id),
 status text not null default 'requested' check(status in ('requested','received','completed','cancelled')),
 refund_amount integer not null check(refund_amount>=0), refund_record_id uuid references public.order_returns(id),
 author_id uuid, created_at timestamptz not null default now()
);
alter table public.item_returns enable row level security;
create policy "staff read item returns" on public.item_returns for select to authenticated using(exists(select 1 from public.orders o where o.id=order_id and public.is_store_member(o.store_id)));
grant select on public.item_returns to authenticated;
create function public.request_item_return(p_id uuid,p_item uuid,p_quantity integer,p_reason text,p_restock boolean,p_replacement uuid default null)
returns void language plpgsql security definer set search_path='' as $$
declare item public.order_items; target public.orders; used bigint; replacement public.product_variants;
begin
 select * into item from public.order_items where id=p_item;
 select * into target from public.orders where id=item.order_id for update;
 if target.id is null or not coalesce(public.is_store_member(target.store_id),false) then raise exception 'Access denied'; end if;
 if exists(select 1 from public.item_returns where id=p_id and order_id=target.id) then return; end if;
 if target.status<>'DELIVERED' then raise exception 'Only delivered orders can be returned'; end if;
 select coalesce(sum(quantity),0) into used from public.item_returns where item_id=p_item and status<>'cancelled';
 if p_quantity is null or p_quantity<1 or p_quantity+used>item.quantity then raise exception 'Invalid return quantity'; end if;
 if p_replacement is not null then
  select * into replacement from public.product_variants where id=p_replacement;
  if replacement.id is null or replacement.product_id is distinct from item.product_id or replacement.id=item.variant_id
    or replacement.price<>item.unit_price or replacement.is_preorder then raise exception 'Select another size of the same product at the same price'; end if;
 end if;
 insert into public.item_returns(id,order_id,item_id,quantity,reason,restock,replacement_variant,refund_amount,author_id)
 values(p_id,target.id,p_item,p_quantity,trim(p_reason),p_restock,p_replacement,case when p_replacement is null then item.unit_price*p_quantity else 0 end,auth.uid());
 insert into public.order_events(order_id,kind,new_value,author_id) values(target.id,'item_return','requested',auth.uid());
end; $$;
create function public.advance_item_return(p_id uuid,p_status text) returns void language plpgsql security definer set search_path='' as $$
declare r public.item_returns; item public.order_items; target public.orders; refunded bigint; refund_id uuid;
begin
 select o.* into target from public.orders o join public.item_returns pending on pending.order_id=o.id where pending.id=p_id for update of o;
 if target.id is null or not coalesce(public.is_store_member(target.store_id),false) then raise exception 'Access denied'; end if;
 select * into r from public.item_returns where id=p_id for update;
 if r.status=p_status then return; end if;
 if not ((r.status='requested' and p_status in ('received','cancelled')) or (r.status='received' and p_status='completed')) then raise exception 'Invalid return transition'; end if;
 select * into item from public.order_items where id=r.item_id;
 if p_status='received' and r.restock then
  if item.variant_id is null then raise exception 'Original variant was removed'; end if;
  perform set_config('tatami.stock_kind','return',true);
  perform set_config('tatami.stock_reason',r.reason,true);
  update public.product_variants set stock_quantity=stock_quantity+r.quantity where id=item.variant_id;
 end if;
 if p_status='completed' then
  if r.replacement_variant is not null then
   perform set_config('tatami.stock_kind','exchange',true);
   perform set_config('tatami.stock_reason',r.reason,true);
   update public.product_variants set stock_quantity=stock_quantity-r.quantity where id=r.replacement_variant and stock_quantity>=r.quantity;
   if not found then raise exception 'Replacement is out of stock'; end if;
  elsif r.refund_amount>0 then
   select coalesce(sum(amount),0) into refunded from public.order_returns where order_id=r.order_id;
   if refunded+r.refund_amount>target.total_price then raise exception 'Return exceeds order total'; end if;
   insert into public.order_returns(order_id,amount,reason,author_id) values(r.order_id,r.refund_amount,r.reason,auth.uid()) returning id into refund_id;
   insert into public.order_events(order_id,kind,new_value,author_id) values(r.order_id,'return',r.refund_amount::text,auth.uid());
  end if;
 end if;
 update public.item_returns set status=p_status,refund_record_id=refund_id where id=p_id;
 insert into public.order_events(order_id,kind,old_value,new_value,author_id) values(r.order_id,'item_return',r.status,p_status,auth.uid());
end; $$;
revoke all on function public.request_item_return(uuid,uuid,integer,text,boolean,uuid),public.advance_item_return(uuid,text) from public;
grant execute on function public.request_item_return(uuid,uuid,integer,text,boolean,uuid),public.advance_item_return(uuid,text) to authenticated;

create table public.restock_subscriptions (
 user_id uuid not null references auth.users(id) on delete cascade,
 variant_id uuid not null references public.product_variants(id) on delete cascade,
 notified_at timestamptz, created_at timestamptz not null default now(),
 primary key(user_id,variant_id)
);
alter table public.restock_subscriptions enable row level security;
create policy "read own restock subscriptions" on public.restock_subscriptions for select to authenticated using(user_id=auth.uid());
create policy "staff read restock demand" on public.restock_subscriptions for select to authenticated using(exists(select 1 from public.product_variants v join public.products p on p.id=v.product_id where v.id=variant_id and public.is_store_member(p.store_id)));
grant select on public.restock_subscriptions to authenticated;
create function public.subscribe_restock(p_variant uuid,p_subscribe boolean) returns void language plpgsql security definer set search_path='' as $$
declare available integer;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if not p_subscribe then delete from public.restock_subscriptions where user_id=auth.uid() and variant_id=p_variant; return; end if;
 select v.stock_quantity into available from public.product_variants v join public.products p on p.id=v.product_id where v.id=p_variant and p.is_active and not v.is_preorder for update of v;
 if not found or available>0 then raise exception 'Variant is already available or unavailable for subscription'; end if;
 insert into public.restock_subscriptions(user_id,variant_id) values(auth.uid(),p_variant)
 on conflict(user_id,variant_id) do update set notified_at=null;
end; $$;
revoke all on function public.subscribe_restock(uuid,boolean) from public;
grant execute on function public.subscribe_restock(uuid,boolean) to authenticated;
create function public.notify_restock() returns trigger language plpgsql security definer set search_path='' as $$
begin
 update public.restock_subscriptions set notified_at=now() where variant_id=new.id and notified_at is null;
 return new;
end; $$;
create trigger notify_restock after update of stock_quantity on public.product_variants for each row
 when(old.stock_quantity=0 and new.stock_quantity>0) execute function public.notify_restock();

create or replace function public.duplicate_catalog_product(p_product uuid)
returns uuid language plpgsql security invoker set search_path='' as $$
declare source public.products; copy_id uuid;
begin
 select * into source from public.products where id=p_product;
 if not found or not coalesce(public.is_store_member(source.store_id),false) then raise exception 'Manager access required'; end if;
 insert into public.products(store_id,category_id,name,description,is_active,position,size_guide,composition,care_instructions)
 values(source.store_id,source.category_id,source.name,source.description,false,source.position,source.size_guide,source.composition,source.care_instructions) returning id into copy_id;
 insert into public.product_variants(product_id,name,sku,price,compare_at_price,stock_quantity,is_preorder,position,low_stock_threshold)
 select copy_id,name,null,price,compare_at_price,0,is_preorder,position,low_stock_threshold from public.product_variants where product_id=p_product;
 insert into public.product_images(product_id,public_url,storage_path,position)
 select copy_id,public_url,storage_path,position from public.product_images where product_id=p_product;
 return copy_id;
end; $$;
