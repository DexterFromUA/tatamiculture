-- CRM operations. Amounts are in minor currency units. No payment/delivery adapters changed.
create table public.order_events (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  kind text not null,
  old_value text,
  new_value text,
  author_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index order_events_order_idx on public.order_events(order_id, created_at desc);
alter table public.order_events enable row level security;
create policy "read own or managed events" on public.order_events for select to authenticated using (
  exists(select 1 from public.orders o where o.id=order_id and (o.user_id=auth.uid() or public.is_store_member(o.store_id)))
);

create table public.customer_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  store_id uuid not null references public.stores(id),
  event_id uuid not null unique references public.order_events(id) on delete cascade,
  order_id uuid not null references public.orders(id) on delete cascade,
  receipt_code text not null,
  kind text not null,
  value text,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.customer_notifications enable row level security;
create policy "read own notifications" on public.customer_notifications for select to authenticated using(user_id=auth.uid());
create index customer_notifications_user_idx on public.customer_notifications(user_id,store_id,created_at desc);
create function public.mark_notification_read(p_id uuid) returns void language sql security definer set search_path=public as $$
  update public.customer_notifications set read_at=now() where id=p_id and user_id=auth.uid();
$$;
revoke all on function public.mark_notification_read(uuid) from public;
grant execute on function public.mark_notification_read(uuid) to authenticated;

create function public.capture_order_events() returns trigger language plpgsql security definer set search_path=public as $$
declare field text; before_value text; after_value text;
begin
  foreach field in array array['status','payment_status'] loop
    before_value := case when TG_OP='INSERT' then null else to_jsonb(old)->>field end;
    after_value := to_jsonb(new)->>field;
    if TG_OP='INSERT' or before_value is distinct from after_value then
      insert into public.order_events(order_id,kind,old_value,new_value,author_id)
      values(new.id,field,before_value,after_value,auth.uid());
    end if;
  end loop;
  return new;
end;
$$;
create trigger orders_capture_events after insert or update of status,payment_status on public.orders for each row execute function public.capture_order_events();
-- Preserve existing history without generating old notifications.
insert into public.order_events(order_id,kind,new_value,author_id,created_at)
select order_id,'status',status::text,author_id,created_at from public.order_status_history;

create function public.notify_order_event() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.kind in ('status','payment_status','return') then
    insert into public.customer_notifications(user_id,store_id,event_id,order_id,receipt_code,kind,value)
    select user_id,store_id,new.id,id,receipt_code,new.kind,new.new_value from public.orders where id=new.order_id and user_id is not null;
  end if;
  return new;
end; $$;
create trigger order_event_notification after insert on public.order_events for each row execute function public.notify_order_event();

create function public.receipt_events(p_code text) returns table(id uuid,kind text,old_value text,new_value text,created_at timestamptz)
language sql stable security definer set search_path=public as $$
 select e.id,e.kind,e.old_value,e.new_value,e.created_at from public.order_events e join public.orders o on o.id=e.order_id
 where o.receipt_code=p_code and e.kind in ('status','payment_status','return') order by e.created_at desc;
$$;
grant execute on function public.receipt_events(text) to anon,authenticated;

create table public.order_financials (
 order_id uuid primary key references public.orders(id) on delete cascade,
 cost_amount integer not null check(cost_amount>=0),
 updated_at timestamptz not null default now()
);
alter table public.order_financials enable row level security;
create policy "staff read financials" on public.order_financials for select to authenticated using(exists(select 1 from public.orders o where o.id=order_id and public.is_store_member(o.store_id)));
create table public.order_returns (
 id uuid primary key default gen_random_uuid(), order_id uuid not null references public.orders(id) on delete cascade,
 amount integer not null check(amount>0), reason text not null check(char_length(reason) between 1 and 1000),
 author_id uuid references auth.users(id), created_at timestamptz not null default now()
);
alter table public.order_returns enable row level security;
create policy "staff read returns" on public.order_returns for select to authenticated using(exists(select 1 from public.orders o where o.id=order_id and public.is_store_member(o.store_id)));
create function public.set_order_cost(p_order_id uuid,p_amount integer) returns void language plpgsql security definer set search_path=public as $$
declare previous_cost integer;
begin
 perform 1 from public.orders where id=p_order_id and public.is_store_member(store_id) for update;
 if not found then raise exception 'Access denied'; end if;
 select cost_amount into previous_cost from public.order_financials where order_id=p_order_id;
 insert into public.order_financials(order_id,cost_amount) values(p_order_id,p_amount) on conflict(order_id) do update set cost_amount=excluded.cost_amount,updated_at=now();
 if previous_cost is distinct from p_amount then
   insert into public.order_events(order_id,kind,old_value,new_value,author_id) values(p_order_id,'cost',previous_cost::text,p_amount::text,auth.uid());
 end if;
end; $$;
create function public.record_order_return(p_order_id uuid,p_amount integer,p_reason text) returns void language plpgsql security definer set search_path=public as $$
declare target public.orders; returned bigint;
begin
 select * into target from public.orders where id=p_order_id for update;
 if not found or not public.is_store_member(target.store_id) then raise exception 'Access denied'; end if;
 if target.status <> 'DELIVERED' then raise exception 'Only delivered orders can be returned'; end if;
 select coalesce(sum(amount),0) into returned from public.order_returns where order_id=p_order_id;
 if p_amount is null or p_amount<=0 or returned+p_amount>target.total_price then raise exception 'Invalid return amount'; end if;
 insert into public.order_returns(order_id,amount,reason,author_id) values(p_order_id,p_amount,trim(p_reason),auth.uid());
 insert into public.order_events(order_id,kind,new_value,author_id) values(p_order_id,'return',p_amount::text,auth.uid());
end; $$;
revoke all on function public.set_order_cost(uuid,integer),public.record_order_return(uuid,integer,text) from public;
grant execute on function public.set_order_cost(uuid,integer),public.record_order_return(uuid,integer,text) to authenticated;
grant select on public.order_events,public.customer_notifications,public.order_financials,public.order_returns to authenticated;
