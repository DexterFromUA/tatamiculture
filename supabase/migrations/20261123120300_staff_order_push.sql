create table public.crm_staff_push_preferences (
  store_id uuid not null,
  user_id uuid not null,
  primary key (store_id, user_id),
  foreign key (store_id, user_id) references public.store_members(store_id, user_id) on delete cascade
);
alter table public.crm_staff_push_preferences enable row level security;
revoke all on public.crm_staff_push_preferences from public, anon, authenticated, service_role;

alter table public.customer_push_deliveries
  add column staff_store_id uuid,
  add column staff_user_id uuid,
  add constraint customer_push_delivery_staff_preference foreign key (staff_store_id, staff_user_id)
    references public.crm_staff_push_preferences(store_id, user_id) match full on delete cascade;
create index customer_push_deliveries_staff_preference on public.customer_push_deliveries(staff_store_id, staff_user_id)
  where staff_store_id is not null;

create function public.crm_staff_push_settings(p_store_id uuid)
returns table(user_id uuid, display_name text, role public.staff_role, enabled boolean, has_subscription boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (select from public.store_members m
    where m.store_id = p_store_id and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then
    raise insufficient_privilege;
  end if;

  return query
  select m.user_id, coalesce(nullif(btrim(profile.name), ''), nullif(u.email::text, ''),
    '•••• ' || right(nullif(u.phone, ''), 4)), m.role, preference.user_id is not null,
    exists (select from public.customer_push_subscriptions s where s.user_id = m.user_id)
  from public.store_members m
  join auth.users u on u.id = m.user_id
  left join public.profiles profile on profile.id = m.user_id
  left join public.crm_staff_push_preferences preference on preference.store_id = m.store_id and preference.user_id = m.user_id
  where m.store_id = p_store_id and m.role in ('OWNER', 'MANAGER') and u.deleted_at is null and not u.is_anonymous
  order by m.role, 2, m.user_id;
end;
$$;

create function public.set_crm_staff_push_enabled(p_store_id uuid, p_user_id uuid, p_enabled boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select from public.store_members m
    where m.store_id = p_store_id and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then
    raise insufficient_privilege;
  end if;
  if p_enabled is null then raise invalid_parameter_value; end if;
  perform 1 from public.store_members m where m.store_id = p_store_id and m.user_id = p_user_id
    and m.role in ('OWNER', 'MANAGER') for update;
  if not found then raise insufficient_privilege; end if;

  if p_enabled then
    insert into public.crm_staff_push_preferences(store_id, user_id) values (p_store_id, p_user_id)
    on conflict do nothing;
  else
    delete from public.crm_staff_push_preferences p where p.store_id = p_store_id and p.user_id = p_user_id;
  end if;
end;
$$;

create function public.clear_demoted_staff_push_preference() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.crm_staff_push_preferences p where p.store_id = new.store_id and p.user_id = new.user_id;
  return new;
end;
$$;

create trigger clear_demoted_staff_push_preference after update of role on public.store_members
  for each row when (old.role in ('OWNER', 'MANAGER') and new.role = 'CONTENT')
  execute function public.clear_demoted_staff_push_preference();

create function public.queue_crm_new_order_push() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.split_origin_id is not null or new.status <> 'IN_PROGRESS' then return new; end if;
  if tg_op = 'UPDATE' then
    -- The workflow marks first-time confirmation of a legacy online reservation as new.
    if not new.is_new or old.is_new then return new; end if;
  elsif new.payment_method = 'ONLINE' and new.payment_status <> 'PAID' then
    return new;
  end if;

  insert into public.customer_push_deliveries(subscription_id, kind, path, staff_store_id, staff_user_id)
  select s.id, 'staff_new_order', '/admin#order-' || new.id::text, m.store_id, m.user_id
  from public.crm_staff_push_preferences p
  join public.store_members m on m.store_id = p.store_id and m.user_id = p.user_id
  join auth.users u on u.id = m.user_id
  join public.customer_push_subscriptions s on s.user_id = m.user_id
  where p.store_id = new.store_id and m.role in ('OWNER', 'MANAGER') and u.deleted_at is null and not u.is_anonymous
  for key share of p, s;
  return new;
end;
$$;

create trigger queue_crm_new_order_push after insert or update of status on public.orders
  for each row execute function public.queue_crm_new_order_push();

revoke all on function public.crm_staff_push_settings(uuid), public.set_crm_staff_push_enabled(uuid, uuid, boolean),
  public.clear_demoted_staff_push_preference(), public.queue_crm_new_order_push() from public, anon, authenticated, service_role;
grant execute on function public.crm_staff_push_settings(uuid), public.set_crm_staff_push_enabled(uuid, uuid, boolean) to authenticated;
notify pgrst, 'reload schema';
