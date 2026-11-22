begin;

-- Payment credentials remain attached to the original invoice. Fulfilment does not depend on those credentials.

CREATE OR REPLACE FUNCTION public.active_nova_poshta_shipments()
 RETURNS TABLE(store_id uuid, ttn text, sender_phone text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select o.store_id, o.nova_poshta_ttn, coalesce(s.sender_phone, '')
  from public.orders o
  left join public.delivery_settings s on s.store_id = o.store_id
  where nullif(o.nova_poshta_ttn, '') is not null
    and o.nova_poshta_ttn not like 'TEST-%'
    and o.status not in ('COMPLETED', 'CANCELLED_BY_USER', 'CANCELLED_BY_STORE')
  group by o.store_id, o.nova_poshta_ttn, s.sender_phone
  order by min(o.nova_poshta_status_updated_at) nulls first, o.store_id, o.nova_poshta_ttn
  limit 500;
$function$;

CREATE OR REPLACE FUNCTION public.apply_nova_poshta_tracking(p_store_id uuid, p_ttn text, p_code text, p_status text, p_checked_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  auto_update boolean;
  shipment public.orders;
  next_status public.order_status;
  tracking_changed boolean;
  changed boolean := false;
begin
  if nullif(p_ttn, '') is null or nullif(p_status, '') is null or p_checked_at is null then
    raise exception 'Invalid shipment status';
  end if;
  if p_ttn like 'TEST-%' then return false; end if;
  select s.auto_update_order_status into auto_update
  from public.delivery_settings s where s.store_id = p_store_id for share;

  for shipment in
    select * from public.orders
    where store_id = p_store_id and nova_poshta_ttn = p_ttn
    order by id for update
  loop
    if p_checked_at <= shipment.nova_poshta_status_updated_at or p_checked_at < shipment.nova_poshta_ttn_created_at then
      continue;
    end if;
    tracking_changed := shipment.nova_poshta_status_code is distinct from p_code
      or shipment.nova_poshta_status is distinct from p_status;
    next_status := shipment.status;
    if coalesce(auto_update, true)
      and shipment.manual_tracking_status_code is distinct from p_code
      and shipment.status in ('PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED') then
      if p_code in ('9', '10', '11')
        and ((shipment.payment_method = 'ONLINE' and shipment.payment_status = 'PAID')
          or (shipment.payment_method = 'CASH_ON_DELIVERY' and shipment.payment_status in ('PENDING', 'PAID'))) then
        next_status := 'COMPLETED';
      elsif p_code in ('7', '8') then
        next_status := 'DELIVERED';
      elsif p_code in ('4', '5', '6', '101') and shipment.status <> 'DELIVERED' then
        next_status := 'IN_TRANSIT';
      end if;
    end if;
    update public.orders set nova_poshta_status = p_status, nova_poshta_status_code = p_code,
      nova_poshta_status_updated_at = p_checked_at, status = next_status,
      manual_tracking_status_code = case when shipment.manual_tracking_status_code = p_code then p_code end,
      shipment_was_dispatched = shipment.shipment_was_dispatched or coalesce(p_code in ('4', '5', '6', '7', '8', '9', '10', '11', '101'), false)
    where id = shipment.id;
    if tracking_changed then
      insert into public.order_delivery_events (order_id, status_code, status_text)
      values (shipment.id, p_code, p_status);
    end if;
    changed := changed or tracking_changed or next_status <> shipment.status;
  end loop;
  return changed;
end;
$function$;

CREATE OR REPLACE FUNCTION public.apply_admin_order_update(p_order_ids uuid[], p_status public.order_status, p_confirm_paid boolean, p_include_group boolean, p_restore_stock boolean)
 RETURNS SETOF public.orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  store uuid;
  affected_ids uuid[];
  order_id uuid;
  stock_order_ids uuid[];
begin
  select o.store_id into store from public.orders o where o.id = p_order_ids[1];
  if store is null or not coalesce(public.is_store_member(store), false) or exists (
    select 1 from unnest(p_order_ids) requested(id)
    where not exists (select 1 from public.orders o where o.id = requested.id and o.store_id = store)
  ) then
    raise exception 'Access denied';
  end if;
  if p_status is null or (p_restore_stock and p_status <> 'CANCELLED_BY_STORE') then
    raise exception 'Invalid order status';
  end if;

  -- Keep group membership and parcel reservation stable until stock and status commit.
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || store::text, 0));
  select array_agg(o.id order by o.id) into affected_ids
  from public.orders o
  where o.store_id = store and (o.id = any(p_order_ids) or (
    p_include_group and exists (
      select 1 from public.order_merge_members m where m.order_id = o.id and m.root_id = any(p_order_ids)
    )
  ));

  perform o.id from public.orders o where o.id = any(affected_ids) order by o.id for update;
  perform p.id from public.payments p where p.order_id = any(affected_ids) order by p.order_id for update;

  if not coalesce(p_confirm_paid, false) and (
    exists (select 1 from public.orders o where o.id = any(affected_ids) and (o.status = 'PAID' or o.payment_status in ('PAID', 'REFUNDED')))
    or exists (select 1 from public.payments p where p.order_id = any(affected_ids) and p.status in ('PAID', 'REFUNDED'))
    or exists (
      select 1 from public.order_events e where e.order_id = any(affected_ids)
        and ((e.kind = 'status' and ('PAID' in (e.old_value, e.new_value)))
          or (e.kind = 'payment_status' and (e.old_value in ('PAID', 'REFUNDED') or e.new_value in ('PAID', 'REFUNDED'))))
    )
    or exists (select 1 from public.order_returns r where r.order_id = any(affected_ids))
  ) then
    raise sqlstate 'PT409' using message = 'Confirm status change for orders with a payment record';
  end if;

  if exists (
    select 1 from public.order_ttn_reservations r where r.order_id = any(affected_ids)
  ) then
    raise exception 'TTN creation is in progress for one of these orders';
  end if;
  if p_status = 'COMPLETED' and exists (
    select 1 from public.orders o where o.id = any(affected_ids)
    and (o.status::text like 'CANCELLED%' or
      (o.payment_method = 'ONLINE' and o.payment_status <> 'PAID') or
      (o.payment_method = 'CASH_ON_DELIVERY' and o.payment_status not in ('PAID', 'PENDING')))
  ) then
    raise exception 'Only active orders with valid payment can be completed';
  end if;
  if p_status in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER') and not p_restore_stock then
    select array_agg(o.id) into stock_order_ids from public.orders o
    where o.id = any(affected_ids) and o.status in ('PENDING', 'IN_PROGRESS', 'WAITING_FOR_STOCK', 'PREPARING_SHIPMENT')
      and not o.shipment_was_dispatched
      and o.nova_poshta_ttn is null and o.nova_poshta_document_ref is null;
    if stock_order_ids is not null then
      perform public.release_order_fulfillment_stock(stock_order_ids);
    end if;
    update public.orders o set cancel_stock_pending = true
    where o.id = any(affected_ids) and not (o.id = any(coalesce(stock_order_ids, array[]::uuid[])))
      and o.status not in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER')
      and exists (
        select from public.order_items i where i.order_id = o.id
          and coalesce(i.stock_deducted, not i.is_preorder) and i.variant_id is not null
      );
  end if;

  if p_restore_stock then
    foreach order_id in array affected_ids loop
      perform public.restore_stock_and_cancel_order(order_id);
    end loop;
  else
    update public.orders o
    set status = p_status,
        manual_tracking_status_code = case when o.status is distinct from p_status
          then o.nova_poshta_status_code else o.manual_tracking_status_code end,
        shipment_was_dispatched = o.shipment_was_dispatched or p_status in ('IN_TRANSIT', 'DELIVERED', 'COMPLETED'),
        cancel_stock_pending = o.cancel_stock_pending and p_status in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER'),
        payment_status = case p_status
          when 'PAID' then 'PAID'::public.payment_status
          when 'PENDING' then 'PENDING'::public.payment_status
          else o.payment_status
        end
    where o.id = any(affected_ids);
  end if;

  return query select o.* from public.orders o where o.id = any(affected_ids);
end;
$function$;

CREATE OR REPLACE FUNCTION public.apply_order_workflow()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'INSERT' then
    if new.status = 'PAID' then
      new.status := 'IN_PROGRESS';
      new.is_new := new.payment_method = 'ONLINE' and new.payment_status = 'PAID';
    elsif new.payment_method = 'CASH_ON_DELIVERY' and new.status = 'PENDING' then
      new.status := 'IN_PROGRESS';
    end if;
    return new;
  end if;

  -- Legacy payment callbacks and RPCs may still ask to set the old order
  -- status. Keep fulfillment where it is after processing has started.
  if new.status = 'PAID' then
    new.status := case when old.status = 'PENDING' then 'IN_PROGRESS'::public.order_status else old.status end;
  end if;
  if new.status is distinct from old.status then
    new.is_new := old.status = 'PENDING' and new.status = 'IN_PROGRESS'
      and new.payment_method = 'ONLINE' and new.payment_status = 'PAID'
      and not exists (
        select 1 from public.order_events e where e.order_id = new.id and (
          (e.kind = 'status' and e.new_value in ('IN_PROGRESS', 'PAID'))
          or (e.kind = 'payment_status' and e.new_value = 'PAID')
        )
      );
    if new.status = 'COMPLETED' and new.payment_method = 'CASH_ON_DELIVERY' and new.payment_status = 'PENDING' then
      new.payment_status := 'PAID';
    end if;
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.attach_crm_customer()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare identity_key text;
begin
 identity_key := case when new.user_id is not null then 'user:'||new.user_id::text
  when length(regexp_replace(new.customer_phone,'[^0-9]','','g'))>=9 then 'phone:'||regexp_replace(new.customer_phone,'[^0-9]','','g')
  when trim(new.customer_email)<>'' then 'email:'||lower(trim(new.customer_email)) else 'order:'||new.id::text end;
 new.crm_customer_id := public.crm_identity(new.store_id,identity_key,new.customer_name,new.customer_phone,new.customer_email);
 return new;
end; $function$;

CREATE OR REPLACE FUNCTION public.cancel_customer_reservation(p_order_id uuid, p_user_id uuid, p_operation uuid, p_provider_order_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_order public.orders;
  v_payment public.payments;
  v_item record;
begin
  select * into v_order from public.orders where id = p_order_id and user_id = p_user_id for update;
  if not found or v_order.status <> 'PENDING' or v_order.payment_method <> 'ONLINE'
      or v_order.payment_status not in ('PENDING', 'FAILED') then
    raise sqlstate 'PT409' using message = 'This reservation is no longer awaiting payment.';
  end if;

  select * into v_payment from public.payments where order_id = p_order_id for update;
  if not found or v_payment.status not in ('PENDING', 'FAILED')
      or v_payment.provider_order_id is distinct from p_provider_order_id
      or v_payment.checkout_operation is distinct from p_operation or p_operation is null
      or v_payment.checkout_operation_until <= now() then
    raise sqlstate 'PT409' using message = 'This reservation is no longer awaiting payment.';
  end if;

  for v_item in
    select variant_id, sum(quantity)::integer as quantity from public.order_items
    where order_id = p_order_id and coalesce(stock_deducted, not is_preorder) and variant_id is not null
    group by variant_id order by variant_id
  loop
    update public.product_variants set stock_quantity = stock_quantity + v_item.quantity where id = v_item.variant_id;
  end loop;

  update public.orders set status = 'CANCELLED_BY_USER', payment_status = 'FAILED' where id = p_order_id;
  update public.payments set status = 'FAILED', checkout_url = null,
    checkout_operation = null, checkout_operation_until = null where id = v_payment.id;
  update public.order_events
  set author_id = p_user_id
  where order_id = p_order_id and kind = 'status' and new_value = 'CANCELLED_BY_USER'
    and created_at = transaction_timestamp() and author_id is null;
end;
$function$;

CREATE OR REPLACE FUNCTION public.confirm_online_checkout(p_provider text, p_reference text, p_amount integer, p_currency text, p_payment_id text, p_callback jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_attempt public.online_checkouts;
  v_item record;
  v_preorder boolean;
  v_stock_deducted boolean;
begin
  select * into v_attempt from public.online_checkouts
  where provider = p_provider and provider_order_id = p_reference for update;
  if not found then raise exception 'Payment attempt not found'; end if;
  if v_attempt.total_price is distinct from p_amount or v_attempt.currency is distinct from p_currency then
    raise exception 'Payment amount or currency mismatch';
  end if;
  if v_attempt.status = 'PAID' then return; end if;

  insert into public.orders (
    id, store_id, user_id, receipt_code, status, payment_status, payment_method,
    customer_name, customer_email, customer_phone, delivery_city, delivery_address, note,
    total_price, currency, delivery_city_ref, delivery_address_ref, delivery_service_type,
    monobank_test_mode, payment_test_mode
  ) values (
    v_attempt.id, v_attempt.store_id, v_attempt.user_id, v_attempt.receipt_code, 'PAID', 'PAID', 'ONLINE',
    trim(v_attempt.checkout->>'name'), lower(trim(coalesce(v_attempt.checkout->>'email', ''))),
    trim(v_attempt.checkout->>'phone'), trim(v_attempt.checkout->>'city'), trim(v_attempt.checkout->>'address'),
    trim(coalesce(v_attempt.checkout->>'note', '')), v_attempt.total_price, v_attempt.currency,
    nullif(trim(v_attempt.checkout->>'cityRef'), ''), nullif(trim(v_attempt.checkout->>'addressRef'), ''),
    case when v_attempt.checkout->>'deliveryServiceType' in ('WarehouseWarehouse', 'WarehousePostomat')
      then v_attempt.checkout->>'deliveryServiceType' end,
    p_provider = 'MONOBANK' and v_attempt.test_mode, v_attempt.test_mode
  );

  for v_item in
    select line.*, (entry.data->>'allow_out_of_stock')::boolean as allow_out_of_stock
    from jsonb_array_elements(v_attempt.items) as entry(data)
    cross join lateral jsonb_populate_record(null::public.order_items, entry.data) as line
    order by line.variant_id
  loop
    -- Honor invoices already issued before pre-orders began counting stock.
    v_preorder := v_item.is_preorder;
    v_stock_deducted := false;
    if not v_preorder or v_attempt.track_preorder_stock then
      update public.product_variants set stock_quantity = stock_quantity - v_item.quantity
      where id = v_item.variant_id and stock_quantity >= v_item.quantity;
      v_stock_deducted := found;
      -- Record the paid order for fulfillment even if stock ran out during payment.
      v_preorder := v_preorder or (not v_stock_deducted and not coalesce(v_item.allow_out_of_stock, false));
    end if;
    insert into public.order_items (
      order_id, product_id, variant_id, product_name, variant_name, quantity,
      unit_price, compare_at_price, line_total, is_preorder, stock_deducted
    ) values (
      v_attempt.id,
      (select id from public.products where id = v_item.product_id for key share),
      (select id from public.product_variants where id = v_item.variant_id for key share),
      v_item.product_name, v_item.variant_name, v_item.quantity,
      v_item.unit_price, v_item.compare_at_price, v_item.line_total, v_preorder, v_stock_deducted
    );
  end loop;


  insert into public.payments (order_id, provider, provider_order_id, provider_payment_id, status, raw_callback)
  values (v_attempt.id, p_provider, p_reference, p_payment_id, 'PAID', p_callback);
  update public.online_checkouts set status = 'PAID', checkout = null, items = null where id = v_attempt.id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.create_priced_catalog_order(p_provider text, p_user_id uuid, p_store_id uuid, p_items jsonb, p_customer_name text, p_customer_email text, p_customer_phone text, p_delivery_city text, p_delivery_address text, p_note text, p_delivery_city_ref text, p_delivery_address_ref text, p_delivery_service_type text, p_monobank_test_mode boolean, p_discount public.customer_discounts, p_expected_total integer)
 RETURNS public.orders
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  created_order public.orders;
  line public.order_items;
  quote record;
  method_enabled boolean;
  monobank_mode boolean;
  shared_test_mode boolean;
  test_mode boolean;
  free_order boolean;
begin
  if p_provider is null or p_provider not in ('CASH_ON_DELIVERY', 'LIQPAY', 'MONOBANK') then
    raise exception 'Invalid payment method';
  end if;
  select case p_provider when 'CASH_ON_DELIVERY' then pm.cash_on_delivery
      when 'LIQPAY' then pm.liqpay when 'MONOBANK' then pm.monobank end,
    pm.monobank_test_mode, pm.payment_test_mode
  into method_enabled, monobank_mode, shared_test_mode
  from public.store_payment_methods pm where pm.store_id = p_store_id;

  test_mode := p_provider <> 'CASH_ON_DELIVERY' and coalesce(shared_test_mode,
    case p_provider when 'MONOBANK' then monobank_mode when 'LIQPAY' then p_monobank_test_mode end, false);
  if coalesce(p_monobank_test_mode, false) is distinct from test_mode
    or (p_monobank_test_mode is null and shared_test_mode is not null) then
    raise sqlstate 'PT409' using message = 'Payment settings changed. Please try again.';
  end if;

  select * into quote from public.quote_catalog_cart(p_store_id, p_items, p_discount.percent, true);
  if p_expected_total is not null and p_expected_total is distinct from quote.total then
    raise sqlstate 'PT409' using message = 'Cart prices changed. Review your cart and try again.';
  end if;
  free_order := p_provider = 'CASH_ON_DELIVERY' and quote.total = 0;
  if not free_order and not coalesce(method_enabled, true) then
    raise sqlstate 'PT409' using message = 'This payment method is no longer available.';
  end if;

  insert into public.orders (
    store_id, user_id, customer_name, customer_email, customer_phone,
    delivery_city, delivery_address, note, total_price, currency,
    delivery_city_ref, delivery_address_ref, delivery_service_type, payment_method,
    monobank_test_mode, payment_test_mode, status, payment_status,
    customer_discount_id, customer_discount_percent, customer_discount_amount
  )
  select p_store_id, p_user_id, trim(p_customer_name), lower(trim(p_customer_email)), trim(p_customer_phone),
    trim(p_delivery_city), trim(p_delivery_address), coalesce(trim(p_note), ''), quote.total, s.currency,
    nullif(trim(p_delivery_city_ref), ''), nullif(trim(p_delivery_address_ref), ''),
    case when p_delivery_service_type in ('WarehouseWarehouse', 'WarehousePostomat') then p_delivery_service_type end,
    case when p_provider = 'CASH_ON_DELIVERY' and not free_order then 'CASH_ON_DELIVERY' else 'ONLINE' end,
    p_provider = 'MONOBANK' and test_mode,
    case when p_provider = 'LIQPAY' and p_monobank_test_mode is null then null else test_mode end,
    case when free_order then 'PAID'::public.order_status else 'PENDING'::public.order_status end,
    case when free_order then 'PAID'::public.payment_status else 'PENDING'::public.payment_status end,
    case when quote.personal_savings > 0 then p_discount.id end,
    case when quote.personal_savings > 0 then p_discount.percent else 0 end,
    quote.personal_savings
  from public.shop_settings s where s.id = p_store_id
  returning * into created_order;

  for line in select * from jsonb_populate_recordset(null::public.order_items, quote.items) order by variant_id loop
    insert into public.order_items (
      order_id, product_id, variant_id, product_name, variant_name, quantity,
      unit_price, compare_at_price, line_total, is_preorder, stock_deducted
    ) values (
      created_order.id, line.product_id, line.variant_id, line.product_name, line.variant_name, line.quantity,
      line.unit_price, line.compare_at_price, line.line_total, line.is_preorder, line.stock_deducted
    );
    if line.stock_deducted then
      update public.product_variants set stock_quantity = stock_quantity - line.quantity where id = line.variant_id;
    end if;
  end loop;

  if p_user_id is not null then
    update public.order_events
    set author_id = p_user_id
    where order_id = created_order.id and kind = 'status' and new_value = created_order.status::text
      and created_at = transaction_timestamp() and author_id is null;
  end if;
  return created_order;
end;
$function$;

CREATE OR REPLACE FUNCTION public.crm_orders_page(p_store_id uuid, p_page integer, p_page_size integer, p_search text DEFAULT ''::text, p_status text DEFAULT 'ALL'::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_order_ids uuid[] DEFAULT NULL::uuid[], p_customer_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  search text := lower(btrim(coalesce(p_search, '')));
  order_search text := regexp_replace(search, '^#', '');
  phone_search text := case when search ~ '^[+0-9[:space:]().-]+$'
    then regexp_replace(search, '[^0-9]', '', 'g') else '' end;
begin
  if not public.is_store_member(p_store_id) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  return (
    with matches as materialized (
      select o.id, o.created_at
      from public.orders o
      left join public.order_merge_members membership on membership.order_id = o.id
      cross join lateral (select regexp_replace(o.customer_phone, '[^0-9]', '', 'g') as digits) phone
      where o.store_id = p_store_id
        and (membership.root_id is null or membership.root_id = o.id)
        and (p_status = 'ALL' or (p_status = 'NO_TTN' and coalesce(btrim(o.nova_poshta_ttn), '') = '') or o.status::text = p_status
          or (p_status = 'CANCELLED_BY_STORE' and o.status = 'CANCELLED_BY_USER'))
        and (p_from is null or o.created_at >= (p_from::timestamp at time zone 'Europe/Kyiv'))
        and (p_to is null or o.created_at < ((p_to + 1)::timestamp at time zone 'Europe/Kyiv'))
        and (p_order_ids is null or o.id = any(p_order_ids) or exists (
          select from public.order_merge_members m where m.root_id = o.id and m.order_id = any(p_order_ids)
        ))
        and (p_customer_id is null or o.crm_customer_id = p_customer_id or exists (
          select from public.order_merge_members m join public.orders child on child.id = m.order_id
          where m.root_id = o.id and child.store_id = p_store_id and child.crm_customer_id = p_customer_id
        ))
        and (search = '' or strpos(lower(o.customer_name), search) > 0
          or (phone_search <> '' and (strpos(phone.digits, phone_search) > 0 or (
            length(phone_search) between 9 and 12 and length(phone.digits) >= 9
            and right(phone.digits, 9) = right(phone_search, 9)
          )))
          or (order_search <> '' and (strpos(lower(o.receipt_code), order_search) > 0
            or strpos(lower(o.nova_poshta_ttn), order_search) > 0 or exists (
              select from public.order_merge_members m join public.orders child on child.id = m.order_id
              where m.root_id = o.id and child.store_id = p_store_id
                and (strpos(lower(child.receipt_code), order_search) > 0 or strpos(lower(child.nova_poshta_ttn), order_search) > 0)
            ))))
    ), totals as (select count(*) as matches from matches),
    paging as (
      select totals.matches, w.* from totals cross join lateral public.crm_page_window(totals.matches, p_page, p_page_size) w
    ), page_ids as (
      select id, created_at from matches order by created_at desc, id desc
      limit (select page_size from paging) offset (select row_offset from paging)
    )
    select jsonb_build_object('total', paging.matches, 'page', paging.page, 'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', o.id, 'user_id', o.user_id, 'crm_customer_id', o.crm_customer_id,
        'customer_discount_amount', o.customer_discount_amount, 'receipt_code', o.receipt_code,
        'customer_name', o.customer_name, 'customer_email', o.customer_email, 'customer_phone', o.customer_phone,
        'note', o.note, 'is_new', o.is_new, 'status', o.status, 'payment_status', o.payment_status,
        'total_price', coalesce(members.total, o.total_price), 'currency', o.currency, 'created_at', o.created_at,
        'nova_poshta_ttn', o.nova_poshta_ttn, 'nova_poshta_document_ref', o.nova_poshta_document_ref,
        'nova_poshta_status', o.nova_poshta_status, 'nova_poshta_status_code', o.nova_poshta_status_code,
        'payment_method', o.payment_method, 'delivery_city_ref', o.delivery_city_ref, 'delivery_address_ref', o.delivery_address_ref,
        'member_ids', coalesce(members.ids, array[o.id])
      ) order by o.created_at desc, o.id desc)
      from page_ids p join public.orders o on o.id = p.id
      cross join lateral (
        select array_agg(child.id order by child.id) as ids, sum(child.total_price) as total
        from public.order_merge_members m join public.orders child on child.id = m.order_id
        where m.root_id = o.id and child.store_id = p_store_id
      ) members
    ), '[]'::jsonb)) from paging
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.mark_order_procurement()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if exists (select from public.orders o where o.id = new.order_id and o.payment_method = 'ONLINE') then
    new.procurement_restocked := false;
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.merge_orders(p_order_ids uuid[], p_target_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  target public.orders;
  ids uuid[];
  selected_count integer;
  paid_count integer;
begin
  if p_order_ids is null or cardinality(p_order_ids) < 2 or not p_target_id = any(p_order_ids) then
    raise exception 'Select at least two orders and a primary order';
  end if;
  select * into target from public.orders where id=p_target_id;
  if target.id is null or not coalesce(public.is_store_member(target.store_id), false) then
    raise exception 'Access denied';
  end if;
  -- Serialize merge operations for the store, then lock all underlying orders.
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || target.store_id::text, 0));
  select array_agg(distinct o.id order by o.id) into ids
  from public.orders o
  left join public.order_merge_members m on m.order_id=o.id
  where o.id=any(p_order_ids) or m.root_id=any(p_order_ids);
  if (select count(distinct x) from unnest(p_order_ids) x) <> cardinality(p_order_ids)
     or (select count(*) from public.orders where id=any(p_order_ids)) <> cardinality(p_order_ids) then
    raise exception 'Invalid order selection';
  end if;
  perform 1 from public.orders where id=any(ids) order by id for update;
  select * into target from public.orders where id=p_target_id;
  if exists(select 1 from public.order_merge_members where order_id=any(p_order_ids) and root_id<>order_id) then
    raise exception 'Choose the primary order of an existing merged order';
  end if;
  if exists(select 1 from public.orders where id=any(ids) and store_id<>target.store_id) then
    raise exception 'Orders must belong to the same store';
  end if;
  if exists(select 1 from public.orders where id=any(ids) and (nova_poshta_ttn is not null or nova_poshta_document_ref is not null)) then
    raise exception 'Orders with an existing TTN cannot be merged';
  end if;
  if exists(select 1 from public.order_ttn_reservations where order_id=any(ids)) then
    raise exception 'TTN creation is in progress for one of these orders';
  end if;
  if exists(select from public.orders where id=any(ids) and status in ('CANCELLED_BY_STORE','CANCELLED_BY_USER')) then
    raise exception 'Cancelled orders cannot be included in a shipment';
  end if;
  if exists(select 1 from public.orders where id=any(ids) and currency<>target.currency) then
    raise exception 'Orders in different currencies cannot be merged';
  end if;
  select count(*), count(*) filter (where payment_status='PAID') into selected_count, paid_count
    from public.orders where id=any(ids);
  if paid_count>0 and paid_count<selected_count then
    raise exception 'Paid and unpaid orders cannot be merged together';
  end if;
  insert into public.order_merge_members(order_id,root_id,author_id)
    select id,p_target_id,auth.uid() from public.orders where id=any(ids)
    on conflict (order_id) do update set root_id=excluded.root_id,author_id=excluded.author_id;
  update public.orders set crm_customer_id=target.crm_customer_id
    where id=any(ids) and id<>p_target_id;
  insert into public.order_events(order_id,kind,new_value,author_id)
    select id,'merge',p_target_id::text,auth.uid() from public.orders where id=any(ids);
  return p_target_id;
end; $function$;

CREATE OR REPLACE FUNCTION public.release_order_fulfillment_stock(p_order_ids uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  released record;
begin
  for released in
    select i.variant_id, sum(greatest(i.quantity - returned.quantity, 0)) as quantity
    from public.order_items i
    join public.orders o on o.id = i.order_id
    cross join lateral (
      select coalesce(sum(r.quantity), 0) as quantity from public.item_returns r
      where r.item_id = i.id and r.restock and r.status in ('received', 'completed')
    ) returned
    where i.order_id = any(p_order_ids)
      and coalesce(i.stock_deducted, not i.is_preorder) and i.variant_id is not null
    group by i.variant_id order by i.variant_id
  loop
    if released.quantity > 0 then
      update public.product_variants v set stock_quantity = (v.stock_quantity + released.quantity)::integer
      where v.id = released.variant_id;
    end if;
  end loop;

  -- A return may already have been opened before the cancellation. Whoever
  -- confirms receipt next can complete it without posting the stock twice.
  update public.item_returns r set restock = false
  from public.order_items i, public.orders o
  where r.item_id = i.id and o.id = i.order_id and i.order_id = any(p_order_ids)
    and coalesce(i.stock_deducted, not i.is_preorder) and r.status = 'requested' and r.restock;
  update public.order_items i set stock_deducted = false
  from public.orders o
  where o.id = i.order_id and i.order_id = any(p_order_ids)
    and coalesce(i.stock_deducted, not i.is_preorder);
  update public.orders set cancel_stock_pending = false
  where id = any(p_order_ids) and cancel_stock_pending;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_order_cancellation_refunds(p_order_ids uuid[])
 RETURNS TABLE(order_id uuid, receipt_code text, currency text, amount integer, method text, status text, error text, automatic_available boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select o.id, o.receipt_code, o.currency,
    coalesce(r.amount, case when o.payment_status = 'REFUNDED' or returned.amount >= o.total_price
      then returned.amount else o.total_price - returned.amount end::integer),
    r.method, coalesce(r.status, case when o.payment_status = 'REFUNDED' or returned.amount >= o.total_price
      then 'completed' end), r.error,
    o.payment_method = 'ONLINE' and returned.amount = 0 and exists (
      select 1 from public.payments p where p.order_id = o.id and p.status = 'PAID'
        and (p.provider = 'MONOBANK' or (p.provider = 'LIQPAY' and not coalesce(o.payment_test_mode, o.monobank_test_mode)))
    )
  from public.orders o
  left join public.order_cancellation_refunds r on r.order_id = o.id
  cross join lateral (select coalesce(sum(rr.amount), 0) as amount from public.order_returns rr where rr.order_id = o.id) returned
  where o.id = any(p_order_ids) and public.is_store_member(o.store_id)
    and o.status in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER')
    and o.total_price > 0
    and (o.payment_status in ('PAID', 'REFUNDED') or r.id is not null)
  order by o.created_at, o.id;
$function$;

CREATE OR REPLACE FUNCTION public.begin_order_cancellation_refund(p_order_id uuid, p_actor uuid, p_method text, p_amount integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  target public.orders;
  payment public.payments;
  operation public.order_cancellation_refunds;
  returned bigint;
begin
  select * into target from public.orders where id = p_order_id for update;
  if not found or not exists (select from public.store_members
      where store_id = target.store_id and user_id = p_actor) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  if target.status not in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER') then
    raise exception 'Only cancelled orders can be refunded';
  end if;
  if p_method is null or p_method not in ('manual', 'automatic', 'check') then raise exception 'Invalid refund method'; end if;

  select * into operation from public.order_cancellation_refunds where order_id = target.id;
  if p_method = 'check' then
    if operation.status is distinct from 'processing' then
      return jsonb_build_object('status', operation.status);
    end if;
    select * into payment from public.payments where id = operation.payment_id;
  else
    if operation.status in ('processing', 'completed') then
      return jsonb_build_object('status', operation.status);
    end if;
    select coalesce(sum(amount), 0) into returned from public.order_returns where order_id = target.id;
    if target.payment_status <> 'PAID' or p_amount is distinct from target.total_price - returned or p_amount <= 0 then
      raise exception 'The refundable amount has changed. Reload the order and try again.';
    end if;
    if p_method = 'automatic' then
      select * into payment from public.payments
      where order_id = target.id and status = 'PAID'
        and (provider = 'MONOBANK' or (provider = 'LIQPAY' and not coalesce(target.payment_test_mode, target.monobank_test_mode))) for update;
      if payment.id is null or target.payment_method <> 'ONLINE' or returned <> 0 then
        raise exception 'Automatic refund is unavailable for this order';
      end if;
    end if;
    insert into public.order_cancellation_refunds (order_id, payment_id, requested_by, amount, method, status)
    values (target.id, payment.id, p_actor, p_amount, p_method, 'processing')
    on conflict (order_id) do update set id = excluded.id, payment_id = excluded.payment_id,
      requested_by = excluded.requested_by, amount = excluded.amount, method = excluded.method,
      status = excluded.status, error = null, updated_at = now()
    returning * into operation;
    if p_method = 'manual' then
      return jsonb_build_object('status', public.finish_order_cancellation_refund(operation.id, 'completed'));
    end if;
  end if;
  return jsonb_build_object('status', operation.status, 'id', operation.id, 'amount', operation.amount,
    'currency', target.currency, 'provider', payment.provider, 'reference', payment.provider_order_id,
    'payment_id', payment.provider_payment_id, 'payment_test_mode', case when payment.provider = 'MONOBANK' then coalesce(target.payment_test_mode, target.monobank_test_mode) else target.payment_test_mode end);
end;
$function$;

CREATE OR REPLACE FUNCTION public.finish_order_cancellation_refund(p_id uuid, p_status text, p_error text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  operation public.order_cancellation_refunds;
  target public.orders;
begin
  if p_status not in ('completed', 'failed') then raise exception 'Invalid refund status'; end if;
  select o.* into target from public.orders o
    join public.order_cancellation_refunds r on r.order_id = o.id where r.id = p_id for update of o;
  select * into operation from public.order_cancellation_refunds where id = p_id for update;
  if not found then raise exception 'Refund operation not found'; end if;
  if operation.status <> 'processing' then return operation.status; end if;
  -- Keep the update and ledger entry in a single transaction.
  update public.order_cancellation_refunds set status = p_status, error = p_error, updated_at = now() where id = p_id;
  if p_status = 'completed' then
    insert into public.order_returns (id, order_id, amount, reason, author_id)
      values (p_id, target.id, operation.amount, 'Повернення за скасоване замовлення', operation.requested_by);
    insert into public.order_events (order_id, kind, new_value, author_id)
      values (target.id, 'return', operation.amount::text, operation.requested_by);
    update public.orders set payment_status = 'REFUNDED' where id = target.id;
    update public.payments set status = 'REFUNDED', updated_at = now()
      where order_id = target.id and status = 'PAID';
  end if;
  return p_status;
end;
$function$;

CREATE OR REPLACE FUNCTION public.pending_order_cancellation_refund(p_provider text, p_reference text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object('id', r.id, 'amount', r.amount, 'currency', o.currency,
    'provider', p.provider, 'reference', p.provider_order_id, 'payment_id', p.provider_payment_id,
    'payment_test_mode', case when p.provider = 'MONOBANK' then coalesce(o.payment_test_mode, o.monobank_test_mode) else o.payment_test_mode end)
  from public.order_cancellation_refunds r
  join public.payments p on p.id = r.payment_id
  join public.orders o on o.id = r.order_id
  where r.status = 'processing' and p.provider = p_provider and p.provider_order_id = p_reference;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_order_cancellation_refund(p_order_id uuid, p_attempt_id uuid, p_actor uuid, p_resolution text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  target public.orders;
  operation public.order_cancellation_refunds;
  outcome text;
begin
  select * into target from public.orders where id = p_order_id for update;
  if not found or not exists (select from public.store_members
      where store_id = target.store_id and user_id = p_actor) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  if target.status not in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER') then
    raise exception 'Only cancelled orders can be refunded';
  end if;
  select * into operation from public.order_cancellation_refunds where order_id = target.id for update;
  if operation.id is distinct from p_attempt_id or not public.can_review_order_refund(operation.id) then
    raise exception 'The refund has changed or is still being processed. Check its status again.';
  end if;
  if p_resolution = 'record_paid' then
    update public.order_cancellation_refunds set requested_by = p_actor, method = 'manual' where id = operation.id;
    outcome := public.finish_order_cancellation_refund(operation.id, 'completed');
  elsif p_resolution = 'not_started' then
    outcome := public.finish_order_cancellation_refund(operation.id, 'failed',
      'The bank did not start this refund. You can try again.');
  else
    raise exception 'Invalid refund resolution';
  end if;
  insert into public.order_events (order_id, kind, new_value, author_id)
    values (target.id, 'refund_review', case when p_resolution = 'record_paid'
      then 'Refund recorded after checking the bank' else 'The bank did not start this refund. You can try again.' end, p_actor);
  return outcome;
end;
$function$;

drop trigger guard_live_waybill_reservation on public.order_ttn_reservations;
drop function public.guard_live_waybill_reservation();

drop trigger restock_cancelled_procurement on public.orders;
create trigger restock_cancelled_procurement after update of status on public.orders
for each row when (new.payment_method = 'ONLINE'
  and new.status in ('CANCELLED_BY_USER', 'CANCELLED_BY_STORE')
  and old.status not in ('CANCELLED_BY_USER', 'CANCELLED_BY_STORE')
  and old.reopened_procurement_progressed is not false)
execute function public.restock_cancelled_procurement();

drop trigger correct_reopened_order on public.orders;
create trigger correct_reopened_order before update of status on public.orders
for each row when (old.status is distinct from new.status)
execute function public.correct_reopened_order();

drop index public.online_checkouts_dashboard_period;
create index online_checkouts_dashboard_period on public.online_checkouts(store_id, created_at);
drop index public.online_checkout_reconciliation;
create index online_checkout_reconciliation on public.online_checkouts(bank_checked_at nulls first, created_at)
  where status = 'PENDING';

create or replace function public.crm_dashboard_payment_stats(p_store_id uuid, p_from date, p_to date, p_currency text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not coalesce(public.is_store_member(p_store_id),false) then
    raise exception 'Access denied' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Invalid date range'; end if;
  return (select jsonb_build_object(
    'paid',count(*) filter (where status = 'PAID' and created_at is not null),
    'failed',count(*) filter (where status = 'FAILED' and created_at is not null),
    'pending',count(*) filter (where status = 'PENDING' and created_at is not null and expires_at > now()),
    'expired',count(*) filter (where status = 'PENDING' and created_at is not null and expires_at <= now()),
    'undated',count(*) filter (where created_at is null)
  ) from public.online_checkouts
  where store_id = p_store_id and currency = p_currency
    and (created_at is null or (created_at >= (p_from::timestamp at time zone 'Europe/Kyiv')
      and created_at < ((p_to + 1)::timestamp at time zone 'Europe/Kyiv'))));
end;
$$;

create or replace function public.claim_payment_checks() returns table(id uuid, provider text, provider_order_id text, test_mode boolean, expires_at timestamptz)
language sql security definer set search_path='' as $$
  with batch as (select c.id from public.online_checkouts c
    where c.status='PENDING' and c.created_at < now()-interval '5 minutes'
      and (c.bank_checked_at is null or c.bank_checked_at < now() -
        case when c.expires_at < now()-interval '1 day' then interval '6 hours' else interval '14 minutes' end)
    order by c.bank_checked_at nulls first,c.created_at desc limit 60 for update skip locked)
  update public.online_checkouts c set bank_checked_at=now() from batch
    where batch.id=c.id returning c.id,c.provider,c.provider_order_id,c.test_mode,c.expires_at;
$$;

create or replace function public.payment_reviews(p_store uuid) returns table(receipt_code text, provider text, bank_reference text, total_price integer,currency text, reason text)
language sql stable security definer set search_path='' as $$
  select c.receipt_code,c.provider,c.provider_order_id,c.total_price,c.currency,c.bank_review_reason from public.online_checkouts c
  where c.store_id=p_store and public.is_store_member(p_store) and c.status='PENDING'
    and c.bank_review_reason is not null order by c.created_at desc;
$$;

notify pgrst, 'reload schema';

commit;
