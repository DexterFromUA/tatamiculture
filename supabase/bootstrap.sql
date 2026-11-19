-- tatami.culture · начальная схема от 18 ноября 2026 года
-- Для нового проекта Supabase с PostgreSQL 17, Auth и Storage.
-- Выполните файл целиком в SQL Editor под ролью postgres.
-- Создаётся пустой магазин tatami. Существующие заказы, пользователи, файлы
-- и ключи интеграций не копируются. Команда назначения владельца — в конце.
-- Учтены миграции репозитория по 20261119101000 включительно.
BEGIN;

DO $$
BEGIN
  IF to_regclass('public.stores') IS NOT NULL THEN
    RAISE EXCEPTION 'Tatami is already installed. Use a new Supabase project.';
  END IF;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS http WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

SET LOCAL search_path = '';
-- pg_dump orders functions with forward references before some of their tables.
SET LOCAL check_function_bodies = false;

CREATE TYPE "public"."order_status" AS ENUM (
    'PENDING',
    'PAID',
    'IN_PROGRESS',
    'READY_FOR_PICKUP',
    'DELIVERED',
    'CANCELLED_BY_USER',
    'CANCELLED_BY_STORE'
);

ALTER TYPE "public"."order_status" OWNER TO "postgres";

CREATE TYPE "public"."payment_status" AS ENUM (
    'PENDING',
    'PAID',
    'FAILED',
    'REFUNDED'
);

ALTER TYPE "public"."payment_status" OWNER TO "postgres";

CREATE TYPE "public"."staff_role" AS ENUM (
    'OWNER',
    'MANAGER',
    'CONTENT'
);

ALTER TYPE "public"."staff_role" OWNER TO "postgres";

SET LOCAL default_tablespace = '';

SET LOCAL default_table_access_method = "heap";

CREATE TABLE "public"."customer_discounts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "store_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "percent" numeric(5,2) NOT NULL,
    "mode" "text" NOT NULL,
    "order_limit" integer,
    "starts_on" "date",
    "ends_on" "date",
    "enabled" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "customer_discounts_check" CHECK ((("mode" = 'orders'::"text") = ("order_limit" IS NOT NULL))),
    CONSTRAINT "customer_discounts_check1" CHECK ((("mode" = 'period'::"text") = (("starts_on" IS NOT NULL) AND ("ends_on" IS NOT NULL)))),
    CONSTRAINT "customer_discounts_check2" CHECK ((("starts_on" IS NULL) OR ("ends_on" >= "starts_on"))),
    CONSTRAINT "customer_discounts_mode_check" CHECK (("mode" = ANY (ARRAY['unlimited'::"text", 'orders'::"text", 'period'::"text"]))),
    CONSTRAINT "customer_discounts_order_limit_check" CHECK (("order_limit" > 0)),
    CONSTRAINT "customer_discounts_percent_check" CHECK ((("percent" > (0)::numeric) AND ("percent" <= (100)::numeric)))
);

ALTER TABLE "public"."customer_discounts" OWNER TO "postgres";

CREATE FUNCTION "public"."active_customer_discount"("p_store" "uuid", "p_user" "uuid") RETURNS "public"."customer_discounts"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare d public.customer_discounts;
begin
  if p_user is null then return null; end if;
  -- Shared with CRM edits and both checkout methods, including first-time assignment.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_store::text || p_user::text, 1));
  select * into d from public.customer_discounts
  where store_id = p_store and user_id = p_user and enabled for update;
  if not found or (d.mode = 'period' and (now() at time zone 'Europe/Kyiv')::date not between d.starts_on and d.ends_on)
    or (d.mode = 'orders' and public.customer_discount_usage(d.id) >= d.order_limit) then return null; end if;
  return d;
end;
$$;

ALTER FUNCTION "public"."active_customer_discount"("p_store" "uuid", "p_user" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."adjust_catalog_stock"("p_variant" "uuid", "p_kind" "text", "p_quantity" integer, "p_reason" "text", "p_request" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
  target_store uuid;
begin
  select p.store_id into target_store from public.product_variants v
    join public.products p on p.id = v.product_id where v.id = p_variant;
  if target_store is null or not coalesce(public.is_store_member(target_store), false) then
    raise exception 'Manager access required';
  end if;
  if p_kind is null or p_kind not in ('receipt', 'writeoff', 'correction')
      or p_quantity is null or p_quantity < 0 or (p_kind <> 'correction' and p_quantity = 0)
      or coalesce(length(trim(p_reason)), 0) not between 1 and 500 then
    raise exception 'Invalid stock operation';
  end if;
  if p_request is not null then
    insert into public.stock_adjustment_requests(id,variant_id,kind,quantity,reason)
      values(p_request,p_variant,p_kind,p_quantity,trim(p_reason)) on conflict(id) do nothing;
    if not found then
      if not exists(select 1 from public.stock_adjustment_requests where id=p_request and variant_id=p_variant and kind=p_kind and quantity=p_quantity and reason=trim(p_reason)) then
        raise exception 'Request was already used for another operation';
      end if;
      return;
    end if;
  end if;
  perform set_config('tatami.stock_kind', p_kind, true);
  perform set_config('tatami.stock_reason', trim(p_reason), true);
  update public.product_variants set stock_quantity = case p_kind
    when 'receipt' then stock_quantity + p_quantity
    when 'writeoff' then stock_quantity - p_quantity
    else p_quantity end
  where id = p_variant;
  if not found then raise exception 'Variant unavailable'; end if;
end;
$$;

ALTER FUNCTION "public"."adjust_catalog_stock"("p_variant" "uuid", "p_kind" "text", "p_quantity" integer, "p_reason" "text", "p_request" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."advance_item_return"("p_id" "uuid", "p_status" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "public"."advance_item_return"("p_id" "uuid", "p_status" "text") OWNER TO "postgres";

CREATE FUNCTION "public"."aggregate_order_cost"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
 if not exists(select 1 from public.order_items i left join public.order_item_costs c on c.item_id=i.id where i.order_id=new.order_id and c.unit_cost is null) then
  insert into public.order_financials(order_id,cost_amount)
   select new.order_id,sum(i.quantity::bigint*c.unit_cost)::integer from public.order_items i join public.order_item_costs c on c.item_id=i.id where i.order_id=new.order_id
   on conflict(order_id) do nothing;
 end if;
 return new;
end; $$;

ALTER FUNCTION "public"."aggregate_order_cost"() OWNER TO "postgres";

CREATE TABLE "public"."orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "store_id" "uuid" NOT NULL,
    "user_id" "uuid",
    "status" "public"."order_status" DEFAULT 'PENDING'::"public"."order_status" NOT NULL,
    "payment_status" "public"."payment_status" DEFAULT 'PENDING'::"public"."payment_status" NOT NULL,
    "receipt_code" "text" DEFAULT "encode"("extensions"."gen_random_bytes"(12), 'hex'::"text") NOT NULL,
    "customer_name" "text" NOT NULL,
    "customer_email" "text" NOT NULL,
    "customer_phone" "text" NOT NULL,
    "delivery_city" "text" NOT NULL,
    "delivery_address" "text" NOT NULL,
    "note" "text" DEFAULT ''::"text" NOT NULL,
    "total_price" integer NOT NULL,
    "currency" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "delivery_city_ref" "text",
    "delivery_address_ref" "text",
    "delivery_service_type" "text",
    "nova_poshta_ttn" "text",
    "nova_poshta_document_ref" "text",
    "nova_poshta_ttn_created_at" timestamp with time zone,
    "payment_method" "text" DEFAULT 'CASH_ON_DELIVERY'::"text" NOT NULL,
    "nova_poshta_status" "text",
    "nova_poshta_status_code" "text",
    "nova_poshta_status_updated_at" timestamp with time zone,
    "crm_customer_id" "uuid",
    "monobank_test_mode" boolean DEFAULT false NOT NULL,
    "payment_test_mode" boolean,
    "reserved_in_profile" boolean DEFAULT false NOT NULL,
    "customer_discount_id" "uuid",
    "customer_discount_percent" numeric(5,2) DEFAULT 0 NOT NULL,
    "customer_discount_amount" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "orders_currency_check" CHECK (("char_length"("currency") = 3)),
    CONSTRAINT "orders_payment_method_check" CHECK (("payment_method" = ANY (ARRAY['ONLINE'::"text", 'CASH_ON_DELIVERY'::"text"]))),
    CONSTRAINT "orders_total_price_check" CHECK (("total_price" >= 0)),
    CONSTRAINT "test_payment_order_status_check" CHECK (((("payment_test_mode" IS NOT TRUE) AND (NOT "monobank_test_mode")) OR ("status" = ANY (ARRAY['PENDING'::"public"."order_status", 'PAID'::"public"."order_status", 'CANCELLED_BY_USER'::"public"."order_status", 'CANCELLED_BY_STORE'::"public"."order_status"]))))
);

ALTER TABLE "public"."orders" OWNER TO "postgres";

CREATE FUNCTION "public"."apply_admin_order_update"("p_order_ids" "uuid"[], "p_status" "public"."order_status", "p_confirm_paid" boolean, "p_include_group" boolean, "p_restore_stock" boolean) RETURNS SETOF "public"."orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  store uuid;
  affected_ids uuid[];
  order_id uuid;
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

  if p_include_group then
    -- Use the same lock as merge_orders so group membership stays fixed.
    perform pg_advisory_xact_lock(hashtextextended('order-merge:' || store::text, 0));
  end if;
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

  if p_restore_stock then
    foreach order_id in array affected_ids loop
      perform public.restore_stock_and_cancel_order(order_id);
    end loop;
  else
    update public.orders o
    set status = p_status,
        payment_status = case p_status
          when 'PAID' then 'PAID'::public.payment_status
          when 'PENDING' then 'PENDING'::public.payment_status
          else o.payment_status
        end
    where o.id = any(affected_ids);
    insert into public.order_status_history (order_id, status, author_id)
    select o.id, o.status, auth.uid() from public.orders o where o.id = any(affected_ids);
  end if;

  return query select o.* from public.orders o where o.id = any(affected_ids);
end;
$$;

ALTER FUNCTION "public"."apply_admin_order_update"("p_order_ids" "uuid"[], "p_status" "public"."order_status", "p_confirm_paid" boolean, "p_include_group" boolean, "p_restore_stock" boolean) OWNER TO "postgres";

CREATE FUNCTION "public"."apply_online_payment_callback"("p_provider" "text", "p_reference" "text", "p_paid" boolean, "p_payment_id" "text", "p_callback" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_order public.orders;
  v_payment public.payments;
  v_status public.payment_status := case when p_paid then 'PAID' else 'FAILED' end;
begin
  select o.* into v_order from public.orders o
  join public.payments p on p.order_id = o.id
  where p.provider = p_provider and p.provider_order_id = p_reference
  for update of o;
  if not found or v_order.status = 'CANCELLED_BY_USER' then return; end if;

  select * into v_payment from public.payments
  where order_id = v_order.id and provider = p_provider and provider_order_id = p_reference for update;
  if not found or v_payment.status = 'REFUNDED' or (not p_paid and v_payment.status = 'PAID') then return; end if;

  update public.payments set status = v_status,
    provider_payment_id = coalesce(p_payment_id, provider_payment_id), raw_callback = p_callback
  where id = v_payment.id;

  if v_order.payment_status in ('PENDING', 'FAILED') or (p_paid and v_order.payment_status = 'PAID' and v_order.status = 'PENDING') then
    update public.orders set payment_status = v_status,
      status = case when p_paid and status = 'PENDING' then 'PAID'::public.order_status else status end
    where id = v_order.id;
  end if;
end;
$$;

ALTER FUNCTION "public"."apply_online_payment_callback"("p_provider" "text", "p_reference" "text", "p_paid" boolean, "p_payment_id" "text", "p_callback" "jsonb") OWNER TO "postgres";

CREATE FUNCTION "public"."attach_crm_customer"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare identity_key text;
begin
 if coalesce(new.payment_test_mode, new.monobank_test_mode) then return new; end if;
 identity_key := case when new.user_id is not null then 'user:'||new.user_id::text
  when length(regexp_replace(new.customer_phone,'[^0-9]','','g'))>=9 then 'phone:'||regexp_replace(new.customer_phone,'[^0-9]','','g')
  when trim(new.customer_email)<>'' then 'email:'||lower(trim(new.customer_email)) else 'order:'||new.id::text end;
 new.crm_customer_id := public.crm_identity(new.store_id,identity_key,new.customer_name,new.customer_phone,new.customer_email);
 return new;
end; $$;

ALTER FUNCTION "public"."attach_crm_customer"() OWNER TO "postgres";

CREATE TABLE "public"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "provider" "text" NOT NULL,
    "provider_order_id" "text" NOT NULL,
    "provider_payment_id" "text",
    "status" "public"."payment_status" DEFAULT 'PENDING'::"public"."payment_status" NOT NULL,
    "raw_callback" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "checkout_url" "text",
    "checkout_managed" boolean DEFAULT false NOT NULL,
    "checkout_started" boolean DEFAULT false NOT NULL,
    "checkout_operation" "uuid",
    "checkout_operation_until" timestamp with time zone,
    CONSTRAINT "payments_provider_check" CHECK (("provider" = ANY (ARRAY['LIQPAY'::"text", 'MONOBANK'::"text"])))
);

ALTER TABLE "public"."payments" OWNER TO "postgres";

CREATE FUNCTION "public"."begin_reserved_order_action"("p_order_id" "uuid", "p_user_id" "uuid", "p_operation" "uuid") RETURNS "public"."payments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_order public.orders;
  v_payment public.payments;
begin
  select * into v_order from public.orders
  where id = p_order_id and user_id = p_user_id for update;
  if not found or v_order.payment_method <> 'ONLINE' then
    raise sqlstate 'PT404' using message = 'Order not found';
  end if;
  if v_order.status <> 'PENDING' or v_order.payment_status not in ('PENDING', 'FAILED') then
    raise sqlstate 'PT409' using message = 'This reservation is no longer awaiting payment.';
  end if;

  select * into v_payment from public.payments where order_id = p_order_id for update;
  if not found or v_payment.status not in ('PENDING', 'FAILED') then
    raise sqlstate 'PT409' using message = 'This reservation is no longer awaiting payment.';
  end if;
  if v_payment.checkout_operation_until > now() then
    raise sqlstate 'PT409' using message = 'Another payment action is in progress. Try again shortly.';
  end if;

  update public.payments
  set checkout_operation = p_operation, checkout_operation_until = now() + interval '90 seconds'
  where id = v_payment.id returning * into v_payment;
  return v_payment;
end;
$$;

ALTER FUNCTION "public"."begin_reserved_order_action"("p_order_id" "uuid", "p_user_id" "uuid", "p_operation" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."cancel_customer_reservation"("p_order_id" "uuid", "p_user_id" "uuid", "p_operation" "uuid", "p_provider_order_id" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

  if not coalesce(v_order.payment_test_mode, v_order.monobank_test_mode) then
    for v_item in
      select variant_id, sum(quantity)::integer as quantity from public.order_items
      where order_id = p_order_id and coalesce(stock_deducted, not is_preorder) and variant_id is not null
      group by variant_id order by variant_id
    loop
      update public.product_variants set stock_quantity = stock_quantity + v_item.quantity where id = v_item.variant_id;
    end loop;
  end if;

  update public.orders set status = 'CANCELLED_BY_USER', payment_status = 'FAILED' where id = p_order_id;
  update public.payments set status = 'FAILED', checkout_url = null,
    checkout_operation = null, checkout_operation_until = null where id = v_payment.id;
  insert into public.order_status_history (order_id, status, author_id)
  values (p_order_id, 'CANCELLED_BY_USER', p_user_id);
end;
$$;

ALTER FUNCTION "public"."cancel_customer_reservation"("p_order_id" "uuid", "p_user_id" "uuid", "p_operation" "uuid", "p_provider_order_id" "text") OWNER TO "postgres";

CREATE FUNCTION "public"."cancel_merged_unpaid_order"("p_order_id" "uuid") RETURNS "public"."orders"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select o from public.apply_admin_order_update(array[p_order_id], 'CANCELLED_BY_STORE', false, true, true) o
  where o.id = p_order_id;
$$;

ALTER FUNCTION "public"."cancel_merged_unpaid_order"("p_order_id" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."cancel_unpaid_order"("p_order_id" "uuid") RETURNS "public"."orders"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select o from public.apply_admin_order_update(array[p_order_id], 'CANCELLED_BY_STORE', false, false, true) o
  where o.id = p_order_id;
$$;

ALTER FUNCTION "public"."cancel_unpaid_order"("p_order_id" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."capture_order_events"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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

ALTER FUNCTION "public"."capture_order_events"() OWNER TO "postgres";

CREATE FUNCTION "public"."capture_stock_movement"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  insert into public.stock_movements(store_id, variant_id, previous_quantity, quantity, kind, reason, author_id)
  select p.store_id, new.id, old.stock_quantity, new.stock_quantity,
    coalesce(nullif(current_setting('tatami.stock_kind', true), ''), 'automatic'),
    nullif(current_setting('tatami.stock_reason', true), ''), auth.uid()
  from public.products p where p.id = new.product_id;
  return new;
end;
$$;

ALTER FUNCTION "public"."capture_stock_movement"() OWNER TO "postgres";

CREATE FUNCTION "public"."catalog_cost_in_uah"("p_amount" integer, "p_currency" "text") RETURNS numeric
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select case when p_currency = 'UAH' then p_amount::numeric
    else round(p_amount * (select r.uah_rate from public.catalog_exchange_rates r where r.currency = p_currency))
  end;
$$;

ALTER FUNCTION "public"."catalog_cost_in_uah"("p_amount" integer, "p_currency" "text") OWNER TO "postgres";

CREATE FUNCTION "public"."change_merged_order_status"("p_order_id" "uuid", "p_status" "public"."order_status") RETURNS "public"."orders"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select o from public.apply_admin_order_update(array[p_order_id], p_status, false, true, false) o
  where o.id = p_order_id;
$$;

ALTER FUNCTION "public"."change_merged_order_status"("p_order_id" "uuid", "p_status" "public"."order_status") OWNER TO "postgres";

CREATE FUNCTION "public"."change_order_status"("p_order_id" "uuid", "p_status" "public"."order_status") RETURNS "public"."orders"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select o from public.apply_admin_order_update(array[p_order_id], p_status, false, false, false) o
  where o.id = p_order_id;
$$;

ALTER FUNCTION "public"."change_order_status"("p_order_id" "uuid", "p_status" "public"."order_status") OWNER TO "postgres";

CREATE FUNCTION "public"."check_category_parent"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if tg_op = 'UPDATE' then
    if new.parent_id is distinct from old.parent_id then
      raise exception 'Category parent cannot be changed' using errcode = '23514';
    end if;
  end if;
  if new.parent_id is not null and not exists (
    select 1 from public.categories
    where id = new.parent_id and store_id = new.store_id and parent_id is null
  ) then
    raise exception 'Choose a main category from this store' using errcode = '23514';
  end if;
  return new;
end;
$$;

ALTER FUNCTION "public"."check_category_parent"() OWNER TO "postgres";

CREATE FUNCTION "public"."claim_guest_order"("p_store_id" "uuid", "p_receipt_code" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  account_id uuid := auth.uid();
  verified_phone text;
  receipt text := lower(trim(p_receipt_code));
  target public.orders%rowtype;
  order_phone text;
  customer_id uuid;
begin
  if account_id is null or receipt is null or receipt !~ '^[0-9a-f]{24}$' then
    return false;
  end if;

  select ltrim(u.phone, '+') into verified_phone
  from auth.users u
  where u.id = account_id and u.phone_confirmed_at is not null
    and u.deleted_at is null and not u.is_anonymous;

  if verified_phone is null or verified_phone = '' then
    return false;
  end if;

  -- Use the same lock order as CRM merges and account removal.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_store_id::text, 0));
  select * into target from public.orders
  where store_id = p_store_id and receipt_code = receipt
  for update;
  if not found then return false; end if;
  if target.user_id = account_id then return true; end if;
  if target.user_id is not null then return false; end if;

  order_phone := regexp_replace(target.customer_phone, '[[:space:]()-]', '', 'g');
  order_phone := case
    when order_phone ~ '^0[0-9]{9}$' then '38' || order_phone
    when order_phone ~ '^(380[0-9]{9}|\+[1-9][0-9]{7,14})$' then ltrim(order_phone, '+')
    else null
  end;
  if order_phone is distinct from verified_phone then return false; end if;

  customer_id := public.crm_identity(
    p_store_id, 'user:' || account_id::text, target.customer_name,
    '+' || verified_phone, target.customer_email
  );
  insert into public.store_customers (store_id, user_id)
  values (p_store_id, account_id) on conflict (store_id, user_id) do nothing;

  update public.orders set user_id = account_id, crm_customer_id = customer_id
  where id = target.id;
  return true;
end;
$_$;

ALTER FUNCTION "public"."claim_guest_order"("p_store_id" "uuid", "p_receipt_code" "text") OWNER TO "postgres";

CREATE FUNCTION "public"."confirm_online_checkout"("p_provider" "text", "p_reference" "text", "p_amount" integer, "p_currency" "text", "p_payment_id" "text", "p_callback" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_attempt public.online_checkouts;
  v_item public.order_items;
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
    select * from jsonb_populate_recordset(null::public.order_items, v_attempt.items) order by variant_id
  loop
    -- Honor invoices already issued before pre-orders began counting stock.
    v_preorder := v_item.is_preorder;
    v_stock_deducted := false;
    if not v_attempt.test_mode and (not v_preorder or v_attempt.track_preorder_stock) then
      update public.product_variants set stock_quantity = stock_quantity - v_item.quantity
      where id = v_item.variant_id and stock_quantity >= v_item.quantity;
      v_stock_deducted := found;
      -- Record the paid order for fulfillment even if stock ran out during payment.
      v_preorder := v_preorder or not v_stock_deducted;
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

  insert into public.order_status_history (order_id, status) values (v_attempt.id, 'PAID');
  insert into public.payments (order_id, provider, provider_order_id, provider_payment_id, status, raw_callback)
  values (v_attempt.id, p_provider, p_reference, p_payment_id, 'PAID', p_callback);
  update public.online_checkouts set status = 'PAID', checkout = null, items = null where id = v_attempt.id;
end;
$$;

ALTER FUNCTION "public"."confirm_online_checkout"("p_provider" "text", "p_reference" "text", "p_amount" integer, "p_currency" "text", "p_payment_id" "text", "p_callback" "jsonb") OWNER TO "postgres";

CREATE FUNCTION "public"."create_discounted_store_order"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text" DEFAULT ''::"text", "p_delivery_city_ref" "text" DEFAULT NULL::"text", "p_delivery_address_ref" "text" DEFAULT NULL::"text", "p_delivery_service_type" "text" DEFAULT NULL::"text", "p_expected_discount_percent" numeric DEFAULT NULL::numeric, "p_expected_total" integer DEFAULT NULL::integer) RETURNS "public"."orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  discount public.customer_discounts;
begin
  discount := public.active_customer_discount(p_store_id, auth.uid());
  if p_expected_discount_percent is not null and p_expected_discount_percent is distinct from coalesce(discount.percent, 0) then
    raise sqlstate 'PT409' using message = 'Your discount changed. Review your cart and try again.';
  end if;
  return public.create_priced_catalog_order('CASH_ON_DELIVERY', auth.uid(), p_store_id, p_items,
    p_customer_name, p_customer_email, p_customer_phone, p_delivery_city, p_delivery_address, p_note,
    p_delivery_city_ref, p_delivery_address_ref, p_delivery_service_type, false, discount, p_expected_total);
end;
$$;

ALTER FUNCTION "public"."create_discounted_store_order"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_expected_discount_percent" numeric, "p_expected_total" integer) OWNER TO "postgres";

CREATE FUNCTION "public"."create_order_with_payment"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text" DEFAULT ''::"text", "p_delivery_city_ref" "text" DEFAULT NULL::"text", "p_delivery_address_ref" "text" DEFAULT NULL::"text", "p_delivery_service_type" "text" DEFAULT NULL::"text") RETURNS "public"."orders"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select public.create_order_with_payment(
    p_provider, p_user_id, p_store_id, p_items, p_customer_name, p_customer_email,
    p_customer_phone, p_delivery_city, p_delivery_address, p_note, p_delivery_city_ref,
    p_delivery_address_ref, p_delivery_service_type, case when p_provider = 'LIQPAY' then null else false end
  );
$$;

ALTER FUNCTION "public"."create_order_with_payment"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text") OWNER TO "postgres";

CREATE FUNCTION "public"."create_order_with_payment"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_monobank_test_mode" boolean) RETURNS "public"."orders"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select public.create_priced_catalog_order(p_provider, p_user_id, p_store_id, p_items,
    p_customer_name, p_customer_email, p_customer_phone, p_delivery_city, p_delivery_address, p_note,
    p_delivery_city_ref, p_delivery_address_ref, p_delivery_service_type, p_monobank_test_mode, null, null);
$$;

ALTER FUNCTION "public"."create_order_with_payment"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_monobank_test_mode" boolean) OWNER TO "postgres";

CREATE FUNCTION "public"."create_priced_catalog_order"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_monobank_test_mode" boolean, "p_discount" "public"."customer_discounts", "p_expected_total" integer) RETURNS "public"."orders"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
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
  from public.stores s where s.id = p_store_id
  returning * into created_order;

  for line in select * from jsonb_populate_recordset(null::public.order_items, quote.items) order by variant_id loop
    insert into public.order_items (
      order_id, product_id, variant_id, product_name, variant_name, quantity,
      unit_price, compare_at_price, line_total, is_preorder, stock_deducted
    ) values (
      created_order.id, line.product_id, line.variant_id, line.product_name, line.variant_name, line.quantity,
      line.unit_price, line.compare_at_price, line.line_total, line.is_preorder, not test_mode
    );
    if not test_mode then
      update public.product_variants set stock_quantity = stock_quantity - line.quantity where id = line.variant_id;
    end if;
  end loop;

  insert into public.order_status_history (order_id, status, author_id)
  values (created_order.id, created_order.status, p_user_id);
  return created_order;
end;
$$;

ALTER FUNCTION "public"."create_priced_catalog_order"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_monobank_test_mode" boolean, "p_discount" "public"."customer_discounts", "p_expected_total" integer) OWNER TO "postgres";

CREATE FUNCTION "public"."create_reserved_online_order"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_monobank_test_mode" boolean) RETURNS "public"."orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_order public.orders;
begin
  if p_user_id is null or p_provider not in ('LIQPAY', 'MONOBANK') then
    raise exception 'Invalid reservation';
  end if;
  v_order := public.create_order_with_payment(
    p_provider, p_user_id, p_store_id, p_items, p_customer_name, p_customer_email, p_customer_phone,
    p_delivery_city, p_delivery_address, p_note, p_delivery_city_ref, p_delivery_address_ref,
    p_delivery_service_type, p_monobank_test_mode
  );
  insert into public.payments (order_id, provider, provider_order_id, checkout_managed)
  values (v_order.id, p_provider, v_order.id::text, true);
  update public.orders set reserved_in_profile = true where id = v_order.id returning * into v_order;
  return v_order;
end;
$$;

ALTER FUNCTION "public"."create_reserved_online_order"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_monobank_test_mode" boolean) OWNER TO "postgres";

CREATE FUNCTION "public"."create_store_order"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text" DEFAULT ''::"text", "p_delivery_city_ref" "text" DEFAULT NULL::"text", "p_delivery_address_ref" "text" DEFAULT NULL::"text", "p_delivery_service_type" "text" DEFAULT NULL::"text") RETURNS "public"."orders"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select public.create_discounted_store_order(p_store_id, p_items, p_customer_name, p_customer_email,
    p_customer_phone, p_delivery_city, p_delivery_address, p_note,
    p_delivery_city_ref, p_delivery_address_ref, p_delivery_service_type);
$$;

ALTER FUNCTION "public"."create_store_order"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text") OWNER TO "postgres";

CREATE FUNCTION "public"."crm_customer_accounts"("p_store_id" "uuid", "p_customer_id" "uuid") RETURNS TABLE("user_id" "uuid", "email" "text", "email_confirmed" boolean, "can_delete" boolean)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_role public.staff_role;
begin
  select member.role into caller_role
  from public.store_members member
  where member.store_id = p_store_id and member.user_id = auth.uid();

  if caller_role is null or caller_role not in ('OWNER', 'MANAGER') then
    raise exception 'Manager access required' using errcode = '42501';
  end if;

  return query
  select account.id, account.email::text, account.email_confirmed_at is not null,
    caller_role = 'OWNER'
      and account.id <> auth.uid()
      and not exists (select 1 from public.store_members staff where staff.user_id = account.id)
      and not exists (select 1 from public.store_customers registered
        where registered.user_id = account.id and registered.store_id <> p_store_id)
      and not exists (select 1 from public.crm_customer_keys other
        where other.key = 'user:' || account.id::text and other.store_id <> p_store_id)
      and not exists (select 1 from public.orders purchase
        where purchase.user_id = account.id and purchase.store_id <> p_store_id)
  from public.crm_customer_keys identity
  join auth.users account on identity.key = 'user:' || account.id::text
  where identity.store_id = p_store_id and identity.customer_id = p_customer_id
    and account.deleted_at is null and not account.is_anonymous
  order by account.created_at, account.id;
end;
$$;

ALTER FUNCTION "public"."crm_customer_accounts"("p_store_id" "uuid", "p_customer_id" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."crm_customer_discount_usage"("p_discount_id" "uuid") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if not exists (select 1 from public.customer_discounts d where d.id = p_discount_id
    and public.is_store_member(d.store_id)) then raise exception 'Access denied' using errcode = '42501'; end if;
  return public.customer_discount_usage(p_discount_id);
end;
$$;

ALTER FUNCTION "public"."crm_customer_discount_usage"("p_discount_id" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."crm_customer_phone_confirmed"("p_store_id" "uuid", "p_customer_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise exception 'Store staff access required' using errcode = '42501';
  end if;

  return exists (
    select 1
    from public.crm_customers customer
    join public.crm_customer_keys identity
      on identity.store_id = customer.store_id and identity.customer_id = customer.id
    join auth.users account on identity.key = 'user:' || account.id::text
    cross join lateral (select regexp_replace(customer.phone, '[^0-9]', '', 'g') as digits) phone
    where customer.id = p_customer_id and customer.store_id = p_store_id
      and account.deleted_at is null and not account.is_anonymous
      and account.phone_confirmed_at is not null
      and phone.digits <> ''
      and ltrim(account.phone, '+') = case
        when phone.digits ~ '^0[0-9]{9}$' then '38' || phone.digits
        else phone.digits
      end
  );
end;
$_$;

ALTER FUNCTION "public"."crm_customer_phone_confirmed"("p_store_id" "uuid", "p_customer_id" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."crm_customer_staff_access"("p_store_id" "uuid", "p_customer_id" "uuid") RETURNS TABLE("user_id" "uuid", "display_name" "text", "email" "text", "phone_suffix" "text", "role" "public"."staff_role", "is_self" boolean)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if not exists (select 1 from public.store_members m where m.store_id = p_store_id
    and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;
  return query
    select a.id, p.name, nullif(a.email::text, ''), right(coalesce(a.phone, ''), 4), m.role, a.id = auth.uid()
    from public.crm_customer_keys k
    join auth.users a on k.key = 'user:' || a.id::text
    join public.profiles p on p.id = a.id
    left join public.store_members m on m.store_id = k.store_id and m.user_id = a.id
    where k.store_id = p_store_id and k.customer_id = p_customer_id
      and a.deleted_at is null and not a.is_anonymous
    order by a.created_at, a.id;
end;
$$;

ALTER FUNCTION "public"."crm_customer_staff_access"("p_store_id" "uuid", "p_customer_id" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."crm_dashboard_payment_stats"("p_store_id" "uuid", "p_from" "date", "p_to" "date", "p_currency" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if not coalesce(public.is_store_member(p_store_id),false) then
    raise exception 'Access denied' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Invalid date range'; end if;
  return (select jsonb_build_object(
    'paid',count(*) filter (where status = 'PAID' and created_at is not null),
    'failed',count(*) filter (where status = 'FAILED' and created_at is not null),
    'pending',count(*) filter (where status = 'PENDING' and created_at is not null),
    'undated',count(*) filter (where created_at is null)
  ) from public.online_checkouts
  where store_id = p_store_id and not test_mode and currency = p_currency
    and (created_at is null or (created_at >= (p_from::timestamp at time zone 'Europe/Kyiv')
      and created_at < ((p_to + 1)::timestamp at time zone 'Europe/Kyiv'))));
end;
$$;

ALTER FUNCTION "public"."crm_dashboard_payment_stats"("p_store_id" "uuid", "p_from" "date", "p_to" "date", "p_currency" "text") OWNER TO "postgres";

CREATE FUNCTION "public"."crm_identity"("p_store" "uuid", "p_key" "text", "p_name" "text", "p_phone" "text", "p_email" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "public"."crm_identity"("p_store" "uuid", "p_key" "text", "p_name" "text", "p_phone" "text", "p_email" "text") OWNER TO "postgres";

CREATE FUNCTION "public"."crm_order_activity"("p_order_id" "uuid") RETURNS TABLE("id" "uuid", "kind" "text", "old_value" "text", "new_value" "text", "created_at" timestamp with time zone, "author_name" "text", "is_system" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select e.id, e.kind, e.old_value, e.new_value, e.created_at,
         nullif(trim(p.name), ''), e.author_id is null
  from public.order_events e
  join public.orders o on o.id = e.order_id
  left join public.profiles p on p.id = e.author_id
  where o.id = p_order_id and public.is_store_member(o.store_id)
  order by e.created_at desc;
$$;

ALTER FUNCTION "public"."crm_order_activity"("p_order_id" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."customer_discount_usage"("p_discount" "uuid") RETURNS bigint
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select (select count(*) from public.orders o where o.customer_discount_id = p_discount
    and o.status not in ('CANCELLED_BY_USER', 'CANCELLED_BY_STORE'))
    + (select count(*) from public.online_checkouts c where c.customer_discount_id = p_discount
      and c.status = 'PENDING' and not exists (select 1 from public.orders o where o.id = c.id));
$$;

ALTER FUNCTION "public"."customer_discount_usage"("p_discount" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."delete_catalog_product"("p_store_id" "uuid", "p_product_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise exception 'Manager access required' using errcode = '42501';
  end if;

  perform 1 from public.products
  where id = p_product_id and store_id = p_store_id for update;
  if not found then return false; end if;

  -- Prevent checkout or stock updates from changing a variant while we check its history.
  perform 1 from public.product_variants
  where product_id = p_product_id order by id for update;

  if exists (select 1 from public.order_items where product_id = p_product_id)
    or exists (
      select 1 from public.product_variants v
      where v.product_id = p_product_id and (
        exists (select 1 from public.order_items i where i.variant_id = v.id)
        or exists (select 1 from public.stock_movements m where m.variant_id = v.id)
      )
    ) then
    raise exception 'Product is used in order or stock history' using errcode = '23503';
  end if;

  delete from public.products where id = p_product_id and store_id = p_store_id;
  return found;
end;
$$;

ALTER FUNCTION "public"."delete_catalog_product"("p_store_id" "uuid", "p_product_id" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."delete_crm_customer_account"("p_store_id" "uuid", "p_customer_id" "uuid", "p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  -- Prevent merges or new account links from changing the target during deletion.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_store_id::text, 0));
  perform 1 from auth.users account where account.id = p_user_id for update;
  perform 1 from public.profiles profile where profile.id = p_user_id for update;

  if not exists (select 1 from public.crm_customer_accounts(p_store_id, p_customer_id) account
    where account.user_id = p_user_id and account.can_delete) then
    raise exception 'This account cannot be deleted from this store' using errcode = '42501';
  end if;

  -- FK actions unlink orders and remove the profile. The CRM card and orders remain.
  delete from auth.users where id = p_user_id;
  delete from public.crm_customer_keys where store_id = p_store_id and key = 'user:' || p_user_id::text;
end;
$$;

ALTER FUNCTION "public"."delete_crm_customer_account"("p_store_id" "uuid", "p_customer_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."duplicate_catalog_product"("p_product" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
  source public.products;
  copy_id uuid;
begin
  select * into source from public.products where id = p_product;
  if not found or not coalesce(public.is_store_member(source.store_id), false) then
    raise exception 'Manager access required';
  end if;

  insert into public.products (
    store_id, category_id, name, description, is_active, position,
    size_guide, composition, care_instructions, size_guide_image_url,
    name_uk, name_en, description_uk, description_en, weight_grams,
    size_guide_en, composition_en, care_instructions_en,
    size_guide_extra_image_urls, discount_percent, stack_customer_discount
  ) values (
    source.store_id, source.category_id, source.name, source.description, false, source.position,
    source.size_guide, source.composition, source.care_instructions, source.size_guide_image_url,
    source.name_uk, source.name_en, source.description_uk, source.description_en, source.weight_grams,
    source.size_guide_en, source.composition_en, source.care_instructions_en,
    source.size_guide_extra_image_urls, source.discount_percent, source.stack_customer_discount
  )
  returning id into copy_id;

  perform public.set_catalog_product_categories(array[copy_id], array(
    select pc.category_id from public.product_categories pc
    where pc.product_id = p_product
    order by (pc.category_id = source.category_id) desc nulls last, pc.category_id
  ));

  insert into public.product_variants (product_id, name, sku, price, compare_at_price, stock_quantity, is_preorder, position, low_stock_threshold, discount_percent, stack_customer_discount)
  select copy_id, name, null, price, compare_at_price, 0, is_preorder, position, low_stock_threshold, discount_percent, stack_customer_discount
  from public.product_variants where product_id = p_product;
  insert into public.product_images (product_id, public_url, storage_path, position)
  select copy_id, public_url, storage_path, position from public.product_images where product_id = p_product;
  return copy_id;
end;
$$;

ALTER FUNCTION "public"."duplicate_catalog_product"("p_product" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."get_online_checkout_status"("p_receipt_code" "text") RETURNS "public"."payment_status"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select status from public.online_checkouts where receipt_code = lower(trim(p_receipt_code));
$$;

ALTER FUNCTION "public"."get_online_checkout_status"("p_receipt_code" "text") OWNER TO "postgres";

CREATE FUNCTION "public"."get_order_receipt"("p_receipt_code" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select to_jsonb(o) || jsonb_build_object(
    'items', coalesce((select jsonb_agg(to_jsonb(oi) order by oi.id) from public.order_items oi where oi.order_id = o.id), '[]'::jsonb)
  )
  from public.orders o
  where o.receipt_code = lower(trim(p_receipt_code));
$$;

ALTER FUNCTION "public"."get_order_receipt"("p_receipt_code" "text") OWNER TO "postgres";

CREATE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.profiles (id, name, phone)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'name', ''),
    coalesce(new.raw_user_meta_data ->> 'phone', '')
  );
  return new;
end;
$$;

ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";

CREATE FUNCTION "public"."is_store_member"("target_store_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.store_members
    where store_id = target_store_id and user_id = auth.uid()
  );
$$;

ALTER FUNCTION "public"."is_store_member"("target_store_id" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."mark_all_notifications_read"("p_store_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  update public.customer_notifications
  set read_at = now()
  where user_id = auth.uid() and store_id = p_store_id and read_at is null;

  -- Restock notices are one-time subscriptions. Dismiss delivered notices only.
  delete from public.restock_subscriptions as subscription
  using public.product_variants as variant, public.products as product
  where subscription.user_id = auth.uid()
    and subscription.notified_at is not null
    and subscription.variant_id = variant.id
    and variant.product_id = product.id
    and product.store_id = p_store_id;
end;
$$;

ALTER FUNCTION "public"."mark_all_notifications_read"("p_store_id" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."mark_notification_read"("p_id" "uuid") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  update public.customer_notifications set read_at=now() where id=p_id and user_id=auth.uid();
$$;

ALTER FUNCTION "public"."mark_notification_read"("p_id" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."merge_crm_customers"("p_source" "uuid", "p_target" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "public"."merge_crm_customers"("p_source" "uuid", "p_target" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."merge_orders"("p_order_ids" "uuid"[], "p_target_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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
  if exists(select 1 from public.orders where id=any(ids) and currency<>target.currency) then
    raise exception 'Orders in different currencies cannot be merged';
  end if;
  if exists(select 1 from public.orders where id=any(ids) and coalesce(payment_test_mode,false)<>coalesce(target.payment_test_mode,false)) then
    raise exception 'Test and live orders cannot be merged';
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
end; $$;

ALTER FUNCTION "public"."merge_orders"("p_order_ids" "uuid"[], "p_target_id" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."merged_order_shipping"("p_order_id" "uuid") RETURNS TABLE("order_ids" "uuid"[], "total_minor" bigint, "cod_minor" bigint, "weight_grams" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with group_orders as (
    select o.* from public.orders o
    where o.id=p_order_id or o.id in (select m.order_id from public.order_merge_members m where m.root_id=p_order_id)
  ), weights as (
    select oi.quantity, coalesce(oi.weight_grams,p.weight_grams) weight
    from public.order_items oi join group_orders g on g.id=oi.order_id
    left join public.products p on p.id=oi.product_id
  )
  select array_agg(id),sum(total_price)::bigint,
    coalesce(sum(total_price) filter (where payment_method='CASH_ON_DELIVERY' and payment_status<>'PAID'),0)::bigint,
    (select case when count(*)=count(weight) then sum(weight::bigint*quantity) end from weights)
  from group_orders;
$$;

ALTER FUNCTION "public"."merged_order_shipping"("p_order_id" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."my_customer_discount"("p_store_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare d public.customer_discounts;
begin
  select * into d from public.customer_discounts where store_id = p_store_id and user_id = auth.uid() and enabled;
  if not found then return null; end if;
  return to_jsonb(d) || jsonb_build_object('pending',
    d.mode = 'orders' and public.customer_discount_usage(d.id) >= d.order_limit and exists (
      select 1 from public.online_checkouts c where c.customer_discount_id = d.id and c.status = 'PENDING'), 'used', public.customer_discount_usage(d.id), 'active',
    (d.mode <> 'period' or (now() at time zone 'Europe/Kyiv')::date between d.starts_on and d.ends_on)
    and (d.mode <> 'orders' or public.customer_discount_usage(d.id) < d.order_limit));
end;
$$;

ALTER FUNCTION "public"."my_customer_discount"("p_store_id" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."notify_order_event"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.kind in ('status','payment_status','return') then
    insert into public.customer_notifications(user_id,store_id,event_id,order_id,receipt_code,kind,value)
    select user_id,store_id,new.id,id,receipt_code,new.kind,new.new_value from public.orders where id=new.order_id and user_id is not null;
  end if;
  return new;
end; $$;

ALTER FUNCTION "public"."notify_order_event"() OWNER TO "postgres";

CREATE FUNCTION "public"."notify_restock"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
 update public.restock_subscriptions set notified_at=now() where variant_id=new.id and notified_at is null;
 return new;
end; $$;

ALTER FUNCTION "public"."notify_restock"() OWNER TO "postgres";

CREATE FUNCTION "public"."nova_poshta_order_weight_grams"("p_order_id" "uuid") RETURNS bigint
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select case when count(*) = count(item.weight)
    then sum(item.weight::bigint * item.quantity)::bigint end
  from (
    select coalesce(oi.weight_grams, p.weight_grams) as weight, oi.quantity
    from public.order_items oi
    left join public.products p on p.id = oi.product_id
    where oi.order_id = p_order_id
  ) item;
$$;

ALTER FUNCTION "public"."nova_poshta_order_weight_grams"("p_order_id" "uuid") OWNER TO "postgres";

CREATE TABLE "public"."online_checkouts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "receipt_code" "text" DEFAULT "replace"(("gen_random_uuid"())::"text", '-'::"text", ''::"text") NOT NULL,
    "store_id" "uuid" NOT NULL,
    "user_id" "uuid",
    "provider" "text" NOT NULL,
    "provider_order_id" "text",
    "test_mode" boolean NOT NULL,
    "total_price" integer NOT NULL,
    "currency" "text" NOT NULL,
    "checkout" "jsonb",
    "items" "jsonb",
    "status" "public"."payment_status" DEFAULT 'PENDING'::"public"."payment_status" NOT NULL,
    "customer_discount_id" "uuid",
    "customer_discount_percent" numeric(5,2) DEFAULT 0 NOT NULL,
    "customer_discount_amount" integer DEFAULT 0 NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '01:00:00'::interval) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "track_preorder_stock" boolean DEFAULT false NOT NULL,
    CONSTRAINT "online_checkouts_provider_check" CHECK (("provider" = ANY (ARRAY['LIQPAY'::"text", 'MONOBANK'::"text"]))),
    CONSTRAINT "online_checkouts_total_price_check" CHECK (("total_price" > 0))
);

ALTER TABLE "public"."online_checkouts" OWNER TO "postgres";

CREATE FUNCTION "public"."prepare_online_checkout"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_checkout" "jsonb", "p_test_mode" boolean) RETURNS "public"."online_checkouts"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_attempt public.online_checkouts;
  v_enabled boolean;
  v_test_mode boolean;
  v_currency text;
  discount public.customer_discounts;
  quote record;
begin
  if p_provider is null or p_provider not in ('LIQPAY', 'MONOBANK') then
    raise exception 'Invalid payment method';
  end if;
  select s.currency, case p_provider when 'LIQPAY' then pm.liqpay else pm.monobank end,
    coalesce(pm.payment_test_mode, case p_provider when 'LIQPAY' then p_test_mode else pm.monobank_test_mode end, false)
  into v_currency, v_enabled, v_test_mode
  from public.stores s left join public.store_payment_methods pm on pm.store_id = s.id
  where s.id = p_store_id;

  if not found or not coalesce(v_enabled, true) then
    raise sqlstate 'PT409' using message = 'This payment method is no longer available.';
  end if;
  if v_test_mode is distinct from p_test_mode then
    raise sqlstate 'PT409' using message = 'Payment settings changed. Please try again.';
  end if;
  if p_provider = 'MONOBANK' and v_currency <> 'UAH' then
    raise exception 'Monobank checkout requires UAH';
  end if;
  if nullif(trim(p_checkout->>'name'), '') is null or nullif(trim(p_checkout->>'phone'), '') is null
      or nullif(trim(p_checkout->>'city'), '') is null or nullif(trim(p_checkout->>'address'), '') is null then
    raise exception 'Missing customer or delivery details';
  end if;

  discount := public.active_customer_discount(p_store_id, p_user_id);
  if p_checkout ? 'expectedDiscountPercent' and
      (p_checkout->>'expectedDiscountPercent')::numeric is distinct from coalesce(discount.percent,0) then
    raise exception 'Your discount changed. Review your cart and try again.' using errcode = 'PT409';
  end if;
  -- A limited entitlement already in payment must not silently turn into a full-price retry.
  if discount.id is null and exists (select 1 from public.customer_discounts x
    join public.online_checkouts a on a.customer_discount_id = x.id
    where x.store_id = p_store_id and x.user_id = p_user_id and x.enabled and x.mode = 'orders' and a.status = 'PENDING') then
    raise exception 'A discounted payment is still pending. Complete it or wait for its status to update.';
  end if;
  select * into quote from public.quote_catalog_cart(p_store_id, p_items, discount.percent, false);
  if p_checkout ? 'expectedTotal' and (p_checkout->>'expectedTotal')::integer is distinct from quote.total then
    raise sqlstate 'PT409' using message = 'Cart prices changed. Review your cart and try again.';
  end if;
  if quote.total <= 0 then raise exception 'Online checkout requires a positive amount'; end if;

  v_attempt.id := gen_random_uuid();
  insert into public.online_checkouts (id, store_id, user_id, provider, provider_order_id, test_mode, total_price, currency, checkout, items,
    track_preorder_stock, customer_discount_id, customer_discount_percent, customer_discount_amount)
  values (v_attempt.id, p_store_id, p_user_id, p_provider,
    case when p_provider = 'LIQPAY' then v_attempt.id::text end, p_test_mode, quote.total, v_currency,
    jsonb_build_object(
      'name', p_checkout->>'name', 'email', p_checkout->>'email', 'phone', p_checkout->>'phone',
      'city', p_checkout->>'city', 'address', p_checkout->>'address', 'note', p_checkout->>'note',
      'cityRef', p_checkout->>'cityRef', 'addressRef', p_checkout->>'addressRef',
      'deliveryServiceType', p_checkout->>'deliveryServiceType'
    ), quote.items, true,
    case when quote.personal_savings > 0 then discount.id end,
    case when quote.personal_savings > 0 then discount.percent else 0 end,
    quote.personal_savings)
  returning * into v_attempt;
  return v_attempt;
end;
$$;

ALTER FUNCTION "public"."prepare_online_checkout"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_checkout" "jsonb", "p_test_mode" boolean) OWNER TO "postgres";

CREATE FUNCTION "public"."quote_catalog_cart"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_percent" numeric, "p_lock_stock" boolean) RETURNS TABLE("items" "jsonb", "total" integer, "personal_savings" integer)
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Cart is empty';
  end if;
  if exists (
    select 1 from jsonb_to_recordset(p_items) as item("variantId" uuid, quantity integer)
    where item."variantId" is null or item.quantity is null or item.quantity not between 1 and 20
  ) then
    raise exception 'Invalid cart item';
  end if;

  if p_lock_stock then
    perform v.id
    from public.product_variants v join public.products p on p.id = v.product_id
    where p.store_id = p_store_id and p.is_active and v.id in (
      select item."variantId" from jsonb_to_recordset(p_items) as item("variantId" uuid)
    )
    order by v.id for update of v;
  end if;

  return query
  with requested as (
    select item."variantId" as variant_id, sum(item.quantity)::integer as quantity
    from jsonb_to_recordset(p_items) as item("variantId" uuid, quantity integer)
    group by item."variantId"
  ), offers as (
    select p.id as product_id, v.id as variant_id, p.name as product_name, v.name as variant_name,
      r.quantity, v.is_preorder, v.price as stored_price,
      greatest(v.price, v.compare_at_price) as regular_price,
      coalesce(v.discount_percent, p.discount_percent) as catalog_percent,
      case when v.discount_percent is null then p.stack_customer_discount
        else v.stack_customer_discount end as allows_stacking
    from requested r
    join public.product_variants v on v.id = r.variant_id
    join public.products p on p.id = v.product_id
    where p.store_id = p_store_id and p.is_active
      and r.quantity <= 20 and v.stock_quantity >= r.quantity
  ), catalog_prices as (
    select offers.*, case when catalog_percent is null then stored_price
      else round(regular_price * (1 - catalog_percent / 100))::integer end as catalog_price
    from offers
  ), final_prices as (
    select catalog_prices.*, case
      when allows_stacking or (coalesce(catalog_percent, 0) = 0 and catalog_price = regular_price)
        then round(catalog_price * (1 - coalesce(p_customer_percent, 0) / 100))::integer
      else catalog_price end as unit_price
    from catalog_prices
  ), lines as (
    select product_id, variant_id, product_name, variant_name, quantity, is_preorder, unit_price,
      case when regular_price > unit_price then regular_price end as compare_at_price,
      unit_price * quantity as line_total,
      (catalog_price - unit_price) * quantity as customer_savings
    from final_prices
  )
  select jsonb_agg(to_jsonb(lines) - 'customer_savings' order by variant_id),
    sum(line_total)::integer, sum(customer_savings)::integer
  from lines
  having count(*) = (select count(*) from requested);
  if not found then
    raise sqlstate 'PT409' using message = 'A product is no longer available in the requested quantity.';
  end if;
end;
$$;

ALTER FUNCTION "public"."quote_catalog_cart"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_percent" numeric, "p_lock_stock" boolean) OWNER TO "postgres";

CREATE FUNCTION "public"."receipt_events"("p_code" "text") RETURNS TABLE("id" "uuid", "kind" "text", "old_value" "text", "new_value" "text", "created_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
 select e.id,e.kind,e.old_value,e.new_value,e.created_at from public.order_events e join public.orders o on o.id=e.order_id
 where o.receipt_code=p_code and e.kind in ('status','payment_status','return') order by e.created_at desc;
$$;

ALTER FUNCTION "public"."receipt_events"("p_code" "text") OWNER TO "postgres";

CREATE FUNCTION "public"."record_order_return"("p_order_id" "uuid", "p_amount" integer, "p_reason" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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

ALTER FUNCTION "public"."record_order_return"("p_order_id" "uuid", "p_amount" integer, "p_reason" "text") OWNER TO "postgres";

CREATE FUNCTION "public"."refresh_catalog_exchange_rates"() RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
  v_date date := (now() at time zone 'Europe/Kyiv')::date;
  v_status integer;
  v_response text;
  v_updated integer;
begin
  perform set_config('http.curlopt_timeout_ms', '5000', true);
  -- Without an explicit date, NBU can publish tomorrow's rate early.
  select response.status, response.content into v_status, v_response
  from extensions.http_get(
    'https://bank.gov.ua/NBUStatService/v1/statdirectory/exchangenew?json&date=' || to_char(v_date, 'YYYYMMDD')
  ) as response;

  if v_status is distinct from 200 then
    raise exception 'NBU exchange rates are unavailable (HTTP %)', v_status;
  end if;

  insert into public.catalog_exchange_rates (currency, uah_rate, rate_date)
  select r.cc, r.rate, v_date
  from jsonb_to_recordset(v_response::jsonb) as r(cc text, rate numeric, exchangedate text)
  where r.cc in ('USD', 'EUR', 'PLN') and r.rate > 0
    and r.exchangedate = to_char(v_date, 'DD.MM.YYYY')
  on conflict (currency) do update set uah_rate = excluded.uah_rate, rate_date = excluded.rate_date
  where public.catalog_exchange_rates.rate_date <= excluded.rate_date;
  get diagnostics v_updated = row_count;
  if v_updated <> 3 then raise exception 'NBU did not return all three rates for %', v_date; end if;
end;
$$;

ALTER FUNCTION "public"."refresh_catalog_exchange_rates"() OWNER TO "postgres";

CREATE FUNCTION "public"."register_crm_customer"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
 perform public.crm_identity(new.store_id,'user:'||new.user_id::text,p.name,p.phone,'') from public.profiles p where p.id=new.user_id;
 return new;
end; $$;

ALTER FUNCTION "public"."register_crm_customer"() OWNER TO "postgres";

CREATE FUNCTION "public"."release_order_ttn"("p_order_id" "uuid") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  delete from public.order_ttn_reservations where order_id=p_order_id;
$$;

ALTER FUNCTION "public"."release_order_ttn"("p_order_id" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."request_item_return"("p_id" "uuid", "p_item" "uuid", "p_quantity" integer, "p_reason" "text", "p_restock" boolean, "p_replacement" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

ALTER FUNCTION "public"."request_item_return"("p_id" "uuid", "p_item" "uuid", "p_quantity" integer, "p_reason" "text", "p_restock" boolean, "p_replacement" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."reserve_order_ttn"("p_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare target public.orders;
begin
  select * into target from public.orders where id=p_order_id;
  if target.id is null then raise exception 'Order not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || target.store_id::text, 0));
  if exists(select 1 from public.order_merge_members where order_id=p_order_id and root_id<>p_order_id) then
    raise exception 'Create the TTN from the primary order';
  end if;
  if exists(select 1 from public.orders where (id=p_order_id or id in
    (select order_id from public.order_merge_members where root_id=p_order_id))
    and (nova_poshta_ttn is not null or nova_poshta_document_ref is not null)) then
    raise exception 'This order already has a TTN';
  end if;
  insert into public.order_ttn_reservations(order_id) values(p_order_id);
end; $$;

ALTER FUNCTION "public"."reserve_order_ttn"("p_order_id" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."restore_stock_and_cancel_order"("p_order_id" "uuid") RETURNS "public"."orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_order public.orders;
  v_item public.order_items;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found or not public.is_store_member(v_order.store_id) then
    raise exception 'You do not have access to this order';
  end if;
  if v_order.payment_status = 'PAID' then
    raise exception 'A paid order cannot be cancelled with stock restoration';
  end if;
  if v_order.status <> 'PENDING' then
    raise exception 'Only pending unpaid orders can be cancelled with stock restoration';
  end if;

  for v_item in select * from public.order_items where order_id = v_order.id loop
    if not coalesce(v_order.payment_test_mode, v_order.monobank_test_mode) and coalesce(v_item.stock_deducted, not v_item.is_preorder) and v_item.variant_id is not null then
      update public.product_variants
      set stock_quantity = stock_quantity + v_item.quantity
      where id = v_item.variant_id;
    end if;
  end loop;

  update public.orders
  set status = 'CANCELLED_BY_STORE', payment_status = 'FAILED'
  where id = v_order.id
  returning * into v_order;

  update public.payments
  set status = 'FAILED', updated_at = now()
  where order_id = v_order.id and status = 'PENDING';

  insert into public.order_status_history (order_id, status, author_id)
  values (v_order.id, v_order.status, auth.uid());
  return v_order;
end;
$$;

ALTER FUNCTION "public"."restore_stock_and_cancel_order"("p_order_id" "uuid") OWNER TO "postgres";

CREATE FUNCTION "public"."save_catalog_costs"("p_product_id" "uuid", "p_update_default" boolean, "p_default_cost" integer, "p_variant_costs" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  perform 1 from public.products p
  where p.id = p_product_id and public.is_store_member(p.store_id)
  for update;
  if not found then raise exception 'Manager access required'; end if;

  if exists (
    select 1 from jsonb_to_recordset(p_variant_costs) as costs(variant_id uuid, cost_amount integer)
    where not exists (
      select 1 from public.product_variants v
      where v.id = costs.variant_id and v.product_id = p_product_id
    )
  ) then
    raise exception 'Variant does not belong to this product';
  end if;

  if p_update_default then
    if p_default_cost is null then
      delete from public.product_costs where product_id = p_product_id;
    else
      insert into public.product_costs (product_id, cost_amount)
      values (p_product_id, p_default_cost)
      on conflict (product_id) do update set cost_amount = excluded.cost_amount;
    end if;
  end if;

  delete from public.variant_costs v
  using jsonb_to_recordset(p_variant_costs) as costs(variant_id uuid, cost_amount integer)
  where v.variant_id = costs.variant_id and costs.cost_amount is null;

  insert into public.variant_costs (variant_id, cost_amount)
  select costs.variant_id, costs.cost_amount
  from jsonb_to_recordset(p_variant_costs) as costs(variant_id uuid, cost_amount integer)
  where costs.cost_amount is not null
  on conflict (variant_id) do update set cost_amount = excluded.cost_amount;
end;
$$;

ALTER FUNCTION "public"."save_catalog_costs"("p_product_id" "uuid", "p_update_default" boolean, "p_default_cost" integer, "p_variant_costs" "jsonb") OWNER TO "postgres";

CREATE FUNCTION "public"."save_catalog_costs_in_currency"("p_product_id" "uuid", "p_update_default" boolean, "p_default_cost" integer, "p_default_currency" "text", "p_variant_costs" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
declare
  v_variant_costs jsonb;
  v_default_in_uah numeric;
begin
  v_default_in_uah := public.catalog_cost_in_uah(p_default_cost, p_default_currency);
  if p_update_default and p_default_cost is not null and v_default_in_uah is null then
    raise exception 'Exchange rate is unavailable. Try again shortly.';
  end if;

  if exists (
    select 1 from jsonb_to_recordset(p_variant_costs) as c(variant_id uuid, cost_amount integer, currency text)
    where c.cost_amount is not null and public.catalog_cost_in_uah(c.cost_amount, c.currency) is null
  ) then
    raise exception 'Exchange rate is unavailable. Try again shortly.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'variant_id', c.variant_id, 'cost_amount', public.catalog_cost_in_uah(c.cost_amount, c.currency)
  )), '[]'::jsonb) into v_variant_costs
  from jsonb_to_recordset(p_variant_costs) as c(variant_id uuid, cost_amount integer, currency text);

  -- Reuse the product lock, membership check and variant validation.
  perform public.save_catalog_costs(p_product_id, p_update_default, v_default_in_uah::integer, v_variant_costs);

  if p_update_default and p_default_cost is not null then
    update public.product_costs set currency = p_default_currency, source_amount = p_default_cost
    where product_id = p_product_id;
  end if;
  update public.variant_costs v set currency = c.currency, source_amount = c.cost_amount
  from jsonb_to_recordset(p_variant_costs) as c(variant_id uuid, cost_amount integer, currency text)
  where v.variant_id = c.variant_id and c.cost_amount is not null;
end;
$$;

ALTER FUNCTION "public"."save_catalog_costs_in_currency"("p_product_id" "uuid", "p_update_default" boolean, "p_default_cost" integer, "p_default_currency" "text", "p_variant_costs" "jsonb") OWNER TO "postgres";

CREATE FUNCTION "public"."set_catalog_product_categories"("p_products" "uuid"[], "p_categories" "uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  shop uuid;
  primary_category uuid;
begin
  if auth.uid() is null or coalesce(cardinality(p_products), 0) = 0
    or array_position(p_products, null) is not null
    or p_categories is null or array_position(p_categories, null) is not null then
    raise exception 'Invalid product or category selection' using errcode = '22023';
  end if;

  select p.store_id into shop from public.products p where p.id = p_products[1];
  if shop is null or not public.is_store_member(shop) then
    raise exception 'Manager access required' using errcode = '42501';
  end if;

  perform 1 from public.products p
  where p.id = any(p_products) and p.store_id = shop order by p.id for update;
  if exists (
    select 1 from unnest(p_products) as requested(id)
    where not exists (select 1 from public.products p where p.id = requested.id and p.store_id = shop)
  ) then
    raise exception 'Choose products from this store' using errcode = '42501';
  end if;

  if exists (
    select 1 from unnest(p_categories) as requested(id)
    left join public.categories c on c.id = requested.id and c.store_id = shop
    where c.id is null or (c.parent_id is not null and not (c.parent_id = any(p_categories)))
  ) then
    raise exception 'Select a main category before its subcategories' using errcode = '23514';
  end if;

  select c.id into primary_category
  from unnest(p_categories) with ordinality as requested(id, position)
  join public.categories c on c.id = requested.id and c.store_id = shop
  where c.parent_id is null order by requested.position limit 1;

  update public.products set category_id = primary_category
  where id = any(p_products) and store_id = shop and category_id is distinct from primary_category;

  delete from public.product_categories
  where product_id = any(p_products) and store_id = shop and not (category_id = any(p_categories));

  insert into public.product_categories (store_id, product_id, category_id)
  select distinct shop, p.id, c.id
  from unnest(p_products) as p(id) cross join unnest(p_categories) as c(id)
  on conflict (product_id, category_id) do nothing;
end;
$$;

ALTER FUNCTION "public"."set_catalog_product_categories"("p_products" "uuid"[], "p_categories" "uuid"[]) OWNER TO "postgres";

CREATE FUNCTION "public"."set_crm_administrator"("p_store_id" "uuid", "p_customer_id" "uuid", "p_user_id" "uuid", "p_grant" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare target_role public.staff_role;
begin
  if p_grant is null then raise exception 'Invalid access setting' using errcode = '22023'; end if;
  -- Shared with CRM merges and account deletion, and serializes concurrent access changes.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_store_id::text, 0));
  if not exists (select 1 from public.store_members m where m.store_id = p_store_id
    and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then
    raise exception 'Administrator access required' using errcode = '42501';
  end if;
  if p_user_id = auth.uid() then raise exception 'You cannot change your own administrator access' using errcode = '42501'; end if;
  if not exists (select 1 from public.crm_customer_keys k join auth.users a on k.key = 'user:' || a.id::text
    join public.profiles p on p.id = a.id
    where k.store_id = p_store_id and k.customer_id = p_customer_id and a.id = p_user_id
      and a.deleted_at is null and not a.is_anonymous) then
    raise exception 'The registered account is no longer linked to this customer' using errcode = '22023';
  end if;
  select m.role into target_role from public.store_members m where m.store_id = p_store_id and m.user_id = p_user_id for update;
  if target_role = 'OWNER' then raise exception 'Owner access cannot be changed here' using errcode = '42501'; end if;
  if p_grant then
    insert into public.store_members(store_id, user_id, role) values(p_store_id, p_user_id, 'MANAGER')
    on conflict (store_id, user_id) do update set role = 'MANAGER';
  else
    delete from public.store_members where store_id = p_store_id and user_id = p_user_id and role in ('MANAGER', 'CONTENT');
  end if;
end;
$$;

ALTER FUNCTION "public"."set_crm_administrator"("p_store_id" "uuid", "p_customer_id" "uuid", "p_user_id" "uuid", "p_grant" boolean) OWNER TO "postgres";

CREATE FUNCTION "public"."set_customer_discount"("p_store_id" "uuid", "p_customer_id" "uuid", "p_user_id" "uuid", "p_percent" numeric, "p_mode" "text", "p_order_limit" integer DEFAULT NULL::integer, "p_starts_on" "date" DEFAULT NULL::"date", "p_ends_on" "date" DEFAULT NULL::"date") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if not exists (select 1 from public.crm_customer_accounts(p_store_id, p_customer_id) a where a.user_id = p_user_id) then
    raise exception 'Registered customer account required' using errcode = '42501';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_store_id::text || p_user_id::text, 1));
  update public.customer_discounts set enabled = false where store_id = p_store_id and user_id = p_user_id and enabled;
  if p_percent is not null then
    insert into public.customer_discounts(store_id, user_id, percent, mode, order_limit, starts_on, ends_on)
    values (p_store_id, p_user_id, p_percent, p_mode,
      case when p_mode = 'orders' then p_order_limit end,
      case when p_mode = 'period' then p_starts_on end, case when p_mode = 'period' then p_ends_on end);
  end if;
end;
$$;

ALTER FUNCTION "public"."set_customer_discount"("p_store_id" "uuid", "p_customer_id" "uuid", "p_user_id" "uuid", "p_percent" numeric, "p_mode" "text", "p_order_limit" integer, "p_starts_on" "date", "p_ends_on" "date") OWNER TO "postgres";

CREATE FUNCTION "public"."set_order_cost"("p_order_id" "uuid", "p_amount" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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

ALTER FUNCTION "public"."set_order_cost"("p_order_id" "uuid", "p_amount" integer) OWNER TO "postgres";

CREATE FUNCTION "public"."snapshot_item_cost"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_cost integer;
begin
  select coalesce(case when current_cost <= 2147483647 then current_cost::integer end, cost_amount)
  into v_cost
  from (
    select v.cost_amount, public.catalog_cost_in_uah(v.source_amount, v.currency) as current_cost, 1 as priority
    from public.variant_costs v where v.variant_id = new.variant_id
    union all
    select p.cost_amount, public.catalog_cost_in_uah(p.source_amount, p.currency), 2
    from public.product_costs p where p.product_id = new.product_id
  ) as costs
  order by priority
  limit 1;

  insert into public.order_item_costs (item_id, unit_cost) values (new.id, v_cost);
  return new;
end;
$$;

ALTER FUNCTION "public"."snapshot_item_cost"() OWNER TO "postgres";

CREATE FUNCTION "public"."snapshot_online_customer_discount"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.payment_method = 'ONLINE' and exists (select 1 from public.online_checkouts c where c.id = new.id) then
    select c.customer_discount_id, c.customer_discount_percent, c.customer_discount_amount
    into new.customer_discount_id, new.customer_discount_percent, new.customer_discount_amount
    from public.online_checkouts c where c.id = new.id;
    new.customer_discount_percent := coalesce(new.customer_discount_percent,0);
    new.customer_discount_amount := coalesce(new.customer_discount_amount,0);
  end if;
  return new;
end;
$$;

ALTER FUNCTION "public"."snapshot_online_customer_discount"() OWNER TO "postgres";

CREATE FUNCTION "public"."snapshot_order_item_weight"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  select p.weight_grams into new.weight_grams
  from public.products p where p.id = new.product_id;
  return new;
end;
$$;

ALTER FUNCTION "public"."snapshot_order_item_weight"() OWNER TO "postgres";

CREATE FUNCTION "public"."subscribe_restock"("p_variant" "uuid", "p_subscribe" boolean) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare available integer;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if not p_subscribe then delete from public.restock_subscriptions where user_id=auth.uid() and variant_id=p_variant; return; end if;
 select v.stock_quantity into available from public.product_variants v join public.products p on p.id=v.product_id where v.id=p_variant and p.is_active for update of v;
 if not found or available>0 then raise exception 'Variant is already available or unavailable for subscription'; end if;
 insert into public.restock_subscriptions(user_id,variant_id) values(auth.uid(),p_variant)
 on conflict(user_id,variant_id) do update set notified_at=null;
end; $$;

ALTER FUNCTION "public"."subscribe_restock"("p_variant" "uuid", "p_subscribe" boolean) OWNER TO "postgres";

CREATE FUNCTION "public"."sync_primary_product_category"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if tg_op = 'UPDATE' then
    if new.category_id is not distinct from old.category_id then return new; end if;
    delete from public.product_categories pc using public.categories c
    where pc.product_id = new.id and pc.category_id = c.id
      and (c.id = old.category_id or c.parent_id = old.category_id);
  end if;

  if new.category_id is not null then
    insert into public.product_categories (store_id, product_id, category_id)
    select new.store_id, new.id, selected.id
    from public.categories c
    cross join lateral (values (c.id), (c.parent_id)) as selected(id)
    where c.id = new.category_id and c.store_id = new.store_id and selected.id is not null
    on conflict (product_id, category_id) do nothing;
    if not found and not exists (
      select 1 from public.categories where id = new.category_id and store_id = new.store_id
    ) then
      raise exception 'Choose categories from this store' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

ALTER FUNCTION "public"."sync_primary_product_category"() OWNER TO "postgres";

CREATE FUNCTION "public"."touch_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin new.updated_at = now(); return new; end;
$$;

ALTER FUNCTION "public"."touch_updated_at"() OWNER TO "postgres";

CREATE FUNCTION "public"."update_admin_orders"("p_order_ids" "uuid"[], "p_status" "public"."order_status", "p_confirm_paid" boolean DEFAULT false, "p_restore_stock" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'status', o.status, 'payment_status', o.payment_status)), '[]'::jsonb)
  from public.apply_admin_order_update(p_order_ids, p_status, p_confirm_paid, true, p_restore_stock) o;
$$;

ALTER FUNCTION "public"."update_admin_orders"("p_order_ids" "uuid"[], "p_status" "public"."order_status", "p_confirm_paid" boolean, "p_restore_stock" boolean) OWNER TO "postgres";

CREATE FUNCTION "public"."update_crm_customer_details"("p_store_id" "uuid", "p_customer_id" "uuid", "p_name" "text", "p_notes" "text", "p_tags" "text"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  customer public.crm_customers;
  account_ids uuid[];
  next_name text := trim(p_name);
begin
  if not coalesce(public.is_store_member(p_store_id),false) then
    raise exception 'Access denied' using errcode = '42501';
  end if;
  if next_name is null or next_name = '' or char_length(next_name) > 100 then
    raise exception 'Enter a name between 1 and 100 characters.' using errcode = '22023';
  end if;
  -- Serialize with customer merges and account deletion before resolving linked accounts.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_store_id::text,0));
  select * into customer from public.crm_customers where id = p_customer_id and store_id = p_store_id for update;
  if not found then raise exception 'Customer not found'; end if;
  if customer.name is distinct from next_name then
    if not exists (select 1 from public.store_members m where m.store_id = p_store_id
      and m.user_id = auth.uid() and m.role in ('OWNER','MANAGER')) then
      raise exception 'Manager access required' using errcode = '42501';
    end if;
    select array_agg(u.id order by u.id) into account_ids
    from public.crm_customer_keys k join auth.users u on k.key = 'user:' || u.id::text
    where k.store_id = p_store_id and k.customer_id = p_customer_id and u.deleted_at is null;
    update auth.users set raw_user_meta_data = coalesce(raw_user_meta_data,'{}'::jsonb) || jsonb_build_object('name',next_name)
      where id = any(account_ids);
    update public.profiles set name = next_name where id = any(account_ids);
  end if;
  update public.crm_customers set name = next_name, notes = p_notes, tags = p_tags where id = customer.id;
end;
$$;

ALTER FUNCTION "public"."update_crm_customer_details"("p_store_id" "uuid", "p_customer_id" "uuid", "p_name" "text", "p_notes" "text", "p_tags" "text"[]) OWNER TO "postgres";

CREATE TABLE "public"."catalog_exchange_rates" (
    "currency" "text" NOT NULL,
    "uah_rate" numeric NOT NULL,
    "rate_date" "date" NOT NULL,
    CONSTRAINT "catalog_exchange_rates_currency_check" CHECK (("currency" = ANY (ARRAY['USD'::"text", 'EUR'::"text", 'PLN'::"text"]))),
    CONSTRAINT "catalog_exchange_rates_uah_rate_check" CHECK (("uah_rate" > (0)::numeric))
);

ALTER TABLE "public"."catalog_exchange_rates" OWNER TO "postgres";

CREATE TABLE "public"."categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "store_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text" NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    "parent_id" "uuid",
    "name_uk" "text",
    "name_en" "text",
    CONSTRAINT "categories_name_en_check" CHECK ((("char_length"("btrim"("name_en")) >= 1) AND ("char_length"("btrim"("name_en")) <= 100))),
    CONSTRAINT "categories_name_uk_check" CHECK ((("char_length"("btrim"("name_uk")) >= 1) AND ("char_length"("btrim"("name_uk")) <= 100)))
);

ALTER TABLE "public"."categories" OWNER TO "postgres";

CREATE TABLE "public"."crm_customer_keys" (
    "store_id" "uuid" NOT NULL,
    "key" "text" NOT NULL,
    "customer_id" "uuid" NOT NULL
);

ALTER TABLE "public"."crm_customer_keys" OWNER TO "postgres";

CREATE TABLE "public"."crm_customers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "store_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "phone" "text" DEFAULT ''::"text" NOT NULL,
    "email" "text" DEFAULT ''::"text" NOT NULL,
    "notes" "text" DEFAULT ''::"text" NOT NULL,
    "tags" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "crm_customers_notes_check" CHECK (("length"("notes") <= 20000)),
    CONSTRAINT "crm_customers_tags_check" CHECK (("cardinality"("tags") <= 200))
);

ALTER TABLE "public"."crm_customers" OWNER TO "postgres";

CREATE TABLE "public"."customer_notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "store_id" "uuid" NOT NULL,
    "event_id" "uuid" NOT NULL,
    "order_id" "uuid" NOT NULL,
    "receipt_code" "text" NOT NULL,
    "kind" "text" NOT NULL,
    "value" "text",
    "read_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "public"."customer_notifications" OWNER TO "postgres";

CREATE TABLE "public"."delivery_settings" (
    "store_id" "uuid" NOT NULL,
    "sender_name" "text" DEFAULT ''::"text" NOT NULL,
    "sender_phone" "text" DEFAULT ''::"text" NOT NULL,
    "city_ref" "text" DEFAULT ''::"text" NOT NULL,
    "city_name" "text" DEFAULT ''::"text" NOT NULL,
    "warehouse_ref" "text" DEFAULT ''::"text" NOT NULL,
    "warehouse_name" "text" DEFAULT ''::"text" NOT NULL,
    "default_weight_grams" integer DEFAULT 1000 NOT NULL,
    "length_cm" integer DEFAULT 20 NOT NULL,
    "width_cm" integer DEFAULT 20 NOT NULL,
    "height_cm" integer DEFAULT 10 NOT NULL,
    "delivery_payer" "text" DEFAULT 'RECIPIENT'::"text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "delivery_settings_default_weight_grams_check" CHECK (("default_weight_grams" > 0)),
    CONSTRAINT "delivery_settings_delivery_payer_check" CHECK (("delivery_payer" = ANY (ARRAY['RECIPIENT'::"text", 'SENDER'::"text"]))),
    CONSTRAINT "delivery_settings_height_cm_check" CHECK (("height_cm" > 0)),
    CONSTRAINT "delivery_settings_length_cm_check" CHECK (("length_cm" > 0)),
    CONSTRAINT "delivery_settings_width_cm_check" CHECK (("width_cm" > 0))
);

ALTER TABLE "public"."delivery_settings" OWNER TO "postgres";

CREATE TABLE "public"."item_returns" (
    "id" "uuid" NOT NULL,
    "order_id" "uuid" NOT NULL,
    "item_id" "uuid" NOT NULL,
    "quantity" integer NOT NULL,
    "reason" "text" NOT NULL,
    "restock" boolean NOT NULL,
    "replacement_variant" "uuid",
    "status" "text" DEFAULT 'requested'::"text" NOT NULL,
    "refund_amount" integer NOT NULL,
    "refund_record_id" "uuid",
    "author_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "item_returns_quantity_check" CHECK (("quantity" > 0)),
    CONSTRAINT "item_returns_reason_check" CHECK ((("length"("reason") >= 1) AND ("length"("reason") <= 1000))),
    CONSTRAINT "item_returns_refund_amount_check" CHECK (("refund_amount" >= 0)),
    CONSTRAINT "item_returns_status_check" CHECK (("status" = ANY (ARRAY['requested'::"text", 'received'::"text", 'completed'::"text", 'cancelled'::"text"])))
);

ALTER TABLE "public"."item_returns" OWNER TO "postgres";

CREATE TABLE "public"."order_delivery_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "status_code" "text" NOT NULL,
    "status_text" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "public"."order_delivery_events" OWNER TO "postgres";

CREATE TABLE "public"."order_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "old_value" "text",
    "new_value" "text",
    "author_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "public"."order_events" OWNER TO "postgres";

CREATE TABLE "public"."order_financials" (
    "order_id" "uuid" NOT NULL,
    "cost_amount" integer NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "order_financials_cost_amount_check" CHECK (("cost_amount" >= 0))
);

ALTER TABLE "public"."order_financials" OWNER TO "postgres";

CREATE TABLE "public"."order_item_costs" (
    "item_id" "uuid" NOT NULL,
    "unit_cost" integer,
    CONSTRAINT "order_item_costs_unit_cost_check" CHECK (("unit_cost" >= 0))
);

ALTER TABLE "public"."order_item_costs" OWNER TO "postgres";

CREATE TABLE "public"."order_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "product_id" "uuid",
    "variant_id" "uuid",
    "product_name" "text" NOT NULL,
    "variant_name" "text" NOT NULL,
    "quantity" integer NOT NULL,
    "unit_price" integer NOT NULL,
    "compare_at_price" integer,
    "line_total" integer NOT NULL,
    "is_preorder" boolean DEFAULT false NOT NULL,
    "weight_grams" integer,
    "stock_deducted" boolean,
    CONSTRAINT "order_items_line_total_check" CHECK (("line_total" >= 0)),
    CONSTRAINT "order_items_quantity_check" CHECK (("quantity" > 0)),
    CONSTRAINT "order_items_unit_price_check" CHECK (("unit_price" >= 0)),
    CONSTRAINT "order_items_weight_grams_check" CHECK (("weight_grams" > 0))
);

ALTER TABLE "public"."order_items" OWNER TO "postgres";

CREATE TABLE "public"."order_merge_members" (
    "order_id" "uuid" NOT NULL,
    "root_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "author_id" "uuid"
);

ALTER TABLE "public"."order_merge_members" OWNER TO "postgres";

CREATE TABLE "public"."order_returns" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "amount" integer NOT NULL,
    "reason" "text" NOT NULL,
    "author_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "order_returns_amount_check" CHECK (("amount" > 0)),
    CONSTRAINT "order_returns_reason_check" CHECK ((("char_length"("reason") >= 1) AND ("char_length"("reason") <= 1000)))
);

ALTER TABLE "public"."order_returns" OWNER TO "postgres";

CREATE TABLE "public"."order_status_history" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "order_id" "uuid" NOT NULL,
    "status" "public"."order_status" NOT NULL,
    "author_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "public"."order_status_history" OWNER TO "postgres";

CREATE TABLE "public"."order_ttn_reservations" (
    "order_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "public"."order_ttn_reservations" OWNER TO "postgres";

CREATE TABLE "public"."product_categories" (
    "id" bigint NOT NULL,
    "store_id" "uuid" NOT NULL,
    "product_id" "uuid" NOT NULL,
    "category_id" "uuid" NOT NULL
);

ALTER TABLE "public"."product_categories" OWNER TO "postgres";

ALTER TABLE "public"."product_categories" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."product_categories_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE "public"."product_costs" (
    "product_id" "uuid" NOT NULL,
    "cost_amount" integer NOT NULL,
    "currency" "text" DEFAULT 'UAH'::"text" NOT NULL,
    "source_amount" integer,
    CONSTRAINT "product_costs_check" CHECK ((("currency" = 'UAH'::"text") OR ("source_amount" IS NOT NULL))),
    CONSTRAINT "product_costs_cost_amount_check" CHECK (("cost_amount" >= 0)),
    CONSTRAINT "product_costs_currency_check" CHECK (("currency" = ANY (ARRAY['UAH'::"text", 'USD'::"text", 'EUR'::"text", 'PLN'::"text"]))),
    CONSTRAINT "product_costs_source_amount_check" CHECK (("source_amount" >= 0))
);

ALTER TABLE "public"."product_costs" OWNER TO "postgres";

CREATE TABLE "public"."product_images" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "storage_path" "text" NOT NULL,
    "public_url" "text" NOT NULL,
    "position" integer DEFAULT 0 NOT NULL
);

ALTER TABLE "public"."product_images" OWNER TO "postgres";

CREATE TABLE "public"."product_variants" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "sku" "text",
    "price" integer NOT NULL,
    "compare_at_price" integer,
    "stock_quantity" integer DEFAULT 0 NOT NULL,
    "is_preorder" boolean DEFAULT false NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    "low_stock_threshold" integer DEFAULT 3 NOT NULL,
    "discount_percent" numeric(5,2),
    "stack_customer_discount" boolean DEFAULT false NOT NULL,
    CONSTRAINT "product_variants_check" CHECK ((("compare_at_price" IS NULL) OR ("compare_at_price" >= "price"))),
    CONSTRAINT "product_variants_discount_percent_check" CHECK ((("discount_percent" >= (0)::numeric) AND ("discount_percent" <= (100)::numeric))),
    CONSTRAINT "product_variants_low_stock_threshold_check" CHECK (("low_stock_threshold" >= 0)),
    CONSTRAINT "product_variants_price_check" CHECK (("price" >= 0)),
    CONSTRAINT "product_variants_stock_quantity_check" CHECK (("stock_quantity" >= 0))
);

ALTER TABLE "public"."product_variants" OWNER TO "postgres";

CREATE TABLE "public"."products" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "store_id" "uuid" NOT NULL,
    "category_id" "uuid",
    "name" "text" NOT NULL,
    "description" "text" DEFAULT ''::"text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "size_guide" "text" DEFAULT ''::"text" NOT NULL,
    "composition" "text" DEFAULT ''::"text" NOT NULL,
    "care_instructions" "text" DEFAULT ''::"text" NOT NULL,
    "size_guide_image_url" "text" DEFAULT ''::"text" NOT NULL,
    "is_new" boolean DEFAULT false NOT NULL,
    "name_uk" "text",
    "name_en" "text",
    "description_uk" "text",
    "description_en" "text",
    "weight_grams" integer,
    "size_guide_en" "text" DEFAULT ''::"text" NOT NULL,
    "composition_en" "text" DEFAULT ''::"text" NOT NULL,
    "care_instructions_en" "text" DEFAULT ''::"text" NOT NULL,
    "size_guide_extra_image_urls" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "discount_percent" numeric(5,2),
    "stack_customer_discount" boolean DEFAULT false NOT NULL,
    CONSTRAINT "products_discount_percent_check" CHECK ((("discount_percent" >= (0)::numeric) AND ("discount_percent" <= (100)::numeric))),
    CONSTRAINT "products_size_guide_extra_image_limit" CHECK (("cardinality"("size_guide_extra_image_urls") <= 2)),
    CONSTRAINT "products_weight_grams_check" CHECK (("weight_grams" > 0))
);

ALTER TABLE "public"."products" OWNER TO "postgres";

CREATE TABLE "public"."profiles" (
    "id" "uuid" NOT NULL,
    "name" "text" DEFAULT ''::"text" NOT NULL,
    "phone" "text" DEFAULT ''::"text" NOT NULL,
    "city" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "public"."profiles" OWNER TO "postgres";

CREATE TABLE "public"."restock_subscriptions" (
    "user_id" "uuid" NOT NULL,
    "variant_id" "uuid" NOT NULL,
    "notified_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "public"."restock_subscriptions" OWNER TO "postgres";

CREATE TABLE "public"."stock_adjustment_requests" (
    "id" "uuid" NOT NULL,
    "variant_id" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "quantity" integer NOT NULL,
    "reason" "text" NOT NULL
);

ALTER TABLE "public"."stock_adjustment_requests" OWNER TO "postgres";

CREATE TABLE "public"."stock_movements" (
    "id" bigint NOT NULL,
    "store_id" "uuid" NOT NULL,
    "variant_id" "uuid" NOT NULL,
    "previous_quantity" integer NOT NULL,
    "quantity" integer NOT NULL,
    "kind" "text" NOT NULL,
    "reason" "text",
    "author_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "public"."stock_movements" OWNER TO "postgres";

ALTER TABLE "public"."stock_movements" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."stock_movements_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE "public"."store_customers" (
    "store_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "joined_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE "public"."store_customers" OWNER TO "postgres";

CREATE TABLE "public"."store_members" (
    "store_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "public"."staff_role" DEFAULT 'MANAGER'::"public"."staff_role" NOT NULL
);

ALTER TABLE "public"."store_members" OWNER TO "postgres";

CREATE TABLE "public"."store_payment_methods" (
    "store_id" "uuid" NOT NULL,
    "cash_on_delivery" boolean DEFAULT true NOT NULL,
    "liqpay" boolean DEFAULT true NOT NULL,
    "monobank" boolean DEFAULT true NOT NULL,
    "monobank_test_mode" boolean DEFAULT false NOT NULL,
    "payment_test_mode" boolean
);

ALTER TABLE "public"."store_payment_methods" OWNER TO "postgres";

CREATE TABLE "public"."storefront_banners" (
    "store_id" "uuid" NOT NULL,
    "image_url" "text" DEFAULT ''::"text" NOT NULL,
    "image_path" "text" DEFAULT ''::"text" NOT NULL,
    "kicker_uk" "text" DEFAULT ''::"text" NOT NULL,
    "kicker_en" "text" DEFAULT ''::"text" NOT NULL,
    "title_uk" "text" DEFAULT ''::"text" NOT NULL,
    "title_en" "text" DEFAULT ''::"text" NOT NULL,
    "description_uk" "text" DEFAULT ''::"text" NOT NULL,
    "description_en" "text" DEFAULT ''::"text" NOT NULL,
    "enabled" boolean DEFAULT true NOT NULL,
    "images" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    CONSTRAINT "storefront_banner_images_are_array" CHECK (("jsonb_typeof"("images") = 'array'::"text"))
);

ALTER TABLE "public"."storefront_banners" OWNER TO "postgres";

CREATE TABLE "public"."storefront_contacts" (
    "store_id" "uuid" NOT NULL,
    "email" "text" DEFAULT ''::"text" NOT NULL,
    "instagram_url" "text" DEFAULT ''::"text" NOT NULL,
    CONSTRAINT "storefront_contacts_email_check" CHECK (("length"("email") <= 254)),
    CONSTRAINT "storefront_contacts_instagram_url_check" CHECK ((("length"("instagram_url") <= 500) AND (("instagram_url" = ''::"text") OR ("instagram_url" ~* '^https://(www\.)?instagram\.com/[A-Za-z0-9._]+/?$'::"text"))))
);

ALTER TABLE "public"."storefront_contacts" OWNER TO "postgres";

CREATE TABLE "public"."stores" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slug" "text" NOT NULL,
    "name" "text" NOT NULL,
    "currency" "text" DEFAULT 'UAH'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sms_notifications_enabled" boolean DEFAULT true NOT NULL,
    CONSTRAINT "stores_currency_check" CHECK (("char_length"("currency") = 3)),
    CONSTRAINT "stores_slug_check" CHECK (("slug" ~ '^[a-z0-9-]+$'::"text"))
);

ALTER TABLE "public"."stores" OWNER TO "postgres";

create function public.set_sms_notifications_enabled(p_store_id uuid, p_enabled boolean)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  enabled boolean;
begin
  update public.stores s
  set sms_notifications_enabled = p_enabled
  where s.id = p_store_id
    and exists (
      select 1 from public.store_members m
      where m.store_id = s.id and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')
    )
  returning s.sms_notifications_enabled into enabled;

  if not found then
    raise insufficient_privilege using message = 'Manager access required';
  end if;

  return enabled;
end;
$$;

revoke all on function public.set_sms_notifications_enabled(uuid, boolean) from public, anon, authenticated, service_role;
grant execute on function public.set_sms_notifications_enabled(uuid, boolean) to authenticated;

CREATE TABLE "public"."variant_costs" (
    "variant_id" "uuid" NOT NULL,
    "cost_amount" integer NOT NULL,
    "currency" "text" DEFAULT 'UAH'::"text" NOT NULL,
    "source_amount" integer,
    CONSTRAINT "variant_costs_check" CHECK ((("currency" = 'UAH'::"text") OR ("source_amount" IS NOT NULL))),
    CONSTRAINT "variant_costs_cost_amount_check" CHECK (("cost_amount" >= 0)),
    CONSTRAINT "variant_costs_currency_check" CHECK (("currency" = ANY (ARRAY['UAH'::"text", 'USD'::"text", 'EUR'::"text", 'PLN'::"text"]))),
    CONSTRAINT "variant_costs_source_amount_check" CHECK (("source_amount" >= 0))
);

ALTER TABLE "public"."variant_costs" OWNER TO "postgres";

ALTER TABLE ONLY "public"."catalog_exchange_rates"
    ADD CONSTRAINT "catalog_exchange_rates_pkey" PRIMARY KEY ("currency");

ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_id_store_id_key" UNIQUE ("id", "store_id");

ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_store_id_slug_key" UNIQUE ("store_id", "slug");

ALTER TABLE ONLY "public"."crm_customer_keys"
    ADD CONSTRAINT "crm_customer_keys_pkey" PRIMARY KEY ("store_id", "key");

ALTER TABLE ONLY "public"."crm_customers"
    ADD CONSTRAINT "crm_customers_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."customer_discounts"
    ADD CONSTRAINT "customer_discounts_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."customer_notifications"
    ADD CONSTRAINT "customer_notifications_event_id_key" UNIQUE ("event_id");

ALTER TABLE ONLY "public"."customer_notifications"
    ADD CONSTRAINT "customer_notifications_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."delivery_settings"
    ADD CONSTRAINT "delivery_settings_pkey" PRIMARY KEY ("store_id");

ALTER TABLE ONLY "public"."item_returns"
    ADD CONSTRAINT "item_returns_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."online_checkouts"
    ADD CONSTRAINT "online_checkouts_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."online_checkouts"
    ADD CONSTRAINT "online_checkouts_provider_order_id_key" UNIQUE ("provider_order_id");

ALTER TABLE ONLY "public"."online_checkouts"
    ADD CONSTRAINT "online_checkouts_receipt_code_key" UNIQUE ("receipt_code");

ALTER TABLE ONLY "public"."order_delivery_events"
    ADD CONSTRAINT "order_delivery_events_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."order_events"
    ADD CONSTRAINT "order_events_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."order_financials"
    ADD CONSTRAINT "order_financials_pkey" PRIMARY KEY ("order_id");

ALTER TABLE ONLY "public"."order_item_costs"
    ADD CONSTRAINT "order_item_costs_pkey" PRIMARY KEY ("item_id");

ALTER TABLE ONLY "public"."order_items"
    ADD CONSTRAINT "order_items_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."order_merge_members"
    ADD CONSTRAINT "order_merge_members_pkey" PRIMARY KEY ("order_id");

ALTER TABLE ONLY "public"."order_returns"
    ADD CONSTRAINT "order_returns_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."order_status_history"
    ADD CONSTRAINT "order_status_history_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."order_ttn_reservations"
    ADD CONSTRAINT "order_ttn_reservations_pkey" PRIMARY KEY ("order_id");

ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_nova_poshta_document_ref_key" UNIQUE ("nova_poshta_document_ref");

ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_nova_poshta_ttn_key" UNIQUE ("nova_poshta_ttn");

ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_receipt_code_key" UNIQUE ("receipt_code");

ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_order_id_key" UNIQUE ("order_id");

ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_provider_order_id_key" UNIQUE ("provider_order_id");

ALTER TABLE ONLY "public"."product_categories"
    ADD CONSTRAINT "product_categories_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."product_categories"
    ADD CONSTRAINT "product_categories_product_id_category_id_key" UNIQUE ("product_id", "category_id");

ALTER TABLE ONLY "public"."product_costs"
    ADD CONSTRAINT "product_costs_pkey" PRIMARY KEY ("product_id");

ALTER TABLE ONLY "public"."product_images"
    ADD CONSTRAINT "product_images_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."product_variants"
    ADD CONSTRAINT "product_variants_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."product_variants"
    ADD CONSTRAINT "product_variants_product_id_sku_key" UNIQUE ("product_id", "sku");

ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_id_store_id_key" UNIQUE ("id", "store_id");

ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."restock_subscriptions"
    ADD CONSTRAINT "restock_subscriptions_pkey" PRIMARY KEY ("user_id", "variant_id");

ALTER TABLE ONLY "public"."stock_adjustment_requests"
    ADD CONSTRAINT "stock_adjustment_requests_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."stock_movements"
    ADD CONSTRAINT "stock_movements_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."store_customers"
    ADD CONSTRAINT "store_customers_pkey" PRIMARY KEY ("store_id", "user_id");

ALTER TABLE ONLY "public"."store_members"
    ADD CONSTRAINT "store_members_pkey" PRIMARY KEY ("store_id", "user_id");

ALTER TABLE ONLY "public"."store_payment_methods"
    ADD CONSTRAINT "store_payment_methods_pkey" PRIMARY KEY ("store_id");

ALTER TABLE ONLY "public"."storefront_banners"
    ADD CONSTRAINT "storefront_banners_pkey" PRIMARY KEY ("store_id");

ALTER TABLE ONLY "public"."storefront_contacts"
    ADD CONSTRAINT "storefront_contacts_pkey" PRIMARY KEY ("store_id");

ALTER TABLE ONLY "public"."stores"
    ADD CONSTRAINT "stores_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."stores"
    ADD CONSTRAINT "stores_slug_key" UNIQUE ("slug");

ALTER TABLE ONLY "public"."variant_costs"
    ADD CONSTRAINT "variant_costs_pkey" PRIMARY KEY ("variant_id");

CREATE UNIQUE INDEX "categories_unique_sibling_name" ON "public"."categories" USING "btree" ("store_id", "parent_id", "lower"("btrim"("name"))) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX "categories_unique_sibling_name_en" ON "public"."categories" USING "btree" ("store_id", "parent_id", "lower"("btrim"(COALESCE("name_en", "name_uk", "name")))) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX "categories_unique_sibling_name_uk" ON "public"."categories" USING "btree" ("store_id", "parent_id", "lower"("btrim"(COALESCE("name_uk", "name_en", "name")))) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX "customer_discount_current" ON "public"."customer_discounts" USING "btree" ("store_id", "user_id") WHERE "enabled";

CREATE INDEX "customer_notifications_user_idx" ON "public"."customer_notifications" USING "btree" ("user_id", "store_id", "created_at" DESC);

CREATE INDEX "online_checkouts_dashboard_period" ON "public"."online_checkouts" USING "btree" ("store_id", "created_at") WHERE (NOT "test_mode");

CREATE INDEX "online_customer_discount" ON "public"."online_checkouts" USING "btree" ("customer_discount_id") WHERE ("customer_discount_id" IS NOT NULL);

CREATE INDEX "order_delivery_events_order_created_idx" ON "public"."order_delivery_events" USING "btree" ("order_id", "created_at" DESC);

CREATE INDEX "order_events_order_idx" ON "public"."order_events" USING "btree" ("order_id", "created_at" DESC);

CREATE INDEX "order_merge_members_root_idx" ON "public"."order_merge_members" USING "btree" ("root_id");

CREATE INDEX "orders_crm_customer" ON "public"."orders" USING "btree" ("crm_customer_id");

CREATE INDEX "orders_customer_discount" ON "public"."orders" USING "btree" ("customer_discount_id") WHERE ("customer_discount_id" IS NOT NULL);

CREATE INDEX "orders_customer_idx" ON "public"."orders" USING "btree" ("user_id", "created_at" DESC);

CREATE INDEX "orders_store_created_idx" ON "public"."orders" USING "btree" ("store_id", "created_at" DESC);

CREATE INDEX "product_categories_by_category" ON "public"."product_categories" USING "btree" ("category_id", "store_id");

CREATE INDEX "stock_movements_variant_history" ON "public"."stock_movements" USING "btree" ("variant_id", "id" DESC);

CREATE INDEX "variants_product_idx" ON "public"."product_variants" USING "btree" ("product_id", "position");

CREATE CONSTRAINT TRIGGER "aggregate_order_cost" AFTER INSERT ON "public"."order_items" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "public"."aggregate_order_cost"();

CREATE OR REPLACE TRIGGER "attach_crm_customer" BEFORE INSERT ON "public"."orders" FOR EACH ROW EXECUTE FUNCTION "public"."attach_crm_customer"();

CREATE OR REPLACE TRIGGER "capture_stock_movement" AFTER UPDATE OF "stock_quantity" ON "public"."product_variants" FOR EACH ROW WHEN (("old"."stock_quantity" IS DISTINCT FROM "new"."stock_quantity")) EXECUTE FUNCTION "public"."capture_stock_movement"();

CREATE OR REPLACE TRIGGER "check_category_parent" BEFORE INSERT OR UPDATE OF "parent_id", "store_id" ON "public"."categories" FOR EACH ROW EXECUTE FUNCTION "public"."check_category_parent"();

CREATE OR REPLACE TRIGGER "delivery_settings_updated" BEFORE UPDATE ON "public"."delivery_settings" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();

CREATE OR REPLACE TRIGGER "notify_restock" AFTER UPDATE OF "stock_quantity" ON "public"."product_variants" FOR EACH ROW WHEN ((("old"."stock_quantity" = 0) AND ("new"."stock_quantity" > 0))) EXECUTE FUNCTION "public"."notify_restock"();

CREATE OR REPLACE TRIGGER "order_event_notification" AFTER INSERT ON "public"."order_events" FOR EACH ROW EXECUTE FUNCTION "public"."notify_order_event"();

CREATE OR REPLACE TRIGGER "orders_capture_events" AFTER INSERT OR UPDATE OF "status", "payment_status" ON "public"."orders" FOR EACH ROW EXECUTE FUNCTION "public"."capture_order_events"();

CREATE OR REPLACE TRIGGER "orders_updated" BEFORE UPDATE ON "public"."orders" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();

CREATE OR REPLACE TRIGGER "payments_updated" BEFORE UPDATE ON "public"."payments" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();

CREATE OR REPLACE TRIGGER "products_updated" BEFORE UPDATE ON "public"."products" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();

CREATE OR REPLACE TRIGGER "profiles_updated" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();

CREATE OR REPLACE TRIGGER "register_crm_customer" AFTER INSERT ON "public"."store_customers" FOR EACH ROW EXECUTE FUNCTION "public"."register_crm_customer"();

CREATE OR REPLACE TRIGGER "snapshot_item_cost" AFTER INSERT ON "public"."order_items" FOR EACH ROW EXECUTE FUNCTION "public"."snapshot_item_cost"();

CREATE OR REPLACE TRIGGER "snapshot_online_customer_discount" BEFORE INSERT ON "public"."orders" FOR EACH ROW EXECUTE FUNCTION "public"."snapshot_online_customer_discount"();

CREATE OR REPLACE TRIGGER "snapshot_order_item_weight" BEFORE INSERT ON "public"."order_items" FOR EACH ROW EXECUTE FUNCTION "public"."snapshot_order_item_weight"();

CREATE OR REPLACE TRIGGER "sync_primary_product_category" AFTER INSERT OR UPDATE OF "category_id" ON "public"."products" FOR EACH ROW EXECUTE FUNCTION "public"."sync_primary_product_category"();

ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_parent_same_store" FOREIGN KEY ("parent_id", "store_id") REFERENCES "public"."categories"("id", "store_id") ON DELETE RESTRICT;

ALTER TABLE ONLY "public"."categories"
    ADD CONSTRAINT "categories_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."crm_customer_keys"
    ADD CONSTRAINT "crm_customer_keys_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."crm_customers"("id");

ALTER TABLE ONLY "public"."crm_customer_keys"
    ADD CONSTRAINT "crm_customer_keys_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id");

ALTER TABLE ONLY "public"."crm_customers"
    ADD CONSTRAINT "crm_customers_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id");

ALTER TABLE ONLY "public"."customer_discounts"
    ADD CONSTRAINT "customer_discounts_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."customer_discounts"
    ADD CONSTRAINT "customer_discounts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."customer_notifications"
    ADD CONSTRAINT "customer_notifications_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."order_events"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."customer_notifications"
    ADD CONSTRAINT "customer_notifications_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."customer_notifications"
    ADD CONSTRAINT "customer_notifications_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id");

ALTER TABLE ONLY "public"."customer_notifications"
    ADD CONSTRAINT "customer_notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."delivery_settings"
    ADD CONSTRAINT "delivery_settings_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."item_returns"
    ADD CONSTRAINT "item_returns_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."order_items"("id");

ALTER TABLE ONLY "public"."item_returns"
    ADD CONSTRAINT "item_returns_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");

ALTER TABLE ONLY "public"."item_returns"
    ADD CONSTRAINT "item_returns_refund_record_id_fkey" FOREIGN KEY ("refund_record_id") REFERENCES "public"."order_returns"("id");

ALTER TABLE ONLY "public"."item_returns"
    ADD CONSTRAINT "item_returns_replacement_variant_fkey" FOREIGN KEY ("replacement_variant") REFERENCES "public"."product_variants"("id");

ALTER TABLE ONLY "public"."online_checkouts"
    ADD CONSTRAINT "online_checkouts_customer_discount_id_fkey" FOREIGN KEY ("customer_discount_id") REFERENCES "public"."customer_discounts"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."online_checkouts"
    ADD CONSTRAINT "online_checkouts_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."online_checkouts"
    ADD CONSTRAINT "online_checkouts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."order_delivery_events"
    ADD CONSTRAINT "order_delivery_events_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."order_events"
    ADD CONSTRAINT "order_events_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."order_events"
    ADD CONSTRAINT "order_events_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."order_financials"
    ADD CONSTRAINT "order_financials_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."order_item_costs"
    ADD CONSTRAINT "order_item_costs_item_id_fkey" FOREIGN KEY ("item_id") REFERENCES "public"."order_items"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."order_items"
    ADD CONSTRAINT "order_items_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."order_items"
    ADD CONSTRAINT "order_items_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."order_items"
    ADD CONSTRAINT "order_items_variant_id_fkey" FOREIGN KEY ("variant_id") REFERENCES "public"."product_variants"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."order_merge_members"
    ADD CONSTRAINT "order_merge_members_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."order_merge_members"
    ADD CONSTRAINT "order_merge_members_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");

ALTER TABLE ONLY "public"."order_merge_members"
    ADD CONSTRAINT "order_merge_members_root_id_fkey" FOREIGN KEY ("root_id") REFERENCES "public"."orders"("id");

ALTER TABLE ONLY "public"."order_returns"
    ADD CONSTRAINT "order_returns_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."order_returns"
    ADD CONSTRAINT "order_returns_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."order_status_history"
    ADD CONSTRAINT "order_status_history_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."order_status_history"
    ADD CONSTRAINT "order_status_history_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."order_ttn_reservations"
    ADD CONSTRAINT "order_ttn_reservations_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");

ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_crm_customer_id_fkey" FOREIGN KEY ("crm_customer_id") REFERENCES "public"."crm_customers"("id");

ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_customer_discount_id_fkey" FOREIGN KEY ("customer_discount_id") REFERENCES "public"."customer_discounts"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id") ON DELETE RESTRICT;

ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."product_categories"
    ADD CONSTRAINT "product_categories_category_id_store_id_fkey" FOREIGN KEY ("category_id", "store_id") REFERENCES "public"."categories"("id", "store_id") ON DELETE RESTRICT;

ALTER TABLE ONLY "public"."product_categories"
    ADD CONSTRAINT "product_categories_product_id_store_id_fkey" FOREIGN KEY ("product_id", "store_id") REFERENCES "public"."products"("id", "store_id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."product_costs"
    ADD CONSTRAINT "product_costs_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."product_images"
    ADD CONSTRAINT "product_images_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."product_variants"
    ADD CONSTRAINT "product_variants_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."categories"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."restock_subscriptions"
    ADD CONSTRAINT "restock_subscriptions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."restock_subscriptions"
    ADD CONSTRAINT "restock_subscriptions_variant_id_fkey" FOREIGN KEY ("variant_id") REFERENCES "public"."product_variants"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."stock_adjustment_requests"
    ADD CONSTRAINT "stock_adjustment_requests_variant_id_fkey" FOREIGN KEY ("variant_id") REFERENCES "public"."product_variants"("id");

ALTER TABLE ONLY "public"."stock_movements"
    ADD CONSTRAINT "stock_movements_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."store_customers"
    ADD CONSTRAINT "store_customers_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."store_customers"
    ADD CONSTRAINT "store_customers_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."store_members"
    ADD CONSTRAINT "store_members_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."store_members"
    ADD CONSTRAINT "store_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."store_payment_methods"
    ADD CONSTRAINT "store_payment_methods_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."storefront_banners"
    ADD CONSTRAINT "storefront_banners_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."storefront_contacts"
    ADD CONSTRAINT "storefront_contacts_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."stores"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."variant_costs"
    ADD CONSTRAINT "variant_costs_variant_id_fkey" FOREIGN KEY ("variant_id") REFERENCES "public"."product_variants"("id") ON DELETE CASCADE;

CREATE POLICY "authenticated read catalogue exchange rates" ON "public"."catalog_exchange_rates" FOR SELECT TO "authenticated" USING (true);

ALTER TABLE "public"."catalog_exchange_rates" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."categories" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."crm_customer_keys" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."crm_customers" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "customer and staff read discounts" ON "public"."customer_discounts" FOR SELECT TO "authenticated" USING ((("user_id" = "auth"."uid"()) OR "public"."is_store_member"("store_id")));

ALTER TABLE "public"."customer_discounts" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."customer_notifications" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "customers join store" ON "public"."store_customers" FOR INSERT WITH CHECK (("user_id" = "auth"."uid"()));

CREATE POLICY "customers read own order items" ON "public"."order_items" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_items"."order_id") AND ("o"."user_id" = "auth"."uid"())))));

CREATE POLICY "customers read own orders" ON "public"."orders" FOR SELECT USING (("user_id" = "auth"."uid"()));

CREATE POLICY "customers read own payments" ON "public"."payments" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "payments"."order_id") AND ("o"."user_id" = "auth"."uid"())))));

CREATE POLICY "customers read own store membership" ON "public"."store_customers" FOR SELECT USING (("user_id" = "auth"."uid"()));

ALTER TABLE "public"."delivery_settings" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."item_returns" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."online_checkouts" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."order_delivery_events" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."order_events" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."order_financials" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."order_item_costs" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."order_items" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."order_merge_members" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."order_returns" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."order_status_history" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."order_ttn_reservations" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."orders" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."product_categories" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."product_costs" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."product_images" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."product_variants" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."products" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "public can read active products" ON "public"."products" FOR SELECT USING ("is_active");

CREATE POLICY "public can read categories" ON "public"."categories" FOR SELECT USING (true);

CREATE POLICY "public can read images of active products" ON "public"."product_images" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."products" "p"
  WHERE (("p"."id" = "product_images"."product_id") AND "p"."is_active"))));

CREATE POLICY "public can read stores" ON "public"."stores" FOR SELECT USING (true);

CREATE POLICY "public can read variants of active products" ON "public"."product_variants" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."products" "p"
  WHERE (("p"."id" = "product_variants"."product_id") AND "p"."is_active"))));

CREATE POLICY "public read payment methods" ON "public"."store_payment_methods" FOR SELECT USING (true);

CREATE POLICY "public read storefront banners" ON "public"."storefront_banners" FOR SELECT USING (true);

CREATE POLICY "public read storefront contacts" ON "public"."storefront_contacts" FOR SELECT TO "authenticated", "anon" USING (true);

CREATE POLICY "read categories of visible products" ON "public"."product_categories" FOR SELECT TO "authenticated", "anon" USING ((EXISTS ( SELECT 1
   FROM "public"."products" "p"
  WHERE (("p"."id" = "product_categories"."product_id") AND ("p"."store_id" = "product_categories"."store_id")))));

CREATE POLICY "read own notifications" ON "public"."customer_notifications" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));

CREATE POLICY "read own restock subscriptions" ON "public"."restock_subscriptions" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));

ALTER TABLE "public"."restock_subscriptions" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "staff access delivery events" ON "public"."order_delivery_events" USING ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_delivery_events"."order_id") AND "public"."is_store_member"("o"."store_id"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_delivery_events"."order_id") AND "public"."is_store_member"("o"."store_id")))));

CREATE POLICY "staff access order items" ON "public"."order_items" USING ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_items"."order_id") AND "public"."is_store_member"("o"."store_id"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_items"."order_id") AND "public"."is_store_member"("o"."store_id")))));

CREATE POLICY "staff access orders" ON "public"."orders" USING ("public"."is_store_member"("store_id")) WITH CHECK ("public"."is_store_member"("store_id"));

CREATE POLICY "staff access status history" ON "public"."order_status_history" USING ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_status_history"."order_id") AND "public"."is_store_member"("o"."store_id"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_status_history"."order_id") AND "public"."is_store_member"("o"."store_id")))));

CREATE POLICY "staff access store payments" ON "public"."payments" USING ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "payments"."order_id") AND "public"."is_store_member"("o"."store_id"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "payments"."order_id") AND "public"."is_store_member"("o"."store_id")))));

CREATE POLICY "staff edit CRM customers" ON "public"."crm_customers" FOR UPDATE TO "authenticated" USING ("public"."is_store_member"("store_id")) WITH CHECK ("public"."is_store_member"("store_id"));

CREATE POLICY "staff insert payment methods" ON "public"."store_payment_methods" FOR INSERT TO "authenticated" WITH CHECK ("public"."is_store_member"("store_id"));

CREATE POLICY "staff manage categories" ON "public"."categories" USING ("public"."is_store_member"("store_id")) WITH CHECK ("public"."is_store_member"("store_id"));

CREATE POLICY "staff manage delivery settings" ON "public"."delivery_settings" USING ("public"."is_store_member"("store_id")) WITH CHECK ("public"."is_store_member"("store_id"));

CREATE POLICY "staff manage images" ON "public"."product_images" USING ((EXISTS ( SELECT 1
   FROM "public"."products" "p"
  WHERE (("p"."id" = "product_images"."product_id") AND "public"."is_store_member"("p"."store_id"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."products" "p"
  WHERE (("p"."id" = "product_images"."product_id") AND "public"."is_store_member"("p"."store_id")))));

CREATE POLICY "staff manage product costs" ON "public"."product_costs" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."products" "p"
  WHERE (("p"."id" = "product_costs"."product_id") AND "public"."is_store_member"("p"."store_id"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."products" "p"
  WHERE (("p"."id" = "product_costs"."product_id") AND "public"."is_store_member"("p"."store_id")))));

CREATE POLICY "staff manage products" ON "public"."products" USING ("public"."is_store_member"("store_id")) WITH CHECK ("public"."is_store_member"("store_id"));

CREATE POLICY "staff manage stock requests" ON "public"."stock_adjustment_requests" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."product_variants" "v"
     JOIN "public"."products" "p" ON (("p"."id" = "v"."product_id")))
  WHERE (("v"."id" = "stock_adjustment_requests"."variant_id") AND "public"."is_store_member"("p"."store_id"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM ("public"."product_variants" "v"
     JOIN "public"."products" "p" ON (("p"."id" = "v"."product_id")))
  WHERE (("v"."id" = "stock_adjustment_requests"."variant_id") AND "public"."is_store_member"("p"."store_id")))));

CREATE POLICY "staff manage storefront banners" ON "public"."storefront_banners" TO "authenticated" USING ("public"."is_store_member"("store_id")) WITH CHECK ("public"."is_store_member"("store_id"));

CREATE POLICY "staff manage storefront contacts" ON "public"."storefront_contacts" TO "authenticated" USING ("public"."is_store_member"("store_id")) WITH CHECK ("public"."is_store_member"("store_id"));

CREATE POLICY "staff manage variant costs" ON "public"."variant_costs" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."product_variants" "v"
     JOIN "public"."products" "p" ON (("p"."id" = "v"."product_id")))
  WHERE (("v"."id" = "variant_costs"."variant_id") AND "public"."is_store_member"("p"."store_id"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM ("public"."product_variants" "v"
     JOIN "public"."products" "p" ON (("p"."id" = "v"."product_id")))
  WHERE (("v"."id" = "variant_costs"."variant_id") AND "public"."is_store_member"("p"."store_id")))));

CREATE POLICY "staff manage variants" ON "public"."product_variants" USING ((EXISTS ( SELECT 1
   FROM "public"."products" "p"
  WHERE (("p"."id" = "product_variants"."product_id") AND "public"."is_store_member"("p"."store_id"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."products" "p"
  WHERE (("p"."id" = "product_variants"."product_id") AND "public"."is_store_member"("p"."store_id")))));

CREATE POLICY "staff read CRM customers" ON "public"."crm_customers" FOR SELECT TO "authenticated" USING ("public"."is_store_member"("store_id"));

CREATE POLICY "staff read CRM identities" ON "public"."crm_customer_keys" FOR SELECT TO "authenticated" USING ("public"."is_store_member"("store_id"));

CREATE POLICY "staff read cost snapshots" ON "public"."order_item_costs" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."order_items" "i"
     JOIN "public"."orders" "o" ON (("o"."id" = "i"."order_id")))
  WHERE (("i"."id" = "order_item_costs"."item_id") AND "public"."is_store_member"("o"."store_id")))));

CREATE POLICY "staff read customers" ON "public"."profiles" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."user_id" = "profiles"."id") AND "public"."is_store_member"("o"."store_id")))));

CREATE POLICY "staff read financials" ON "public"."order_financials" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_financials"."order_id") AND "public"."is_store_member"("o"."store_id")))));

CREATE POLICY "staff read internal events" ON "public"."order_events" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_events"."order_id") AND "public"."is_store_member"("o"."store_id")))));

CREATE POLICY "staff read item returns" ON "public"."item_returns" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "item_returns"."order_id") AND "public"."is_store_member"("o"."store_id")))));

CREATE POLICY "staff read merged orders" ON "public"."order_merge_members" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_merge_members"."order_id") AND "public"."is_store_member"("o"."store_id")))));

CREATE POLICY "staff read own membership" ON "public"."store_members" FOR SELECT USING (("user_id" = "auth"."uid"()));

CREATE POLICY "staff read restock demand" ON "public"."restock_subscriptions" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."product_variants" "v"
     JOIN "public"."products" "p" ON (("p"."id" = "v"."product_id")))
  WHERE (("v"."id" = "restock_subscriptions"."variant_id") AND "public"."is_store_member"("p"."store_id")))));

CREATE POLICY "staff read returns" ON "public"."order_returns" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."orders" "o"
  WHERE (("o"."id" = "order_returns"."order_id") AND "public"."is_store_member"("o"."store_id")))));

CREATE POLICY "staff read stock movements" ON "public"."stock_movements" FOR SELECT TO "authenticated" USING ("public"."is_store_member"("store_id"));

CREATE POLICY "staff read store customers" ON "public"."store_customers" FOR SELECT USING ("public"."is_store_member"("store_id"));

CREATE POLICY "staff update payment methods" ON "public"."store_payment_methods" FOR UPDATE TO "authenticated" USING ("public"."is_store_member"("store_id")) WITH CHECK ("public"."is_store_member"("store_id"));

ALTER TABLE "public"."stock_adjustment_requests" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."stock_movements" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."store_customers" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."store_members" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."store_payment_methods" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."storefront_banners" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."storefront_contacts" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."stores" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users read own profile" ON "public"."profiles" FOR SELECT USING (("id" = "auth"."uid"()));

CREATE POLICY "users update own profile" ON "public"."profiles" FOR UPDATE USING (("id" = "auth"."uid"())) WITH CHECK (("id" = "auth"."uid"()));

ALTER TABLE "public"."variant_costs" ENABLE ROW LEVEL SECURITY;

GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

REVOKE ALL ON TABLE "public"."customer_discounts" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."customer_discounts" TO "anon";
GRANT ALL ON TABLE "public"."customer_discounts" TO "authenticated";
GRANT ALL ON TABLE "public"."customer_discounts" TO "service_role";

REVOKE ALL ON FUNCTION "public"."active_customer_discount"("p_store" "uuid", "p_user" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."active_customer_discount"("p_store" "uuid", "p_user" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."active_customer_discount"("p_store" "uuid", "p_user" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."adjust_catalog_stock"("p_variant" "uuid", "p_kind" "text", "p_quantity" integer, "p_reason" "text", "p_request" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."adjust_catalog_stock"("p_variant" "uuid", "p_kind" "text", "p_quantity" integer, "p_reason" "text", "p_request" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."adjust_catalog_stock"("p_variant" "uuid", "p_kind" "text", "p_quantity" integer, "p_reason" "text", "p_request" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."adjust_catalog_stock"("p_variant" "uuid", "p_kind" "text", "p_quantity" integer, "p_reason" "text", "p_request" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."adjust_catalog_stock"("p_variant" "uuid", "p_kind" "text", "p_quantity" integer, "p_reason" "text", "p_request" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."advance_item_return"("p_id" "uuid", "p_status" "text") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."advance_item_return"("p_id" "uuid", "p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."advance_item_return"("p_id" "uuid", "p_status" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."advance_item_return"("p_id" "uuid", "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."advance_item_return"("p_id" "uuid", "p_status" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."aggregate_order_cost"() FROM anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION "public"."aggregate_order_cost"() TO PUBLIC;
GRANT ALL ON FUNCTION "public"."aggregate_order_cost"() TO "anon";
GRANT ALL ON FUNCTION "public"."aggregate_order_cost"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."aggregate_order_cost"() TO "service_role";

REVOKE ALL ON TABLE "public"."orders" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."orders" TO "anon";
GRANT ALL ON TABLE "public"."orders" TO "authenticated";
GRANT ALL ON TABLE "public"."orders" TO "service_role";

REVOKE ALL ON FUNCTION "public"."apply_admin_order_update"("p_order_ids" "uuid"[], "p_status" "public"."order_status", "p_confirm_paid" boolean, "p_include_group" boolean, "p_restore_stock" boolean) FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."apply_admin_order_update"("p_order_ids" "uuid"[], "p_status" "public"."order_status", "p_confirm_paid" boolean, "p_include_group" boolean, "p_restore_stock" boolean) FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."apply_online_payment_callback"("p_provider" "text", "p_reference" "text", "p_paid" boolean, "p_payment_id" "text", "p_callback" "jsonb") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."apply_online_payment_callback"("p_provider" "text", "p_reference" "text", "p_paid" boolean, "p_payment_id" "text", "p_callback" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."apply_online_payment_callback"("p_provider" "text", "p_reference" "text", "p_paid" boolean, "p_payment_id" "text", "p_callback" "jsonb") TO "service_role";

REVOKE ALL ON FUNCTION "public"."attach_crm_customer"() FROM anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION "public"."attach_crm_customer"() TO PUBLIC;
GRANT ALL ON FUNCTION "public"."attach_crm_customer"() TO "anon";
GRANT ALL ON FUNCTION "public"."attach_crm_customer"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."attach_crm_customer"() TO "service_role";

REVOKE ALL ON TABLE "public"."payments" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."payments" TO "anon";
GRANT ALL ON TABLE "public"."payments" TO "authenticated";
GRANT ALL ON TABLE "public"."payments" TO "service_role";

REVOKE ALL ON FUNCTION "public"."begin_reserved_order_action"("p_order_id" "uuid", "p_user_id" "uuid", "p_operation" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."begin_reserved_order_action"("p_order_id" "uuid", "p_user_id" "uuid", "p_operation" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."begin_reserved_order_action"("p_order_id" "uuid", "p_user_id" "uuid", "p_operation" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."cancel_customer_reservation"("p_order_id" "uuid", "p_user_id" "uuid", "p_operation" "uuid", "p_provider_order_id" "text") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."cancel_customer_reservation"("p_order_id" "uuid", "p_user_id" "uuid", "p_operation" "uuid", "p_provider_order_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cancel_customer_reservation"("p_order_id" "uuid", "p_user_id" "uuid", "p_operation" "uuid", "p_provider_order_id" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."cancel_merged_unpaid_order"("p_order_id" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."cancel_merged_unpaid_order"("p_order_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cancel_merged_unpaid_order"("p_order_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."cancel_merged_unpaid_order"("p_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancel_merged_unpaid_order"("p_order_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."cancel_unpaid_order"("p_order_id" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."cancel_unpaid_order"("p_order_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cancel_unpaid_order"("p_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancel_unpaid_order"("p_order_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."capture_order_events"() FROM anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION "public"."capture_order_events"() TO PUBLIC;
GRANT ALL ON FUNCTION "public"."capture_order_events"() TO "anon";
GRANT ALL ON FUNCTION "public"."capture_order_events"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."capture_order_events"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."capture_stock_movement"() FROM anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION "public"."capture_stock_movement"() TO PUBLIC;
GRANT ALL ON FUNCTION "public"."capture_stock_movement"() TO "anon";
GRANT ALL ON FUNCTION "public"."capture_stock_movement"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."capture_stock_movement"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."catalog_cost_in_uah"("p_amount" integer, "p_currency" "text") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."catalog_cost_in_uah"("p_amount" integer, "p_currency" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."catalog_cost_in_uah"("p_amount" integer, "p_currency" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."catalog_cost_in_uah"("p_amount" integer, "p_currency" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."change_merged_order_status"("p_order_id" "uuid", "p_status" "public"."order_status") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."change_merged_order_status"("p_order_id" "uuid", "p_status" "public"."order_status") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."change_merged_order_status"("p_order_id" "uuid", "p_status" "public"."order_status") TO "anon";
GRANT ALL ON FUNCTION "public"."change_merged_order_status"("p_order_id" "uuid", "p_status" "public"."order_status") TO "authenticated";
GRANT ALL ON FUNCTION "public"."change_merged_order_status"("p_order_id" "uuid", "p_status" "public"."order_status") TO "service_role";

REVOKE ALL ON FUNCTION "public"."change_order_status"("p_order_id" "uuid", "p_status" "public"."order_status") FROM anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION "public"."change_order_status"("p_order_id" "uuid", "p_status" "public"."order_status") TO PUBLIC;
GRANT ALL ON FUNCTION "public"."change_order_status"("p_order_id" "uuid", "p_status" "public"."order_status") TO "anon";
GRANT ALL ON FUNCTION "public"."change_order_status"("p_order_id" "uuid", "p_status" "public"."order_status") TO "authenticated";
GRANT ALL ON FUNCTION "public"."change_order_status"("p_order_id" "uuid", "p_status" "public"."order_status") TO "service_role";

REVOKE ALL ON FUNCTION "public"."check_category_parent"() FROM anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION "public"."check_category_parent"() TO PUBLIC;
GRANT ALL ON FUNCTION "public"."check_category_parent"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_category_parent"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_category_parent"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."claim_guest_order"("p_store_id" "uuid", "p_receipt_code" "text") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."claim_guest_order"("p_store_id" "uuid", "p_receipt_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_guest_order"("p_store_id" "uuid", "p_receipt_code" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."claim_guest_order"("p_store_id" "uuid", "p_receipt_code" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."confirm_online_checkout"("p_provider" "text", "p_reference" "text", "p_amount" integer, "p_currency" "text", "p_payment_id" "text", "p_callback" "jsonb") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."confirm_online_checkout"("p_provider" "text", "p_reference" "text", "p_amount" integer, "p_currency" "text", "p_payment_id" "text", "p_callback" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."confirm_online_checkout"("p_provider" "text", "p_reference" "text", "p_amount" integer, "p_currency" "text", "p_payment_id" "text", "p_callback" "jsonb") TO "service_role";

REVOKE ALL ON FUNCTION "public"."create_discounted_store_order"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_expected_discount_percent" numeric, "p_expected_total" integer) FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."create_discounted_store_order"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_expected_discount_percent" numeric, "p_expected_total" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_discounted_store_order"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_expected_discount_percent" numeric, "p_expected_total" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."create_discounted_store_order"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_expected_discount_percent" numeric, "p_expected_total" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_discounted_store_order"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_expected_discount_percent" numeric, "p_expected_total" integer) TO "service_role";

REVOKE ALL ON FUNCTION "public"."create_order_with_payment"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."create_order_with_payment"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_order_with_payment"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."create_order_with_payment"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_monobank_test_mode" boolean) FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."create_order_with_payment"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_monobank_test_mode" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_order_with_payment"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_monobank_test_mode" boolean) TO "service_role";

REVOKE ALL ON FUNCTION "public"."create_priced_catalog_order"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_monobank_test_mode" boolean, "p_discount" "public"."customer_discounts", "p_expected_total" integer) FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."create_priced_catalog_order"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_monobank_test_mode" boolean, "p_discount" "public"."customer_discounts", "p_expected_total" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_priced_catalog_order"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_monobank_test_mode" boolean, "p_discount" "public"."customer_discounts", "p_expected_total" integer) TO "service_role";

REVOKE ALL ON FUNCTION "public"."create_reserved_online_order"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_monobank_test_mode" boolean) FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."create_reserved_online_order"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_monobank_test_mode" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_reserved_online_order"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text", "p_monobank_test_mode" boolean) TO "service_role";

REVOKE ALL ON FUNCTION "public"."create_store_order"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text") FROM anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION "public"."create_store_order"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text") TO PUBLIC;
GRANT ALL ON FUNCTION "public"."create_store_order"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_store_order"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_store_order"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_delivery_city" "text", "p_delivery_address" "text", "p_note" "text", "p_delivery_city_ref" "text", "p_delivery_address_ref" "text", "p_delivery_service_type" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."crm_customer_accounts"("p_store_id" "uuid", "p_customer_id" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."crm_customer_accounts"("p_store_id" "uuid", "p_customer_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crm_customer_accounts"("p_store_id" "uuid", "p_customer_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."crm_customer_accounts"("p_store_id" "uuid", "p_customer_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."crm_customer_discount_usage"("p_discount_id" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."crm_customer_discount_usage"("p_discount_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crm_customer_discount_usage"("p_discount_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crm_customer_discount_usage"("p_discount_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."crm_customer_phone_confirmed"("p_store_id" "uuid", "p_customer_id" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."crm_customer_phone_confirmed"("p_store_id" "uuid", "p_customer_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crm_customer_phone_confirmed"("p_store_id" "uuid", "p_customer_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."crm_customer_phone_confirmed"("p_store_id" "uuid", "p_customer_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."crm_customer_staff_access"("p_store_id" "uuid", "p_customer_id" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."crm_customer_staff_access"("p_store_id" "uuid", "p_customer_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crm_customer_staff_access"("p_store_id" "uuid", "p_customer_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crm_customer_staff_access"("p_store_id" "uuid", "p_customer_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."crm_dashboard_payment_stats"("p_store_id" "uuid", "p_from" "date", "p_to" "date", "p_currency" "text") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."crm_dashboard_payment_stats"("p_store_id" "uuid", "p_from" "date", "p_to" "date", "p_currency" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crm_dashboard_payment_stats"("p_store_id" "uuid", "p_from" "date", "p_to" "date", "p_currency" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crm_dashboard_payment_stats"("p_store_id" "uuid", "p_from" "date", "p_to" "date", "p_currency" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."crm_identity"("p_store" "uuid", "p_key" "text", "p_name" "text", "p_phone" "text", "p_email" "text") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."crm_identity"("p_store" "uuid", "p_key" "text", "p_name" "text", "p_phone" "text", "p_email" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crm_identity"("p_store" "uuid", "p_key" "text", "p_name" "text", "p_phone" "text", "p_email" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."crm_identity"("p_store" "uuid", "p_key" "text", "p_name" "text", "p_phone" "text", "p_email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crm_identity"("p_store" "uuid", "p_key" "text", "p_name" "text", "p_phone" "text", "p_email" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."crm_order_activity"("p_order_id" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."crm_order_activity"("p_order_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crm_order_activity"("p_order_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crm_order_activity"("p_order_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."customer_discount_usage"("p_discount" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."customer_discount_usage"("p_discount" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."customer_discount_usage"("p_discount" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."delete_catalog_product"("p_store_id" "uuid", "p_product_id" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."delete_catalog_product"("p_store_id" "uuid", "p_product_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_catalog_product"("p_store_id" "uuid", "p_product_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."delete_catalog_product"("p_store_id" "uuid", "p_product_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."delete_crm_customer_account"("p_store_id" "uuid", "p_customer_id" "uuid", "p_user_id" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."delete_crm_customer_account"("p_store_id" "uuid", "p_customer_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_crm_customer_account"("p_store_id" "uuid", "p_customer_id" "uuid", "p_user_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."delete_crm_customer_account"("p_store_id" "uuid", "p_customer_id" "uuid", "p_user_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."duplicate_catalog_product"("p_product" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."duplicate_catalog_product"("p_product" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."duplicate_catalog_product"("p_product" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."duplicate_catalog_product"("p_product" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."duplicate_catalog_product"("p_product" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."get_online_checkout_status"("p_receipt_code" "text") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."get_online_checkout_status"("p_receipt_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_online_checkout_status"("p_receipt_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_online_checkout_status"("p_receipt_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_online_checkout_status"("p_receipt_code" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."get_order_receipt"("p_receipt_code" "text") FROM anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION "public"."get_order_receipt"("p_receipt_code" "text") TO PUBLIC;
GRANT ALL ON FUNCTION "public"."get_order_receipt"("p_receipt_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_order_receipt"("p_receipt_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_order_receipt"("p_receipt_code" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."handle_new_user"() FROM anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION "public"."handle_new_user"() TO PUBLIC;
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."is_store_member"("target_store_id" "uuid") FROM anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION "public"."is_store_member"("target_store_id" "uuid") TO PUBLIC;
GRANT ALL ON FUNCTION "public"."is_store_member"("target_store_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_store_member"("target_store_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_store_member"("target_store_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."mark_all_notifications_read"("p_store_id" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."mark_all_notifications_read"("p_store_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mark_all_notifications_read"("p_store_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."mark_all_notifications_read"("p_store_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."mark_all_notifications_read"("p_store_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."mark_notification_read"("p_id" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."mark_notification_read"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mark_notification_read"("p_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."mark_notification_read"("p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."mark_notification_read"("p_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."merge_crm_customers"("p_source" "uuid", "p_target" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."merge_crm_customers"("p_source" "uuid", "p_target" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."merge_crm_customers"("p_source" "uuid", "p_target" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."merge_crm_customers"("p_source" "uuid", "p_target" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."merge_crm_customers"("p_source" "uuid", "p_target" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."merge_orders"("p_order_ids" "uuid"[], "p_target_id" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."merge_orders"("p_order_ids" "uuid"[], "p_target_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."merge_orders"("p_order_ids" "uuid"[], "p_target_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."merge_orders"("p_order_ids" "uuid"[], "p_target_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."merge_orders"("p_order_ids" "uuid"[], "p_target_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."merged_order_shipping"("p_order_id" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."merged_order_shipping"("p_order_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."merged_order_shipping"("p_order_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."my_customer_discount"("p_store_id" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."my_customer_discount"("p_store_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."my_customer_discount"("p_store_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."my_customer_discount"("p_store_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."notify_order_event"() FROM anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION "public"."notify_order_event"() TO PUBLIC;
GRANT ALL ON FUNCTION "public"."notify_order_event"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_order_event"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_order_event"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."notify_restock"() FROM anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION "public"."notify_restock"() TO PUBLIC;
GRANT ALL ON FUNCTION "public"."notify_restock"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_restock"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_restock"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."nova_poshta_order_weight_grams"("p_order_id" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."nova_poshta_order_weight_grams"("p_order_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."nova_poshta_order_weight_grams"("p_order_id" "uuid") TO "service_role";

REVOKE ALL ON TABLE "public"."online_checkouts" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."online_checkouts" TO "service_role";

REVOKE ALL ON FUNCTION "public"."prepare_online_checkout"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_checkout" "jsonb", "p_test_mode" boolean) FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."prepare_online_checkout"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_checkout" "jsonb", "p_test_mode" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."prepare_online_checkout"("p_provider" "text", "p_user_id" "uuid", "p_store_id" "uuid", "p_items" "jsonb", "p_checkout" "jsonb", "p_test_mode" boolean) TO "service_role";

REVOKE ALL ON FUNCTION "public"."quote_catalog_cart"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_percent" numeric, "p_lock_stock" boolean) FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."quote_catalog_cart"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_percent" numeric, "p_lock_stock" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."quote_catalog_cart"("p_store_id" "uuid", "p_items" "jsonb", "p_customer_percent" numeric, "p_lock_stock" boolean) TO "service_role";

REVOKE ALL ON FUNCTION "public"."receipt_events"("p_code" "text") FROM anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION "public"."receipt_events"("p_code" "text") TO PUBLIC;
GRANT ALL ON FUNCTION "public"."receipt_events"("p_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."receipt_events"("p_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."receipt_events"("p_code" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."record_order_return"("p_order_id" "uuid", "p_amount" integer, "p_reason" "text") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."record_order_return"("p_order_id" "uuid", "p_amount" integer, "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_order_return"("p_order_id" "uuid", "p_amount" integer, "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."record_order_return"("p_order_id" "uuid", "p_amount" integer, "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_order_return"("p_order_id" "uuid", "p_amount" integer, "p_reason" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."refresh_catalog_exchange_rates"() FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."refresh_catalog_exchange_rates"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."refresh_catalog_exchange_rates"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."register_crm_customer"() FROM anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION "public"."register_crm_customer"() TO PUBLIC;
GRANT ALL ON FUNCTION "public"."register_crm_customer"() TO "anon";
GRANT ALL ON FUNCTION "public"."register_crm_customer"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_crm_customer"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."release_order_ttn"("p_order_id" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."release_order_ttn"("p_order_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."release_order_ttn"("p_order_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."request_item_return"("p_id" "uuid", "p_item" "uuid", "p_quantity" integer, "p_reason" "text", "p_restock" boolean, "p_replacement" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."request_item_return"("p_id" "uuid", "p_item" "uuid", "p_quantity" integer, "p_reason" "text", "p_restock" boolean, "p_replacement" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."request_item_return"("p_id" "uuid", "p_item" "uuid", "p_quantity" integer, "p_reason" "text", "p_restock" boolean, "p_replacement" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."request_item_return"("p_id" "uuid", "p_item" "uuid", "p_quantity" integer, "p_reason" "text", "p_restock" boolean, "p_replacement" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."request_item_return"("p_id" "uuid", "p_item" "uuid", "p_quantity" integer, "p_reason" "text", "p_restock" boolean, "p_replacement" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."reserve_order_ttn"("p_order_id" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."reserve_order_ttn"("p_order_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reserve_order_ttn"("p_order_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."restore_stock_and_cancel_order"("p_order_id" "uuid") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."restore_stock_and_cancel_order"("p_order_id" "uuid") FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."save_catalog_costs"("p_product_id" "uuid", "p_update_default" boolean, "p_default_cost" integer, "p_variant_costs" "jsonb") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."save_catalog_costs"("p_product_id" "uuid", "p_update_default" boolean, "p_default_cost" integer, "p_variant_costs" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."save_catalog_costs"("p_product_id" "uuid", "p_update_default" boolean, "p_default_cost" integer, "p_variant_costs" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_catalog_costs"("p_product_id" "uuid", "p_update_default" boolean, "p_default_cost" integer, "p_variant_costs" "jsonb") TO "service_role";

REVOKE ALL ON FUNCTION "public"."save_catalog_costs_in_currency"("p_product_id" "uuid", "p_update_default" boolean, "p_default_cost" integer, "p_default_currency" "text", "p_variant_costs" "jsonb") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."save_catalog_costs_in_currency"("p_product_id" "uuid", "p_update_default" boolean, "p_default_cost" integer, "p_default_currency" "text", "p_variant_costs" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."save_catalog_costs_in_currency"("p_product_id" "uuid", "p_update_default" boolean, "p_default_cost" integer, "p_default_currency" "text", "p_variant_costs" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_catalog_costs_in_currency"("p_product_id" "uuid", "p_update_default" boolean, "p_default_cost" integer, "p_default_currency" "text", "p_variant_costs" "jsonb") TO "service_role";

REVOKE ALL ON FUNCTION "public"."set_catalog_product_categories"("p_products" "uuid"[], "p_categories" "uuid"[]) FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."set_catalog_product_categories"("p_products" "uuid"[], "p_categories" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_catalog_product_categories"("p_products" "uuid"[], "p_categories" "uuid"[]) TO "service_role";
GRANT ALL ON FUNCTION "public"."set_catalog_product_categories"("p_products" "uuid"[], "p_categories" "uuid"[]) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."set_crm_administrator"("p_store_id" "uuid", "p_customer_id" "uuid", "p_user_id" "uuid", "p_grant" boolean) FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."set_crm_administrator"("p_store_id" "uuid", "p_customer_id" "uuid", "p_user_id" "uuid", "p_grant" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_crm_administrator"("p_store_id" "uuid", "p_customer_id" "uuid", "p_user_id" "uuid", "p_grant" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_crm_administrator"("p_store_id" "uuid", "p_customer_id" "uuid", "p_user_id" "uuid", "p_grant" boolean) TO "service_role";

REVOKE ALL ON FUNCTION "public"."set_customer_discount"("p_store_id" "uuid", "p_customer_id" "uuid", "p_user_id" "uuid", "p_percent" numeric, "p_mode" "text", "p_order_limit" integer, "p_starts_on" "date", "p_ends_on" "date") FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."set_customer_discount"("p_store_id" "uuid", "p_customer_id" "uuid", "p_user_id" "uuid", "p_percent" numeric, "p_mode" "text", "p_order_limit" integer, "p_starts_on" "date", "p_ends_on" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_customer_discount"("p_store_id" "uuid", "p_customer_id" "uuid", "p_user_id" "uuid", "p_percent" numeric, "p_mode" "text", "p_order_limit" integer, "p_starts_on" "date", "p_ends_on" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."set_customer_discount"("p_store_id" "uuid", "p_customer_id" "uuid", "p_user_id" "uuid", "p_percent" numeric, "p_mode" "text", "p_order_limit" integer, "p_starts_on" "date", "p_ends_on" "date") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."set_order_cost"("p_order_id" "uuid", "p_amount" integer) FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."set_order_cost"("p_order_id" "uuid", "p_amount" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_order_cost"("p_order_id" "uuid", "p_amount" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."set_order_cost"("p_order_id" "uuid", "p_amount" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_order_cost"("p_order_id" "uuid", "p_amount" integer) TO "service_role";

REVOKE ALL ON FUNCTION "public"."snapshot_item_cost"() FROM anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION "public"."snapshot_item_cost"() TO PUBLIC;
GRANT ALL ON FUNCTION "public"."snapshot_item_cost"() TO "anon";
GRANT ALL ON FUNCTION "public"."snapshot_item_cost"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."snapshot_item_cost"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."snapshot_online_customer_discount"() FROM anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION "public"."snapshot_online_customer_discount"() TO PUBLIC;
GRANT ALL ON FUNCTION "public"."snapshot_online_customer_discount"() TO "anon";
GRANT ALL ON FUNCTION "public"."snapshot_online_customer_discount"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."snapshot_online_customer_discount"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."snapshot_order_item_weight"() FROM anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION "public"."snapshot_order_item_weight"() TO PUBLIC;
GRANT ALL ON FUNCTION "public"."snapshot_order_item_weight"() TO "anon";
GRANT ALL ON FUNCTION "public"."snapshot_order_item_weight"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."snapshot_order_item_weight"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."subscribe_restock"("p_variant" "uuid", "p_subscribe" boolean) FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."subscribe_restock"("p_variant" "uuid", "p_subscribe" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."subscribe_restock"("p_variant" "uuid", "p_subscribe" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."subscribe_restock"("p_variant" "uuid", "p_subscribe" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."subscribe_restock"("p_variant" "uuid", "p_subscribe" boolean) TO "service_role";

REVOKE ALL ON FUNCTION "public"."sync_primary_product_category"() FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."sync_primary_product_category"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_primary_product_category"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."touch_updated_at"() FROM anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION "public"."touch_updated_at"() TO PUBLIC;
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "service_role";

REVOKE ALL ON FUNCTION "public"."update_admin_orders"("p_order_ids" "uuid"[], "p_status" "public"."order_status", "p_confirm_paid" boolean, "p_restore_stock" boolean) FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."update_admin_orders"("p_order_ids" "uuid"[], "p_status" "public"."order_status", "p_confirm_paid" boolean, "p_restore_stock" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_admin_orders"("p_order_ids" "uuid"[], "p_status" "public"."order_status", "p_confirm_paid" boolean, "p_restore_stock" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_admin_orders"("p_order_ids" "uuid"[], "p_status" "public"."order_status", "p_confirm_paid" boolean, "p_restore_stock" boolean) TO "service_role";

REVOKE ALL ON FUNCTION "public"."update_crm_customer_details"("p_store_id" "uuid", "p_customer_id" "uuid", "p_name" "text", "p_notes" "text", "p_tags" "text"[]) FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION "public"."update_crm_customer_details"("p_store_id" "uuid", "p_customer_id" "uuid", "p_name" "text", "p_notes" "text", "p_tags" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_crm_customer_details"("p_store_id" "uuid", "p_customer_id" "uuid", "p_name" "text", "p_notes" "text", "p_tags" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_crm_customer_details"("p_store_id" "uuid", "p_customer_id" "uuid", "p_name" "text", "p_notes" "text", "p_tags" "text"[]) TO "service_role";

REVOKE ALL ON TABLE "public"."catalog_exchange_rates" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."catalog_exchange_rates" TO "service_role";
GRANT SELECT ON TABLE "public"."catalog_exchange_rates" TO "authenticated";

REVOKE ALL ON TABLE "public"."categories" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."categories" TO "anon";
GRANT ALL ON TABLE "public"."categories" TO "authenticated";
GRANT ALL ON TABLE "public"."categories" TO "service_role";

REVOKE ALL ON TABLE "public"."crm_customer_keys" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."crm_customer_keys" TO "anon";
GRANT ALL ON TABLE "public"."crm_customer_keys" TO "authenticated";
GRANT ALL ON TABLE "public"."crm_customer_keys" TO "service_role";

REVOKE ALL ON TABLE "public"."crm_customers" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."crm_customers" TO "anon";
GRANT ALL ON TABLE "public"."crm_customers" TO "authenticated";
GRANT ALL ON TABLE "public"."crm_customers" TO "service_role";

REVOKE ALL ON TABLE "public"."customer_notifications" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."customer_notifications" TO "anon";
GRANT ALL ON TABLE "public"."customer_notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."customer_notifications" TO "service_role";

REVOKE ALL ON TABLE "public"."delivery_settings" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."delivery_settings" TO "anon";
GRANT ALL ON TABLE "public"."delivery_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."delivery_settings" TO "service_role";

REVOKE ALL ON TABLE "public"."item_returns" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."item_returns" TO "anon";
GRANT ALL ON TABLE "public"."item_returns" TO "authenticated";
GRANT ALL ON TABLE "public"."item_returns" TO "service_role";

REVOKE ALL ON TABLE "public"."order_delivery_events" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."order_delivery_events" TO "anon";
GRANT ALL ON TABLE "public"."order_delivery_events" TO "authenticated";
GRANT ALL ON TABLE "public"."order_delivery_events" TO "service_role";

REVOKE ALL ON TABLE "public"."order_events" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."order_events" TO "anon";
GRANT ALL ON TABLE "public"."order_events" TO "authenticated";
GRANT ALL ON TABLE "public"."order_events" TO "service_role";

REVOKE ALL ON TABLE "public"."order_financials" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."order_financials" TO "anon";
GRANT ALL ON TABLE "public"."order_financials" TO "authenticated";
GRANT ALL ON TABLE "public"."order_financials" TO "service_role";

REVOKE ALL ON TABLE "public"."order_item_costs" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."order_item_costs" TO "anon";
GRANT ALL ON TABLE "public"."order_item_costs" TO "authenticated";
GRANT ALL ON TABLE "public"."order_item_costs" TO "service_role";

REVOKE ALL ON TABLE "public"."order_items" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."order_items" TO "anon";
GRANT ALL ON TABLE "public"."order_items" TO "authenticated";
GRANT ALL ON TABLE "public"."order_items" TO "service_role";

REVOKE ALL ON TABLE "public"."order_merge_members" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."order_merge_members" TO "anon";
GRANT ALL ON TABLE "public"."order_merge_members" TO "authenticated";
GRANT ALL ON TABLE "public"."order_merge_members" TO "service_role";

REVOKE ALL ON TABLE "public"."order_returns" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."order_returns" TO "anon";
GRANT ALL ON TABLE "public"."order_returns" TO "authenticated";
GRANT ALL ON TABLE "public"."order_returns" TO "service_role";

REVOKE ALL ON TABLE "public"."order_status_history" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."order_status_history" TO "anon";
GRANT ALL ON TABLE "public"."order_status_history" TO "authenticated";
GRANT ALL ON TABLE "public"."order_status_history" TO "service_role";

REVOKE ALL ON TABLE "public"."order_ttn_reservations" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."order_ttn_reservations" TO "anon";
GRANT ALL ON TABLE "public"."order_ttn_reservations" TO "authenticated";
GRANT ALL ON TABLE "public"."order_ttn_reservations" TO "service_role";

REVOKE ALL ON TABLE "public"."product_categories" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."product_categories" TO "service_role";
GRANT SELECT ON TABLE "public"."product_categories" TO "anon";
GRANT SELECT ON TABLE "public"."product_categories" TO "authenticated";

REVOKE ALL ON SEQUENCE "public"."product_categories_id_seq" FROM anon, authenticated, service_role;
GRANT ALL ON SEQUENCE "public"."product_categories_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."product_categories_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."product_categories_id_seq" TO "service_role";

REVOKE ALL ON TABLE "public"."product_costs" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."product_costs" TO "authenticated";
GRANT ALL ON TABLE "public"."product_costs" TO "service_role";

REVOKE ALL ON TABLE "public"."product_images" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."product_images" TO "anon";
GRANT ALL ON TABLE "public"."product_images" TO "authenticated";
GRANT ALL ON TABLE "public"."product_images" TO "service_role";

REVOKE ALL ON TABLE "public"."product_variants" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."product_variants" TO "anon";
GRANT ALL ON TABLE "public"."product_variants" TO "authenticated";
GRANT ALL ON TABLE "public"."product_variants" TO "service_role";

REVOKE ALL ON TABLE "public"."products" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."products" TO "anon";
GRANT ALL ON TABLE "public"."products" TO "authenticated";
GRANT ALL ON TABLE "public"."products" TO "service_role";

REVOKE ALL ON TABLE "public"."profiles" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";

REVOKE ALL ON TABLE "public"."restock_subscriptions" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."restock_subscriptions" TO "anon";
GRANT ALL ON TABLE "public"."restock_subscriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."restock_subscriptions" TO "service_role";

REVOKE ALL ON TABLE "public"."stock_adjustment_requests" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."stock_adjustment_requests" TO "anon";
GRANT ALL ON TABLE "public"."stock_adjustment_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."stock_adjustment_requests" TO "service_role";

REVOKE ALL ON TABLE "public"."stock_movements" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."stock_movements" TO "anon";
GRANT ALL ON TABLE "public"."stock_movements" TO "authenticated";
GRANT ALL ON TABLE "public"."stock_movements" TO "service_role";

REVOKE ALL ON SEQUENCE "public"."stock_movements_id_seq" FROM anon, authenticated, service_role;
GRANT ALL ON SEQUENCE "public"."stock_movements_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."stock_movements_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."stock_movements_id_seq" TO "service_role";

REVOKE ALL ON TABLE "public"."store_customers" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."store_customers" TO "anon";
GRANT ALL ON TABLE "public"."store_customers" TO "authenticated";
GRANT ALL ON TABLE "public"."store_customers" TO "service_role";

REVOKE ALL ON TABLE "public"."store_members" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."store_members" TO "anon";
GRANT ALL ON TABLE "public"."store_members" TO "authenticated";
GRANT ALL ON TABLE "public"."store_members" TO "service_role";

REVOKE ALL ON TABLE "public"."store_payment_methods" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."store_payment_methods" TO "service_role";
GRANT SELECT ON TABLE "public"."store_payment_methods" TO "anon";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."store_payment_methods" TO "authenticated";

REVOKE ALL ON TABLE "public"."storefront_banners" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."storefront_banners" TO "anon";
GRANT ALL ON TABLE "public"."storefront_banners" TO "authenticated";
GRANT ALL ON TABLE "public"."storefront_banners" TO "service_role";

REVOKE ALL ON TABLE "public"."storefront_contacts" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."storefront_contacts" TO "anon";
GRANT ALL ON TABLE "public"."storefront_contacts" TO "authenticated";
GRANT ALL ON TABLE "public"."storefront_contacts" TO "service_role";

REVOKE ALL ON TABLE "public"."stores" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."stores" TO "anon";
GRANT ALL ON TABLE "public"."stores" TO "authenticated";
GRANT ALL ON TABLE "public"."stores" TO "service_role";

REVOKE ALL ON TABLE "public"."variant_costs" FROM anon, authenticated, service_role;
GRANT ALL ON TABLE "public"."variant_costs" TO "anon";
GRANT ALL ON TABLE "public"."variant_costs" TO "authenticated";
GRANT ALL ON TABLE "public"."variant_costs" TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";

-- Supabase Auth and Storage integrations
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  ('product-images', 'product-images', true, 5242880, ARRAY['image/jpeg', 'image/png', 'image/webp']),
  ('storefront-banners', 'storefront-banners', true, 5242880, ARRAY['image/jpeg', 'image/png', 'image/webp']);

CREATE POLICY "public can read product image files" ON storage.objects
  FOR SELECT USING (bucket_id = 'product-images');

create policy "staff manage own store product images"
on storage.objects for all to authenticated
using (
  bucket_id = 'product-images'
  and (storage.foldername(storage.objects.name))[1] = 'products'
  and exists (
    select 1
    from public.products p
    where p.id = case
      when (storage.foldername(storage.objects.name))[2] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then (storage.foldername(storage.objects.name))[2]::uuid
    end
    and public.is_store_member(p.store_id)
  )
);

create policy "public read storefront banner images" on storage.objects for select using (bucket_id = 'storefront-banners');
create policy "staff upload storefront banner images" on storage.objects for insert to authenticated with check (
  bucket_id = 'storefront-banners' and public.is_store_member(case when split_part(name, '/', 1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(name, '/', 1)::uuid else null end)
);
create policy "staff delete storefront banner images" on storage.objects for delete to authenticated using (
  bucket_id = 'storefront-banners' and public.is_store_member(case when split_part(name, '/', 1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(name, '/', 1)::uuid else null end)
);

-- Create the store in a fresh Supabase database.
insert into public.stores (id, slug, name, currency)
values ('11111111-1111-4111-8111-111111111111', 'tatami', 'tatami.culture', 'UAH')
on conflict (slug) do update set name = excluded.name, currency = excluded.currency;

-- Manual orders use catalog prices and the normal inventory and CRM triggers.
create function public.create_crm_order(
  p_store_id uuid, p_request_id uuid, p_items jsonb, p_customer jsonb,
  p_delivery jsonb, p_note text, p_expected_total integer
) returns public.orders
language plpgsql security definer set search_path = '' as $$
declare
  created_order public.orders;
  quote record;
  buyer_name text := btrim(coalesce(p_customer->>'name', ''));
  buyer_phone text := btrim(coalesce(p_customer->>'phone', ''));
  buyer_email text := lower(btrim(coalesce(p_customer->>'email', '')));
  city_name text := btrim(coalesce(p_delivery->>'city', ''));
  address_name text := btrim(coalesce(p_delivery->>'address', ''));
  city_ref text := nullif(btrim(p_delivery->>'cityRef'), '');
  address_ref text := nullif(btrim(p_delivery->>'addressRef'), '');
  service_type text := p_delivery->>'serviceType';
  order_note text := btrim(coalesce(p_note, ''));
begin
  if not public.is_store_member(p_store_id) then
    raise insufficient_privilege using message = 'Manager access required';
  end if;
  if p_request_id is null then
    raise invalid_parameter_value using message = 'Invalid order request.';
  end if;

  -- Reuse the order ID on retries, including after a lost response.
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));
  select * into created_order from public.orders
  where id = p_request_id and store_id = p_store_id;
  if found then return created_order; end if;

  if buyer_name = '' or length(buyer_name) > 200
    or buyer_phone !~ '^\+[1-9][0-9]{7,14}$' or length(buyer_email) > 254 then
    raise invalid_parameter_value using message = 'Enter a valid customer name and phone number.';
  end if;
  if city_name = '' or address_name = '' or length(city_name) > 200 or length(address_name) > 500 then
    raise invalid_parameter_value using message = 'Enter the city and delivery address.';
  end if;
  if (city_ref is null) <> (address_ref is null)
    or (city_ref is not null and coalesce(service_type, '') not in ('WarehouseWarehouse', 'WarehousePostomat')) then
    raise invalid_parameter_value using message = 'Choose a city and Nova Poshta branch';
  end if;
  if length(order_note) > 2000 then
    raise invalid_parameter_value using message = 'The order note is too long.';
  end if;

  select * into quote from public.quote_catalog_cart(p_store_id, p_items, null, true);
  if p_expected_total is distinct from quote.total then
    raise sqlstate 'PT409' using message = 'Order prices changed. Review the total and try again.';
  end if;

  insert into public.orders (
    id, store_id, customer_name, customer_phone, customer_email, delivery_city, delivery_address,
    delivery_city_ref, delivery_address_ref, delivery_service_type, note, total_price, currency,
    payment_method, payment_test_mode, status, payment_status
  )
  select p_request_id, s.id, buyer_name, buyer_phone, buyer_email, city_name, address_name,
    city_ref, address_ref, case when city_ref is not null then service_type end, order_note, quote.total, s.currency,
    'CASH_ON_DELIVERY', false,
    case when quote.total = 0 then 'PAID'::public.order_status else 'PENDING'::public.order_status end,
    case when quote.total = 0 then 'PAID'::public.payment_status else 'PENDING'::public.payment_status end
  from public.stores s where s.id = p_store_id
  returning * into created_order;

  insert into public.order_items (
    order_id, product_id, variant_id, product_name, variant_name, quantity,
    unit_price, compare_at_price, line_total, is_preorder, stock_deducted
  )
  select created_order.id, line.product_id, line.variant_id, line.product_name, line.variant_name, line.quantity,
    line.unit_price, line.compare_at_price, line.line_total, line.is_preorder, true
  from jsonb_populate_recordset(null::public.order_items, quote.items) as line;

  update public.product_variants v set stock_quantity = v.stock_quantity - line.quantity
  from jsonb_populate_recordset(null::public.order_items, quote.items) as line
  where v.id = line.variant_id;

  insert into public.order_status_history (order_id, status, author_id)
  values (created_order.id, created_order.status, auth.uid());
  return created_order;
end;
$$;

revoke all on function public.create_crm_order(uuid, uuid, jsonb, jsonb, jsonb, text, integer) from public, anon, authenticated, service_role;
grant execute on function public.create_crm_order(uuid, uuid, jsonb, jsonb, jsonb, text, integer) to authenticated;

-- Baseline the included migrations for subsequent Supabase CLI db push.
CREATE SCHEMA IF NOT EXISTS supabase_migrations;
CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (
  version text PRIMARY KEY,
  statements text[],
  name text
);
ALTER TABLE supabase_migrations.schema_migrations ADD COLUMN IF NOT EXISTS name text;
INSERT INTO supabase_migrations.schema_migrations (version, name) VALUES
  ('20261101112059', 'order_delivery_workflows'),
  ('20261102201144', 'crm_operations'),
  ('20261102202118', 'crm_event_visibility'),
  ('20261104122435', 'storefront_banner'),
  ('20261104133611', 'catalog_stock_operations'),
  ('20261104134453', 'product_details'),
  ('20261104180416', 'crm_customers_returns_costs'),
  ('20261104190845', 'mark_all_notifications_read'),
  ('20261104191255', 'rename_tatami_culture'),
  ('20261105122554', 'crm_registered_customer_management'),
  ('20261105124347', 'storefront_banner_visibility'),
  ('20261105125842', 'storefront_banner_carousel'),
  ('20261105131036', 'store_payment_methods'),
  ('20261107152819', 'claim_guest_order'),
  ('20261108135342', 'fix_product_image_storage_policy'),
  ('20261108141032', 'catalog_category_hierarchy'),
  ('20261108142420', 'protect_catalog_product_deletion'),
  ('20261108144413', 'catalog_category_localized_names'),
  ('20261108171626', 'storefront_contacts'),
  ('20261108200523', 'product_size_guide_image'),
  ('20261108201327', 'product_new_badge'),
  ('20261108202850', 'lowercase_store_brand'),
  ('20261108213552', 'product_localized_text'),
  ('20261109113746', 'crm_order_activity_author_names'),
  ('20261109121242', 'monobank_test_mode'),
  ('20261109122342', 'shared_payment_test_mode'),
  ('20261109124604', 'allow_ttn_for_test_orders'),
  ('20261109181916', 'product_shipping_weight'),
  ('20261110152426', 'merge_orders'),
  ('20261110154540', 'preserve_merged_order_statuses'),
  ('20261110155505', 'synchronize_manual_paid_status'),
  ('20261110160130', 'respect_manual_payment_status'),
  ('20261110160554', 'confirm_admin_status_after_payment'),
  ('20261111125649', 'crm_customer_phone_status'),
  ('20261111133647', 'sms_auth_provider'),
  ('20261111134809', 'remove_sms_provider_shadow_setting'),
  ('20261111194033', 'manage_reserved_online_orders'),
  ('20261111225847', 'create_online_orders_after_payment'),
  ('20261117161352', 'default_product_cost'),
  ('20261117162234', 'catalog_cost_exchange_rates'),
  ('20261117171203', 'personal_customer_discounts'),
  ('20261117171948', 'guard_discount_checkout_totals'),
  ('20261117181559', 'edit_crm_customer_name'),
  ('20261117182931', 'dashboard_payment_analytics'),
  ('20261117184618', 'manage_crm_administrators'),
  ('20261118120000', 'product_information_translations'),
  ('20261118120100', 'size_guide_gallery'),
  ('20261118120200', 'track_preorder_stock'),
  ('20261118120300', 'catalog_discounts'),
  ('20261118120400', 'remove_obsolete_store_fields'),
  ('20261118120500', 'create_crm_order'),
  ('20261119090000', 'sms_notifications_setting'),
  ('20261119101000', 'crm_customer_filters')
ON CONFLICT (version) DO NOTHING;

create function public.list_crm_customers(p_store_id uuid)
returns table (
  id uuid, name text, phone text, email text, notes text, tags text[], created_at timestamptz,
  phone_confirmed boolean, is_administrator boolean, has_active_discount boolean
)
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if not public.is_store_member(p_store_id) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;

  return query
  with account_flags as (
    select k.customer_id,
      bool_or(a.phone_confirmed_at is not null
        and number.digits <> ''
        and ltrim(a.phone, '+') = case when number.digits ~ '^0[0-9]{9}$' then '38' || number.digits else number.digits end
      ) as phone_confirmed,
      bool_or(m.role in ('OWNER', 'MANAGER')) as is_administrator,
      bool_or(case d.mode
        when 'unlimited' then true
        when 'period' then (now() at time zone 'Europe/Kyiv')::date between d.starts_on and d.ends_on
        when 'orders' then public.customer_discount_usage(d.id) < d.order_limit
        else false
      end) as has_active_discount
    from public.crm_customer_keys k
    join public.crm_customers c on c.id = k.customer_id and c.store_id = k.store_id
    join auth.users a on k.key = 'user:' || a.id::text
    cross join lateral (select regexp_replace(c.phone, '[^0-9]', '', 'g') as digits) number
    left join public.store_members m on m.store_id = k.store_id and m.user_id = a.id
    left join public.customer_discounts d on d.store_id = k.store_id and d.user_id = a.id and d.enabled
    where k.store_id = p_store_id and a.deleted_at is null and not a.is_anonymous
    group by k.customer_id
  )
  select c.id, c.name, c.phone, c.email, c.notes, c.tags, c.created_at,
    coalesce(f.phone_confirmed, false), coalesce(f.is_administrator, false), coalesce(f.has_active_discount, false)
  from public.crm_customers c
  left join account_flags f on f.customer_id = c.id
  where c.store_id = p_store_id;
end;
$$;

revoke all on function public.list_crm_customers(uuid) from public, anon, authenticated, service_role;
grant execute on function public.list_crm_customers(uuid) to authenticated;

-- Обновление курсов начинается по расписанию, даже если НБУ недоступен при установке.
SELECT cron.schedule('tatami-catalog-exchange-rates', '*/15 * * * *',
                     'select public.refresh_catalog_exchange_rates()');

NOTIFY pgrst, 'reload schema';
COMMIT;

-- Первый владелец CRM. Зарегистрируйтесь в магазине, скопируйте UUID своего
-- пользователя из Authentication → Users и отдельно выполните эту команду:
-- INSERT INTO public.store_members (store_id, user_id, role)
-- SELECT id, '<UUID пользователя>'::uuid, 'OWNER' FROM public.stores WHERE slug = 'tatami';
