begin;

-- The waybill belongs to one carrier document but can cover several orders.
alter table public.orders drop constraint orders_nova_poshta_ttn_key;
create unique index orders_nova_poshta_verified_ttn_key on public.orders (nova_poshta_ttn)
  where nova_poshta_document_ref is not null;
create index orders_nova_poshta_tracking_number_idx on public.orders (nova_poshta_ttn)
  where nova_poshta_ttn is not null;

create or replace function public.finish_order_ttn_attempt(
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
    if exists (select from public.orders
      where (nova_poshta_ttn = p_ttn or nova_poshta_document_ref = p_document_ref) and id <> all(shipment_ids))
      or exists (select from public.orders where id = any(shipment_ids) and nova_poshta_ttn is not null and nova_poshta_ttn <> p_ttn) then
      raise exception 'This TTN is already linked to an order.';
    end if;
    -- A consolidated shipment has a single provider document. Each order
    -- keeps the tracking number, while its unique document reference is on the root.
    update public.orders o set
      nova_poshta_ttn = p_ttn,
      nova_poshta_document_ref = case when o.id = p_order_id then p_document_ref else o.nova_poshta_document_ref end,
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

create function public.attach_verified_order_ttn(p_order_id uuid, p_ttn text, p_document_ref text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  store uuid;
  attachment uuid;
begin
  select o.store_id into store from public.orders o where o.id = p_order_id;
  if store is null then raise exception 'Order was not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || store::text, 0));
  if exists (select from public.order_merge_members where order_id = p_order_id and root_id <> p_order_id) then
    raise exception 'Link the TTN from the primary order.';
  end if;

  -- Claim the same per-order reservation as creation, then finalize the
  -- verified attachment within this transaction without reserving stock.
  insert into public.order_ttn_reservations(order_id, needs_review) values (p_order_id, true)
  on conflict (order_id) do nothing returning attempt_id into attachment;
  if attachment is null then raise exception 'TTN creation is still in progress.'; end if;
  perform public.finish_order_ttn_attempt(p_order_id, attachment, 'attached', p_ttn, p_document_ref);
end;
$$;
revoke all on function public.attach_verified_order_ttn(uuid, text, text) from public, anon, authenticated;
grant execute on function public.attach_verified_order_ttn(uuid, text, text) to service_role;
notify pgrst, 'reload schema';

commit;
