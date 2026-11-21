begin;

do $$
declare
  manager uuid := gen_random_uuid();
  stranger uuid := gen_random_uuid();
  shop uuid;
  first_order uuid;
  other_order uuid;
  first_attempt uuid;
  next_attempt uuid;
  actions jsonb;
  carrier_ref text := '11111111-2222-3333-4444-555555555555';
begin
  select id into shop from public.shop_settings;
  insert into auth.users(id) values (manager), (stranger);
  insert into public.store_members(store_id, user_id, role) values (shop, manager, 'OWNER');
  insert into public.orders (
    store_id, customer_name, customer_email, customer_phone, delivery_city, delivery_address, total_price, currency, status
  ) values (shop, 'A', '', '0990000001', 'City', 'Branch', 105050, 'UAH', 'PREPARING_SHIPMENT')
  returning id into first_order;
  insert into public.orders (
    store_id, customer_name, customer_email, customer_phone, delivery_city, delivery_address, total_price, currency, status
  ) values (shop, 'B', '', '0990000002', 'City', 'Branch', 105050, 'UAH', 'PREPARING_SHIPMENT')
  returning id into other_order;

  perform set_config('request.jwt.claim.sub', stranger::text, true);
  begin
    perform public.get_order_delivery_actions(first_order);
    raise exception 'A non-staff user could inspect recovery';
  exception when insufficient_privilege then null;
  end;
  if has_function_privilege('authenticated', 'public.finish_order_ttn_attempt(uuid,uuid,text,text,text)', 'execute') then
    raise exception 'A frontend caller can bypass carrier verification';
  end if;
  perform set_config('request.jwt.claim.sub', manager::text, true);
  first_attempt := public.begin_order_ttn_attempt(first_order);
  actions := public.get_order_delivery_actions(first_order);
  if actions#>>'{ttnAttempt,state}' <> 'creating' then raise exception 'New attempt was not marked active'; end if;
  begin
    perform public.finish_order_ttn_attempt(first_order, first_attempt, 'not_created');
    raise exception 'An active request could be discarded';
  exception when raise_exception then
    if sqlerrm <> 'TTN creation is still in progress.' then raise; end if;
  end;
  perform public.prepare_order_ttn_request(first_order, first_attempt, '{"delivery_city":"Київ","delivery_address":"Відділення №1"}', 'test-order');
  perform public.finish_order_ttn_attempt(first_order, first_attempt, 'uncertain');
  actions := public.get_order_delivery_actions(first_order);
  if actions#>>'{ttnAttempt,state}' <> 'review' then raise exception 'Uncertain result could not be recovered'; end if;
  perform public.finish_order_ttn_attempt(first_order, first_attempt, 'attached', '59000000000123', carrier_ref);
  perform public.finish_order_ttn_attempt(first_order, first_attempt, 'attached', '59000000000123', carrier_ref);
  if not exists (select from public.orders where id = first_order and nova_poshta_ttn = '59000000000123'
    and nova_poshta_document_ref = carrier_ref and delivery_city = 'Київ' and delivery_address = 'Відділення №1')
    or exists (select from public.order_ttn_reservations where order_id = first_order) then
    raise exception 'Existing TTN was not attached with its saved delivery address';
  end if;

  first_attempt := public.begin_order_ttn_attempt(other_order);
  update public.order_ttn_reservations set created_at = now() - interval '9 minutes' where order_id = other_order;
  begin
    perform public.finish_order_ttn_attempt(other_order, first_attempt, 'attached', '59000000000123', carrier_ref);
    raise exception 'Another order accepted the already linked TTN';
  exception when raise_exception then
    if sqlerrm <> 'This TTN is already linked to an order.' then raise; end if;
  end;
  perform public.finish_order_ttn_attempt(other_order, first_attempt, 'not_created');
  next_attempt := public.begin_order_ttn_attempt(other_order);
  begin
    perform public.finish_order_ttn_attempt(other_order, first_attempt, 'rejected');
    raise exception 'Old request removed the new attempt';
  exception when raise_exception then
    if sqlerrm <> 'This TTN attempt is no longer current.' then raise; end if;
  end;
  if not exists (select from public.order_ttn_reservations where order_id = other_order and attempt_id = next_attempt) then
    raise exception 'Retry did not create a new active attempt';
  end if;
end;
$$;

rollback;
