begin;

alter table public.order_ttn_reservations
  add column attempt_id uuid not null default gen_random_uuid(),
  add column needs_review boolean not null default false,
  add column recipient_address jsonb,
  add column client_reference text;

create function public.get_order_delivery_actions(p_order_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  target public.orders;
  attempt public.order_ttn_reservations;
  pending_stock boolean;
begin
  select * into target from public.orders where id = p_order_id;
  if not found or not coalesce(public.is_store_member(target.store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  select exists (
    select from public.orders o where o.store_id = target.store_id and o.cancel_stock_pending
      and (o.id = p_order_id or exists (
        select from public.order_merge_members m where m.root_id = p_order_id and m.order_id = o.id
      ))
  ) into pending_stock;
  select * into attempt from public.order_ttn_reservations where order_id = p_order_id;
  return jsonb_build_object(
    'cancelStockPending', pending_stock, 'ttn', target.nova_poshta_ttn,
    'ttnAttempt', case when attempt.attempt_id is not null and target.nova_poshta_ttn is null
      then jsonb_build_object('id', attempt.attempt_id,
        'state', case when attempt.needs_review or attempt.created_at <= now() - interval '8 minutes'
          then 'review' else 'creating' end)
    end
  );
end;
$$;
revoke all on function public.get_order_delivery_actions(uuid) from public, anon, service_role;
grant execute on function public.get_order_delivery_actions(uuid) to authenticated;

create function public.begin_order_ttn_attempt(p_order_id uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  perform public.reserve_order_ttn(p_order_id);
  return (select r.attempt_id from public.order_ttn_reservations r where r.order_id = p_order_id);
end;
$$;
revoke all on function public.begin_order_ttn_attempt(uuid) from public, anon, authenticated;
grant execute on function public.begin_order_ttn_attempt(uuid) to service_role;

create function public.prepare_order_ttn_request(
  p_order_id uuid, p_attempt_id uuid, p_address jsonb, p_client_reference text
) returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.order_ttn_reservations set recipient_address = p_address, client_reference = p_client_reference
  where order_id = p_order_id and attempt_id = p_attempt_id and not needs_review
    and created_at > now() - interval '8 minutes';
  if not found then raise exception 'This TTN attempt is no longer current.'; end if;
end;
$$;
revoke all on function public.prepare_order_ttn_request(uuid, uuid, jsonb, text) from public, anon, authenticated;
grant execute on function public.prepare_order_ttn_request(uuid, uuid, jsonb, text) to service_role;

create function public.finish_order_ttn_attempt(
  p_order_id uuid, p_attempt_id uuid, p_outcome text, p_ttn text default null, p_document_ref text default null
) returns void language plpgsql security definer set search_path = '' as $$
declare
  store uuid;
  shipment_ids uuid[];
  attempt public.order_ttn_reservations;
begin
  if p_outcome is null or p_outcome not in ('created', 'rejected', 'uncertain', 'attached', 'not_created') then
    raise exception 'Invalid TTN outcome';
  end if;
  select o.store_id into store from public.orders o where o.id = p_order_id;
  if store is null then raise exception 'Order was not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || store::text, 0));

  select * into attempt from public.order_ttn_reservations
  where order_id = p_order_id and attempt_id = p_attempt_id for update;
  if not found then
    if p_outcome in ('created', 'attached') and exists (
      select from public.orders where id = p_order_id and nova_poshta_ttn = p_ttn
    ) then return; end if;
    raise exception 'This TTN attempt is no longer current.';
  end if;
  -- Wait longer than the hosted function's lifetime after an interrupted run
  -- that never got a chance to record the provider's uncertain response.
  if p_outcome in ('attached', 'not_created') and not attempt.needs_review
    and attempt.created_at > now() - interval '8 minutes' then
    raise exception 'TTN creation is still in progress.';
  end if;
  if p_outcome = 'uncertain' then
    update public.order_ttn_reservations set needs_review = true where order_id = p_order_id;
    return;
  end if;

  if p_outcome in ('created', 'attached') then
    if p_ttn is null or p_ttn !~ '^[0-9]{14}$' or nullif(btrim(p_document_ref), '') is null then
      raise exception 'Enter a valid 14-digit Nova Poshta tracking number.';
    end if;
    select array_agg(o.id) into shipment_ids from public.orders o where o.store_id = store
      and (o.id = p_order_id or exists (
        select from public.order_merge_members m where m.root_id = p_order_id and m.order_id = o.id
      ));
    perform o.id from public.orders o where o.id = any(shipment_ids) order by o.id for update;
    perform pg_advisory_xact_lock(hashtextextended('nova-poshta-ttn:' || p_ttn, 0));
    if exists (select from public.orders where nova_poshta_ttn = p_ttn and id <> all(shipment_ids))
      or exists (select from public.orders where id = any(shipment_ids) and nova_poshta_ttn is not null and nova_poshta_ttn <> p_ttn) then
      raise exception 'This TTN is already linked to an order.';
    end if;
    update public.orders o set
      nova_poshta_ttn = p_ttn, nova_poshta_document_ref = p_document_ref,
      nova_poshta_ttn_created_at = coalesce(o.nova_poshta_ttn_created_at, now()),
      delivery_city_ref = coalesce(attempt.recipient_address->>'delivery_city_ref', o.delivery_city_ref),
      delivery_city = coalesce(attempt.recipient_address->>'delivery_city', o.delivery_city),
      delivery_address_ref = coalesce(attempt.recipient_address->>'delivery_address_ref', o.delivery_address_ref),
      delivery_address = coalesce(attempt.recipient_address->>'delivery_address', o.delivery_address),
      delivery_service_type = coalesce(attempt.recipient_address->>'delivery_service_type', o.delivery_service_type)
    where o.id = any(shipment_ids);
  elsif p_outcome = 'not_created' and exists (
    select from public.orders where id = p_order_id and nova_poshta_ttn is not null
  ) then
    raise exception 'This order already has a TTN.';
  end if;
  delete from public.order_ttn_reservations where order_id = p_order_id and attempt_id = p_attempt_id;
end;
$$;
revoke all on function public.finish_order_ttn_attempt(uuid, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.finish_order_ttn_attempt(uuid, uuid, text, text, text) to service_role;
notify pgrst, 'reload schema';

commit;
