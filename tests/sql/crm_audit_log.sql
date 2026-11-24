begin;

do $$
declare
  shop uuid := (select id from public.shop_settings);
  manager uuid := gen_random_uuid();
  employee uuid := gen_random_uuid();
  customer_account uuid := gen_random_uuid();
  customer_card uuid := gen_random_uuid();
  order_id uuid := gen_random_uuid();
  product_id uuid := gen_random_uuid();
  push_request uuid := gen_random_uuid();
  result jsonb;
  audit_count bigint;
begin
  insert into auth.users (id, raw_user_meta_data)
  values (manager, '{"name":"Audit Manager"}'), (employee, '{}'), (customer_account, '{}');
  insert into public.store_members (store_id, user_id, role)
  values (shop, manager, 'MANAGER'), (shop, employee, 'CONTENT');

  perform set_config('request.jwt.claim.sub', manager::text, true);
  insert into public.crm_customers (id, store_id, name, phone, notes)
  values (customer_card, shop, 'Fixture customer', '+380671234567', 'Private fixture note');
  insert into public.crm_customer_keys (store_id, key, customer_id)
  values (shop, 'user:' || customer_account::text, customer_card);
  update public.crm_customers set notes = 'Updated private fixture note' where id = customer_card;

  insert into public.orders (id, store_id, customer_name, customer_email, customer_phone,
    delivery_city, delivery_address, total_price, currency, status)
  values (order_id, shop, 'Fixture customer', '', '+380671234567',
    'Київ', 'Branch', 12000, 'UAH', 'IN_PROGRESS');
  update public.orders set status = 'PREPARING_SHIPMENT' where id = order_id;
  select count(*) into audit_count from public.crm_audit_log;
  update public.orders set status = 'PREPARING_SHIPMENT', updated_at = clock_timestamp() where id = order_id;
  assert (select count(*) from public.crm_audit_log) = audit_count, 'No-op updates must not create log entries';

  perform set_config('request.jwt.claim.sub', '', true);
  perform public.settle_order_ttn_as_staff(order_id, null, 'attached', '59000000000123',
    '11111111-2222-3333-4444-555555555555', manager);
  assert exists (select from public.crm_audit_log where actor_id = manager
    and entity_id = order_id::text and action = 'ttn_linked'), 'Service-role TTN actions must keep the actor';
  perform public.apply_crm_nova_poshta_tracking(order_id, manager, '59000000000123',
    '4', 'Відправлення у місті', now() + interval '1 second', null);
  assert exists (select from public.crm_audit_log where actor_id = manager
    and entity_id = order_id::text and action = 'tracking_refresh'), 'Manual tracking refresh must be audited';

  perform set_config('request.jwt.claim.sub', employee::text, true);
  insert into public.products (id, store_id, name) values (product_id, shop, 'Audit product');
  begin
    perform public.crm_audit_log_page(shop, 1, 50);
    raise exception 'Content staff can read the audit log';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claim.sub', manager::text, true);
  perform public.record_crm_export(shop, 'crm_customers', 1);
  insert into public.customer_push_subscriptions (user_id, endpoint, p256dh, auth_secret, language)
  values (customer_account, 'https://fcm.googleapis.com/fcm/send/audit-fixture', 'fixture', 'fixture', 'uk');
  perform public.queue_crm_customer_push(shop, customer_card, customer_account, push_request, 'Private push fixture');
  perform public.queue_crm_customer_push(shop, customer_card, customer_account, push_request, 'Private push fixture');

  result := public.crm_audit_log_page(shop, 1, 50, 'orders', order_id::text);
  assert exists (select from jsonb_array_elements(result->'rows') event
    where event->>'action' = 'order_status'
      and event->>'actor_name' = 'Audit Manager'
      and event#>>'{details,status,before}' = 'IN_PROGRESS'
      and event#>>'{details,status,after}' = 'PREPARING_SHIPMENT'), 'Status changes must have actor and old/new values';
  assert (public.crm_audit_log_page(shop, 1, 50, 'catalog', product_id::text)->>'total')::int = 1;
  assert (public.crm_audit_log_page(shop, 1, 50, 'exports')->>'total')::int = 1;
  assert (public.crm_audit_log_page(shop, 1, 50, 'notifications', customer_card::text)->>'total')::int = 1,
    'Retrying a notification must not create a second audit entry';
  assert not exists (select from public.crm_audit_log where details::text like '%fixture note%'
    or details::text like '%Private push fixture%' or details::text like '%380671234567%'),
    'Sensitive values must not be copied into the audit log';

  assert not has_table_privilege('authenticated', 'public.crm_audit_log', 'SELECT');
  assert not has_table_privilege('authenticated', 'public.crm_audit_log', 'INSERT');
  assert not has_function_privilege('authenticated',
    'public.write_crm_audit_event(uuid,uuid,text,text,text,text,text[],jsonb)', 'EXECUTE');
  assert not has_function_privilege('authenticated',
    'public.record_crm_sms_provider_change(uuid,uuid,text,text)', 'EXECUTE');
  perform set_config('request.jwt.claim.sub', customer_account::text, true);
  begin
    perform public.record_crm_export(shop, 'orders', 100);
    raise exception 'A customer impersonated a CRM export';
  exception when insufficient_privilege then null;
  end;
end;
$$;

rollback;
