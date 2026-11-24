create table public.crm_audit_log (
  id bigint generated always as identity primary key,
  store_id uuid not null,
  occurred_at timestamptz not null default clock_timestamp(),
  actor_id uuid,
  actor_name text,
  area text not null check (area in ('orders', 'catalog', 'customers', 'settings', 'notifications', 'exports')),
  entity text not null,
  entity_id text,
  action text not null,
  fields text[] not null default '{}',
  details jsonb not null default '{}'
);
create index crm_audit_log_store_id_idx on public.crm_audit_log (store_id, id desc);
create index crm_audit_log_store_area_idx on public.crm_audit_log (store_id, area, id desc);
alter table public.crm_audit_log enable row level security;
revoke all on public.crm_audit_log from public, anon, authenticated, service_role;

create function public.write_crm_audit_event(
  p_store uuid, p_actor uuid, p_area text, p_entity text, p_entity_id text,
  p_action text, p_fields text[] default '{}', p_details jsonb default '{}'
) returns void language sql set search_path = '' as $$
  insert into public.crm_audit_log (store_id, actor_id, actor_name, area, entity, entity_id, action, fields, details)
  values (p_store, p_actor, (select left(nullif(btrim(p.name), ''), 100) from public.profiles p where p.id = p_actor),
    p_area, p_entity, p_entity_id, p_action, p_fields, p_details);
$$;
revoke all on function public.write_crm_audit_event(uuid, uuid, text, text, text, text, text[], jsonb)
  from public, anon, authenticated, service_role;

-- Record changed field names, and keep values only for structured operational data.
create function public.capture_crm_audit_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  before_row jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) else '{}'::jsonb end;
  after_row jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) else '{}'::jsonb end;
  subject jsonb := case when tg_op = 'DELETE' then before_row else after_row end;
  table_name text := tg_table_name;
  area text := tg_argv[0];
  entity_id text := coalesce(subject->>'id', subject->>'order_id', subject->>'item_id',
    subject->>'variant_id', subject->>'product_id', subject->>'customer_id', subject->>'user_id', subject->>'store_id');
  store uuid := (subject->>'store_id')::uuid;
  actor uuid := auth.uid();
  subject_order uuid := (subject->>'order_id')::uuid;
  action text := lower(tg_op);
  changed_fields text[] := '{}';
  event_details jsonb := '{}';
  actor_is_staff boolean;
begin
  if table_name = 'shop_settings' then
    store := (subject->>'id')::uuid;
  elsif table_name in ('product_variants', 'product_images', 'product_costs') then
    select p.store_id into store from public.products p where p.id = (subject->>'product_id')::uuid;
  elsif table_name = 'variant_costs' then
    select p.store_id into store from public.product_variants v join public.products p on p.id = v.product_id
    where v.id = (subject->>'variant_id')::uuid;
  elsif table_name = 'order_item_costs' then
    select o.store_id, o.id into store, subject_order from public.order_items i join public.orders o on o.id = i.order_id
    where i.id = (subject->>'item_id')::uuid;
  elsif store is null and subject_order is not null then
    select o.store_id into store from public.orders o where o.id = subject_order;
  end if;
  if store is null then return null; end if;

  if actor is null and table_name in ('orders', 'order_ttn_reservations') then
    actor := coalesce(nullif(current_setting('tatami.ttn_actor', true), ''),
      nullif(current_setting('tatami.audit_tracking_actor', true), ''))::uuid;
  elsif actor is null and table_name = 'order_events' then
    actor := (subject->>'author_id')::uuid;
  elsif actor is null and table_name = 'order_cancellation_refunds' then
    if subject->>'method' = 'manual' or subject->>'status' = 'processing' then
      actor := (subject->>'requested_by')::uuid;
    end if;
  end if;
  actor_is_staff := actor is not null and exists (
    select from public.store_members m where m.store_id = store and m.user_id = actor
  );

  if tg_op = 'UPDATE' then
    select array(select k from jsonb_object_keys(after_row) k
      where (before_row->k) is distinct from (after_row->k)
        and k not in ('updated_at', 'nova_poshta_status_updated_at')
      order by k) into changed_fields;
    if cardinality(changed_fields) = 0 then return null; end if;
  end if;

  if table_name = 'orders' and tg_op = 'UPDATE' then
    if not actor_is_staff then
      if not changed_fields && array['status', 'payment_status', 'nova_poshta_status_code'] then return null; end if;
      actor := null;
      changed_fields := array(select f from unnest(changed_fields) f
        where f in ('status', 'payment_status', 'nova_poshta_status_code'));
    end if;
    if 'nova_poshta_ttn' = any(changed_fields) then
      action := case
        when after_row->>'nova_poshta_ttn' is null then 'ttn_unlinked'
        when current_setting('tatami.audit_ttn_outcome', true) = 'created' then 'ttn_created'
        else 'ttn_linked'
      end;
    elsif 'status' = any(changed_fields) then
      action := 'order_status';
    end if;
  elsif table_name = 'order_cancellation_refunds' then
    if tg_op = 'DELETE' or (tg_op = 'UPDATE' and not changed_fields && array['status', 'method', 'id']) then return null; end if;
    actor := case when actor_is_staff then actor end;
    action := 'refund';
  elsif not actor_is_staff then
    return null;
  end if;

  if table_name = 'order_events' then
    action := subject->>'kind';
    if action not in ('merge', 'split_order', 'refund_review') then return null; end if;
    table_name := 'orders';
    entity_id := subject_order::text;
  elsif table_name = 'crm_customer_keys' and tg_op = 'DELETE' and subject->>'key' like 'user:%' then
    action := 'customer_account_removed';
  elsif table_name = 'order_ttn_reservations' then
    if tg_op <> 'DELETE' or exists (
      select from public.orders o where o.id = subject_order and o.nova_poshta_ttn is not null
    ) then return null; end if;
    table_name := 'orders';
    action := 'ttn_attempt_closed';
  elsif table_name in ('customer_push_broadcasts', 'crm_sms_requests') then
    if tg_op <> 'UPDATE' or coalesce((subject->>'recipient_count')::int, 0) <= 0 then return null; end if;
    action := case when table_name = 'crm_sms_requests' then 'sms_queued' else 'push_queued' end;
    event_details := jsonb_build_object('recipient_count', subject->'recipient_count');
    changed_fields := '{}';
  end if;

  if subject_order is not null then
    event_details := event_details || jsonb_build_object('order_id', subject_order);
  end if;
  if subject ? 'product_id' then
    event_details := event_details || jsonb_build_object('product_id', subject->'product_id');
  end if;

  select event_details || coalesce(jsonb_object_agg(k, jsonb_build_object('before', before_row->k, 'after', after_row->k)), '{}')
    into event_details
  from unnest(case when tg_op = 'UPDATE' then changed_fields else array(select jsonb_object_keys(subject)) end) k
  where k in ('status', 'payment_status', 'nova_poshta_status_code', 'payment_method', 'method', 'role',
    'stock_quantity', 'quantity', 'amount', 'percent', 'enabled', 'is_active', 'is_new', 'allow_out_of_stock',
    'payment_test_mode', 'cash_on_delivery', 'liqpay', 'monobank', 'auto_update_order_status',
    'order_push_enabled', 'order_sms_enabled', 'restock_sms_enabled', 'sms_notifications_enabled', 'previous_quantity',
    'nova_poshta_tracking_interval_minutes', 'low_stock_threshold', 'price', 'sale_price', 'cost_amount');

  perform public.write_crm_audit_event(store, actor, area, table_name, entity_id, action, changed_fields, event_details);
  return null;
end;
$$;
revoke all on function public.capture_crm_audit_change() from public, anon, authenticated, service_role;

do $$
declare rule record;
begin
  for rule in select * from (values
    ('orders', 'orders'), ('order_items', 'orders'), ('order_events', 'orders'),
    ('order_ttn_reservations', 'orders'), ('order_returns', 'orders'), ('item_returns', 'orders'),
    ('order_financials', 'orders'), ('order_item_costs', 'orders'), ('order_cancellation_refunds', 'orders'),
    ('products', 'catalog'), ('product_variants', 'catalog'), ('categories', 'catalog'),
    ('product_categories', 'catalog'), ('product_images', 'catalog'), ('product_costs', 'catalog'), ('variant_costs', 'catalog'),
    ('stock_movements', 'catalog'), ('crm_customers', 'customers'), ('crm_customer_keys', 'customers'),
    ('customer_discounts', 'customers'), ('store_members', 'settings'), ('store_payment_methods', 'settings'),
    ('delivery_settings', 'settings'), ('shop_settings', 'settings'), ('storefront_theme_settings', 'settings'),
    ('storefront_banners', 'settings'), ('storefront_contacts', 'settings'),
    ('crm_staff_push_preferences', 'notifications'), ('crm_staff_sms_preferences', 'notifications'),
    ('customer_push_broadcasts', 'notifications'), ('crm_sms_requests', 'notifications')
  ) targets(name, area)
  loop
    execute format('create trigger crm_audit_change after insert or update or delete on public.%I
      for each row execute function public.capture_crm_audit_change(%L)', rule.name, rule.area);
  end loop;
end;
$$;

create function public.crm_audit_log_page(
  p_store_id uuid, p_page integer, p_page_size integer, p_area text default null, p_search text default ''
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare search text := lower(left(btrim(coalesce(p_search, '')), 100));
begin
  if not exists (select from public.store_members m
    where m.store_id = p_store_id and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then
    raise insufficient_privilege using message = 'Manager access required';
  end if;
  return (
    with matches as not materialized (
      select a.id from public.crm_audit_log a
      where a.store_id = p_store_id and (p_area is null or a.area = p_area)
        and (search = '' or strpos(lower(concat_ws(' ', a.actor_name, a.actor_id::text,
            a.entity_id, a.details->>'order_id', a.details->>'product_id', a.details->>'merged_customer_id')), search) > 0)
    ), paging as (
      select t.total, w.* from (select count(*) as total from matches) t
      cross join lateral public.crm_page_window(t.total, p_page, least(100, coalesce(p_page_size, 50))) w
    ), ids as (
      select id from matches order by id desc
      limit (select page_size from paging) offset (select row_offset from paging)
    )
    select jsonb_build_object('page', paging.page, 'total', paging.total, 'rows',
      coalesce((select jsonb_agg(to_jsonb(a) - 'store_id' order by a.id desc)
        from ids join public.crm_audit_log a using (id)), '[]'::jsonb))
    from paging
  );
end;
$$;

create function public.record_crm_export(p_store_id uuid, p_entity text, p_count integer)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_store_member(p_store_id) then raise insufficient_privilege; end if;
  if p_entity is null or p_entity not in ('orders', 'crm_customers') or p_count is null or p_count < 0 then
    raise invalid_parameter_value;
  end if;
  perform public.write_crm_audit_event(p_store_id, auth.uid(), 'exports', p_entity, null, 'export_csv',
    p_details => jsonb_build_object('row_count', p_count));
end;
$$;

create function public.record_crm_sms_provider_change(p_store_id uuid, p_actor uuid, p_before text, p_after text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select from public.store_members m
    where m.store_id = p_store_id and m.user_id = p_actor and m.role in ('OWNER', 'MANAGER')) then raise insufficient_privilege; end if;
  if p_before not in ('twilio', 'kyivstar', 'smsclub') or p_after not in ('twilio', 'kyivstar', 'smsclub')
    or p_before is null or p_after is null then raise invalid_parameter_value; end if;
  if p_before <> p_after then
    perform public.write_crm_audit_event(p_store_id, p_actor, 'settings', 'sms_provider', null, 'update',
      array['provider'], jsonb_build_object('provider', jsonb_build_object('before', p_before, 'after', p_after)));
  end if;
end;
$$;

create function public.apply_crm_nova_poshta_tracking(
  p_order_id uuid, p_actor uuid, p_ttn text, p_code text, p_status text,
  p_checked_at timestamptz, p_paid_storage_from date
) returns boolean language plpgsql security definer set search_path = '' as $$
declare store uuid; changed boolean;
begin
  select o.store_id into store from public.orders o join public.store_members m on m.store_id = o.store_id
  where o.id = p_order_id and o.nova_poshta_ttn = p_ttn and m.user_id = p_actor;
  if not found then raise insufficient_privilege; end if;
  perform set_config('tatami.audit_tracking_actor', p_actor::text, true);
  changed := public.apply_nova_poshta_tracking_with_storage(store, p_ttn, p_code, p_status, p_checked_at, p_paid_storage_from);
  perform set_config('tatami.audit_tracking_actor', '', true);
  perform public.write_crm_audit_event(store, p_actor, 'orders', 'orders', p_order_id::text, 'tracking_refresh');
  return changed;
end;
$$;

create or replace function public.settle_order_ttn_as_staff(
  p_order_id uuid, p_attempt_id uuid, p_outcome text, p_ttn text, p_document_ref text, p_actor uuid
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (
    select from public.orders o join public.store_members m on m.store_id = o.store_id
    where o.id = p_order_id and m.user_id = p_actor
  ) then raise insufficient_privilege using message = 'Store staff access required'; end if;
  perform set_config('tatami.ttn_actor', p_actor::text, true);
  perform set_config('tatami.audit_ttn_outcome', coalesce(p_outcome, ''), true);
  if p_attempt_id is null and p_outcome = 'attached' then
    perform public.attach_verified_order_ttn(p_order_id, p_ttn, p_document_ref);
  else
    perform public.finish_order_ttn_attempt(p_order_id, p_attempt_id, p_outcome, p_ttn, p_document_ref);
  end if;
  perform set_config('tatami.audit_ttn_outcome', '', true);
  perform set_config('tatami.ttn_actor', '', true);
end;
$$;

create or replace function public.merge_crm_customers(p_source uuid, p_target uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare source public.crm_customers; target public.crm_customers;
begin
  select * into source from public.crm_customers where id = p_source;
  if not found or not coalesce(public.is_store_member(source.store_id), false) then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(hashtextextended(source.store_id::text, 0));
  select * into source from public.crm_customers where id = p_source for update;
  select * into target from public.crm_customers where id = p_target for update;
  if source.id is null or target.id is null or source.id = target.id or source.store_id <> target.store_id then
    raise exception 'Invalid customer selection';
  end if;
  update public.orders set crm_customer_id = p_target where crm_customer_id = p_source;
  update public.crm_customer_keys set customer_id = p_target where customer_id = p_source;
  update public.crm_customers set notes = concat_ws(E'\n\n', nullif(target.notes, ''), nullif(source.notes, '')),
    tags = array(select distinct unnest(target.tags || source.tags)), created_at = least(target.created_at, source.created_at),
    phone = coalesce(nullif(target.phone, ''), source.phone), email = coalesce(nullif(target.email, ''), source.email)
    where id = p_target;
  delete from public.crm_customers where id = p_source;
  perform public.write_crm_audit_event(target.store_id, auth.uid(), 'customers', 'crm_customers', p_target::text,
    'customers_merged', p_details => jsonb_build_object('merged_customer_id', p_source));
end;
$$;

revoke all on function public.crm_audit_log_page(uuid, integer, integer, text, text),
  public.record_crm_export(uuid, text, integer),
  public.record_crm_sms_provider_change(uuid, uuid, text, text),
  public.apply_crm_nova_poshta_tracking(uuid, uuid, text, text, text, timestamptz, date)
  from public, anon, authenticated, service_role;
grant execute on function public.crm_audit_log_page(uuid, integer, integer, text, text),
  public.record_crm_export(uuid, text, integer) to authenticated;
grant execute on function public.record_crm_sms_provider_change(uuid, uuid, text, text),
  public.apply_crm_nova_poshta_tracking(uuid, uuid, text, text, text, timestamptz, date) to service_role;

create or replace function public.queue_crm_customer_push(
  p_store_id uuid, p_customer_id uuid, p_user_id uuid, p_request_id uuid, p_message text
) returns boolean language plpgsql security definer set search_path = '' as $$
declare
  message text := btrim(p_message, E' \t\r\n');
begin
  -- Keep the account link stable until the message is queued, even during a CRM merge.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_store_id::text, 0));
  if not exists (select from public.crm_customer_accounts(p_store_id, p_customer_id) a where a.user_id = p_user_id) then
    raise exception 'Registered customer account required' using errcode = '42501';
  end if;
  if p_request_id is null or message is null or char_length(message) not between 1 and 500 then
    raise exception 'Enter a notification between 1 and 500 characters.' using errcode = '22023';
  end if;

  insert into public.customer_notifications(id, store_id, user_id, kind, value)
  values (p_request_id, p_store_id, p_user_id, 'manual', message) on conflict (id) do nothing;
  if not found then
    if not exists (select from public.customer_notifications n where n.id = p_request_id
      and n.store_id = p_store_id and n.user_id = p_user_id and n.kind = 'manual' and n.value = message) then
      raise insufficient_privilege;
    end if;
    return true;
  end if;

  insert into public.customer_push_deliveries(subscription_id, kind, path)
  select s.id, 'manual:' || message, '/account' from public.customer_push_subscriptions s
  where s.user_id = p_user_id for key share;
  if not found then
    delete from public.customer_notifications where id = p_request_id;
    return false;
  end if;
  perform public.write_crm_audit_event(p_store_id, auth.uid(), 'notifications', 'crm_customers',
    p_customer_id::text, 'push_queued', p_details => jsonb_build_object('recipient_count', 1));
  return true;
end;
$$;

notify pgrst, 'reload schema';
