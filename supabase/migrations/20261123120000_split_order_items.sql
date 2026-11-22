alter table public.orders add column split_origin_id uuid references public.orders(id) on delete set null;
create index orders_split_origin on public.orders(split_origin_id) where split_origin_id is not null;

create function public.split_order_items(p_order_id uuid, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  source public.orders;
  created public.orders;
  source_store uuid;
  origin_id uuid;
  line record;
  inserted_item uuid;
  source_quantity bigint;
  moved_quantity bigint;
  source_total bigint;
  moved_total integer;
  moved_line_total integer;
  value_basis bigint;
  moved_basis bigint;
  moved_discount integer;
  saved_cost integer;
  source_item_cost bigint;
  moved_item_cost bigint;
  moved_cost integer;
begin
  select store_id into source_store from public.orders where id = p_order_id;
  if source_store is null or not coalesce(public.is_store_member(source_store), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || source_store::text, 0));
  select * into source from public.orders where id = p_order_id and store_id = source_store for update;
  if not found then raise exception 'Order not found'; end if;

  if source.status not in ('IN_PROGRESS', 'WAITING_FOR_STOCK', 'PREPARING_SHIPMENT') or source.shipment_was_dispatched then
    raise sqlstate 'PT409' using message = 'Only orders that have not been shipped can be split.';
  end if;
  if source.nova_poshta_ttn is not null or source.nova_poshta_document_ref is not null then
    raise sqlstate 'PT409' using message = 'Unlink the TTN before splitting the order.';
  end if;
  if exists (select from public.order_ttn_reservations where order_id = source.id) then
    raise sqlstate 'PT409' using message = 'Resolve the TTN attempt before splitting the order.';
  end if;
  if exists (select from public.order_merge_members where order_id = source.id or root_id = source.id) then
    raise sqlstate 'PT409' using message = 'Combined shipments cannot be split into separate orders here.';
  end if;
  if source.payment_status <> 'PAID' and (source.payment_method <> 'CASH_ON_DELIVERY' or source.payment_status <> 'PENDING') then
    raise sqlstate 'PT409' using message = 'Only paid orders and unpaid cash-on-delivery orders can be split.';
  end if;
  if exists (select from public.item_returns where order_id = source.id)
    or exists (select from public.order_returns where order_id = source.id)
    or exists (select from public.order_cancellation_refunds where order_id = source.id) then
    raise sqlstate 'PT409' using message = 'An order with a return or refund cannot be split.';
  end if;
  if coalesce(jsonb_typeof(p_items), '') <> 'array' then
    raise exception 'Choose the items and quantities to move.';
  end if;
  if jsonb_array_length(p_items) = 0 then raise exception 'Choose the items and quantities to move.'; end if;

  perform 1 from public.order_items where order_id = source.id order by id for update;
  if (
    select count(distinct r.item_id) <> count(*) or coalesce(bool_or(
      i.id is null or r.quantity is null or r.quantity < 1 or r.quantity > i.quantity
      or r.expected_quantity is distinct from i.quantity or r.expected_line_total is distinct from i.line_total
    ), true)
    from jsonb_to_recordset(p_items) as r(item_id uuid, quantity integer, expected_quantity integer, expected_line_total integer)
    left join public.order_items i on i.id = r.item_id and i.order_id = source.id
  ) then
    raise sqlstate 'PT409' using message = 'The selected items have changed. Refresh the order and try again.';
  end if;

  select sum(i.quantity), sum(i.line_total), sum(i.quantity::bigint * greatest(i.unit_price, i.compare_at_price)),
    case when bool_and(c.unit_cost is not null) then sum(i.quantity::bigint * c.unit_cost) end
  into source_quantity, source_total, value_basis, source_item_cost
  from public.order_items i left join public.order_item_costs c on c.item_id = i.id
  where i.order_id = source.id;
  select sum(r.quantity), sum(round(i.line_total::numeric * r.quantity / i.quantity))::integer,
    sum(r.quantity::bigint * greatest(i.unit_price, i.compare_at_price)),
    case when bool_and(c.unit_cost is not null) then sum(r.quantity::bigint * c.unit_cost) end
  into moved_quantity, moved_total, moved_basis, moved_item_cost
  from jsonb_to_recordset(p_items) as r(item_id uuid, quantity integer)
  join public.order_items i on i.id = r.item_id and i.order_id = source.id
  left join public.order_item_costs c on c.item_id = i.id;

  if moved_quantity is null or moved_quantity >= source_quantity then
    raise exception 'Leave at least one item in the original order.';
  end if;
  if source_total is distinct from source.total_price::bigint then
    raise sqlstate 'PT409' using message = 'The order total does not match its items. It cannot be split.';
  end if;
  -- Historical lines already include discounts. Only the order-level summary is allocated proportionally.
  moved_discount := round(source.customer_discount_amount::numeric
    * case when value_basis > 0 then moved_basis::numeric / value_basis else moved_quantity::numeric / source_quantity end);
  select cost_amount into saved_cost from public.order_financials where order_id = source.id for update;
  if saved_cost is not null then
    moved_cost := round(saved_cost::numeric * case
      when source_item_cost > 0 then moved_item_cost::numeric / source_item_cost
      when value_basis > 0 then moved_basis::numeric / value_basis
      else moved_quantity::numeric / source_quantity end);
  end if;

  origin_id := coalesce(source.split_origin_id, source.id);
  insert into public.orders (
    store_id, user_id, crm_customer_id, status, payment_status, payment_method, customer_name, customer_email,
    customer_phone, delivery_city, delivery_address, delivery_city_ref, delivery_address_ref, delivery_service_type,
    note, total_price, currency, created_at, monobank_test_mode, payment_test_mode,
    customer_discount_id, customer_discount_percent, customer_discount_amount, reopened_procurement_progressed, split_origin_id
  ) values (
    source.store_id, source.user_id, source.crm_customer_id, source.status, source.payment_status, source.payment_method,
    source.customer_name, source.customer_email, source.customer_phone, source.delivery_city, source.delivery_address,
    source.delivery_city_ref, source.delivery_address_ref, source.delivery_service_type, source.note, moved_total,
    source.currency, source.created_at, source.monobank_test_mode, source.payment_test_mode,
    source.customer_discount_id, source.customer_discount_percent, moved_discount, source.reopened_procurement_progressed, origin_id
  ) returning * into created;
  -- Identity lookup on insert must not detach an existing CRM customer link.
  if created.crm_customer_id is distinct from source.crm_customer_id then
    update public.orders set crm_customer_id = source.crm_customer_id where id = created.id;
  end if;

  for line in
    select i.*, r.quantity as move_quantity, c.unit_cost
    from jsonb_to_recordset(p_items) as r(item_id uuid, quantity integer)
    join public.order_items i on i.id = r.item_id and i.order_id = source.id
    left join public.order_item_costs c on c.item_id = i.id
    order by i.id
  loop
    if line.move_quantity = line.quantity then
      update public.order_items set order_id = created.id where id = line.id;
    else
      moved_line_total := round(line.line_total::numeric * line.move_quantity / line.quantity);
      update public.order_items set quantity = line.quantity - line.move_quantity,
        line_total = line.line_total - moved_line_total where id = line.id;
      insert into public.order_items (
        order_id, product_id, variant_id, product_name, variant_name, quantity, unit_price, compare_at_price,
        line_total, is_preorder, stock_deducted
      ) values (
        created.id, line.product_id, line.variant_id, line.product_name, line.variant_name, line.move_quantity,
        line.unit_price, line.compare_at_price, moved_line_total, line.is_preorder, line.stock_deducted
      ) returning id into inserted_item;
      -- Inserts normally snapshot current catalog data. The split keeps the original snapshots.
      update public.order_items set weight_grams = line.weight_grams, procurement_restocked = line.procurement_restocked
        where id = inserted_item;
      insert into public.order_item_costs(item_id, unit_cost) values (inserted_item, line.unit_cost)
        on conflict (item_id) do update set unit_cost = excluded.unit_cost;
    end if;
  end loop;

  update public.orders set total_price = total_price - moved_total,
    customer_discount_amount = customer_discount_amount - moved_discount, split_origin_id = origin_id
    where id = source.id;
  if saved_cost is not null then
    update public.order_financials set cost_amount = saved_cost - moved_cost, updated_at = now()
      where order_id = source.id;
    insert into public.order_financials(order_id, cost_amount) values (created.id, moved_cost);
  else
    insert into public.order_financials(order_id, cost_amount)
    select i.order_id, sum(i.quantity::bigint * c.unit_cost)::integer
    from public.order_items i left join public.order_item_costs c on c.item_id = i.id
    where i.order_id in (source.id, created.id)
    group by i.order_id having bool_and(c.unit_cost is not null)
    on conflict (order_id) do nothing;
  end if;

  insert into public.order_events(order_id, kind, new_value, author_id) values
    (source.id, 'split_order', '#' || created.receipt_code, auth.uid()),
    (created.id, 'split_from', '#' || source.receipt_code, auth.uid());
  return jsonb_build_object('order_id', created.id, 'receipt_code', created.receipt_code);
end;
$$;

revoke all on function public.split_order_items(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.split_order_items(uuid, jsonb) to authenticated;

create or replace function public.customer_discount_usage(p_discount uuid)
returns bigint language sql stable security definer set search_path = '' as $$
  select (select count(distinct coalesce(o.split_origin_id, o.id)) from public.orders o
    where o.customer_discount_id = p_discount and o.status not in ('CANCELLED_BY_USER', 'CANCELLED_BY_STORE'))
    + (select count(*) from public.online_checkouts c where c.customer_discount_id = p_discount
      and c.status = 'PENDING' and not exists (select from public.orders o where o.id = c.id));
$$;

create or replace function public.notify_order_event() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.kind in ('status','payment_status','return') then
    insert into public.customer_notifications(user_id,store_id,event_id,order_id,receipt_code,kind,value)
    select o.user_id,o.store_id,new.id,o.id,o.receipt_code,new.kind,new.new_value from public.orders o
    where o.id = new.order_id and o.user_id is not null
      and (o.split_origin_id is null or new.old_value is not null or new.kind = 'return');
  end if;
  return new;
end;
$$;

create or replace function public.get_order_cancellation_refunds(p_order_ids uuid[])
returns table(order_id uuid, receipt_code text, currency text, amount integer, method text, status text, error text, automatic_available boolean)
language sql stable security definer set search_path = '' as $$
  select o.id, o.receipt_code, o.currency,
    coalesce(r.amount, case when o.payment_status = 'REFUNDED' or returned.amount >= o.total_price
      then returned.amount else o.total_price - returned.amount end::integer),
    r.method, coalesce(r.status, case when o.payment_status = 'REFUNDED' or returned.amount >= o.total_price
      then 'completed' end), r.error,
    o.split_origin_id is null and o.payment_method = 'ONLINE' and returned.amount = 0 and exists (
      select from public.payments p where p.order_id = o.id and p.status = 'PAID'
        and (p.provider = 'MONOBANK' or (p.provider = 'LIQPAY' and not coalesce(o.payment_test_mode, o.monobank_test_mode)))
    )
  from public.orders o
  left join public.order_cancellation_refunds r on r.order_id = o.id
  cross join lateral (select coalesce(sum(rr.amount), 0) as amount from public.order_returns rr where rr.order_id = o.id) returned
  where o.id = any(p_order_ids) and public.is_store_member(o.store_id)
    and o.status in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER') and o.total_price > 0
    and (o.payment_status in ('PAID', 'REFUNDED') or r.id is not null)
  order by o.created_at, o.id;
$$;

create function public.guard_split_order_automatic_refund() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select from public.orders where id = new.order_id and split_origin_id is not null) then
    raise sqlstate 'PT409' using message = 'Refunds for split orders must be recorded manually.';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_split_order_automatic_refund() from public, anon, authenticated, service_role;
create trigger guard_split_order_automatic_refund before insert or update of method on public.order_cancellation_refunds
  for each row when (new.method = 'automatic') execute function public.guard_split_order_automatic_refund();

create or replace function public.finish_order_cancellation_refund(p_id uuid, p_status text, p_error text default null)
returns text language plpgsql security definer set search_path = '' as $$
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
  update public.order_cancellation_refunds set status = p_status, error = p_error, updated_at = now() where id = p_id;
  if p_status = 'completed' then
    insert into public.order_returns (id, order_id, amount, reason, author_id)
      values (p_id, target.id, operation.amount, 'Повернення за скасоване замовлення', operation.requested_by);
    insert into public.order_events (order_id, kind, new_value, author_id)
      values (target.id, 'return', operation.amount::text, operation.requested_by);
    update public.orders set payment_status = 'REFUNDED' where id = target.id;
    if target.split_origin_id is null then
      update public.payments set status = 'REFUNDED', updated_at = now()
        where order_id = target.id and status = 'PAID';
    end if;
  end if;
  return p_status;
end;
$$;

notify pgrst, 'reload schema';
