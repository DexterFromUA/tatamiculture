-- tatami.culture · начальная схема для нового проекта Supabase
-- Для нового проекта Supabase с PostgreSQL 17, Auth и Storage.
-- Выполните файл целиком в SQL Editor под ролью postgres.
-- Создаётся пустой магазин tatami. Существующие заказы, пользователи, файлы
-- и ключи интеграций не копируются. Владелец назначается через seed-owner.sql.
-- Учтены миграции репозитория по 20261124161810 включительно.
BEGIN;

DO $$
BEGIN
  IF to_regclass('public.shop_settings') IS NOT NULL OR to_regclass('public.stores') IS NOT NULL THEN
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
    'CANCELLED_BY_STORE',
    'WAITING_FOR_STOCK',
    'PREPARING_SHIPMENT',
    'IN_TRANSIT',
    'COMPLETED'
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
  update public.order_events
  set author_id = p_user_id
  where order_id = p_order_id and kind = 'status' and new_value = 'CANCELLED_BY_USER'
    and created_at = transaction_timestamp() and author_id is null;
end;
$$;

ALTER FUNCTION "public"."cancel_customer_reservation"("p_order_id" "uuid", "p_user_id" "uuid", "p_operation" "uuid", "p_provider_order_id" "text") OWNER TO "postgres";

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
    if not v_attempt.test_mode and (not v_preorder or v_attempt.track_preorder_stock) then
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
  from public.shop_settings s where s.id = p_store_id
  returning * into created_order;

  for line in select * from jsonb_populate_recordset(null::public.order_items, quote.items) order by variant_id loop
    insert into public.order_items (
      order_id, product_id, variant_id, product_name, variant_name, quantity,
      unit_price, compare_at_price, line_total, is_preorder, stock_deducted
    ) values (
      created_order.id, line.product_id, line.variant_id, line.product_name, line.variant_name, line.quantity,
      line.unit_price, line.compare_at_price, line.line_total, line.is_preorder, line.stock_deducted and not test_mode
    );
    if line.stock_deducted and not test_mode then
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
    'pending',count(*) filter (where status = 'PENDING' and created_at is not null and expires_at > now()),
    'expired',count(*) filter (where status = 'PENDING' and created_at is not null and expires_at <= now()),
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

  insert into public.product_variants (product_id, name, sku, price, compare_at_price, stock_quantity, is_preorder, position, low_stock_threshold, discount_percent, stack_customer_discount, allow_out_of_stock)
  select copy_id, name, null, price, compare_at_price, 0, is_preorder, position, low_stock_threshold, discount_percent, stack_customer_discount, allow_out_of_stock
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
  from public.shop_settings s left join public.store_payment_methods pm on pm.store_id = s.id
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
      v.allow_out_of_stock,
      v.stock_quantity >= r.quantity as stock_deducted,
      greatest(v.price, v.compare_at_price) as regular_price,
      coalesce(v.discount_percent, p.discount_percent) as catalog_percent,
      case when v.discount_percent is null then p.stack_customer_discount
        else v.stack_customer_discount end as allows_stacking
    from requested r
    join public.product_variants v on v.id = r.variant_id
    join public.products p on p.id = v.product_id
    where p.store_id = p_store_id and p.is_active
      and r.quantity <= 20
      and (v.stock_quantity >= r.quantity
        or (v.stock_quantity = 0 and v.allow_out_of_stock))
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
    select product_id, variant_id, product_name, variant_name, quantity, is_preorder, allow_out_of_stock, stock_deducted, unit_price,
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
  set status = 'CANCELLED_BY_STORE',
      payment_status = case when v_order.payment_method = 'CASH_ON_DELIVERY'
        then v_order.payment_status else 'FAILED'::public.payment_status end
  where id = v_order.id
  returning * into v_order;

  update public.payments
  set status = 'FAILED', updated_at = now()
  where order_id = v_order.id and status = 'PENDING';

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
    "allow_out_of_stock" boolean DEFAULT false NOT NULL,
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

CREATE TABLE "public"."shop_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "currency" "text" DEFAULT 'UAH'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sms_notifications_enabled" boolean DEFAULT true NOT NULL,
    CONSTRAINT "shop_settings_currency_check" CHECK (("char_length"("currency") = 3))
);

ALTER TABLE "public"."shop_settings" OWNER TO "postgres";

create function public.set_sms_notifications_enabled(p_store_id uuid, p_enabled boolean)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  enabled boolean;
begin
  update public.shop_settings s
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

ALTER TABLE ONLY "public"."shop_settings"
    ADD CONSTRAINT "shop_settings_pkey" PRIMARY KEY ("id");

CREATE UNIQUE INDEX shop_settings_single_row_idx ON public.shop_settings ((true));

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
    ADD CONSTRAINT "categories_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."shop_settings"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."crm_customer_keys"
    ADD CONSTRAINT "crm_customer_keys_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "public"."crm_customers"("id");

ALTER TABLE ONLY "public"."crm_customer_keys"
    ADD CONSTRAINT "crm_customer_keys_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."shop_settings"("id");

ALTER TABLE ONLY "public"."crm_customers"
    ADD CONSTRAINT "crm_customers_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."shop_settings"("id");

ALTER TABLE ONLY "public"."customer_discounts"
    ADD CONSTRAINT "customer_discounts_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."shop_settings"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."customer_discounts"
    ADD CONSTRAINT "customer_discounts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."customer_notifications"
    ADD CONSTRAINT "customer_notifications_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."order_events"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."customer_notifications"
    ADD CONSTRAINT "customer_notifications_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."customer_notifications"
    ADD CONSTRAINT "customer_notifications_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."shop_settings"("id");

ALTER TABLE ONLY "public"."customer_notifications"
    ADD CONSTRAINT "customer_notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."delivery_settings"
    ADD CONSTRAINT "delivery_settings_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."shop_settings"("id") ON DELETE CASCADE;

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
    ADD CONSTRAINT "online_checkouts_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."shop_settings"("id") ON DELETE CASCADE;

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

ALTER TABLE ONLY "public"."order_ttn_reservations"
    ADD CONSTRAINT "order_ttn_reservations_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");

ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_crm_customer_id_fkey" FOREIGN KEY ("crm_customer_id") REFERENCES "public"."crm_customers"("id");

ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_customer_discount_id_fkey" FOREIGN KEY ("customer_discount_id") REFERENCES "public"."customer_discounts"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."shop_settings"("id") ON DELETE RESTRICT;

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
    ADD CONSTRAINT "products_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."shop_settings"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."restock_subscriptions"
    ADD CONSTRAINT "restock_subscriptions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."restock_subscriptions"
    ADD CONSTRAINT "restock_subscriptions_variant_id_fkey" FOREIGN KEY ("variant_id") REFERENCES "public"."product_variants"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."stock_adjustment_requests"
    ADD CONSTRAINT "stock_adjustment_requests_variant_id_fkey" FOREIGN KEY ("variant_id") REFERENCES "public"."product_variants"("id");

ALTER TABLE ONLY "public"."stock_movements"
    ADD CONSTRAINT "stock_movements_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."shop_settings"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."store_customers"
    ADD CONSTRAINT "store_customers_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."shop_settings"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."store_customers"
    ADD CONSTRAINT "store_customers_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."store_members"
    ADD CONSTRAINT "store_members_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."shop_settings"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."store_members"
    ADD CONSTRAINT "store_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."store_payment_methods"
    ADD CONSTRAINT "store_payment_methods_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."shop_settings"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."storefront_banners"
    ADD CONSTRAINT "storefront_banners_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."shop_settings"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."storefront_contacts"
    ADD CONSTRAINT "storefront_contacts_store_id_fkey" FOREIGN KEY ("store_id") REFERENCES "public"."shop_settings"("id") ON DELETE CASCADE;

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

CREATE POLICY "public can read shop settings" ON "public"."shop_settings" FOR SELECT USING (true);

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

ALTER TABLE "public"."shop_settings" ENABLE ROW LEVEL SECURITY;

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

REVOKE ALL ON TABLE "public"."shop_settings" FROM anon, authenticated, service_role;
GRANT SELECT ON TABLE "public"."shop_settings" TO "anon";
GRANT SELECT ON TABLE "public"."shop_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."shop_settings" TO "service_role";

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
insert into public.shop_settings (id, name, currency)
values ('11111111-1111-4111-8111-111111111111', 'tatami.culture', 'UAH');

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
  from public.shop_settings s where s.id = p_store_id
  returning * into created_order;

  insert into public.order_items (
    order_id, product_id, variant_id, product_name, variant_name, quantity,
    unit_price, compare_at_price, line_total, is_preorder, stock_deducted
  )
  select created_order.id, line.product_id, line.variant_id, line.product_name, line.variant_name, line.quantity,
    line.unit_price, line.compare_at_price, line.line_total, line.is_preorder, line.stock_deducted
  from jsonb_populate_recordset(null::public.order_items, quote.items) as line;

  update public.product_variants v set stock_quantity = v.stock_quantity - line.quantity
  from jsonb_populate_recordset(null::public.order_items, quote.items) as line
  where v.id = line.variant_id and line.stock_deducted;

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
  ('20261119101000', 'crm_customer_filters'),
  ('20261119110000', 'allow_out_of_stock_purchases'),
  ('20261119110100', 'variant_out_of_stock_purchases'),
  ('20261119110200', 'correct_cod_payment_status'),
  ('20261119110300', 'crm_server_pagination'),
  ('20261119110400', 'storefront_catalog_feed'),
  ('20261119110500', 'single_shop_settings'),
  ('20261119110600', 'retire_order_status_history'),
  ('20261119110700', 'retire_stores_view'),
  ('20261119110800', 'remove_obsolete_rpcs'),
  ('20261120120000', 'storefront_theme_settings'),
  ('20261120150000', 'registration_agreement'),
  ('20261121120000', 'dashboard_expired_payment_attempts'),
  ('20261121120100', 'order_workflow_statuses'),
  ('20261121120200', 'order_workflow'),
  ('20261121120300', 'nova_poshta_order_tracking'),
  ('20261121120400', 'order_cancellation_refunds'),
  ('20261121120500', 'order_fulfillment_stock'),
  ('20261121120600', 'order_ttn_recovery'),
  ('20261121120700', 'attach_existing_order_ttn'),
  ('20261121120800', 'order_status_automation_setting'),
  ('20261121120900', 'procured_orders_and_waybill_controls'),
  ('20261121121000', 'order_refund_review'),
  ('20261121121100', 'online_fulfillment_stages'),
  ('20261121121200', 'cancel_online_procurement'),
  ('20261121121300', 'correct_order_operations'),
  ('20261121121400', 'payment_reconciliation'),
  ('20261121121500', 'allow_test_order_status_changes'),
  ('20261121121600', 'nova_poshta_simulator'),
  ('20261121121700', 'test_waybill_details_and_refunds'),
  ('20261121121800', 'monobank_test_refunds'),
  ('20261121121900', 'nova_poshta_stage'),
  ('20261122120000', 'nova_poshta_stage_tracking'),
  ('20261122120100', 'manual_test_orders'),
  ('20261122120200', 'remove_delivery_and_refund_testing'),
  ('20261122120300', 'unify_order_workflow'),
  ('20261122120400', 'match_crm_customers_by_phone'),
  ('20261122120500', 'crm_verified_phone_identity'),
  ('20261122120600', 'validate_checkout_phone'),
  ('20261122120700', 'nova_poshta_tracking_interval'),
  ('20261122120800', 'nova_poshta_tracking_minutes'),
  ('20261122120900', 'completed_order_ttn'),
  ('20261122121000', 'new_order_filter'),
  ('20261122121100', 'customer_web_push'),
  ('20261122121200', 'customer_push_order_updates'),
  ('20261122121300', 'actionable_customer_push'),
  ('20261122121400', 'customer_discount_push'),
  ('20261123120000', 'split_order_items'),
  ('20261123120100', 'manual_customer_push'),
  ('20261123120200', 'customer_push_broadcast'),
  ('20261123120300', 'staff_order_push'),
  ('20261123120400', 'sms_notifications'),
  ('20261123120500', 'sms_outside_customer_profile'),
  ('20261123120600', 'suppress_payment_accepted_push'),
  ('20261123120700', 'dashboard_net_successful_payments'),
  ('20261124160740', 'selected_customer_broadcast'),
  ('20261124161810', 'verified_sms_broadcast')
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

create index crm_customers_store_page_idx on public.crm_customers (store_id, created_at desc, id);
create index products_store_page_idx on public.products (store_id, created_at desc, id desc);

-- The count and rows use the same snapshot. Clamp after deletes or filter changes.
create function public.crm_page_window(p_count bigint, p_page integer, p_page_size integer)
returns table (page integer, page_size integer, row_offset bigint)
language sql immutable set search_path = ''
as $$
  with bounds as (
    select least(500, greatest(1, coalesce(p_page_size, 50))) as size,
      greatest(1, coalesce(p_page, 1)) as requested
  ), page_bounds as (
    select least(requested, greatest(1, (p_count + size - 1) / size))::integer as page, size
    from bounds
  )
  select page, size, (page::bigint - 1) * size from page_bounds;
$$;

create function public.crm_orders_page(
  p_store_id uuid, p_page integer, p_page_size integer, p_search text default '',
  p_status text default 'ALL', p_from date default null, p_to date default null,
  p_order_ids uuid[] default null, p_customer_id uuid default null
) returns jsonb language plpgsql stable security definer set search_path = ''
as $$
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
        and (p_status = 'ALL' or (p_status = 'NO_TTN' and coalesce(btrim(o.nova_poshta_ttn), '') = '') or o.status::text = p_status)
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
        'note', o.note, 'payment_test_mode', o.payment_test_mode, 'status', o.status, 'payment_status', o.payment_status,
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
$$;

create function public.crm_customers_page(
  p_store_id uuid, p_page integer, p_page_size integer, p_search text default '', p_filter text default 'all'
) returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  search text := lower(btrim(coalesce(p_search, '')));
  order_search text := regexp_replace(search, '^#[[:space:]]*', '');
begin
  if not public.is_store_member(p_store_id) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  return (
    with customers as materialized (
      select c.*, regexp_replace(c.phone, '[^0-9]', '', 'g') as digits
      from public.list_crm_customers(p_store_id) c
    ), duplicates as (
      select case when digits ~ '^0[0-9]{9}$' then '38' || digits else digits end as phone
      from customers where p_filter = 'duplicates' and length(digits) >= 9
      group by 1 having count(*) > 1
    ), matches as materialized (
      select c.id, c.created_at from customers c
      where (case p_filter
        when 'all' then true
        when 'confirmed-phone' then c.phone_confirmed
        when 'unconfirmed-phone' then not c.phone_confirmed
        when 'administrators' then c.is_administrator
        when 'discount' then c.has_active_discount
        when 'duplicates' then exists (
          select from duplicates d where d.phone = case when c.digits ~ '^0[0-9]{9}$' then '38' || c.digits else c.digits end
        )
        else false end)
        and (search = '' or strpos(lower(concat_ws(' ', c.name, c.phone, c.email, array_to_string(c.tags, ' '))), search) > 0
          or strpos(lower(c.notes), search) > 0 or (order_search <> '' and exists (
            select from public.orders o where o.store_id = p_store_id and o.crm_customer_id = c.id
              and strpos(lower(o.receipt_code), order_search) > 0
          )))
    ), totals as (select count(*) as matches from matches),
    paging as (
      select totals.matches, w.* from totals cross join lateral public.crm_page_window(totals.matches, p_page, p_page_size) w
    ), page_ids as (
      select id, created_at from matches order by created_at desc, id asc
      limit (select page_size from paging) offset (select row_offset from paging)
    )
    select jsonb_build_object('total', paging.matches, 'page', paging.page, 'rows', coalesce((
      select jsonb_agg((to_jsonb(c) - 'digits') || jsonb_build_object(
        'order_count', coalesce(stats.order_count, 0), 'totals', coalesce(stats.totals, '{}'::jsonb)
      ) order by c.created_at desc, c.id asc)
      from page_ids p join customers c on c.id = p.id
      cross join lateral (
        select sum(grouped.units) as order_count, jsonb_object_agg(grouped.currency, grouped.amount) as totals
        from (
          select o.currency, count(*) as units, sum(o.total_price) as amount
          from public.orders o where o.store_id = p_store_id and o.crm_customer_id = c.id
            and o.status not in ('CANCELLED_BY_USER', 'CANCELLED_BY_STORE')
          group by o.currency
        ) grouped
      ) stats
    ), '[]'::jsonb)) from paging
  );
end;
$$;

create function public.crm_catalog_page(
  p_store_id uuid, p_page integer, p_page_size integer, p_search text default '',
  p_filter text default 'all', p_category_id uuid default null
) returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare search text := lower(btrim(coalesce(p_search, '')));
begin
  if not public.is_store_member(p_store_id) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  return (
    with matches as materialized (
      select p.id, p.created_at from public.products p
      where p.store_id = p_store_id
        and (p_category_id is null or p.category_id = p_category_id or exists (
          select from public.product_categories c where c.product_id = p.id and c.store_id = p_store_id and c.category_id = p_category_id
        ))
        and (search = '' or strpos(lower(p.name), search) > 0 or strpos(lower(p.name_uk), search) > 0
          or strpos(lower(p.name_en), search) > 0 or exists (
            select from public.product_variants v where v.product_id = p.id and strpos(lower(v.sku), search) > 0
          ))
        and (case p_filter
          when 'all' then true
          when 'published' then p.is_active
          when 'hidden' then not p.is_active
          when 'stock' then exists (select from public.product_variants v where v.product_id = p.id)
          when 'low-stock' then exists (select from public.product_variants v where v.product_id = p.id and v.stock_quantity < v.low_stock_threshold)
          when 'out-of-stock' then exists (select from public.product_variants v where v.product_id = p.id and v.stock_quantity = 0)
          else false end)
    ), totals as (select count(*) as matches from matches),
    paging as (
      select totals.matches, w.* from totals cross join lateral public.crm_page_window(totals.matches, p_page, p_page_size) w
    ), page_ids as (
      select id, created_at from matches order by created_at desc, id desc
      limit (select page_size from paging) offset (select row_offset from paging)
    )
    select jsonb_build_object('total', paging.matches, 'page', paging.page, 'rows', coalesce((
      select jsonb_agg(to_jsonb(p) || jsonb_build_object(
        'product_costs', (select to_jsonb(c) from public.product_costs c where c.product_id = p.id),
        'product_categories', coalesce((select jsonb_agg(jsonb_build_object('category_id', c.category_id))
          from public.product_categories c where c.product_id = p.id and c.store_id = p_store_id), '[]'::jsonb),
        'product_images', coalesce((select jsonb_agg(to_jsonb(i) order by i.position, i.id)
          from public.product_images i where i.product_id = p.id), '[]'::jsonb),
        'product_variants', coalesce((select jsonb_agg(to_jsonb(v) || jsonb_build_object(
          'variant_costs', (select to_jsonb(c) from public.variant_costs c where c.variant_id = v.id)
        ) order by v.position, v.id) from public.product_variants v where v.product_id = p.id), '[]'::jsonb)
      ) order by p.created_at desc, p.id desc)
      from page_ids ids join public.products p on p.id = ids.id
    ), '[]'::jsonb)) from paging
  );
end;
$$;

create function public.crm_catalog_category_counts(p_store_id uuid)
returns table (category_id uuid, product_count bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_store_member(p_store_id) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  return query
    select assigned.category_id, count(*)
    from (
      select p.category_id, p.id as product_id from public.products p
      where p.store_id = p_store_id and p.category_id is not null
      union
      select c.category_id, c.product_id from public.product_categories c where c.store_id = p_store_id
    ) assigned
    group by assigned.category_id;
end;
$$;

revoke all on function public.crm_page_window(bigint, integer, integer)
  from public, anon, authenticated, service_role;
revoke all on function public.crm_orders_page(uuid, integer, integer, text, text, date, date, uuid[], uuid),
  public.crm_customers_page(uuid, integer, integer, text, text),
  public.crm_catalog_page(uuid, integer, integer, text, text, uuid),
  public.crm_catalog_category_counts(uuid) from public, anon, authenticated, service_role;
grant execute on function public.crm_orders_page(uuid, integer, integer, text, text, date, date, uuid[], uuid),
  public.crm_customers_page(uuid, integer, integer, text, text),
  public.crm_catalog_page(uuid, integer, integer, text, text, uuid),
  public.crm_catalog_category_counts(uuid) to authenticated;

create index products_store_updated_feed_idx
  on public.products (store_id, updated_at desc, id) where is_active;

create view public.storefront_variant_prices with (security_invoker = true) as
  select v.id, v.product_id, v.name, offer.price, offer.price < regular.price as is_discount
  from public.product_variants v join public.products p on p.id = v.product_id
  cross join lateral (select greatest(v.price, v.compare_at_price) as price) regular
  cross join lateral (select case when coalesce(v.discount_percent, p.discount_percent) is null then v.price
    else round(regular.price * (1 - coalesce(v.discount_percent, p.discount_percent) / 100))::integer end as price) offer
  where p.is_active;

create view public.storefront_category_links with (security_invoker = true) as
  select p.store_id, p.id as product_id, c.category_id
  from public.products p join public.product_categories c on c.product_id = p.id and c.store_id = p.store_id
  where p.is_active
  union all
  select p.store_id, p.id, p.category_id
  from public.products p
  where p.is_active and p.category_id is not null
    and not exists (select from public.product_categories c where c.product_id = p.id and c.store_id = p.store_id);

revoke all on public.storefront_variant_prices, public.storefront_category_links from public, anon, authenticated;
grant select on public.storefront_variant_prices, public.storefront_category_links to anon, authenticated;

create function public.storefront_product_payload(p_product_id uuid)
returns jsonb language sql stable set search_path = ''
as $$
  select to_jsonb(p) || jsonb_build_object(
    'categories', (select to_jsonb(c) from public.categories c where c.id = p.category_id and c.store_id = p.store_id),
    'product_categories', coalesce((
      select jsonb_agg(jsonb_build_object('categories', to_jsonb(c)))
      from public.product_categories link join public.categories c on c.id = link.category_id and c.store_id = link.store_id
      where link.product_id = p.id and link.store_id = p.store_id
    ), '[]'::jsonb),
    'product_images', coalesce((select jsonb_agg(jsonb_build_object('public_url', i.public_url, 'position', i.position) order by i.position, i.id)
      from public.product_images i where i.product_id = p.id), '[]'::jsonb),
    'product_variants', coalesce((select jsonb_agg(to_jsonb(v) order by v.position, v.id)
      from public.product_variants v where v.product_id = p.id), '[]'::jsonb)
  )
  from public.products p where p.id = p_product_id and p.is_active;
$$;

create function public.storefront_catalog_page(
  p_store_id uuid, p_search text default '', p_size text default '', p_sort text default 'recently-updated',
  p_category_id uuid default null, p_collection text default 'all', p_limit integer default 24,
  p_after_price bigint default null, p_after_updated_at timestamptz default null, p_after_id uuid default null
) returns jsonb language sql stable set search_path = ''
as $$
  with settings as (
    select lower(btrim(coalesce(p_search, ''))) as search, btrim(coalesce(p_size, '')) as size,
      greatest(1, least(48, coalesce(p_limit, 24))) as batch_size
  ), matches as materialized (
    select p.id, p.updated_at,
      case p_sort
        when 'price-low' then coalesce(prices.lowest::bigint, 2147483648)
        when 'price-high' then coalesce(-prices.lowest::bigint, 2147483648)
        else 0 end as price_key
    from public.products p cross join settings s
    left join lateral (
      select min(v.price) as lowest from public.storefront_variant_prices v
      where v.product_id = p.id and p_sort in ('price-low', 'price-high')
    ) prices on true
    where p.store_id = p_store_id and p.is_active
      and (p_collection <> 'new' or p.is_new)
      and (p_category_id is null or exists (
        select from public.storefront_category_links c where c.store_id = p_store_id
          and c.product_id = p.id and c.category_id = p_category_id
      ))
      and (s.search = '' or strpos(lower(p.name), s.search) > 0 or strpos(lower(p.name_uk), s.search) > 0 or strpos(lower(p.name_en), s.search) > 0)
      and ((s.size = '' and p_collection <> 'sale') or exists (
        select from public.storefront_variant_prices v where v.product_id = p.id
          and (s.size = '' or btrim(v.name) = s.size)
          and (p_collection <> 'sale' or v.is_discount)
      ))
  ), windowed as materialized (
    select matches.*
    from matches
    where p_after_id is null or price_key > p_after_price or (price_key = p_after_price and (
      updated_at < p_after_updated_at or (updated_at = p_after_updated_at and id > p_after_id)
    ))
    order by price_key, updated_at desc, id
    limit (select batch_size + 1 from settings)
  ), page_ids as materialized (
    select * from windowed order by price_key, updated_at desc, id limit (select batch_size from settings)
  )
  select jsonb_build_object(
    'total', (select count(*) from matches),
    'rows', coalesce((select jsonb_agg(public.storefront_product_payload(id) order by price_key, updated_at desc, id) from page_ids), '[]'::jsonb),
    'next_cursor', case when (select count(*) from windowed) > (select batch_size from settings) then (
      select jsonb_build_object('price', price_key, 'updatedAt', updated_at, 'id', id)
      from page_ids order by price_key desc, updated_at, id desc limit 1
    ) end
  );
$$;

create function public.storefront_catalog_metadata(p_store_id uuid)
returns jsonb language sql stable set search_path = ''
as $$
  with published as materialized (
    select p.id, p.name, p.name_uk, p.name_en, p.is_new, p.created_at,
      exists (select from public.storefront_variant_prices v where v.product_id = p.id and v.is_discount) as on_sale
    from public.products p where p.store_id = p_store_id and p.is_active
  )
  select jsonb_build_object(
    'categories', coalesce((
      select jsonb_agg(to_jsonb(c) order by c.position, c.id) from public.categories c
      where c.store_id = p_store_id and exists (
        select from public.storefront_category_links link where link.store_id = p_store_id and link.category_id = c.id
      )
    ), '[]'::jsonb),
    'sizes', coalesce((select jsonb_agg(distinct btrim(v.name))
      from published p join public.product_variants v on v.product_id = p.id where btrim(v.name) <> ''), '[]'::jsonb),
    'hasNewArrivals', exists (select from published where is_new),
    'hasDiscountedProducts', exists (select from published where on_sale),
    'bannerProducts', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'name_uk', p.name_uk, 'name_en', p.name_en, 'url', img.public_url)
        order by p.is_new desc, p.created_at desc, p.id)
      from published p cross join lateral (
        select i.public_url from public.product_images i where i.product_id = p.id order by i.position, i.id limit 1
      ) img where (p.is_new or p.on_sale) and img.public_url <> ''
    ), '[]'::jsonb)
  );
$$;

create function public.storefront_related_products(p_store_id uuid, p_product_id uuid)
returns jsonb language sql stable set search_path = ''
as $$
  with ranked as (
    select candidate.product_id, p.created_at,
      count(*) filter (where c.parent_id is not null) as subcategories, count(*) as shared
    from public.storefront_category_links original
    join public.storefront_category_links candidate on candidate.category_id = original.category_id and candidate.store_id = original.store_id
    join public.categories c on c.id = candidate.category_id
    join public.products p on p.id = candidate.product_id
    where original.store_id = p_store_id and original.product_id = p_product_id and candidate.product_id <> p_product_id
      and exists (select from public.product_variants v where v.product_id = candidate.product_id)
    group by candidate.product_id, p.created_at
    order by subcategories desc, shared desc, p.created_at desc, candidate.product_id
    limit 4
  )
  select coalesce(jsonb_agg(public.storefront_product_payload(product_id) order by subcategories desc, shared desc, created_at desc, product_id), '[]'::jsonb)
  from ranked;
$$;

revoke all on function public.storefront_product_payload(uuid),
  public.storefront_catalog_page(uuid, text, text, text, uuid, text, integer, bigint, timestamptz, uuid),
  public.storefront_catalog_metadata(uuid), public.storefront_related_products(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.storefront_product_payload(uuid),
  public.storefront_catalog_page(uuid, text, text, text, uuid, text, integer, bigint, timestamptz, uuid),
  public.storefront_catalog_metadata(uuid), public.storefront_related_products(uuid, uuid)
  to anon, authenticated;

create table public.storefront_theme_settings (
  store_id uuid primary key references public.shop_settings(id) on delete cascade,
  show_theme_switch boolean not null default true,
  default_theme text not null default 'system' check (default_theme in ('system', 'light', 'dark'))
);

alter table public.storefront_theme_settings enable row level security;
grant select on public.storefront_theme_settings to anon, authenticated;
grant insert, update, delete on public.storefront_theme_settings to authenticated;
create policy "public read storefront theme" on public.storefront_theme_settings for select to anon, authenticated using (true);
create policy "staff manage storefront theme" on public.storefront_theme_settings for all to authenticated
  using (public.is_store_member(store_id)) with check (public.is_store_member(store_id));

notify pgrst, 'reload schema';

-- Keep the published text and the first acceptance separate from editable Auth metadata.
create table public.legal_agreement_versions (
  version text primary key,
  document jsonb not null,
  published_at timestamptz not null default now()
);
alter table public.legal_agreement_versions enable row level security;
revoke all on public.legal_agreement_versions from public, anon, authenticated;
grant select on public.legal_agreement_versions to anon, authenticated;
create policy "public read agreement versions" on public.legal_agreement_versions
  for select to anon, authenticated using (true);

insert into public.legal_agreement_versions (version, document)
values ('2026-11-20', $agreement${"seller":{"name":"ФОП Яковішина Дарʼя Андріївна","taxId":"3620003508","address":"Україна, м. Кривий Ріг, Дніпровське шосе, буд. 36, кв. 117","email":"tatami.culture@gmail.com"},"agreement":{"uk":{"title":"Угода користувача","subtitle":"Умови користування магазином, купівлі товарів та обробки персональних даних","sections":[{"id":"general","title":"1. Загальні положення та продавець","paragraphs":["Ця Угода визначає умови користування інтернет-магазином tatami.culture, створення облікового запису, замовлення товарів і обробки персональних даних. Продавець та володілець персональних даних — ФОП Яковішина Дарʼя Андріївна, реєстраційний номер облікової картки платника податків 3620003508. Адреса реєстрації: Україна, м. Кривий Ріг, Дніпровське шосе, буд. 36, кв. 117. Звернення приймаються на tatami.culture@gmail.com; додатковий канал зв’язку — Instagram магазину, посилання на який наведене нижче.","Відносини сторін регулюються законодавством України, зокрема нормами про електронну комерцію, захист прав споживачів і персональних даних. Обов’язкові права споживача мають перевагу над положеннями цієї Угоди. Реєстрація сама по собі не створює обов’язку купити товар."]},{"id":"account","title":"2. Реєстрація та безпека облікового запису","paragraphs":["Для реєстрації користувач надає достовірне ім’я та номер телефону, самостійно позначає згоду з цією Угодою та підтверджує контроль над номером одноразовим SMS-кодом. Передавати коди іншим особам або створювати акаунт із чужими даними без належних повноважень заборонено.","Ми фіксуємо редакцію Угоди, з якою погодився користувач, та час її прийняття. Автопідстановка SMS-коду залежить від браузера й дозволів пристрою та не надає магазину доступу до інших повідомлень. Якщо номер втрачено або є підозра на сторонній доступ, зверніться до продавця.","Користувач повинен мати необхідну цивільну дієздатність для своїх дій; у випадках, визначених законом, неповнолітні діють за участю або згодою законного представника."]},{"id":"orders","title":"3. Товари та оформлення замовлення","paragraphs":["Характеристики, розміри, ціна та доступність товару наведені в каталозі. Користувач перевіряє склад замовлення, контактні дані, адресу або відділення доставки та спосіб оплати перед підтвердженням. Фотографії можуть відрізнятися за відтінком через налаштування екрана; це не скасовує вимог щодо відповідності товару опису.","Договір щодо конкретної покупки укладається після підтвердження замовлення продавцем, у тому числі автоматичного підтвердження прийнятого оплаченого замовлення. Підтвердження містить склад і вартість покупки. У разі помилки в ціні або відсутності товару продавець зв’язується з покупцем: зміна складу, суми чи строків потребує погодження. Якщо виконати замовлення неможливо, отримані кошти підлягають поверненню за законом.","Для передзамовлень або товарів під замовлення строк відправлення погоджується окремо до оплати. Позначка про можливість замовлення за відсутності залишку не означає негайну наявність товару."]},{"id":"payment","title":"4. Ціна, оплата та доставка","paragraphs":["До підтвердження покупки відображаються ціна товарів, доступні знижки та сума замовлення. Плата за доставку й комісія післяплати, якщо вони сплачуються окремо перевізнику чи фінансовому сервісу, визначаються обраним тарифом і повідомляються до завершення оформлення. Розрахунки з продавцем здійснюються у гривні; довідкові валютні перерахунки не змінюють погоджену суму.","Доступні способи оплати відображаються під час оформлення. Для онлайн-оплати користувач переходить до платіжного провайдера. Реквізити картки та CVV вводяться на його захищеній стороні й не зберігаються магазином. Результат оплати визначається підтвердженням провайдера, а не самим переходом назад на сайт. Продавець надає передбачений законом розрахунковий документ; сторінка замовлення не замінює його, коли закон вимагає фіскального документа.","Доставка здійснюється обраним під час оформлення способом, зокрема Новою поштою. Строки відправлення та орієнтовний час перевезення повідомляються покупцю. Покупець перевіряє упаковку і товар під час отримання та, за наявності пошкоджень, за можливості фіксує їх із перевізником. Відсутність такої фіксації сама по собі не позбавляє законних прав споживача."]},{"id":"returns","title":"5. Скасування, обмін, повернення та недоліки","paragraphs":["Для скасування, обміну, повернення товару або звернення щодо його недоліків напишіть на tatami.culture@gmail.com із номером замовлення та описом ситуації. Продавець надасть адресу й інструкції для повернення; не надсилайте товар на випадкове відділення.","Обмін товару належної якості можливий у передбачений законом строк, за загальним правилом — протягом 14 днів без урахування дня купівлі, якщо товар не використовувався та збережено його вигляд, властивості, пломби й ярлики та підтвердження покупки. Для дистанційних договорів діє також передбачене законом право на відмову; його строки, початок перебігу й винятки визначає закон.","Законодавчі обмеження для окремих категорій товарів належної якості застосовуються лише в установлених законом випадках. Сам факт належності речі до спортивного одягу не виключає права на повернення. За недоліків товару зберігаються права на ремонт, заміну, зменшення ціни або повернення коштів у випадках, передбачених законом. Знижка не скасовує цих прав.","Повернення коштів, строки й розподіл витрат на пересилання визначаються законом та підставою повернення. Продавець повідомляє порядок до відправлення товару назад і не встановлює довільних утримань, які обмежують обов’язкові права покупця."]},{"id":"use","title":"6. Правила користування та права на матеріали","paragraphs":["Сайт, його оформлення, тексти, фотографії та позначення охороняються правами відповідних правовласників. Користувач отримує невиключний дозвіл користуватися сайтом для перегляду, особистих покупок і керування власними замовленнями. Це не передає прав на торговельні марки або комерційне відтворення матеріалів.","Заборонені несанкціонований доступ, втручання в оплату або облік залишків, шахрайські замовлення, поширення шкідливого коду та порушення прав інших осіб. Законне використання матеріалів, дозволене законодавством, не обмежується цією Угодою."]},{"id":"data","title":"7. Які дані обробляються і для чого","paragraphs":["Магазин обробляє надані користувачем ім’я, телефон, email за наявності, місто та реквізити доставки, склад і історію замовлень, статуси оплат і відправлень, повернення та звернення. Також обробляються ідентифікатори акаунта і сесії, запис прийняття Угоди та технічні дані запитів, необхідні для роботи й безпеки сервісу, зокрема IP-адреса, дані браузера та час запиту.","Цілі — реєстрація і вхід, виконання замовлень, доставка, оплата та повернення коштів, підтримка покупця, облік, запобігання шахрайству і виконання законних обов’язків. Підставою є укладення та виконання договору, вимоги закону, законні інтереси з урахуванням прав людини, а коли це потрібно — окрема згода. Обробка обмежується даними, необхідними для відповідної мети.","Погодження з Угодою не є згодою на рекламні SMS, email-розсилки або передачу даних для чужого маркетингу. Для реклами, коли цього вимагає закон, потрібна окрема добровільна згода; відмова від неї не перешкоджає реєстрації або покупкам. SMS-коди й повідомлення щодо конкретного замовлення мають сервісне призначення."]},{"id":"services","title":"8. Зовнішні сервіси та одержувачі даних","paragraphs":["Для роботи магазину використовуються або можуть підключатися перелічені нижче сервіси. Альтернативні SMS- та платіжні провайдери отримують дані лише тоді, коли відповідний провайдер фактично обраний або використовується для операції. Перелік не означає передачі всіх даних кожному сервісу.","Обсяг передачі визначається функцією сервісу: дані акаунта й замовлення — для зберігання та обслуговування; телефон і код — для SMS; потрібні відомості про отримувача та посилку — для перевезення; сума, опис і ідентифікатори операції — для оплати. Банки та перевізники можуть також самостійно обробляти дані для виконання власних законних обов’язків.","Умови відповідного провайдера застосовуються до його послуг, але не замінюють обов’язків продавця перед покупцем. Позначення чекбокса не є автоматичним укладенням усіх договорів із третіми особами та не дозволяє необмежену передачу даних."]},{"id":"storage","title":"9. Локальні налаштування та SMS-автопідстановка","paragraphs":["Браузер зберігає необхідні для роботи кошик, дані сесії, вибрану мову, тему та технічні позначки оформлення й оплати. Для цього можуть використовуватися localStorage, sessionStorage і технічні cookie залучених сервісів. Після очищення сховища можуть зникнути налаштування, незавершений кошик або вхід у систему.","Автопідстановка коду відбувається засобами операційної системи чи браузера, зокрема WebOTP за підтримки та дозволу користувача. Магазин отримує лише код для поточного входу; ручне введення залишається доступним. Необов’язкові рекламні трекери не включаються на підставі цієї Угоди; якщо їх буде запроваджено, буде надана відповідна інформація і, де потрібно, окремий вибір."]},{"id":"retention","title":"10. Зберігання, захист і міжнародна передача","paragraphs":["Дані зберігаються протягом часу, потрібного для обслуговування акаунта і договору, розгляду претензій та обов’язкового обліку. Після закінчення відповідної мети і встановлених законом строків дані видаляються або знеособлюються. Видалення акаунта не завжди означає негайне видалення документів щодо вже здійсненої покупки, які закон зобов’язує зберігати.","Хмарні постачальники можуть обробляти дані за межами України. Продавець має забезпечити належні правові підстави такої передачі та захист даних відповідно до законодавства України; ця Угода не є дозволом передавати дані до будь-якої країни без необхідних гарантій. Відомості про одержувачів і місце обробки можна запитати у продавця.","Для захисту використовуються розмежування доступу, захищені з’єднання та засоби автентифікації. Користувач також повинен захищати телефон, пристрій і коди входу. Жодне положення не звільняє продавця від відповідальності за порушення обов’язків із захисту даних."]},{"id":"rights","title":"11. Права щодо персональних даних","paragraphs":["Користувач має передбачені законом права знати мету та одержувачів обробки, отримувати доступ до своїх даних, вимагати виправлення недостовірних даних, заперечувати проти незаконної обробки, вимагати видалення у встановлених випадках та відкликати згоду щодо обробки, що ґрунтується саме на згоді. Відкликання не скасовує попередню правомірну обробку і законні обов’язки щодо зберігання.","Запити надсилаються на tatami.culture@gmail.com. Для захисту даних продавець може перевірити особу заявника в обсязі, необхідному для запиту. Користувач має право звернутися до Уповноваженого Верховної Ради України з прав людини або до суду."]},{"id":"liability","title":"12. Відповідальність та вирішення спорів","paragraphs":["Сторони відповідають за свої дії відповідно до закону. Технічні перерви, збої оператора, банку або перевізника можуть впливати на доступність окремих функцій, однак саме залучення зовнішнього сервісу не усуває зобов’язань продавця щодо замовлення, повернення коштів чи законних прав споживача.","Про проблему слід повідомити продавця, щоб узгодити її вирішення. Це не позбавляє права звертатися до компетентних органів або суду без обов’язкового досудового врегулювання, якщо закон його не вимагає. Обставини непереборної сили оцінюються у порядку, визначеному законом; вони не створюють автоматичного права залишити оплату за непоставлений товар."]},{"id":"changes","title":"13. Редакції Угоди","paragraphs":["Чинна редакція та дата оприлюднюються на цій сторінці. Зміни застосовуються до майбутніх відносин і не змінюють заднім числом погоджену ціну, права щодо вже оформленого замовлення або обсяг раніше наданої згоди. Якщо закон вимагає нового погодження, його отримують окремо.","Український текст є основним; англійський переклад надано для зручності. У разі суперечності застосовується українська редакція з урахуванням обов’язкових вимог законодавства."]}]},"en":{"title":"User agreement","subtitle":"Store terms, purchases and personal data processing","sections":[{"id":"general","title":"1. General terms and seller","paragraphs":["This Agreement governs use of tatami.culture, account creation, purchases and personal data processing. The seller and personal data controller is ФОП Яковішина Дарʼя Андріївна, Ukrainian individual taxpayer registration number 3620003508. Registered address: Ukraine, Kryvyi Rih, Dniprovske Shose, building 36, apartment 117. Contact: tatami.culture@gmail.com. The store’s current Instagram account, linked below, is an additional contact channel.","Ukrainian law applies, including electronic commerce, consumer protection and personal data legislation. Mandatory consumer rights prevail over this Agreement. Creating an account does not require a purchase."]},{"id":"account","title":"2. Registration and account security","paragraphs":["To register, provide an accurate name and phone number, actively accept this Agreement and verify control of the number with an SMS code. Do not share codes or use another person’s details without proper authority.","We record the Agreement version accepted and the time of acceptance. SMS autofill depends on the browser and device permissions and does not give the store access to other messages. Contact the seller if you lose your phone number or suspect unauthorised access.","Users must have the legal capacity required for their actions. Where required by law, minors must act with the involvement or consent of a legal representative."]},{"id":"orders","title":"3. Products and orders","paragraphs":["The catalogue shows product descriptions, sizes, prices and availability. Check your items, contact details, delivery destination and payment method before submitting an order. Screen settings may affect colours in photographs; products must still conform to their description.","A purchase contract is formed when the seller confirms the order, including automated confirmation of an accepted paid order. Confirmation states the items and price. If a price is incorrect or stock is unavailable, the seller contacts you; changes to items, price or timing require agreement. Payments for orders that cannot be fulfilled must be refunded in accordance with law.","Dispatch dates for preorders or items ordered from a supplier are agreed before payment. An option to order an out-of-stock item does not mean that it is immediately available."]},{"id":"payment","title":"4. Prices, payment and delivery","paragraphs":["Product prices, available discounts and the order total are shown before confirmation. Any separate delivery or cash-on-delivery charge depends on the selected service and is disclosed before checkout is completed. Payments to the seller are in Ukrainian hryvnia; indicative currency conversions do not change the agreed amount.","Available payment methods appear at checkout. Online payment takes place with the payment provider. Card details and CVV are entered on the provider’s side and are not stored by the store. Payment is confirmed by the provider, not merely by returning to the website. The seller provides the payment document required by law; the order page is not a substitute for a fiscal receipt where one is required.","Orders are delivered by the method selected at checkout, including Nova Poshta. The buyer is informed of dispatch timing and estimated transit time. Inspect the packaging and goods on receipt and, where possible, record damage with the carrier. Failure to obtain such a record does not by itself remove statutory consumer rights."]},{"id":"returns","title":"5. Cancellations, exchanges, returns and defects","paragraphs":["For a cancellation, exchange, return or defect claim, email tatami.culture@gmail.com with the order number and a description of the issue. The seller will provide the return address and instructions. Do not send goods to an unconfirmed branch.","Goods of satisfactory quality may be exchanged within the statutory period, generally 14 days excluding the purchase date, subject to statutory conditions including unused condition, preserved appearance, properties, seals, labels and proof of purchase. Distance contracts also carry statutory withdrawal rights, with their applicable starting dates, time limits and exceptions.","Exceptions for particular categories of satisfactory-quality goods apply only where the law provides them. Sports clothing is not automatically excluded. For defective goods, statutory rights may include repair, replacement, a price reduction or refund as applicable. A discount does not remove these rights.","Refund procedures, deadlines and responsibility for return shipping follow the law and the reason for the return. The seller explains the process before return shipment and does not impose arbitrary deductions that restrict mandatory rights."]},{"id":"use","title":"6. Website use and intellectual property","paragraphs":["The website design, text, photographs and marks belong to their respective rights holders. Users receive non-exclusive permission to browse, make personal purchases and manage their orders. This does not transfer trademark rights or a right to reproduce materials commercially.","Unauthorised access, interference with payments or inventory, fraudulent orders, malicious code and violations of others’ rights are prohibited. Uses permitted by law remain permitted."]},{"id":"data","title":"7. Personal data and purposes","paragraphs":["The store processes the name, phone, optional email, delivery destination, order contents and history, payment and shipment statuses, returns and support enquiries you provide. Processing also includes account and session identifiers, the acceptance record and technical request data needed for operation and security, such as IP address, browser information and request time.","Purposes include account access, order fulfilment, shipping, payments and refunds, support, accounting, fraud prevention and legal compliance. Applicable grounds include entering into and performing a contract, legal duties, legitimate interests balanced against individual rights and, where required, separate consent. Processing is limited to what is necessary for its purpose.","Accepting this Agreement is not consent to advertising SMS, email campaigns or another party’s marketing. Marketing requires separate voluntary consent where required by law; refusing it does not prevent registration or purchases. Login codes and communications about a specific order are service messages."]},{"id":"services","title":"8. External services and recipients","paragraphs":["The services listed below are used or supported by the store. Alternative SMS and payment providers receive data only when actually selected or involved in the relevant transaction. Listing them does not mean that all information is shared with every provider.","Data shared depends on the service: account and order data for storage and operation; a phone number and code for SMS; necessary recipient and parcel details for delivery; amount, description and transaction identifiers for payment. Banks and carriers may also process data independently to meet their own legal duties.","Provider terms apply to their services but do not replace the seller’s duties to the buyer. Checking the registration box does not automatically enter you into every third-party contract or authorise unlimited disclosure."]},{"id":"storage","title":"9. Browser storage and SMS autofill","paragraphs":["The browser stores the cart, session information, language, theme and technical checkout/payment markers needed for the service. This may use localStorage, sessionStorage and technical cookies from involved services. Clearing storage may remove preferences, an unfinished cart or your login.","The operating system or browser provides SMS autofill, including WebOTP where supported and permitted. The store receives only the relevant login code; manual entry remains available. This Agreement does not enable optional advertising trackers. Any future introduction requires appropriate information and, where required, a separate choice."]},{"id":"retention","title":"10. Retention, security and international transfers","paragraphs":["Data is kept for the time necessary to service the account and contract, handle claims and fulfil statutory recordkeeping. It is deleted or anonymised when its purpose and applicable legal retention periods end. Account deletion does not necessarily immediately delete purchase records that must legally be retained.","Cloud providers may process data outside Ukraine. The seller must ensure a lawful basis and appropriate safeguards under Ukrainian law; this Agreement does not authorise unrestricted transfers to any country. Ask the seller for information about recipients and processing locations.","Security measures include restricted access, protected connections and authentication. Users should also protect their phones, devices and login codes. These terms do not exclude the seller’s liability for breaches of data protection duties."]},{"id":"rights","title":"11. Your personal data rights","paragraphs":["Subject to law, you may learn the purposes and recipients of processing, access your data, request corrections, object to unlawful processing, request deletion where applicable and withdraw consent for processing based on consent. Withdrawal does not invalidate previous lawful processing or statutory retention duties.","Send requests to tatami.culture@gmail.com. The seller may verify identity to the extent needed to protect the data. You may complain to the Ukrainian Parliament Commissioner for Human Rights or seek judicial protection."]},{"id":"liability","title":"12. Liability and disputes","paragraphs":["Each party is responsible under applicable law. Interruptions and faults at an operator, bank or carrier may affect particular functions, but using an external provider does not remove the seller’s duties concerning orders, refunds or statutory consumer rights.","Contact the seller to help resolve a problem. You retain access to competent authorities and courts without mandatory prior negotiation unless required by law. Force majeure is assessed under law and does not automatically entitle the seller to retain payment for undelivered goods."]},{"id":"changes","title":"13. Agreement versions","paragraphs":["The current version and date are published on this page. Changes apply prospectively and do not retrospectively change agreed prices, rights relating to existing orders or the scope of earlier consent. Fresh acceptance is obtained separately where legally required.","The Ukrainian text is authoritative; this English translation is provided for convenience. In case of a difference, the Ukrainian version applies, subject to mandatory legal requirements."]}]}},"services":[{"name":"Supabase","url":"https://supabase.com/privacy","purpose":{"uk":"Акаунти, база даних, зберігання файлів і серверні функції.","en":"Accounts, database, file storage and server functions."},"data":{"uk":"Дані профілю, замовлень, доставок, оплат, звернень, запис згоди та технічні журнали.","en":"Profile, order, delivery, payment and support data, acceptance records and technical logs."}},{"name":"Cloudflare","url":"https://www.cloudflare.com/privacypolicy/","purpose":{"uk":"Розміщення та доставка вебсторінок, мережевий захист.","en":"Website hosting, content delivery and network security."},"data":{"uk":"IP-адреса, URL, час і технічні параметри вебзапитів; дані запиту в межах залучених мережевих функцій.","en":"IP address, URL, time and technical request information; request data within the network functions used."}},{"name":"Нова пошта / Nova Poshta","url":"https://novaposhta.ua/more/privacy-policy/","purpose":{"uk":"Пошук міст і відділень, оформлення та відстеження доставки.","en":"City and branch search, shipment creation and tracking."},"data":{"uk":"Пошуковий запит; для відправлення — ім’я й телефон отримувача, місто, відділення або адреса, опис, вартість і параметри посилки, дані післяплати за потреби.","en":"Search queries; for shipments, recipient name and phone, city, branch or address, parcel description, value and dimensions, and cash-on-delivery details where needed."}},{"name":"LiqPay / ПриватБанк","url":"https://www.liqpay.ua/uk/information/user","purpose":{"uk":"Онлайн-оплата та підтвердження її результату, якщо обрано цей спосіб.","en":"Online payments and payment confirmation when this method is selected."},"data":{"uk":"Сума, валюта, опис і номер замовлення, ідентифікатори та статус операції. Платіжні реквізити покупець надає безпосередньо провайдеру.","en":"Amount, currency, order description and reference, transaction identifiers and status. Buyers provide payment credentials directly to the provider."}},{"name":"monobank / АТ «УНІВЕРСАЛ БАНК»","url":"https://monobank.ua/terms","purpose":{"uk":"Інтернет-еквайринг, якщо обрано цей спосіб оплати.","en":"Internet acquiring when this payment method is selected."},"data":{"uk":"Сума, валюта, склад і номер замовлення, ідентифікатор рахунку та статус оплати. Реквізити платіжного інструмента обробляє провайдер.","en":"Amount, currency, order contents and reference, invoice identifier and payment status. The provider processes payment instrument credentials."}},{"name":"Twilio","url":"https://www.twilio.com/en-us/legal/privacy","purpose":{"uk":"Доставка кодів входу, якщо активний цей SMS-провайдер.","en":"Login code delivery when this SMS provider is active."},"data":{"uk":"Номер телефону, SMS-код або текст повідомлення та службові дані доставки через оператора.","en":"Phone number, SMS code or message content and carrier delivery information."}},{"name":"Київстар / Kyivstar","url":"https://kyivstar.ua/about/confidentiality","purpose":{"uk":"Доставка кодів входу, якщо активний цей SMS-провайдер.","en":"Login code delivery when this SMS provider is active."},"data":{"uk":"Номер телефону, текст із кодом та службові дані доставки; у тестовому режимі — лише дозволені провайдером тестові отримувачі.","en":"Phone number, message containing the code and delivery information; test mode is limited to recipients allowed by the provider."}},{"name":"SMSClub / AlphaSMS","url":"https://smsclub.com.ua/","purpose":{"uk":"Доставка кодів входу через SMSClub та його HTTP-шлюз AlphaSMS, якщо активний цей провайдер.","en":"Login code delivery through SMSClub and its AlphaSMS HTTP gateway when this provider is active."},"data":{"uk":"Номер телефону, текст із кодом, ім’я відправника та службові дані доставки через оператора.","en":"Phone number, message containing the code, sender name and carrier delivery information."}},{"name":"Google Sheets","url":"https://policies.google.com/privacy","purpose":{"uk":"Імпорт продавцем замовлень із Google-таблиць.","en":"Seller-initiated order imports from Google spreadsheets."},"data":{"uk":"Вміст наданої продавцем таблиці може містити дані замовлень. Магазин завантажує її для імпорту; реєстрація покупця не створює Google-акаунт і не надсилає автоматично його дані в таблицю.","en":"A seller-provided spreadsheet may contain order data. The store downloads it for import; buyer registration neither creates a Google account nor automatically uploads buyer data to a sheet."}},{"name":"Instagram / Meta","url":"https://privacycenter.instagram.com/policy/","purpose":{"uk":"Сторінка магазину та спілкування за ініціативою користувача.","en":"The store’s social page and user-initiated communications."},"data":{"uk":"Після переходу або звернення Instagram обробляє дані відвідування, профілю й надіслані вами повідомлення за власними правилами. Каталог магазину не передає автоматично історію замовлень в Instagram.","en":"After you follow the link or contact the store, Instagram processes visit and profile data and the messages you send under its own policies. The catalogue does not automatically send order history to Instagram."}},{"name":"Національний банк України / NBU","url":"https://bank.gov.ua/","purpose":{"uk":"Публічні курси валют для перерахунків.","en":"Public exchange rates for currency calculations."},"data":{"uk":"Запити курсів; персональні дані покупця для цього не потрібні.","en":"Exchange rate requests; buyer personal data is not needed for this purpose."}},{"name":"GitHub","url":"https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement","purpose":{"uk":"Зберігання коду та оновлення сайту.","en":"Source code hosting and website updates."},"data":{"uk":"Код і технічні матеріали розгортання; штатна реєстрація не передає до репозиторію профіль покупця, SMS-код чи історію замовлень.","en":"Code and deployment materials; normal registration does not send buyer profiles, SMS codes or order history to the repository."}},{"name":"Infisical","url":"https://infisical.com/privacy","purpose":{"uk":"Захищене керування конфігурацією інтеграцій.","en":"Secure management of integration configuration."},"data":{"uk":"Службова конфігурація та ключі сервісів; не є сховищем профілів покупців, замовлень або одноразових SMS-кодів.","en":"Service configuration and credentials; it is not used to store buyer profiles, orders or one-time SMS codes."}}]}$agreement$::jsonb);

create table public.user_agreement_acceptances (
  user_id uuid not null references auth.users(id) on delete cascade,
  version text not null references public.legal_agreement_versions(version),
  accepted_at timestamptz not null default now(),
  source text not null default 'registration' check (source = 'registration'),
  primary key (user_id, version)
);
alter table public.user_agreement_acceptances enable row level security;
revoke all on public.user_agreement_acceptances from public, anon, authenticated;
grant select on public.user_agreement_acceptances to authenticated;
create policy "users read own agreement acceptance" on public.user_agreement_acceptances
  for select to authenticated using (user_id = (select auth.uid()));

create function public.record_registration_agreement()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  accepted_version text := new.raw_user_meta_data ->> 'terms_version';
begin
  -- Do not invent acceptance for historical accounts or block the currently deployed old form.
  if accepted_version is null then return new; end if;
  if new.raw_user_meta_data -> 'terms_accepted' is distinct from 'true'::jsonb
     or accepted_version <> '2026-11-20' then
    raise exception 'The current user agreement must be accepted' using errcode = '23514';
  end if;
  insert into public.user_agreement_acceptances(user_id, version)
  values (new.id, accepted_version);
  return new;
end;
$$;
revoke all on function public.record_registration_agreement() from public, anon, authenticated;
create trigger record_registration_agreement after insert on auth.users
  for each row execute function public.record_registration_agreement();

notify pgrst, 'reload schema';

-- Миграции после исходного снимка схемы применяются в общей транзакции.

SET LOCAL check_function_bodies = true;
SET LOCAL search_path TO public, extensions;

-- 20261121120100_order_workflow_statuses.sql включена в определение public.order_status.

-- 20261121120200_order_workflow.sql
alter table public.orders add column is_new boolean not null default false;
alter table public.orders drop constraint test_payment_order_status_check;
alter table public.orders add constraint test_payment_order_status_check check (
  not coalesce(payment_test_mode, monobank_test_mode)
  or status in ('PENDING', 'PAID', 'IN_PROGRESS', 'CANCELLED_BY_USER', 'CANCELLED_BY_STORE')
);

-- Historical orders keep their payment state and do not generate new notifications.
alter table public.orders disable trigger orders_capture_events;
update public.orders
set status = case
  when status = 'DELIVERED' and payment_status = 'PAID' then 'COMPLETED'::public.order_status
  when status = 'READY_FOR_PICKUP' and nova_poshta_status_code in ('7', '8') then 'DELIVERED'::public.order_status
  when status = 'READY_FOR_PICKUP' then 'PREPARING_SHIPMENT'::public.order_status
  else 'IN_PROGRESS'::public.order_status
end
where status = 'PAID' or (not coalesce(payment_test_mode, monobank_test_mode)
  and (status = 'READY_FOR_PICKUP'
    or (status = 'DELIVERED' and payment_status = 'PAID')
    or (status = 'PENDING' and payment_method = 'CASH_ON_DELIVERY')));
alter table public.orders enable trigger orders_capture_events;
alter table public.orders add constraint order_status_is_not_payment check (status <> 'PAID');

create function public.apply_order_workflow() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.status = 'PAID' then
      new.status := 'IN_PROGRESS';
      new.is_new := new.payment_method = 'ONLINE' and new.payment_status = 'PAID'
        and not coalesce(new.payment_test_mode, new.monobank_test_mode);
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
      and not coalesce(new.payment_test_mode, new.monobank_test_mode)
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
$$;

create trigger apply_order_workflow before insert or update of status on public.orders
for each row execute function public.apply_order_workflow();

CREATE OR REPLACE FUNCTION "public"."apply_admin_order_update"("p_order_ids" "uuid"[], "p_status" "public"."order_status", "p_confirm_paid" boolean, "p_include_group" boolean, "p_restore_stock" boolean) RETURNS SETOF "public"."orders"
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
  end if;

  return query select o.* from public.orders o where o.id = any(affected_ids);
end;
$$;

CREATE OR REPLACE FUNCTION "public"."restore_stock_and_cancel_order"("p_order_id" "uuid") RETURNS "public"."orders"
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
  if v_order.payment_status in ('PAID', 'REFUNDED') then
    raise exception 'A paid order cannot be cancelled with stock restoration';
  end if;
  if v_order.status not in ('PENDING', 'IN_PROGRESS', 'WAITING_FOR_STOCK', 'PREPARING_SHIPMENT')
      or v_order.nova_poshta_ttn is not null or v_order.nova_poshta_document_ref is not null then
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
  set status = 'CANCELLED_BY_STORE',
      payment_status = case when v_order.payment_method = 'CASH_ON_DELIVERY'
        then v_order.payment_status else 'FAILED'::public.payment_status end
  where id = v_order.id
  returning * into v_order;

  update public.payments
  set status = 'FAILED', updated_at = now()
  where order_id = v_order.id and status = 'PENDING';

  return v_order;
end;
$$;

CREATE OR REPLACE FUNCTION "public"."reserve_order_ttn"("p_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare target public.orders;
begin
  select * into target from public.orders where id=p_order_id;
  if target.id is null then raise exception 'Order not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || target.store_id::text, 0));
  select * into target from public.orders where id=p_order_id for update;
  if not coalesce(target.payment_test_mode, target.monobank_test_mode)
      and target.status not in ('PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED', 'COMPLETED') then
    raise exception 'Move the order to preparing for shipment first';
  end if;
  if target.status::text like 'CANCELLED%' then
    raise exception 'A TTN cannot be created for a cancelled order';
  end if;
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

create or replace function public.crm_orders_page(
  p_store_id uuid, p_page integer, p_page_size integer, p_search text default '',
  p_status text default 'ALL', p_from date default null, p_to date default null,
  p_order_ids uuid[] default null, p_customer_id uuid default null
) returns jsonb language plpgsql stable security definer set search_path = ''
as $$
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
        'note', o.note, 'is_new', o.is_new, 'payment_test_mode', o.payment_test_mode, 'status', o.status, 'payment_status', o.payment_status,
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
$$;

CREATE OR REPLACE FUNCTION "public"."request_item_return"("p_id" "uuid", "p_item" "uuid", "p_quantity" integer, "p_reason" "text", "p_restock" boolean, "p_replacement" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare item public.order_items; target public.orders; used bigint; replacement public.product_variants;
begin
 select * into item from public.order_items where id=p_item;
 select * into target from public.orders where id=item.order_id for update;
 if target.id is null or not coalesce(public.is_store_member(target.store_id),false) then raise exception 'Access denied'; end if;
 if exists(select 1 from public.item_returns where id=p_id and order_id=target.id) then return; end if;
 if target.status not in ('DELIVERED', 'COMPLETED') then raise exception 'Only delivered orders can be returned'; end if;
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

notify pgrst, 'reload schema';

-- 20261121120300_nova_poshta_order_tracking.sql
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

create table public.nova_poshta_tracking_schedule (
  singleton boolean primary key default true check (singleton),
  project_url text check (project_url ~ '^https://[a-z0-9]+[.]supabase[.]co$'),
  token text not null default encode(extensions.gen_random_bytes(32), 'hex')
);
insert into public.nova_poshta_tracking_schedule default values;
alter table public.nova_poshta_tracking_schedule enable row level security;
revoke all on public.nova_poshta_tracking_schedule from public, anon, authenticated, service_role;

create function public.is_nova_poshta_tracking_job(p_token text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select extensions.digest(token, 'sha256') = extensions.digest(p_token, 'sha256')
    from public.nova_poshta_tracking_schedule where singleton
  ), false);
$$;
revoke all on function public.is_nova_poshta_tracking_job(text) from public, anon, authenticated;
grant execute on function public.is_nova_poshta_tracking_job(text) to service_role;

create function public.run_nova_poshta_tracking_job() returns bigint
language sql security definer set search_path = '' as $$
  select net.http_post(
    url := project_url || '/functions/v1/nova-poshta-track-ttn',
    headers := jsonb_build_object('Content-Type', 'application/json', 'X-Tracking-Job', token),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000
  )
  from public.nova_poshta_tracking_schedule where singleton and project_url is not null;
$$;
revoke all on function public.run_nova_poshta_tracking_job() from public, anon, authenticated, service_role;
select cron.schedule('tatami-nova-poshta-tracking', '0 */2 * * *', 'select public.run_nova_poshta_tracking_job()');

create function public.active_nova_poshta_shipments()
returns table(store_id uuid, ttn text, sender_phone text)
language sql stable security definer set search_path = '' as $$
  select o.store_id, o.nova_poshta_ttn, coalesce(s.sender_phone, '')
  from public.orders o
  left join public.delivery_settings s on s.store_id = o.store_id
  where nullif(o.nova_poshta_ttn, '') is not null
    and not coalesce(o.payment_test_mode, o.monobank_test_mode)
    and o.status not in ('COMPLETED', 'CANCELLED_BY_USER', 'CANCELLED_BY_STORE')
  group by o.store_id, o.nova_poshta_ttn, s.sender_phone
  order by min(o.nova_poshta_status_updated_at) nulls first, o.store_id, o.nova_poshta_ttn
  limit 500;
$$;
revoke all on function public.active_nova_poshta_shipments() from public, anon, authenticated;
grant execute on function public.active_nova_poshta_shipments() to service_role;

-- Status 9/10/11 is recipient handover. A return, refusal or redirection is recorded
-- in tracking but never used to infer cancellation, payment or a stock movement.
create function public.apply_nova_poshta_tracking(
  p_store_id uuid, p_ttn text, p_code text, p_status text, p_checked_at timestamptz
) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  shipment public.orders;
  next_status public.order_status;
  tracking_changed boolean;
  changed boolean := false;
begin
  if nullif(p_ttn, '') is null or nullif(p_status, '') is null or p_checked_at is null then
    raise exception 'Invalid shipment status';
  end if;
  for shipment in
    select * from public.orders
    where store_id = p_store_id and nova_poshta_ttn = p_ttn
    order by id for update
  loop
    if p_checked_at <= shipment.nova_poshta_status_updated_at then continue; end if;
    tracking_changed := shipment.nova_poshta_status_code is distinct from p_code
      or shipment.nova_poshta_status is distinct from p_status;
    next_status := shipment.status;
    if not coalesce(shipment.payment_test_mode, shipment.monobank_test_mode)
      and shipment.status not in ('COMPLETED', 'CANCELLED_BY_USER', 'CANCELLED_BY_STORE') then
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
      nova_poshta_status_updated_at = p_checked_at, status = next_status
    where id = shipment.id;
    if tracking_changed then
      insert into public.order_delivery_events (order_id, status_code, status_text)
      values (shipment.id, p_code, p_status);
    end if;
    changed := changed or tracking_changed or next_status <> shipment.status;
  end loop;
  return changed;
end;
$$;
revoke all on function public.apply_nova_poshta_tracking(uuid, text, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_nova_poshta_tracking(uuid, text, text, text, timestamptz) to service_role;
notify pgrst, 'reload schema';

-- 20261121120400_order_cancellation_refunds.sql
create table public.order_cancellation_refunds (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders(id) on delete cascade,
  payment_id uuid references public.payments(id) on delete set null,
  requested_by uuid references auth.users(id) on delete set null,
  method text not null check (method in ('manual', 'automatic')),
  status text not null check (status in ('processing', 'failed', 'completed')),
  amount integer not null check (amount > 0),
  error text,
  updated_at timestamptz not null default now()
);
alter table public.order_cancellation_refunds enable row level security;
revoke all on public.order_cancellation_refunds from public, anon, authenticated, service_role;

create function public.get_order_cancellation_refunds(p_order_ids uuid[]) returns table (
  order_id uuid, receipt_code text, currency text, amount integer, method text, status text, error text, automatic_available boolean
)
language sql stable security definer set search_path = '' as $$
  select o.id, o.receipt_code, o.currency,
    coalesce(r.amount, case when o.payment_status = 'REFUNDED' or returned.amount >= o.total_price
      then returned.amount else o.total_price - returned.amount end::integer),
    r.method, coalesce(r.status, case when o.payment_status = 'REFUNDED' or returned.amount >= o.total_price
      then 'completed' end), r.error,
    o.payment_method = 'ONLINE' and returned.amount = 0 and exists (
      select 1 from public.payments p where p.order_id = o.id and p.status = 'PAID'
        and p.provider in ('MONOBANK', 'LIQPAY')
    )
  from public.orders o
  left join public.order_cancellation_refunds r on r.order_id = o.id
  cross join lateral (select coalesce(sum(rr.amount), 0) as amount from public.order_returns rr where rr.order_id = o.id) returned
  where o.id = any(p_order_ids) and public.is_store_member(o.store_id)
    and o.status in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER')
    and not coalesce(o.payment_test_mode, o.monobank_test_mode)
    and o.total_price > 0
    and (o.payment_status in ('PAID', 'REFUNDED') or r.id is not null)
  order by o.created_at, o.id;
$$;
revoke all on function public.get_order_cancellation_refunds(uuid[]) from public, anon;
grant execute on function public.get_order_cancellation_refunds(uuid[]) to authenticated;

-- Both paths lock the source order. The operation ID is also sent to Monobank
-- so a retry of a status check can find this specific refund.
create function public.finish_order_cancellation_refund(p_id uuid, p_status text, p_error text default null)
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
$$;
revoke all on function public.finish_order_cancellation_refund(uuid, text, text) from public, anon, authenticated;
grant execute on function public.finish_order_cancellation_refund(uuid, text, text) to service_role;

create function public.begin_order_cancellation_refund(
  p_order_id uuid, p_actor uuid, p_method text, p_amount integer
) returns jsonb language plpgsql security definer set search_path = '' as $$
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
  if target.status not in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER')
    or coalesce(target.payment_test_mode, target.monobank_test_mode) then
    raise exception 'Only cancelled live orders can be refunded';
  end if;
  if p_method not in ('manual', 'automatic', 'check') then raise exception 'Invalid refund method'; end if;

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
      where order_id = target.id and status = 'PAID' and provider in ('MONOBANK', 'LIQPAY') for update;
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
    'payment_id', payment.provider_payment_id, 'payment_test_mode', target.payment_test_mode);
end;
$$;
revoke all on function public.begin_order_cancellation_refund(uuid, uuid, text, integer) from public, anon, authenticated;
grant execute on function public.begin_order_cancellation_refund(uuid, uuid, text, integer) to service_role;

create function public.pending_order_cancellation_refund(p_provider text, p_reference text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', r.id, 'amount', r.amount, 'currency', o.currency,
    'provider', p.provider, 'reference', p.provider_order_id, 'payment_id', p.provider_payment_id,
    'payment_test_mode', o.payment_test_mode)
  from public.order_cancellation_refunds r
  join public.payments p on p.id = r.payment_id
  join public.orders o on o.id = r.order_id
  where r.status = 'processing' and p.provider = p_provider and p.provider_order_id = p_reference;
$$;
revoke all on function public.pending_order_cancellation_refund(text, text) from public, anon, authenticated;
grant execute on function public.pending_order_cancellation_refund(text, text) to service_role;

create function public.protect_processing_order_refund() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select from public.order_cancellation_refunds where order_id = old.id and status = 'processing') then
    raise exception 'Wait for the refund result before changing this order';
  end if;
  if old.payment_status = 'REFUNDED' and (new.payment_status <> 'REFUNDED'
    or (old.status::text like 'CANCELLED%' and new.status::text not like 'CANCELLED%')) then
    raise exception 'This order has already been refunded';
  end if;
  return new;
end;
$$;
create trigger protect_processing_order_refund before update of status, payment_status on public.orders
for each row when (old.status is distinct from new.status or old.payment_status is distinct from new.payment_status)
execute function public.protect_processing_order_refund();

create function public.protect_processing_refund_ledger() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform 1 from public.orders where id = new.order_id for update;
  if exists (select from public.order_cancellation_refunds where order_id = new.order_id and status = 'processing') then
    raise exception 'Wait for the refund result before recording another refund';
  end if;
  return new;
end;
$$;
create trigger protect_processing_refund_ledger before insert on public.order_returns
for each row execute function public.protect_processing_refund_ledger();
notify pgrst, 'reload schema';

-- 20261121120500_order_fulfillment_stock.sql
alter table public.orders add column cancel_stock_pending boolean not null default false;

-- Lock and allocate by variant, so a batch or merged order either gets all
-- of its missing stock or remains at its previous stage.
create function public.reserve_order_fulfillment_stock(p_order_ids uuid[]) returns void
language plpgsql set search_path = '' as $$
declare
  demand record;
begin
  if exists (
    select from public.order_items i
    join public.orders o on o.id = i.order_id
    where i.order_id = any(p_order_ids) and not coalesce(o.payment_test_mode, o.monobank_test_mode)
      and not coalesce(i.stock_deducted, not i.is_preorder) and i.variant_id is null
  ) then
    raise exception 'An order item no longer has a stock variant.';
  end if;

  for demand in
    select i.variant_id, sum(i.quantity) as quantity
    from public.order_items i
    join public.orders o on o.id = i.order_id
    where i.order_id = any(p_order_ids) and not coalesce(o.payment_test_mode, o.monobank_test_mode)
      and not coalesce(i.stock_deducted, not i.is_preorder)
    group by i.variant_id order by i.variant_id
  loop
    update public.product_variants as v
    set stock_quantity = (v.stock_quantity - demand.quantity)::integer
    where v.id = demand.variant_id and v.stock_quantity >= demand.quantity;
    if not found then
      raise exception 'There is not enough stock to prepare the order.';
    end if;
  end loop;

  update public.order_items i set stock_deducted = true
  from public.orders o
  where o.id = i.order_id and i.order_id = any(p_order_ids)
    and not coalesce(o.payment_test_mode, o.monobank_test_mode)
    and not coalesce(i.stock_deducted, not i.is_preorder);
end;
$$;
revoke all on function public.reserve_order_fulfillment_stock(uuid[]) from public, anon, authenticated, service_role;

create function public.release_order_fulfillment_stock(p_order_ids uuid[]) returns void
language plpgsql set search_path = '' as $$
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
    where i.order_id = any(p_order_ids) and not coalesce(o.payment_test_mode, o.monobank_test_mode)
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
    and not coalesce(o.payment_test_mode, o.monobank_test_mode)
    and coalesce(i.stock_deducted, not i.is_preorder) and r.status = 'requested' and r.restock;
  update public.order_items i set stock_deducted = false
  from public.orders o
  where o.id = i.order_id and i.order_id = any(p_order_ids)
    and not coalesce(o.payment_test_mode, o.monobank_test_mode)
    and coalesce(i.stock_deducted, not i.is_preorder);
  update public.orders set cancel_stock_pending = false
  where id = any(p_order_ids) and cancel_stock_pending;
end;
$$;
revoke all on function public.release_order_fulfillment_stock(uuid[]) from public, anon, authenticated, service_role;

-- Staff use this after the parcel is physically back. A cancelled order
-- that was already restocked is a harmless no-op on retry.
create function public.confirm_cancelled_order_stock_return(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  store uuid;
  affected_ids uuid[];
begin
  select o.store_id into store from public.orders o where o.id = p_order_id;
  if store is null or not coalesce(public.is_store_member(store), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || store::text, 0));
  select array_agg(o.id order by o.id) into affected_ids from public.orders o
  where o.store_id = store and (o.id = p_order_id or exists (
    select from public.order_merge_members m where m.root_id = p_order_id and m.order_id = o.id
  ));
  perform o.id from public.orders o where o.id = any(affected_ids) order by o.id for update;
  select array_agg(o.id) into affected_ids from public.orders o
  where o.id = any(affected_ids) and o.status in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER') and o.cancel_stock_pending;
  if affected_ids is not null then
    perform public.release_order_fulfillment_stock(affected_ids);
  end if;
end;
$$;
revoke all on function public.confirm_cancelled_order_stock_return(uuid) from public, anon, service_role;
grant execute on function public.confirm_cancelled_order_stock_return(uuid) to authenticated;

CREATE OR REPLACE FUNCTION "public"."apply_admin_order_update"("p_order_ids" "uuid"[], "p_status" "public"."order_status", "p_confirm_paid" boolean, "p_include_group" boolean, "p_restore_stock" boolean) RETURNS SETOF "public"."orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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
  if p_status in ('PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED', 'COMPLETED') then
    select array_agg(o.id) into stock_order_ids from public.orders o
    where o.id = any(affected_ids)
      and o.status in ('PENDING', 'IN_PROGRESS', 'WAITING_FOR_STOCK', 'PREPARING_SHIPMENT')
      and o.nova_poshta_ttn is null and o.nova_poshta_document_ref is null;
    if stock_order_ids is not null then
      perform public.reserve_order_fulfillment_stock(stock_order_ids);
    end if;
  end if;

  if p_status in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER') and not p_restore_stock then
    select array_agg(o.id) into stock_order_ids from public.orders o
    where o.id = any(affected_ids) and o.status in ('PENDING', 'IN_PROGRESS', 'WAITING_FOR_STOCK', 'PREPARING_SHIPMENT')
      and o.nova_poshta_ttn is null and o.nova_poshta_document_ref is null;
    if stock_order_ids is not null then
      perform public.release_order_fulfillment_stock(stock_order_ids);
    end if;
    update public.orders o set cancel_stock_pending = true
    where o.id = any(affected_ids) and not (o.id = any(coalesce(stock_order_ids, array[]::uuid[])))
      and o.status not in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER')
      and not coalesce(o.payment_test_mode, o.monobank_test_mode)
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
$$;

CREATE OR REPLACE FUNCTION "public"."restore_stock_and_cancel_order"("p_order_id" "uuid") RETURNS "public"."orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_order public.orders;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found or not public.is_store_member(v_order.store_id) then
    raise exception 'You do not have access to this order';
  end if;
  if v_order.payment_status in ('PAID', 'REFUNDED') then
    raise exception 'A paid order cannot be cancelled with stock restoration';
  end if;
  if v_order.status not in ('PENDING', 'IN_PROGRESS', 'WAITING_FOR_STOCK', 'PREPARING_SHIPMENT')
      or v_order.nova_poshta_ttn is not null or v_order.nova_poshta_document_ref is not null then
    raise exception 'Only pending unpaid orders can be cancelled with stock restoration';
  end if;

  perform public.release_order_fulfillment_stock(array[v_order.id]);

  update public.orders
  set status = 'CANCELLED_BY_STORE',
      payment_status = case when v_order.payment_method = 'CASH_ON_DELIVERY'
        then v_order.payment_status else 'FAILED'::public.payment_status end
  where id = v_order.id
  returning * into v_order;

  update public.payments
  set status = 'FAILED', updated_at = now()
  where order_id = v_order.id and status = 'PENDING';

  return v_order;
end;
$$;

CREATE OR REPLACE FUNCTION "public"."reserve_order_ttn"("p_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  target public.orders;
  shipment_ids uuid[];
begin
  select * into target from public.orders where id=p_order_id;
  if target.id is null then raise exception 'Order not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || target.store_id::text, 0));
  select * into target from public.orders where id=p_order_id for update;
  if not coalesce(target.payment_test_mode, target.monobank_test_mode)
      and target.status not in ('PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED', 'COMPLETED') then
    raise exception 'Move the order to preparing for shipment first';
  end if;
  if target.status::text like 'CANCELLED%' then
    raise exception 'A TTN cannot be created for a cancelled order';
  end if;
  if exists(select 1 from public.order_merge_members where order_id=p_order_id and root_id<>p_order_id) then
    raise exception 'Create the TTN from the primary order';
  end if;
  if exists(select 1 from public.orders where (id=p_order_id or id in
    (select order_id from public.order_merge_members where root_id=p_order_id))
    and (nova_poshta_ttn is not null or nova_poshta_document_ref is not null)) then
    raise exception 'This order already has a TTN';
  end if;
  insert into public.order_ttn_reservations(order_id) values(p_order_id);
  select array_agg(o.id) into shipment_ids from public.orders o
  where o.id = p_order_id or exists (
    select from public.order_merge_members m where m.root_id=p_order_id and m.order_id=o.id
  );
  perform o.id from public.orders o where o.id = any(shipment_ids) order by o.id for update;
  perform public.reserve_order_fulfillment_stock(shipment_ids);
end; $$;

notify pgrst, 'reload schema';

-- 20261121120600_order_ttn_recovery.sql
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

-- 20261121120700_attach_existing_order_ttn.sql
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

-- 20261121120800_order_status_automation_setting.sql
alter table public.delivery_settings add column auto_update_order_status boolean not null default true;

-- Status 9/10/11 is recipient handover. A return, refusal or redirection is recorded
-- in tracking but never used to infer cancellation, payment or a stock movement.
create or replace function public.apply_nova_poshta_tracking(
  p_store_id uuid, p_ttn text, p_code text, p_status text, p_checked_at timestamptz
) returns boolean
language plpgsql security definer set search_path = '' as $$
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
  select s.auto_update_order_status into auto_update
  from public.delivery_settings s where s.store_id = p_store_id for share;

  for shipment in
    select * from public.orders
    where store_id = p_store_id and nova_poshta_ttn = p_ttn
    order by id for update
  loop
    if p_checked_at <= shipment.nova_poshta_status_updated_at then continue; end if;
    tracking_changed := shipment.nova_poshta_status_code is distinct from p_code
      or shipment.nova_poshta_status is distinct from p_status;
    next_status := shipment.status;
    if coalesce(auto_update, true)
      and not coalesce(shipment.payment_test_mode, shipment.monobank_test_mode)
      and shipment.status not in ('COMPLETED', 'CANCELLED_BY_USER', 'CANCELLED_BY_STORE') then
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
      nova_poshta_status_updated_at = p_checked_at, status = next_status
    where id = shipment.id;
    if tracking_changed then
      insert into public.order_delivery_events (order_id, status_code, status_text)
      values (shipment.id, p_code, p_status);
    end if;
    changed := changed or tracking_changed or next_status <> shipment.status;
  end loop;
  return changed;
end;
$$;
notify pgrst, 'reload schema';

-- 20261121120900_procured_orders_and_waybill_controls.sql
alter table public.orders
  add column manual_tracking_status_code text,
  add column shipment_was_dispatched boolean not null default false;

update public.orders o set shipment_was_dispatched = true
where o.status in ('IN_TRANSIT', 'DELIVERED', 'COMPLETED')
  or o.nova_poshta_status_code in ('4', '5', '6', '7', '8', '9', '10', '11', '101')
  or (o.nova_poshta_ttn is not null and exists (
    select from public.order_delivery_events e where e.order_id = o.id
      and e.status_code in ('4', '5', '6', '7', '8', '9', '10', '11', '101')
  ));

-- Orders reserve available stock at checkout. Unallocated goods are bought for
-- the customer and never enter the available balance during fulfillment.
CREATE OR REPLACE FUNCTION "public"."apply_admin_order_update"("p_order_ids" "uuid"[], "p_status" "public"."order_status", "p_confirm_paid" boolean, "p_include_group" boolean, "p_restore_stock" boolean) RETURNS SETOF "public"."orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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
      and not coalesce(o.payment_test_mode, o.monobank_test_mode)
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
$$;

CREATE OR REPLACE FUNCTION "public"."restore_stock_and_cancel_order"("p_order_id" "uuid") RETURNS "public"."orders"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_order public.orders;
begin
  select * into v_order from public.orders where id = p_order_id for update;
  if not found or not public.is_store_member(v_order.store_id) then
    raise exception 'You do not have access to this order';
  end if;
  if v_order.payment_status in ('PAID', 'REFUNDED') then
    raise exception 'A paid order cannot be cancelled with stock restoration';
  end if;
  if v_order.status not in ('PENDING', 'IN_PROGRESS', 'WAITING_FOR_STOCK', 'PREPARING_SHIPMENT')
      or v_order.shipment_was_dispatched
      or v_order.nova_poshta_ttn is not null or v_order.nova_poshta_document_ref is not null then
    raise exception 'Only pending unpaid orders can be cancelled with stock restoration';
  end if;

  perform public.release_order_fulfillment_stock(array[v_order.id]);

  update public.orders
  set status = 'CANCELLED_BY_STORE',
      payment_status = case when v_order.payment_method = 'CASH_ON_DELIVERY'
        then v_order.payment_status else 'FAILED'::public.payment_status end
  where id = v_order.id
  returning * into v_order;

  update public.payments
  set status = 'FAILED', updated_at = now()
  where order_id = v_order.id and status = 'PENDING';

  return v_order;
end;
$$;

CREATE OR REPLACE FUNCTION "public"."reserve_order_ttn"("p_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  target public.orders;
begin
  select * into target from public.orders where id=p_order_id;
  if target.id is null then raise exception 'Order not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || target.store_id::text, 0));
  select * into target from public.orders where id=p_order_id for update;
  if not coalesce(target.payment_test_mode, target.monobank_test_mode)
      and target.status not in ('PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED', 'COMPLETED') then
    raise exception 'Move the order to preparing for shipment first';
  end if;
  if target.status::text like 'CANCELLED%' then
    raise exception 'A TTN cannot be created for a cancelled order';
  end if;
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

drop function public.reserve_order_fulfillment_stock(uuid[]);

create or replace function public.apply_nova_poshta_tracking(
  p_store_id uuid, p_ttn text, p_code text, p_status text, p_checked_at timestamptz
) returns boolean
language plpgsql security definer set search_path = '' as $$
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
      and not coalesce(shipment.payment_test_mode, shipment.monobank_test_mode)
      and shipment.status not in ('COMPLETED', 'CANCELLED_BY_USER', 'CANCELLED_BY_STORE') then
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
$$;

create function public.capture_order_waybill() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.order_events(order_id, kind, new_value, author_id)
    values(new.id, case when new.nova_poshta_ttn is null then 'ttn_unlinked' else 'ttn_linked' end,
      coalesce(new.nova_poshta_ttn, old.nova_poshta_ttn),
      coalesce(auth.uid(), nullif(current_setting('tatami.ttn_actor', true), '')::uuid));
  return new;
end;
$$;
revoke all on function public.capture_order_waybill() from public, anon, authenticated, service_role;
create trigger orders_capture_waybill after update of nova_poshta_ttn on public.orders
  for each row when (old.nova_poshta_ttn is distinct from new.nova_poshta_ttn)
  execute function public.capture_order_waybill();

create function public.settle_order_ttn_as_staff(
  p_order_id uuid, p_attempt_id uuid, p_outcome text, p_ttn text, p_document_ref text, p_actor uuid
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (
    select from public.orders o join public.store_members m on m.store_id = o.store_id
    where o.id = p_order_id and m.user_id = p_actor
  ) then raise insufficient_privilege using message = 'Store staff access required'; end if;
  perform set_config('tatami.ttn_actor', p_actor::text, true);
  if p_attempt_id is null and p_outcome = 'attached' then
    perform public.attach_verified_order_ttn(p_order_id, p_ttn, p_document_ref);
  else
    perform public.finish_order_ttn_attempt(p_order_id, p_attempt_id, p_outcome, p_ttn, p_document_ref);
  end if;
  perform set_config('tatami.ttn_actor', '', true);
end;
$$;
revoke all on function public.settle_order_ttn_as_staff(uuid, uuid, text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.settle_order_ttn_as_staff(uuid, uuid, text, text, text, uuid) to service_role;

create function public.unlink_order_ttn(p_order_id uuid, p_ttn text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  target public.orders;
begin
  select * into target from public.orders where id = p_order_id;
  if not found or not coalesce(public.is_store_member(target.store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || target.store_id::text, 0));
  select * into target from public.orders where id = p_order_id for update;
  if exists (select from public.order_merge_members where order_id = p_order_id and root_id <> p_order_id) then
    raise exception 'Unlink the TTN from the primary order.';
  end if;
  if p_ttn is null or target.nova_poshta_ttn is distinct from p_ttn then
    raise exception 'The TTN has changed. Refresh the order and try again.';
  end if;
  update public.orders o set nova_poshta_ttn = null, nova_poshta_document_ref = null,
      nova_poshta_ttn_created_at = null, nova_poshta_status = null, nova_poshta_status_code = null,
      nova_poshta_status_updated_at = null, manual_tracking_status_code = null
    where o.store_id = target.store_id and o.nova_poshta_ttn = p_ttn and
      (o.id = p_order_id or exists (
        select from public.order_merge_members m where m.root_id = p_order_id and m.order_id = o.id
      ));
end;
$$;
revoke all on function public.unlink_order_ttn(uuid, text) from public, anon, service_role;
grant execute on function public.unlink_order_ttn(uuid, text) to authenticated;

notify pgrst, 'reload schema';

-- 20261121121000_order_refund_review.sql
create function public.can_review_order_refund(p_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select from public.order_cancellation_refunds
    where id = p_id and status = 'processing' and method = 'automatic'
      and updated_at <= now() - interval '15 minutes');
$$;
revoke all on function public.can_review_order_refund(uuid) from public, anon, authenticated;
grant execute on function public.can_review_order_refund(uuid) to service_role;

create function public.resolve_order_cancellation_refund(
  p_order_id uuid, p_attempt_id uuid, p_actor uuid, p_resolution text
) returns text language plpgsql security definer set search_path = '' as $$
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
  if target.status not in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER')
    or coalesce(target.payment_test_mode, target.monobank_test_mode) then
    raise exception 'Only cancelled live orders can be refunded';
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
$$;
revoke all on function public.resolve_order_cancellation_refund(uuid, uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.resolve_order_cancellation_refund(uuid, uuid, uuid, text) to service_role;

notify pgrst, 'reload schema';

-- 20261121121100_online_fulfillment_stages.sql
-- Starting preparation enables tracking even if the waybill was attached earlier.
create function public.start_order_shipment_tracking() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.manual_tracking_status_code := null;
  return new;
end;
$$;
create trigger start_order_shipment_tracking before update of status on public.orders
  for each row when (old.status in ('IN_PROGRESS', 'WAITING_FOR_STOCK') and new.status = 'PREPARING_SHIPMENT')
  execute function public.start_order_shipment_tracking();

CREATE OR REPLACE FUNCTION "public"."reserve_order_ttn"("p_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  target public.orders;
begin
  select * into target from public.orders where id=p_order_id;
  if target.id is null then raise exception 'Order not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || target.store_id::text, 0));
  select * into target from public.orders where id=p_order_id for update;
  if target.status not in ('PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED', 'COMPLETED') then
    raise exception 'Move the order to preparing for shipment first';
  end if;
  if target.status::text like 'CANCELLED%' then
    raise exception 'A TTN cannot be created for a cancelled order';
  end if;
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

create or replace function public.apply_nova_poshta_tracking(
  p_store_id uuid, p_ttn text, p_code text, p_status text, p_checked_at timestamptz
) returns boolean
language plpgsql security definer set search_path = '' as $$
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
      and not coalesce(shipment.payment_test_mode, shipment.monobank_test_mode)
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
$$;

notify pgrst, 'reload schema';

-- 20261121121200_cancel_online_procurement.sql
-- NULL for stock-backed lines, false for procurement, true once credited.
alter table public.order_items add column procurement_restocked boolean;

update public.order_items i set procurement_restocked = false
from public.orders o
where o.id = i.order_id and o.payment_method = 'ONLINE' and i.stock_deducted = false
  and not coalesce(o.payment_test_mode, o.monobank_test_mode)
  and o.status not in ('CANCELLED_BY_STORE','CANCELLED_BY_USER')
  and not exists (select from public.order_events e where e.order_id = o.id and e.kind = 'status'
    and e.new_value in ('CANCELLED_BY_STORE','CANCELLED_BY_USER'));

create function public.mark_order_procurement() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select from public.orders o where o.id = new.order_id and o.payment_method = 'ONLINE'
    and not coalesce(o.payment_test_mode, o.monobank_test_mode)) then
    new.procurement_restocked := false;
  end if;
  return new;
end;
$$;
create trigger mark_order_procurement before insert on public.order_items
for each row when (new.stock_deducted = false) execute function public.mark_order_procurement();

create function public.restock_cancelled_procurement() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  item record;
  added integer;
  credited integer := 0;
begin
  if old.status not in ('WAITING_FOR_STOCK','PREPARING_SHIPMENT','IN_TRANSIT','DELIVERED','COMPLETED')
    and not exists (select from public.order_events e where e.order_id = new.id and e.kind = 'status'
      and e.new_value in ('WAITING_FOR_STOCK','PREPARING_SHIPMENT','IN_TRANSIT','DELIVERED','COMPLETED')) then
    return new;
  end if;
  for item in select i.* from public.order_items i where i.order_id = new.id
    and i.procurement_restocked = false and i.variant_id is not null order by i.variant_id, i.id for update
  loop
    select greatest(item.quantity - coalesce(sum(r.quantity),0),0) into added
      from public.item_returns r where r.item_id = item.id and r.restock and r.status in ('received','completed');
    if added > 0 then
      update public.product_variants set stock_quantity = stock_quantity + added where id = item.variant_id;
      credited := credited + added;
    end if;
    update public.order_items set procurement_restocked = true where id = item.id;
    update public.item_returns set restock = false where item_id = item.id and restock and status = 'requested';
  end loop;
  if credited > 0 then
    perform set_config('tatami.procurement_credit',
      (coalesce(nullif(current_setting('tatami.procurement_credit', true), ''), '0')::integer + credited)::text, true);
    insert into public.order_events(order_id, kind, new_value, author_id)
      values (new.id, 'procurement_restock', credited::text, auth.uid());
  end if;
  return new;
end;
$$;
create trigger restock_cancelled_procurement after update of status on public.orders
for each row when (new.payment_method = 'ONLINE' and not coalesce(new.payment_test_mode, new.monobank_test_mode)
  and new.status in ('CANCELLED_BY_USER','CANCELLED_BY_STORE')
  and old.status not in ('CANCELLED_BY_USER','CANCELLED_BY_STORE'))
execute function public.restock_cancelled_procurement();

-- Reopening a cancelled order also reopens item returns; keep stock idempotent.
create function public.prevent_duplicate_procurement_return() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select from public.order_items where id = new.item_id and procurement_restocked) then
    new.restock := false;
  end if;
  return new;
end;
$$;
create trigger prevent_duplicate_procurement_return before insert on public.item_returns
for each row when (new.restock) execute function public.prevent_duplicate_procurement_return();

create function public.update_admin_orders_with_stock_notice(
  p_order_ids uuid[], p_status public.order_status, p_confirm_paid boolean, p_restore_stock boolean
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  updated jsonb;
begin
  perform set_config('tatami.procurement_credit', '0', true);
  updated := public.update_admin_orders(p_order_ids,p_status,p_confirm_paid,p_restore_stock);
  return jsonb_build_object('orders', updated, 'stock_added', current_setting('tatami.procurement_credit')::integer);
end;
$$;
revoke all on function public.update_admin_orders_with_stock_notice(uuid[], public.order_status, boolean, boolean) from public, anon;
grant execute on function public.update_admin_orders_with_stock_notice(uuid[], public.order_status, boolean, boolean) to authenticated;
notify pgrst, 'reload schema';

-- 20261121121300_correct_order_operations.sql
CREATE OR REPLACE FUNCTION "public"."merge_orders"("p_order_ids" "uuid"[], "p_target_id" "uuid") RETURNS "uuid"
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
  if exists(select from public.orders where id=any(ids) and status in ('CANCELLED_BY_STORE','CANCELLED_BY_USER')) then
    raise exception 'Cancelled orders cannot be included in a shipment';
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
CREATE OR REPLACE FUNCTION "public"."reserve_order_ttn"("p_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  target public.orders;
begin
  select * into target from public.orders where id=p_order_id;
  if target.id is null then raise exception 'Order not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || target.store_id::text, 0));
  select * into target from public.orders where id=p_order_id for update;
  if target.status not in ('PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED', 'COMPLETED') then
    raise exception 'Move the order to preparing for shipment first';
  end if;
  if target.status::text like 'CANCELLED%' then
    raise exception 'A TTN cannot be created for a cancelled order';
  end if;
  if exists(select 1 from public.order_merge_members where order_id=p_order_id and root_id<>p_order_id) then
    raise exception 'Create the TTN from the primary order';
  end if;
  if exists(select 1 from public.orders where (id=p_order_id or id in
    (select order_id from public.order_merge_members where root_id=p_order_id))
    and (nova_poshta_ttn is not null or nova_poshta_document_ref is not null)) then
    raise exception 'This order already has a TTN';
  end if;
  perform o.id from public.orders o join public.order_merge_members m on o.id=m.order_id
    where m.root_id=p_order_id order by o.id for update of o;
  if exists(select from public.order_merge_members m join public.orders o on o.id=m.order_id
    where m.root_id=p_order_id and o.status in ('CANCELLED_BY_STORE','CANCELLED_BY_USER')) then
    raise exception 'Cancelled orders cannot be included in a shipment';
  end if;
  insert into public.order_ttn_reservations(order_id) values(p_order_id);
end; $$;

CREATE OR REPLACE FUNCTION "public"."merged_order_shipping"("p_order_id" "uuid") RETURNS TABLE("order_ids" "uuid"[], "total_minor" bigint, "cod_minor" bigint, "weight_grams" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if exists(select from public.order_merge_members m join public.orders o on o.id=m.order_id
      where m.root_id=p_order_id and o.status in ('CANCELLED_BY_USER','CANCELLED_BY_STORE')) then
    raise exception 'Cancelled orders cannot be included in a shipment';
  end if;
  return query with group_orders as (
    select o.* from public.orders o
    where o.id=p_order_id or o.id in (select m.order_id from public.order_merge_members m where m.root_id=p_order_id)
  ), weights as (
    select oi.quantity, coalesce(oi.weight_grams,p.weight_grams) weight
    from public.order_items oi join group_orders g on g.id=oi.order_id
    left join public.products p on p.id=oi.product_id
  )
  select array_agg(id),sum(total_price)::bigint,
    coalesce(sum(total_price) filter (where payment_method='CASH_ON_DELIVERY' and payment_status<>'PAID'),0)::bigint,
    (select case when count(*)=count(weight) then sum(weight::bigint*quantity)::bigint end from weights)
  from group_orders;
end;
$$;

-- For a reopened order only fulfilment in the current cycle qualifies a new procurement credit.
alter table public.orders add column reopened_procurement_progressed boolean;
drop trigger restock_cancelled_procurement on public.orders;
create trigger restock_cancelled_procurement after update of status on public.orders
for each row when (new.payment_method='ONLINE' and not coalesce(new.payment_test_mode,new.monobank_test_mode)
  and new.status in ('CANCELLED_BY_USER','CANCELLED_BY_STORE') and old.status not in ('CANCELLED_BY_USER','CANCELLED_BY_STORE')
  and old.reopened_procurement_progressed is not false)
execute function public.restock_cancelled_procurement();

create function public.protect_merged_shipment_during_creation() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if exists(select from public.order_merge_members m join public.order_ttn_reservations r on r.order_id=m.root_id
    where m.order_id=old.id) then raise exception 'TTN creation is in progress for one of these orders'; end if;
  return new;
end; $$;
create trigger protect_merged_shipment_during_creation before update of status,payment_status on public.orders for each row
when(old.status is distinct from new.status or old.payment_status is distinct from new.payment_status)
execute function public.protect_merged_shipment_during_creation();

create function public.correct_reopened_order() returns trigger language plpgsql
security definer set search_path = '' as $$
declare
  item record;
  source text := current_setting('tatami.reopen_source',true);
  received text := current_setting('tatami.cod_received',true);
begin
  if old.status = 'COMPLETED' and old.payment_method = 'CASH_ON_DELIVERY'
    and old.payment_status = 'PAID' and old.total_price > 0 then
    if coalesce(received,'') not in ('yes','no') then raise exception 'Confirm COD collection'; end if;
    if received = 'no' then new.payment_status := 'PENDING'; end if;
  end if;
  if old.status in ('CANCELLED_BY_USER','CANCELLED_BY_STORE') and new.status not in ('CANCELLED_BY_USER','CANCELLED_BY_STORE') then
    new.reopened_procurement_progressed := new.status in ('WAITING_FOR_STOCK','PREPARING_SHIPMENT','IN_TRANSIT','DELIVERED','COMPLETED');
    for item in select * from public.order_items where order_id=new.id
      and not coalesce(stock_deducted,not is_preorder) order by variant_id,id for update
    loop
      if coalesce(source,'') not in ('stock','supplier') then raise exception 'Choose stock for reopened orders'; end if;
      if source = 'stock' then
        update public.product_variants set stock_quantity=stock_quantity-item.quantity
          where id=item.variant_id and stock_quantity>=item.quantity;
        if not found then raise exception 'Not enough stock to reopen the order'; end if;
        update public.order_items set stock_deducted=true, procurement_restocked=null where id=item.id;
      else
        update public.order_items set procurement_restocked=case when new.payment_method='ONLINE' then false end where id=item.id;
      end if;
    end loop;
  elsif old.reopened_procurement_progressed is false and new.status in ('WAITING_FOR_STOCK','PREPARING_SHIPMENT','IN_TRANSIT','DELIVERED','COMPLETED') then
    new.reopened_procurement_progressed := true;
  end if;
  return new;
end; $$;
create trigger correct_reopened_order before update of status on public.orders for each row
when(old.status is distinct from new.status and not coalesce(old.payment_test_mode,old.monobank_test_mode))
execute function public.correct_reopened_order();

create function public.correct_admin_order_status(p_order_ids uuid[],p_status public.order_status,
  p_confirm_paid boolean,p_restore_stock boolean,p_source text,p_received text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb;
begin
  perform set_config('tatami.reopen_source',coalesce(p_source,''),true);
  perform set_config('tatami.cod_received',coalesce(p_received,''),true);
  result := public.update_admin_orders_with_stock_notice(p_order_ids,p_status,p_confirm_paid,p_restore_stock);
  perform set_config('tatami.reopen_source','',true);
  perform set_config('tatami.cod_received','',true);
  return result;
end; $$;
revoke all on function public.correct_admin_order_status(uuid[],public.order_status,boolean,boolean,text,text) from public,anon;
grant execute on function public.correct_admin_order_status(uuid[],public.order_status,boolean,boolean,text,text) to authenticated;

-- The customer keeps this unguessable request ID across network retries.
create table public.cod_checkout_requests(
  request_id uuid primary key, fingerprint text not null, order_id uuid not null references public.orders on delete cascade
);
alter table public.cod_checkout_requests enable row level security;
revoke all on public.cod_checkout_requests from public,anon,authenticated;
create function public.place_cod_order(p_request_id uuid,p_order jsonb) returns public.orders
language plpgsql security definer set search_path='' as $$
declare
  fingerprint text := encode(extensions.digest(jsonb_build_array(auth.uid(),p_order)::text,'sha256'),'hex');
  previous public.cod_checkout_requests;
  result public.orders;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
  select * into previous from public.cod_checkout_requests where request_id=p_request_id;
  if found then
    if previous.fingerprint <> fingerprint then raise exception 'Checkout request changed'; end if;
    select * into strict result from public.orders where id=previous.order_id;
  else
    result := public.create_discounted_store_order((p_order->>'p_store_id')::uuid,p_order->'p_items',
      p_order->>'p_customer_name',p_order->>'p_customer_email',p_order->>'p_customer_phone',p_order->>'p_delivery_city',
      p_order->>'p_delivery_address',p_order->>'p_note',p_order->>'p_delivery_city_ref',p_order->>'p_delivery_address_ref',
      p_order->>'p_delivery_service_type',(p_order->>'p_expected_discount_percent')::numeric,(p_order->>'p_expected_total')::integer);
    insert into public.cod_checkout_requests values(p_request_id,fingerprint,result.id);
  end if;
  return result;
end; $$;
revoke all on function public.place_cod_order(uuid,jsonb) from public;
grant execute on function public.place_cod_order(uuid,jsonb) to anon,authenticated;
create function public.recover_cod_receipt(p_request_id uuid) returns text
language sql stable security definer set search_path='' as $$
  select o.receipt_code from public.cod_checkout_requests r join public.orders o on o.id=r.order_id
  where r.request_id=p_request_id and o.user_id is not distinct from auth.uid();
$$;
revoke all on function public.recover_cod_receipt(uuid) from public;
grant execute on function public.recover_cod_receipt(uuid) to anon,authenticated;

create function public.existing_import_orders(p_store uuid,p_ids uuid[]) returns setof uuid
language sql stable security invoker set search_path='' as $$
  select id from public.orders where store_id=p_store and id=any(p_ids) and public.is_store_member(p_store);
$$;
revoke all on function public.existing_import_orders(uuid,uuid[]) from public,anon;
grant execute on function public.existing_import_orders(uuid,uuid[]) to authenticated;
notify pgrst,'reload schema';

-- 20261121121400_payment_reconciliation.sql
alter table public.online_checkouts add column bank_checked_at timestamptz, add column bank_review_reason text;
create index online_checkout_reconciliation on public.online_checkouts(bank_checked_at nulls first, created_at)
  where status='PENDING' and not test_mode;
create function public.claim_payment_checks() returns table(id uuid, provider text, provider_order_id text, test_mode boolean, expires_at timestamptz)
language sql security definer set search_path='' as $$
  with batch as (select c.id from public.online_checkouts c
    where c.status='PENDING' and not c.test_mode and c.created_at < now()-interval '5 minutes'
      and (c.bank_checked_at is null or c.bank_checked_at < now() -
        case when c.expires_at < now()-interval '1 day' then interval '6 hours' else interval '14 minutes' end)
    order by c.bank_checked_at nulls first,c.created_at desc limit 60 for update skip locked)
  update public.online_checkouts c set bank_checked_at=now() from batch
    where batch.id=c.id returning c.id,c.provider,c.provider_order_id,c.test_mode,c.expires_at;
$$;
revoke all on function public.claim_payment_checks() from public,anon,authenticated;
grant execute on function public.claim_payment_checks() to service_role;
create function public.payment_reviews(p_store uuid) returns table(receipt_code text, provider text, bank_reference text, total_price integer,currency text, reason text)
language sql stable security definer set search_path='' as $$
  select c.receipt_code,c.provider,c.provider_order_id,c.total_price,c.currency,c.bank_review_reason from public.online_checkouts c
  where c.store_id=p_store and public.is_store_member(p_store) and c.status='PENDING'
    and c.bank_review_reason is not null and not c.test_mode order by c.created_at desc;
$$;
revoke all on function public.payment_reviews(uuid) from public,anon;
grant execute on function public.payment_reviews(uuid) to authenticated;

create table public.payment_job_secret(singleton boolean primary key default true check(singleton),
  token text not null default encode(extensions.gen_random_bytes(32),'hex'));
alter table public.payment_job_secret enable row level security;
revoke all on public.payment_job_secret from public,anon,authenticated,service_role;
insert into public.payment_job_secret default values;
create function public.is_payment_check_job(p_token text) returns boolean language sql stable security definer set search_path='' as $$
  select extensions.digest(token,'sha256')=extensions.digest(p_token,'sha256') from public.payment_job_secret;
$$;
revoke all on function public.is_payment_check_job(text) from public,anon,authenticated;
grant execute on function public.is_payment_check_job(text) to service_role;
create function public.run_payment_checks() returns bigint language sql security definer set search_path='' as $$
  select net.http_post(url:=s.project_url||'/functions/v1/reconcile-payments',
    headers:=jsonb_build_object('X-Payment-Job',j.token,'Content-Type','application/json'),
    body:='{}'::jsonb,timeout_milliseconds:=120000)
  from public.nova_poshta_tracking_schedule s cross join public.payment_job_secret j where s.project_url is not null;
$$;
revoke all on function public.run_payment_checks() from public,anon,authenticated,service_role;
select cron.schedule('tatami-payment-checks','*/15 * * * *','select public.run_payment_checks()');
notify pgrst,'reload schema';

-- 20261121121500_allow_test_order_status_changes.sql
alter table public.orders drop constraint test_payment_order_status_check;

notify pgrst, 'reload schema';

-- 20261121121600_nova_poshta_simulator.sql
alter table public.delivery_settings add column nova_poshta_test_mode boolean not null default false;

create table public.nova_poshta_test_waybills (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.shop_settings on delete cascade,
  order_id uuid references public.orders on delete set null,
  number text generated always as ('TEST-' || upper(replace(id::text, '-', ''))) stored unique,
  status_code text not null default '1' check (status_code in ('1', '5', '7', '9', '103')),
  created_at timestamptz not null default now()
);
create index nova_poshta_test_waybills_store on public.nova_poshta_test_waybills(store_id, created_at desc);
alter table public.nova_poshta_test_waybills enable row level security;
revoke all on public.nova_poshta_test_waybills from public, anon, authenticated, service_role;

create function public.guard_live_waybill_reservation() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  target public.orders;
begin
  select * into strict target from public.orders where id = new.order_id;
  if exists (select from public.delivery_settings s where s.store_id = target.store_id and s.nova_poshta_test_mode)
      or coalesce(target.payment_test_mode, target.monobank_test_mode) then
    raise exception 'Live TTN creation requires live delivery mode and a live order.';
  end if;
  return new;
end;
$$;
create trigger guard_live_waybill_reservation before insert on public.order_ttn_reservations
  for each row execute function public.guard_live_waybill_reservation();

create function public.set_nova_poshta_test_mode(p_store_id uuid, p_test_mode boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || p_store_id::text, 0));
  if exists (select from public.order_ttn_reservations r
      join public.orders o on o.id = r.order_id
      where o.store_id = p_store_id and not r.needs_review and r.created_at > now() - interval '8 minutes') then
    raise exception 'Wait for active TTN creation before changing delivery mode.';
  end if;
  insert into public.delivery_settings(store_id, nova_poshta_test_mode) values (p_store_id, p_test_mode)
    on conflict (store_id) do update set nova_poshta_test_mode = excluded.nova_poshta_test_mode;
end;
$$;
revoke all on function public.set_nova_poshta_test_mode(uuid, boolean) from public, anon;
grant execute on function public.set_nova_poshta_test_mode(uuid, boolean) to authenticated;

create function public.list_nova_poshta_test_waybills(p_store_id uuid)
returns table (id uuid, number text, status_code text, receipt_code text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  return query
    select w.id, w.number, w.status_code, o.receipt_code, w.created_at from public.nova_poshta_test_waybills w
    left join public.orders o on o.id = w.order_id and o.nova_poshta_ttn = w.number
    where w.store_id = p_store_id order by w.created_at desc, w.id;
end;
$$;
revoke all on function public.list_nova_poshta_test_waybills(uuid) from public, anon;
grant execute on function public.list_nova_poshta_test_waybills(uuid) to authenticated;

create function public.create_nova_poshta_test_waybill(p_store_id uuid, p_order_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  target public.orders;
  waybill public.nova_poshta_test_waybills;
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || p_store_id::text, 0));
  if not exists (select from public.delivery_settings where store_id = p_store_id and nova_poshta_test_mode) then
    raise exception 'Enable Nova Poshta test mode first.';
  end if;
  if p_order_id is not null then
    select * into target from public.orders where id = p_order_id and store_id = p_store_id for update;
    if not found or not coalesce(target.payment_test_mode, target.monobank_test_mode) then
      raise exception 'Test waybills can only be linked to test orders.';
    end if;
    if exists (select from public.order_merge_members m
      where m.order_id = target.id and m.root_id <> target.id) then
      raise exception 'Create the TTN from the primary order';
    end if;
    if target.nova_poshta_ttn is not null then
      select * into waybill from public.nova_poshta_test_waybills where store_id = p_store_id and number = target.nova_poshta_ttn;
      if found then return jsonb_build_object('ttn', waybill.number, 'documentRef', waybill.id, 'existing', true); end if;
      raise exception 'This order already has a TTN.';
    end if;
    if target.status not in ('PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED', 'COMPLETED') then
      raise exception 'Move the order to preparing for shipment first';
    end if;
    if exists (select from public.order_ttn_reservations where order_id = target.id) then
      raise exception 'Resolve the pending TTN attempt first.';
    end if;
    if exists (select from public.order_merge_members m join public.orders o on o.id = m.order_id
      where m.root_id = target.id and (not coalesce(o.payment_test_mode, o.monobank_test_mode)
        or o.status in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER') or o.nova_poshta_ttn is not null)) then
      raise exception 'Every order in a test shipment must be active, in test mode and without a TTN.';
    end if;
  end if;

  insert into public.nova_poshta_test_waybills(store_id, order_id) values (p_store_id, p_order_id) returning * into waybill;
  if p_order_id is not null then
    update public.orders o set nova_poshta_ttn = waybill.number,
      nova_poshta_document_ref = case when o.id = p_order_id then waybill.id::text end,
      nova_poshta_ttn_created_at = now(), nova_poshta_status_code = '1', nova_poshta_status = 'Створено',
      nova_poshta_status_updated_at = now(), manual_tracking_status_code = null
    where o.store_id = p_store_id and (o.id = p_order_id or exists (
      select from public.order_merge_members m where m.root_id = p_order_id and m.order_id = o.id
    ));
  end if;
  return jsonb_build_object('ttn', waybill.number, 'documentRef', waybill.id, 'existing', false);
end;
$$;
revoke all on function public.create_nova_poshta_test_waybill(uuid, uuid) from public, anon;
grant execute on function public.create_nova_poshta_test_waybill(uuid, uuid) to authenticated;

create function public.apply_nova_poshta_tracking_update(
  p_store_id uuid, p_ttn text, p_code text, p_status text, p_checked_at timestamptz, p_simulated boolean
) returns boolean
language plpgsql security definer set search_path = '' as $$
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
  select s.auto_update_order_status into auto_update
  from public.delivery_settings s where s.store_id = p_store_id for share;

  for shipment in
    select * from public.orders
    where store_id = p_store_id and nova_poshta_ttn = p_ttn
      and (not p_simulated or coalesce(payment_test_mode, monobank_test_mode))
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
      and (p_simulated or not coalesce(shipment.payment_test_mode, shipment.monobank_test_mode))
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
$$;

revoke all on function public.apply_nova_poshta_tracking_update(uuid, text, text, text, timestamptz, boolean)
  from public, anon, authenticated, service_role;

create or replace function public.apply_nova_poshta_tracking(
  p_store_id uuid, p_ttn text, p_code text, p_status text, p_checked_at timestamptz
) returns boolean
language sql security definer set search_path = '' as $$
  select case when p_ttn like 'TEST-%' then false else
    public.apply_nova_poshta_tracking_update(p_store_id, p_ttn, p_code, p_status, p_checked_at, false) end;
$$;

create function public.update_nova_poshta_test_waybill(p_store_id uuid, p_id uuid, p_status_code text)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  waybill public.nova_poshta_test_waybills;
  status_label text := case p_status_code
    when '1' then 'Створено' when '5' then 'У дорозі' when '7' then 'У відділенні'
    when '9' then 'Отримано' when '103' then 'Відмова від отримання' end;
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  if status_label is null then raise exception 'Invalid test waybill status'; end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || p_store_id::text, 0));
  update public.nova_poshta_test_waybills set status_code = p_status_code
    where id = p_id and store_id = p_store_id returning * into waybill;
  if not found then raise exception 'Test waybill not found'; end if;
  perform public.apply_nova_poshta_tracking_update(p_store_id, waybill.number, p_status_code, status_label, clock_timestamp(), true);
end;
$$;
revoke all on function public.update_nova_poshta_test_waybill(uuid, uuid, text) from public, anon;
grant execute on function public.update_nova_poshta_test_waybill(uuid, uuid, text) to authenticated;

create function public.delete_nova_poshta_test_waybill(p_store_id uuid, p_id uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  waybill public.nova_poshta_test_waybills;
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || p_store_id::text, 0));
  delete from public.nova_poshta_test_waybills where id = p_id and store_id = p_store_id returning * into waybill;
  if not found or waybill.order_id is null then return; end if;
  if exists (select from public.orders where id = waybill.order_id and nova_poshta_ttn = waybill.number) then
    perform public.unlink_order_ttn(waybill.order_id, waybill.number);
  end if;
end;
$$;
revoke all on function public.delete_nova_poshta_test_waybill(uuid, uuid) from public, anon;
grant execute on function public.delete_nova_poshta_test_waybill(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';

-- 20261121121700_test_waybill_details_and_refunds.sql
alter table public.nova_poshta_test_waybills add column shipment_details jsonb;

-- Keep standalone fixtures working while saving the same destination as live creation.
create function public.create_nova_poshta_test_waybill(p_store_id uuid, p_order_id uuid, p_shipment jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  result jsonb;
  destination jsonb := p_shipment->'destination';
  expected_cod bigint := (p_shipment->>'codMinor')::bigint;
  actual_cod bigint;
begin
  result := public.create_nova_poshta_test_waybill(p_store_id, p_order_id);
  if (result->>'existing')::boolean then return result; end if;
  select s.cod_minor into actual_cod from public.merged_order_shipping(p_order_id) s;
  if p_order_id is null or expected_cod is distinct from actual_cod then
    raise exception 'COD amount changed. Reopen the shipment.';
  end if;
  update public.nova_poshta_test_waybills set shipment_details = p_shipment
    where store_id = p_store_id and id = (result->>'documentRef')::uuid;
  update public.orders o set
    delivery_city_ref = coalesce(destination->>'delivery_city_ref', o.delivery_city_ref),
    delivery_city = coalesce(destination->>'delivery_city', o.delivery_city),
    delivery_address_ref = coalesce(destination->>'delivery_address_ref', o.delivery_address_ref),
    delivery_address = coalesce(destination->>'delivery_address', o.delivery_address),
    delivery_service_type = coalesce(destination->>'delivery_service_type', o.delivery_service_type)
    where o.store_id = p_store_id and o.nova_poshta_ttn = result->>'ttn';
  return result;
end;
$$;
revoke all on function public.create_nova_poshta_test_waybill(uuid, uuid, jsonb) from public, anon;
grant execute on function public.create_nova_poshta_test_waybill(uuid, uuid, jsonb) to authenticated;

alter table public.order_cancellation_refunds drop constraint order_cancellation_refunds_method_check;
alter table public.order_cancellation_refunds add constraint order_cancellation_refunds_method_check
  check (method in ('manual', 'automatic', 'simulated'));

create function public.get_order_cancellation_refunds(p_order_ids uuid[], p_include_test boolean) returns table (
  order_id uuid, receipt_code text, currency text, amount integer, method text, status text, error text, automatic_available boolean, simulated boolean
)
language sql stable security definer set search_path = '' as $$
  select o.id, o.receipt_code, o.currency,
    coalesce(r.amount, case when o.payment_status = 'REFUNDED' or returned.amount >= o.total_price
      then returned.amount else o.total_price - returned.amount end::integer),
    r.method, coalesce(r.status, case when o.payment_status = 'REFUNDED' or returned.amount >= o.total_price
      then 'completed' end), r.error,
    not coalesce(o.payment_test_mode, o.monobank_test_mode) and o.payment_method = 'ONLINE' and returned.amount = 0 and exists (
      select 1 from public.payments p where p.order_id = o.id and p.status = 'PAID'
        and p.provider in ('MONOBANK', 'LIQPAY')
    ), coalesce(o.payment_test_mode, o.monobank_test_mode)
  from public.orders o
  left join public.order_cancellation_refunds r on r.order_id = o.id
  cross join lateral (select coalesce(sum(rr.amount), 0) as amount from public.order_returns rr where rr.order_id = o.id) returned
  where o.id = any(p_order_ids) and public.is_store_member(o.store_id)
    and o.status in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER')
    and (not coalesce(o.payment_test_mode, o.monobank_test_mode)
      or (p_include_test and o.payment_method = 'ONLINE'))
    and o.total_price > 0
    and (o.payment_status in ('PAID', 'REFUNDED') or r.id is not null)
  order by o.created_at, o.id;
$$;
revoke all on function public.get_order_cancellation_refunds(uuid[], boolean) from public, anon;
grant execute on function public.get_order_cancellation_refunds(uuid[], boolean) to authenticated;

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
  -- Keep the update and ledger entry in a single transaction.
  update public.order_cancellation_refunds set status = p_status, error = p_error, updated_at = now() where id = p_id;
  if p_status = 'completed' then
    insert into public.order_returns (id, order_id, amount, reason, author_id)
      values (p_id, target.id, operation.amount, case when operation.method = 'simulated'
        then 'Тестове повернення за скасоване замовлення'
        else 'Повернення за скасоване замовлення' end, operation.requested_by);
    insert into public.order_events (order_id, kind, new_value, author_id)
      values (target.id, 'return', operation.amount::text, operation.requested_by);
    update public.orders set payment_status = 'REFUNDED' where id = target.id;
    update public.payments set status = 'REFUNDED', updated_at = now()
      where order_id = target.id and status = 'PAID';
  end if;
  return p_status;
end;
$$;
revoke all on function public.finish_order_cancellation_refund(uuid, text, text) from public, anon, authenticated;
grant execute on function public.finish_order_cancellation_refund(uuid, text, text) to service_role;

create or replace function public.begin_order_cancellation_refund(
  p_order_id uuid, p_actor uuid, p_method text, p_amount integer
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  target public.orders;
  payment public.payments;
  operation public.order_cancellation_refunds;
  returned bigint;
  is_test boolean;
begin
  select * into target from public.orders where id = p_order_id for update;
  if not found or not exists (select from public.store_members
      where store_id = target.store_id and user_id = p_actor) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  is_test := coalesce(target.payment_test_mode, target.monobank_test_mode);
  if p_method is null or p_method not in ('manual', 'automatic', 'check', 'simulated') then
    raise exception 'Invalid refund method';
  end if;
  if target.status not in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER') then
    raise exception 'Only cancelled orders can be refunded';
  end if;
  if p_method = 'simulated' then
    if not is_test or target.payment_method <> 'ONLINE' then
      raise exception 'Test refunds require an online test order.';
    end if;
  elsif is_test then
    raise exception 'Only cancelled live orders can be refunded';
  end if;

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
      where order_id = target.id and status = 'PAID' and provider in ('MONOBANK', 'LIQPAY') for update;
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
    if p_method in ('manual', 'simulated') then
      return jsonb_build_object('status', public.finish_order_cancellation_refund(operation.id, 'completed'));
    end if;
  end if;
  return jsonb_build_object('status', operation.status, 'id', operation.id, 'amount', operation.amount,
    'currency', target.currency, 'provider', payment.provider, 'reference', payment.provider_order_id,
    'payment_id', payment.provider_payment_id, 'payment_test_mode', target.payment_test_mode);
end;
$$;
revoke all on function public.begin_order_cancellation_refund(uuid, uuid, text, integer) from public, anon, authenticated;
grant execute on function public.begin_order_cancellation_refund(uuid, uuid, text, integer) to service_role;

notify pgrst, 'reload schema';

-- 20261121121800_monobank_test_refunds.sql
create or replace function public.get_order_cancellation_refunds(p_order_ids uuid[], p_include_test boolean) returns table (
  order_id uuid, receipt_code text, currency text, amount integer, method text, status text, error text, automatic_available boolean, simulated boolean
)
language sql stable security definer set search_path = '' as $$
  select o.id, o.receipt_code, o.currency,
    coalesce(r.amount, case when o.payment_status = 'REFUNDED' or returned.amount >= o.total_price
      then returned.amount else o.total_price - returned.amount end::integer),
    r.method, coalesce(r.status, case when o.payment_status = 'REFUNDED' or returned.amount >= o.total_price
      then 'completed' end), r.error,
    o.payment_method = 'ONLINE' and returned.amount = 0 and exists (
      select 1 from public.payments p where p.order_id = o.id and p.status = 'PAID'
        and (p.provider = 'MONOBANK' or
          (p.provider = 'LIQPAY' and not coalesce(o.payment_test_mode, o.monobank_test_mode)))
    ), coalesce(o.payment_test_mode, o.monobank_test_mode)
  from public.orders o
  left join public.order_cancellation_refunds r on r.order_id = o.id
  cross join lateral (select coalesce(sum(rr.amount), 0) as amount from public.order_returns rr where rr.order_id = o.id) returned
  where o.id = any(p_order_ids) and public.is_store_member(o.store_id)
    and o.status in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER')
    and (not coalesce(o.payment_test_mode, o.monobank_test_mode)
      or (p_include_test and o.payment_method = 'ONLINE'))
    and o.total_price > 0
    and (o.payment_status in ('PAID', 'REFUNDED') or r.id is not null)
  order by o.created_at, o.id;
$$;
revoke all on function public.get_order_cancellation_refunds(uuid[], boolean) from public, anon;
grant execute on function public.get_order_cancellation_refunds(uuid[], boolean) to authenticated;

create or replace function public.begin_order_cancellation_refund(
  p_order_id uuid, p_actor uuid, p_method text, p_amount integer
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  target public.orders;
  payment public.payments;
  operation public.order_cancellation_refunds;
  returned bigint;
  is_test boolean;
begin
  select * into target from public.orders where id = p_order_id for update;
  if not found or not exists (select from public.store_members
      where store_id = target.store_id and user_id = p_actor) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  is_test := coalesce(target.payment_test_mode, target.monobank_test_mode);
  if p_method is null or p_method not in ('manual', 'automatic', 'check', 'simulated') then
    raise exception 'Invalid refund method';
  end if;
  if target.status not in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER') then
    raise exception 'Only cancelled orders can be refunded';
  end if;
  if p_method = 'simulated' then
    if not is_test or target.payment_method <> 'ONLINE' then
      raise exception 'Test refunds require an online test order.';
    end if;
  elsif is_test and (target.payment_method <> 'ONLINE' or p_method = 'manual') then
    raise exception 'Only cancelled live orders can use a manual refund';
  end if;

  select * into operation from public.order_cancellation_refunds where order_id = target.id;
  if p_method = 'check' then
    if operation.status is distinct from 'processing' then
      return jsonb_build_object('status', operation.status);
    end if;
    select * into payment from public.payments where id = operation.payment_id;
    if is_test and payment.provider is distinct from 'MONOBANK' then
      raise exception 'Test refunds via the provider require a Monobank invoice.';
    end if;
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
        and (provider = 'MONOBANK' or (not is_test and provider = 'LIQPAY')) for update;
      if payment.id is null or target.payment_method <> 'ONLINE' or returned <> 0 then
        raise exception 'Automatic refund is unavailable for this order';
      end if;
    end if;
    if p_method = 'simulated' and exists (
      select from public.payments where order_id = target.id and provider = 'MONOBANK'
    ) then raise exception 'Use the Monobank test refund for this order.'; end if;
    insert into public.order_cancellation_refunds (order_id, payment_id, requested_by, amount, method, status)
    values (target.id, payment.id, p_actor, p_amount, p_method, 'processing')
    on conflict (order_id) do update set id = excluded.id, payment_id = excluded.payment_id,
      requested_by = excluded.requested_by, amount = excluded.amount, method = excluded.method,
      status = excluded.status, error = null, updated_at = now()
    returning * into operation;
    if p_method in ('manual', 'simulated') then
      return jsonb_build_object('status', public.finish_order_cancellation_refund(operation.id, 'completed'));
    end if;
  end if;
  return jsonb_build_object('status', operation.status, 'id', operation.id, 'amount', operation.amount,
    'currency', target.currency, 'provider', payment.provider, 'reference', payment.provider_order_id,
    'payment_id', payment.provider_payment_id, 'payment_test_mode', case when is_test then true else target.payment_test_mode end);
end;
$$;
revoke all on function public.begin_order_cancellation_refund(uuid, uuid, text, integer) from public, anon, authenticated;
grant execute on function public.begin_order_cancellation_refund(uuid, uuid, text, integer) to service_role;

create or replace function public.pending_order_cancellation_refund(p_provider text, p_reference text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', r.id, 'amount', r.amount, 'currency', o.currency,
    'provider', p.provider, 'reference', p.provider_order_id, 'payment_id', p.provider_payment_id,
    'payment_test_mode', case when coalesce(o.payment_test_mode, o.monobank_test_mode) then true else o.payment_test_mode end)
  from public.order_cancellation_refunds r
  join public.payments p on p.id = r.payment_id
  join public.orders o on o.id = r.order_id
  where r.status = 'processing' and p.provider = p_provider and p.provider_order_id = p_reference;
$$;
revoke all on function public.pending_order_cancellation_refund(text, text) from public, anon, authenticated;
grant execute on function public.pending_order_cancellation_refund(text, text) to service_role;

create or replace function public.resolve_order_cancellation_refund(
  p_order_id uuid, p_attempt_id uuid, p_actor uuid, p_resolution text
) returns text language plpgsql security definer set search_path = '' as $$
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
  if target.status not in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER')
    or (coalesce(target.payment_test_mode, target.monobank_test_mode) and p_resolution is distinct from 'not_started') then
    raise exception 'Only cancelled live orders can be refunded';
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
$$;
revoke all on function public.resolve_order_cancellation_refund(uuid, uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.resolve_order_cancellation_refund(uuid, uuid, uuid, text) to service_role;

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
  -- Keep the update and ledger entry in a single transaction.
  update public.order_cancellation_refunds set status = p_status, error = p_error, updated_at = now() where id = p_id;
  if p_status = 'completed' then
    insert into public.order_returns (id, order_id, amount, reason, author_id)
      values (p_id, target.id, operation.amount, case when coalesce(target.payment_test_mode, target.monobank_test_mode)
        then 'Тестове повернення за скасоване замовлення'
        else 'Повернення за скасоване замовлення' end, operation.requested_by);
    insert into public.order_events (order_id, kind, new_value, author_id)
      values (target.id, 'return', operation.amount::text, operation.requested_by);
    update public.orders set payment_status = 'REFUNDED' where id = target.id;
    update public.payments set status = 'REFUNDED', updated_at = now()
      where order_id = target.id and status = 'PAID';
  end if;
  return p_status;
end;
$$;
revoke all on function public.finish_order_cancellation_refund(uuid, text, text) from public, anon, authenticated;
grant execute on function public.finish_order_cancellation_refund(uuid, text, text) to service_role;

notify pgrst, 'reload schema';

-- 20261121121900_nova_poshta_stage.sql
alter table public.nova_poshta_test_waybills
  add column stage_state text check (stage_state in ('pending', 'created', 'deleted')),
  add column stage_ref text,
  add column stage_number text;
grant select on public.nova_poshta_test_waybills to service_role;
grant update (stage_state, stage_ref, stage_number) on public.nova_poshta_test_waybills to service_role;

-- Reserve a local waybill before sending the request to prevent duplicate shipments.
create function public.begin_nova_poshta_stage_waybill(p_store_id uuid, p_order_id uuid, p_shipment jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  result jsonb;
begin
  if p_order_id is null then raise exception 'Order is required'; end if;
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || p_store_id::text, 0));
  if exists (select from public.nova_poshta_test_waybills w join public.orders o on o.id = w.order_id
      where w.store_id = p_store_id and w.order_id = p_order_id and w.stage_state = 'pending'
        and o.nova_poshta_ttn is distinct from w.number) then
    raise exception 'Check the Stage shipment in delivery settings before retrying.';
  end if;
  result := public.create_nova_poshta_test_waybill(p_store_id, p_order_id, p_shipment);
  if not (result->>'existing')::boolean then
    update public.nova_poshta_test_waybills set stage_state = 'pending'
      where id = (result->>'documentRef')::uuid and store_id = p_store_id;
  end if;
  return result;
end;
$$;
revoke all on function public.begin_nova_poshta_stage_waybill(uuid, uuid, jsonb) from public, anon;
grant execute on function public.begin_nova_poshta_stage_waybill(uuid, uuid, jsonb) to authenticated;

create function public.list_nova_poshta_test_waybills(p_store_id uuid, p_include_stage boolean)
returns table (id uuid, number text, status_code text, receipt_code text, created_at timestamptz, stage_state text, stage_number text)
language sql stable security definer set search_path = '' as $$
  select row.id, row.number, row.status_code, row.receipt_code, row.created_at, w.stage_state, w.stage_number
  from public.list_nova_poshta_test_waybills(p_store_id) row
  join public.nova_poshta_test_waybills w using (id)
  where p_include_stage or w.stage_state is null
  order by row.created_at desc, row.id;
$$;
revoke all on function public.list_nova_poshta_test_waybills(uuid, boolean) from public, anon;
grant execute on function public.list_nova_poshta_test_waybills(uuid, boolean) to authenticated;

create or replace function public.delete_nova_poshta_test_waybill(p_store_id uuid, p_id uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  waybill public.nova_poshta_test_waybills;
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || p_store_id::text, 0));
  select * into waybill from public.nova_poshta_test_waybills where id = p_id and store_id = p_store_id for update;
  if not found then return; end if;
  if waybill.stage_state in ('pending', 'created') then
    raise exception 'Confirm the Stage shipment was deleted first.';
  end if;
  delete from public.nova_poshta_test_waybills where id = waybill.id;
  if exists (select from public.orders where id = waybill.order_id and nova_poshta_ttn = waybill.number) then
    perform public.unlink_order_ttn(waybill.order_id, waybill.number);
  end if;
end;
$$;

create function public.apply_nova_poshta_stage_tracking(p_store_id uuid, p_id uuid, p_code text, p_label text, p_checked_at timestamptz)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  number text;
begin
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || p_store_id::text, 0));
  update public.nova_poshta_test_waybills w
    set status_code = case when p_code in ('1','5','7','9','103') then p_code else w.status_code end
    where w.id = p_id and w.store_id = p_store_id and w.stage_state = 'created'
    returning w.number into number;
  if not found then return false; end if;
  return public.apply_nova_poshta_tracking_update(p_store_id, number, p_code, p_label, p_checked_at, true);
end;
$$;
revoke all on function public.apply_nova_poshta_stage_tracking(uuid, uuid, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.apply_nova_poshta_stage_tracking(uuid, uuid, text, text, timestamptz) to service_role;

create or replace function public.get_order_delivery_actions(p_order_id uuid) returns jsonb
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
    'stageNumber', (select w.stage_number from public.nova_poshta_test_waybills w
      where w.store_id = target.store_id and w.number = target.nova_poshta_ttn and w.stage_state = 'created'),
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

notify pgrst, 'reload schema';

-- 20261122120000_nova_poshta_stage_tracking.sql
alter table public.nova_poshta_test_waybills add column stage_manual_status_at timestamptz;

create function public.active_nova_poshta_stage_waybills()
returns table (id uuid, store_id uuid, number text, stage_number text)
language sql stable security definer set search_path = '' as $$
  select w.id, w.store_id, w.number, w.stage_number
  from public.nova_poshta_test_waybills w
  join public.orders o on o.store_id = w.store_id and o.nova_poshta_ttn = w.number
  where w.stage_state = 'created' and w.stage_number is not null
    and w.stage_manual_status_at is null
    and coalesce(o.payment_test_mode, o.monobank_test_mode)
    and o.status in ('PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED')
  group by w.id
  order by min(o.nova_poshta_status_updated_at) nulls first, w.id
  limit 100;
$$;
revoke all on function public.active_nova_poshta_stage_waybills() from public, anon, authenticated;
grant execute on function public.active_nova_poshta_stage_waybills() to service_role;

create or replace function public.update_nova_poshta_test_waybill(p_store_id uuid, p_id uuid, p_status_code text)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  waybill public.nova_poshta_test_waybills;
  checked_at timestamptz := clock_timestamp();
  status_label text := case p_status_code
    when '1' then 'Створено' when '5' then 'У дорозі' when '7' then 'У відділенні'
    when '9' then 'Отримано' when '103' then 'Відмова від отримання' end;
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  if status_label is null then raise exception 'Invalid test waybill status'; end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || p_store_id::text, 0));
  update public.nova_poshta_test_waybills set status_code = p_status_code,
    stage_manual_status_at = case when stage_state = 'created' then checked_at end
    where id = p_id and store_id = p_store_id and (stage_state is null or stage_state = 'created') returning * into waybill;
  if not found then raise exception 'Test waybill not found'; end if;
  perform public.apply_nova_poshta_tracking_update(p_store_id, waybill.number, p_status_code, status_label, checked_at, true);
end;
$$;

create function public.apply_nova_poshta_stage_tracking(
  p_store_id uuid, p_id uuid, p_code text, p_label text, p_checked_at timestamptz, p_resume boolean
) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  number text;
begin
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || p_store_id::text, 0));
  update public.nova_poshta_test_waybills w set stage_manual_status_at = null,
    status_code = case
      when p_code = '1' then '1' when p_code in ('4','5','6','101') then '5'
      when p_code in ('7','8') then '7' when p_code in ('9','10','11') then '9'
      when p_code = '103' then '103' else w.status_code end
    where w.id = p_id and w.store_id = p_store_id and w.stage_state = 'created'
      and (w.stage_manual_status_at is null or (p_resume and w.stage_manual_status_at <= p_checked_at))
      and not exists (
        select from public.orders o where o.store_id = w.store_id and o.nova_poshta_ttn = w.number
          and o.nova_poshta_status_updated_at >= p_checked_at
      )
    returning w.number into number;
  if not found then return false; end if;
  return public.apply_nova_poshta_tracking_update(p_store_id, number, p_code, p_label, p_checked_at, true);
end;
$$;
revoke all on function public.apply_nova_poshta_stage_tracking(uuid, uuid, text, text, timestamptz, boolean) from public, anon, authenticated;
grant execute on function public.apply_nova_poshta_stage_tracking(uuid, uuid, text, text, timestamptz, boolean) to service_role;

create or replace function public.apply_nova_poshta_stage_tracking(p_store_id uuid, p_id uuid, p_code text, p_label text, p_checked_at timestamptz)
returns boolean language sql security definer set search_path = '' as $$
  select public.apply_nova_poshta_stage_tracking(p_store_id, p_id, p_code, p_label, p_checked_at, false);
$$;

notify pgrst, 'reload schema';

-- 20261122120100_manual_test_orders.sql
create function public.create_crm_order(
  p_store_id uuid, p_request_id uuid, p_items jsonb, p_customer jsonb,
  p_delivery jsonb, p_note text, p_expected_total integer, p_test boolean
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
  test_order boolean := coalesce(p_test, false);
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
  if found then
    if coalesce(created_order.payment_test_mode, created_order.monobank_test_mode) is distinct from test_order then
      raise sqlstate 'PT409' using message = 'This order was already saved in a different mode.';
    end if;
    return created_order;
  end if;

  if test_order then
    perform 1 from public.delivery_settings where store_id = p_store_id and nova_poshta_test_mode for share;
    if not found then raise exception 'Enable Nova Poshta test mode first.'; end if;
  end if;

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

  select * into quote from public.quote_catalog_cart(p_store_id, p_items, null, not test_order);
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
    'CASH_ON_DELIVERY', test_order,
    case when quote.total = 0 then 'PAID'::public.order_status else 'PENDING'::public.order_status end,
    case when quote.total = 0 then 'PAID'::public.payment_status else 'PENDING'::public.payment_status end
  from public.shop_settings s where s.id = p_store_id
  returning * into created_order;

  insert into public.order_items (
    order_id, product_id, variant_id, product_name, variant_name, quantity,
    unit_price, compare_at_price, line_total, is_preorder, stock_deducted
  )
  select created_order.id, line.product_id, line.variant_id, line.product_name, line.variant_name, line.quantity,
    line.unit_price, line.compare_at_price, line.line_total, line.is_preorder, not test_order and line.stock_deducted
  from jsonb_populate_recordset(null::public.order_items, quote.items) as line;

  if not test_order then
    update public.product_variants v set stock_quantity = v.stock_quantity - line.quantity
    from jsonb_populate_recordset(null::public.order_items, quote.items) as line
    where v.id = line.variant_id and line.stock_deducted;
  end if;
  return created_order;
end;
$$;

revoke all on function public.create_crm_order(uuid, uuid, jsonb, jsonb, jsonb, text, integer, boolean) from public, anon, authenticated, service_role;
grant execute on function public.create_crm_order(uuid, uuid, jsonb, jsonb, jsonb, text, integer, boolean) to authenticated;

create or replace function public.create_crm_order(
  p_store_id uuid, p_request_id uuid, p_items jsonb, p_customer jsonb,
  p_delivery jsonb, p_note text, p_expected_total integer
) returns public.orders
language sql security definer set search_path = '' as $$
  select public.create_crm_order(p_store_id, p_request_id, p_items, p_customer, p_delivery, p_note, p_expected_total, false);
$$;

notify pgrst, 'reload schema';

-- 20261122120200_remove_delivery_and_refund_testing.sql
-- Protect the live carrier path for test payments even after delivery testing is removed.
create or replace function public.guard_live_waybill_reservation() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  is_test boolean;
begin
  select coalesce(payment_test_mode, monobank_test_mode) into strict is_test
  from public.orders where id = new.order_id;
  if is_test then raise exception 'A live TTN is unavailable for a test order.'; end if;
  return new;
end;
$$;

create or replace function public.get_order_delivery_actions(p_order_id uuid) returns jsonb
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

create or replace function public.apply_nova_poshta_tracking(
  p_store_id uuid, p_ttn text, p_code text, p_status text, p_checked_at timestamptz
) returns boolean
language plpgsql security definer set search_path = '' as $$
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
      and not coalesce(shipment.payment_test_mode, shipment.monobank_test_mode)
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
$$;

create or replace function public.create_crm_order(
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
  from public.shop_settings s where s.id = p_store_id
  returning * into created_order;

  insert into public.order_items (
    order_id, product_id, variant_id, product_name, variant_name, quantity,
    unit_price, compare_at_price, line_total, is_preorder, stock_deducted
  )
  select created_order.id, line.product_id, line.variant_id, line.product_name, line.variant_name, line.quantity,
    line.unit_price, line.compare_at_price, line.line_total, line.is_preorder, line.stock_deducted
  from jsonb_populate_recordset(null::public.order_items, quote.items) as line;

  update public.product_variants v set stock_quantity = v.stock_quantity - line.quantity
  from jsonb_populate_recordset(null::public.order_items, quote.items) as line
  where v.id = line.variant_id and line.stock_deducted;

  return created_order;
end;
$$;

create or replace function public.begin_order_cancellation_refund(
  p_order_id uuid, p_actor uuid, p_method text, p_amount integer
) returns jsonb language plpgsql security definer set search_path = '' as $$
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
  if target.status not in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER')
    or coalesce(target.payment_test_mode, target.monobank_test_mode) then
    raise exception 'Only cancelled live orders can be refunded';
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
      where order_id = target.id and status = 'PAID' and provider in ('MONOBANK', 'LIQPAY') for update;
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
    'payment_id', payment.provider_payment_id, 'payment_test_mode', target.payment_test_mode);
end;
$$;

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
  if coalesce(target.payment_test_mode, target.monobank_test_mode) then
    raise exception 'Only cancelled live orders can be refunded';
  end if;
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
$$;

create or replace function public.pending_order_cancellation_refund(p_provider text, p_reference text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', r.id, 'amount', r.amount, 'currency', o.currency,
    'provider', p.provider, 'reference', p.provider_order_id, 'payment_id', p.provider_payment_id,
    'payment_test_mode', o.payment_test_mode)
  from public.order_cancellation_refunds r
  join public.payments p on p.id = r.payment_id
  join public.orders o on o.id = r.order_id
  where r.status = 'processing' and p.provider = p_provider and p.provider_order_id = p_reference
    and not coalesce(o.payment_test_mode, o.monobank_test_mode);
$$;

create or replace function public.resolve_order_cancellation_refund(
  p_order_id uuid, p_attempt_id uuid, p_actor uuid, p_resolution text
) returns text language plpgsql security definer set search_path = '' as $$
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
  if target.status not in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER')
    or coalesce(target.payment_test_mode, target.monobank_test_mode) then
    raise exception 'Only cancelled live orders can be refunded';
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
$$;

-- Retain recorded financial outcomes and archived test shipment data.
drop function public.get_order_cancellation_refunds(uuid[], boolean);
drop function public.create_crm_order(uuid, uuid, jsonb, jsonb, jsonb, text, integer, boolean);

drop function public.active_nova_poshta_stage_waybills();
drop function public.apply_nova_poshta_stage_tracking(uuid, uuid, text, text, timestamptz);
drop function public.apply_nova_poshta_stage_tracking(uuid, uuid, text, text, timestamptz, boolean);
drop function public.update_nova_poshta_test_waybill(uuid, uuid, text);
drop function public.apply_nova_poshta_tracking_update(uuid, text, text, text, timestamptz, boolean);
drop function public.delete_nova_poshta_test_waybill(uuid, uuid);
drop function public.list_nova_poshta_test_waybills(uuid, boolean);
drop function public.list_nova_poshta_test_waybills(uuid);
drop function public.begin_nova_poshta_stage_waybill(uuid, uuid, jsonb);
drop function public.create_nova_poshta_test_waybill(uuid, uuid, jsonb);
drop function public.create_nova_poshta_test_waybill(uuid, uuid);
drop function public.set_nova_poshta_test_mode(uuid, boolean);
alter table public.delivery_settings drop column nova_poshta_test_mode;
revoke all on public.nova_poshta_test_waybills from public, anon, authenticated, service_role;
revoke update (stage_state, stage_ref, stage_number) on public.nova_poshta_test_waybills from service_role;

notify pgrst, 'reload schema';

-- 20261122120300_unify_order_workflow.sql
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

-- 20261122120400_match_crm_customers_by_phone.sql
create function public.crm_normalize_phone(p_phone text)
returns text
language sql immutable strict
set search_path = ''
as $$
  select case
    when compact ~ '^0[0-9]{9}$' then '38' || compact
    when compact ~ '^\+?[1-9][0-9]{7,14}$' then ltrim(compact, '+')
  end
  from (select regexp_replace(p_phone, '[[:space:]()-]', '', 'g') as compact) phone;
$$;

create index crm_customers_normalized_phone_idx
  on public.crm_customers (store_id, public.crm_normalize_phone(phone));

create function public.crm_customer_for_order(p_order public.orders)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_phone text := public.crm_normalize_phone(p_order.customer_phone);
  v_phone_key text := 'phone:' || v_phone;
  v_local_phone_key text;
  v_key text;
  v_customer uuid;
begin
  if p_order.user_id is not null then
    v_key := 'user:' || p_order.user_id::text;
  elsif v_phone is not null then
    -- Use the same per-store lock as identity creation and customer merges.
    perform pg_advisory_xact_lock(hashtextextended(p_order.store_id::text, 0));
    if v_phone ~ '^380[0-9]{9}$' then
      v_local_phone_key := 'phone:' || substr(v_phone, 3);
    end if;

    with matching as (
      select c.id, c.created_at, exists (
        select from public.crm_customer_keys k
        where k.store_id = p_order.store_id and k.customer_id = c.id and k.key like 'user:%'
      ) as registered, k.key
      from public.crm_customers c
      left join public.crm_customer_keys k on k.store_id = c.store_id and k.customer_id = c.id
        and k.key in (v_phone_key, v_local_phone_key)
      where c.store_id = p_order.store_id
        and (public.crm_normalize_phone(c.phone) = v_phone or k.key is not null)
    ), candidates as (
      select id, created_at, registered, coalesce(bool_or(key = v_phone_key), false) as canonical_key
      from matching
      group by id, created_at, registered
    )
    select id into v_customer
    from candidates
    -- A shared number alone cannot select between two registered profiles.
    where not registered or canonical_key
      or (select count(*) from candidates where registered) = 1
    order by registered desc, canonical_key desc, created_at, id
    limit 1;

    if v_customer is not null then
      return v_customer;
    end if;
    v_key := v_phone_key;
  elsif trim(p_order.customer_email) <> '' then
    v_key := 'email:' || lower(trim(p_order.customer_email));
  else
    v_key := 'order:' || p_order.id::text;
  end if;

  return public.crm_identity(
    p_order.store_id, v_key, p_order.customer_name, p_order.customer_phone, p_order.customer_email
  );
end;
$$;

revoke all on function public.crm_customer_for_order(public.orders) from public, anon, authenticated, service_role;

create or replace function public.attach_crm_customer()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  new.crm_customer_id := public.crm_customer_for_order(new);
  return new;
end;
$$;

-- Repair missing links on legacy orders. Preserve links already assigned by staff.
do $$
declare
  v_order public.orders;
begin
  for v_order in
    select o.* from public.orders o
    where o.crm_customer_id is null and not exists (
      select from public.order_merge_members m where m.order_id = o.id and m.root_id <> o.id
    )
    order by o.store_id, o.created_at, o.id
  loop
    update public.orders
    set crm_customer_id = public.crm_customer_for_order(v_order)
    where id = v_order.id and crm_customer_id is null;
  end loop;
end;
$$;

update public.orders o
set crm_customer_id = root.crm_customer_id
from public.order_merge_members m
join public.orders root on root.id = m.root_id
where o.id = m.order_id and o.store_id = root.store_id
  and o.crm_customer_id is null and root.crm_customer_id is not null;

-- 20261122120500_crm_verified_phone_identity.sql
-- Phone verification belongs to the number. Account permissions still use the user key.
create function public.crm_verified_phone_customers(p_store_id uuid, p_phone text)
returns table(customer_id uuid)
language sql stable strict
set search_path = ''
as $$
  select distinct k.customer_id
  from auth.users a
  join public.crm_customer_keys k on k.store_id = p_store_id and k.key = 'user:' || a.id::text
  where a.phone in (p_phone, '+' || p_phone) and a.phone_confirmed_at is not null
    and a.deleted_at is null and not a.is_anonymous;
$$;

revoke all on function public.crm_verified_phone_customers(uuid, text) from public, anon, authenticated, service_role;

create or replace function public.crm_identity(p_store uuid, p_key text, p_name text, p_phone text, p_email text)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_customer uuid;
  v_verified_phone text;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_store::text, 0));

  select customer_id into v_customer
  from public.crm_customer_keys
  where store_id = p_store and key = p_key;
  if v_customer is not null then
    return v_customer;
  end if;

  if p_key like 'user:%' then
    select public.crm_normalize_phone(a.phone) into v_verified_phone
    from auth.users a
    where a.id = substr(p_key, 6)::uuid and a.phone_confirmed_at is not null
      and a.deleted_at is null and not a.is_anonymous;

    if v_verified_phone is not null then
      p_phone := '+' || v_verified_phone;
      -- A customer who registers after ordering as a guest keeps the same CRM card.
      select c.id into v_customer
      from public.crm_customers c
      where c.store_id = p_store and public.crm_normalize_phone(c.phone) = v_verified_phone
        and not exists (
          select from public.crm_customer_keys k
          where k.store_id = p_store and k.customer_id = c.id and k.key like 'user:%'
        )
      order by c.created_at, c.id
      limit 1;
    end if;
  end if;

  if v_customer is null then
    insert into public.crm_customers(store_id, name, phone, email)
    values (p_store, p_name, p_phone, p_email)
    returning id into v_customer;
  end if;

  insert into public.crm_customer_keys(store_id, key, customer_id) values (p_store, p_key, v_customer);
  return v_customer;
end;
$$;

revoke all on function public.crm_identity(uuid, text, text, text, text) from public, anon, authenticated;

create or replace function public.crm_customer_for_order(p_order public.orders)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_phone text := public.crm_normalize_phone(p_order.customer_phone);
  v_phone_key text := 'phone:' || v_phone;
  v_local_phone_key text;
  v_key text;
  v_customer uuid;
begin
  if p_order.user_id is not null then
    v_key := 'user:' || p_order.user_id::text;
  elsif v_phone is not null then
    -- Use the same per-store lock as identity creation and customer merges.
    perform pg_advisory_xact_lock(hashtextextended(p_order.store_id::text, 0));
    select (array_agg(customer_id))[1] into v_customer
    from public.crm_verified_phone_customers(p_order.store_id, v_phone)
    having count(*) = 1;
    if v_customer is not null then
      return v_customer;
    end if;

    if v_phone ~ '^380[0-9]{9}$' then
      v_local_phone_key := 'phone:' || substr(v_phone, 3);
    end if;

    with matching as (
      select c.id, c.created_at, exists (
        select from public.crm_customer_keys k
        where k.store_id = p_order.store_id and k.customer_id = c.id and k.key like 'user:%'
      ) as registered, k.key
      from public.crm_customers c
      left join public.crm_customer_keys k on k.store_id = c.store_id and k.customer_id = c.id
        and k.key in (v_phone_key, v_local_phone_key)
      where c.store_id = p_order.store_id
        and (public.crm_normalize_phone(c.phone) = v_phone or k.key is not null)
    ), candidates as (
      select id, created_at, registered, coalesce(bool_or(key = v_phone_key), false) as canonical_key
      from matching
      group by id, created_at, registered
    )
    select id into v_customer
    from candidates
    -- A shared number alone cannot select between two registered profiles.
    where not registered or canonical_key
      or (select count(*) from candidates where registered) = 1
    order by registered desc, canonical_key desc, created_at, id
    limit 1;

    if v_customer is not null then
      return v_customer;
    end if;
    v_key := v_phone_key;
  elsif trim(p_order.customer_email) <> '' then
    v_key := 'email:' || lower(trim(p_order.customer_email));
  else
    v_key := 'order:' || p_order.id::text;
  end if;

  return public.crm_identity(
    p_order.store_id, v_key, p_order.customer_name, p_order.customer_phone, p_order.customer_email
  );
end;
$$;

create or replace function public.crm_customer_phone_confirmed(p_store_id uuid, p_customer_id uuid)
returns boolean
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;

  return exists (
    select from public.crm_customers c
    cross join lateral public.crm_verified_phone_customers(p_store_id, public.crm_normalize_phone(c.phone))
    where c.id = p_customer_id and c.store_id = p_store_id
  );
end;
$$;

create or replace function public.list_crm_customers(p_store_id uuid)
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
    left join public.store_members m on m.store_id = k.store_id and m.user_id = a.id
    left join public.customer_discounts d on d.store_id = k.store_id and d.user_id = a.id and d.enabled
    where k.store_id = p_store_id and a.deleted_at is null and not a.is_anonymous
    group by k.customer_id
  )
  select c.id, c.name, c.phone, c.email, c.notes, c.tags, c.created_at,
    exists (select from public.crm_verified_phone_customers(p_store_id, public.crm_normalize_phone(c.phone))),
    coalesce(f.is_administrator, false), coalesce(f.has_active_discount, false)
  from public.crm_customers c
  left join account_flags f on f.customer_id = c.id
  where c.store_id = p_store_id;
end;
$$;

-- Consolidate old automatically generated phone-only duplicates with no independent
-- customer data. Keep the recipient name and account ownership on each order.
do $$
declare
  v_store uuid;
  v_duplicate record;
begin
  for v_store in select id from public.shop_settings order by id loop
    perform pg_advisory_xact_lock(hashtextextended(v_store::text, 0));
    for v_duplicate in
      select c.id, c.created_at, verified.id as target_id
      from public.crm_customers c
      cross join lateral (select public.crm_normalize_phone(c.phone) as value) phone
      cross join lateral (
        select (array_agg(customer_id))[1] as id
        from public.crm_verified_phone_customers(v_store, phone.value)
        having count(*) = 1
      ) verified
      where c.store_id = v_store and c.id <> verified.id
        and c.notes = '' and c.email = '' and cardinality(c.tags) = 0
        and exists (
          select from public.crm_customer_keys k
          where k.store_id = v_store and k.customer_id = c.id and k.key like 'phone:%'
            and public.crm_normalize_phone(substr(k.key, 7)) = phone.value
        )
        and not exists (
          select from public.crm_customer_keys k
          where k.customer_id = c.id and (k.store_id <> v_store or k.key not like 'phone:%'
            or public.crm_normalize_phone(substr(k.key, 7)) is distinct from phone.value)
        )
        and exists (
          select from public.orders o
          where o.crm_customer_id = c.id and o.customer_name = c.name and o.customer_email = c.email
        )
        and not exists (
          select from public.orders o
          where o.crm_customer_id = c.id
            and (o.store_id <> v_store or o.user_id is not null
              or public.crm_normalize_phone(o.customer_phone) is distinct from phone.value)
        )
      for update of c
    loop
      update public.orders set crm_customer_id = v_duplicate.target_id
      where crm_customer_id = v_duplicate.id;

      update public.crm_customer_keys set customer_id = v_duplicate.target_id
      where customer_id = v_duplicate.id;

      update public.crm_customers set created_at = least(created_at, v_duplicate.created_at)
      where id = v_duplicate.target_id;

      delete from public.crm_customers where id = v_duplicate.id;
    end loop;
  end loop;
end;
$$;

-- 20261122120600_validate_checkout_phone.sql
-- Keep the checkout rule in sync with normalizeCheckoutPhone in src/lib/phone.ts.
-- The Ukrainian prefixes cover national geographic and subscriber network codes.
create function public.validate_checkout_phone(p_phone text)
returns text
language plpgsql immutable set search_path = ''
as $$
declare
  v_compact text := regexp_replace(translate(p_phone, chr(160) || chr(8239), '  '), '[[:space:]()-]', '', 'g');
  v_phone text;
begin
  v_phone := case
    when v_compact ~ '^0[0-9]{9}$' then '+38' || v_compact
    when v_compact ~ '^380[0-9]{9}$' then '+' || v_compact
    when v_compact ~ '^\+[1-9][0-9]{7,14}$' then v_compact
  end;
  if v_phone is null or (v_phone like '+380%' and v_phone !~ '^\+380(3[1-8]|4[13-8]|5[0-7]|6[1-9]|7[3-9]|8[1-59]|9[1-9])[0-9]{7}$') then
    raise invalid_parameter_value using message = 'Enter a valid phone number, for example +380 67 123 45 67.';
  end if;
  return v_phone;
end;
$$;
revoke all on function public.validate_checkout_phone(text) from public, anon, authenticated;

create or replace function public.create_discounted_store_order(
  p_store_id uuid, p_items jsonb, p_customer_name text, p_customer_email text, p_customer_phone text,
  p_delivery_city text, p_delivery_address text, p_note text default '', p_delivery_city_ref text default null,
  p_delivery_address_ref text default null, p_delivery_service_type text default null,
  p_expected_discount_percent numeric default null, p_expected_total integer default null
) returns public.orders
language plpgsql security definer set search_path = '' as $$
declare
  discount public.customer_discounts;
  v_phone text := public.validate_checkout_phone(p_customer_phone);
begin
  discount := public.active_customer_discount(p_store_id, auth.uid());
  if p_expected_discount_percent is not null and p_expected_discount_percent is distinct from coalesce(discount.percent, 0) then
    raise sqlstate 'PT409' using message = 'Your discount changed. Review your cart and try again.';
  end if;
  return public.create_priced_catalog_order('CASH_ON_DELIVERY', auth.uid(), p_store_id, p_items,
    p_customer_name, p_customer_email, v_phone, p_delivery_city, p_delivery_address, p_note,
    p_delivery_city_ref, p_delivery_address_ref, p_delivery_service_type, false, discount, p_expected_total);
end;
$$;

create or replace function public.prepare_online_checkout(
  p_provider text, p_user_id uuid, p_store_id uuid, p_items jsonb, p_checkout jsonb, p_test_mode boolean
) returns public.online_checkouts
language plpgsql security definer set search_path = '' as $$
declare
  v_attempt public.online_checkouts;
  v_enabled boolean;
  v_test_mode boolean;
  v_currency text;
  v_phone text := public.validate_checkout_phone(p_checkout->>'phone');
  discount public.customer_discounts;
  quote record;
begin
  if p_provider is null or p_provider not in ('LIQPAY', 'MONOBANK') then
    raise exception 'Invalid payment method';
  end if;
  select s.currency, case p_provider when 'LIQPAY' then pm.liqpay else pm.monobank end,
    coalesce(pm.payment_test_mode, case p_provider when 'LIQPAY' then p_test_mode else pm.monobank_test_mode end, false)
  into v_currency, v_enabled, v_test_mode
  from public.shop_settings s left join public.store_payment_methods pm on pm.store_id = s.id
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
  if nullif(trim(p_checkout->>'name'), '') is null
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
      'name', p_checkout->>'name', 'email', p_checkout->>'email', 'phone', v_phone,
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

-- 20261122120700_nova_poshta_tracking_interval.sql
alter table public.delivery_settings
  add column nova_poshta_tracking_interval_hours integer not null default 2
  check (nova_poshta_tracking_interval_hours in (1, 2, 3, 6, 12, 24));

-- The CRM has one shop, and its delivery settings control the existing tracking job.
create function public.sync_nova_poshta_tracking_interval() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  interval_hours integer := 2;
  tracking_schedule text;
begin
  if tg_op <> 'DELETE' then
    interval_hours := new.nova_poshta_tracking_interval_hours;
  end if;

  if tg_op = 'UPDATE' and interval_hours = old.nova_poshta_tracking_interval_hours then
    return null;
  end if;

  tracking_schedule := case interval_hours
    when 1 then '0 * * * *'
    when 24 then '0 0 * * *'
    else format('0 */%s * * *', interval_hours)
  end;
  perform cron.schedule(
    'tatami-nova-poshta-tracking',
    tracking_schedule,
    'select public.run_nova_poshta_tracking_job()'
  );
  return null;
end;
$$;
revoke all on function public.sync_nova_poshta_tracking_interval() from public, anon, authenticated, service_role;

create trigger sync_nova_poshta_tracking_interval
  after insert or update of nova_poshta_tracking_interval_hours or delete on public.delivery_settings
  for each row execute function public.sync_nova_poshta_tracking_interval();

notify pgrst, 'reload schema';

-- 20261122120800_nova_poshta_tracking_minutes.sql
drop trigger sync_nova_poshta_tracking_interval on public.delivery_settings;
drop function public.sync_nova_poshta_tracking_interval();

alter table public.delivery_settings
  drop constraint delivery_settings_nova_poshta_tracking_interval_hours_check;
alter table public.delivery_settings
  rename column nova_poshta_tracking_interval_hours to nova_poshta_tracking_interval_minutes;
update public.delivery_settings
set nova_poshta_tracking_interval_minutes = nova_poshta_tracking_interval_minutes * 60;
alter table public.delivery_settings
  alter column nova_poshta_tracking_interval_minutes set default 120,
  add constraint delivery_settings_nova_poshta_tracking_interval_minutes_check
    check (nova_poshta_tracking_interval_minutes > 0);

alter table public.nova_poshta_tracking_schedule add column last_dispatched_at timestamptz;

-- Keep the current schedule aligned with the previous UTC cron slots at migration time.
update public.nova_poshta_tracking_schedule
set last_dispatched_at = date_bin(
  make_interval(mins => coalesce((select nova_poshta_tracking_interval_minutes from public.delivery_settings limit 1), 120)),
  statement_timestamp(),
  '2000-01-01 00:00:00+00'::timestamptz
)
where singleton;

create or replace function public.run_nova_poshta_tracking_job() returns bigint
language sql security definer
set search_path = ''
as $$
  with timing as (
    select date_trunc('minute', statement_timestamp()) as tick,
      make_interval(mins => coalesce((select nova_poshta_tracking_interval_minutes from public.delivery_settings limit 1), 120)) as frequency
  ), due as (
    update public.nova_poshta_tracking_schedule s
    set last_dispatched_at = timing.tick
    from timing
    where s.singleton and s.project_url is not null
      and (s.last_dispatched_at is null or s.last_dispatched_at + timing.frequency <= timing.tick)
    returning s.project_url, s.token
  )
  select net.http_post(
    url := project_url || '/functions/v1/nova-poshta-track-ttn',
    headers := jsonb_build_object('Content-Type', 'application/json', 'X-Tracking-Job', token),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000
  )
  from due;
$$;

-- pg_cron checks locally each minute. Only a due run queues an HTTP request.
select cron.schedule('tatami-nova-poshta-tracking', '* * * * *', 'select public.run_nova_poshta_tracking_job()');

notify pgrst, 'reload schema';

-- 20261122120900_completed_order_ttn.sql
CREATE OR REPLACE FUNCTION "public"."reserve_order_ttn"("p_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  target public.orders;
begin
  select * into target from public.orders where id=p_order_id;
  if target.id is null then raise exception 'Order not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || target.store_id::text, 0));
  select * into target from public.orders where id=p_order_id for update;
  if target.status = 'COMPLETED' then
    raise sqlstate 'PT409' using message = 'A TTN cannot be created for a completed order.';
  end if;
  if target.status not in ('PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED') then
    raise exception 'Move the order to preparing for shipment first';
  end if;
  if target.status::text like 'CANCELLED%' then
    raise exception 'A TTN cannot be created for a cancelled order';
  end if;
  if exists(select 1 from public.order_merge_members where order_id=p_order_id and root_id<>p_order_id) then
    raise exception 'Create the TTN from the primary order';
  end if;
  if exists(select 1 from public.orders where (id=p_order_id or id in
    (select order_id from public.order_merge_members where root_id=p_order_id))
    and (nova_poshta_ttn is not null or nova_poshta_document_ref is not null)) then
    raise exception 'This order already has a TTN';
  end if;
  perform o.id from public.orders o join public.order_merge_members m on o.id=m.order_id
    where m.root_id=p_order_id order by o.id for update of o;
  if exists(select from public.order_merge_members m join public.orders o on o.id=m.order_id
    where m.root_id=p_order_id and o.status in ('CANCELLED_BY_STORE','CANCELLED_BY_USER')) then
    raise exception 'Cancelled orders cannot be included in a shipment';
  end if;
  if exists (
    select from public.order_merge_members m join public.orders o on o.id = m.order_id
    where m.root_id = p_order_id and o.status = 'COMPLETED'
  ) then
    raise sqlstate 'PT409' using message = 'A TTN cannot be created for a completed order.';
  end if;
  insert into public.order_ttn_reservations(order_id) values(p_order_id);
end; $$;

create or replace function public.protect_merged_shipment_during_creation() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.status = 'COMPLETED' and old.status is distinct from new.status
    and exists (select from public.order_ttn_reservations r where r.order_id = old.id) then
    raise exception 'TTN creation is in progress for one of these orders';
  end if;
  if exists(select from public.order_merge_members m join public.order_ttn_reservations r on r.order_id=m.root_id
    where m.order_id=old.id) then raise exception 'TTN creation is in progress for one of these orders'; end if;
  return new;
end; $$;

create or replace function public.unlink_order_ttn(p_order_id uuid, p_ttn text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  target public.orders;
begin
  select * into target from public.orders where id = p_order_id;
  if not found or not coalesce(public.is_store_member(target.store_id), false) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('order-merge:' || target.store_id::text, 0));
  select * into target from public.orders where id = p_order_id for update;
  if exists (select from public.order_merge_members where order_id = p_order_id and root_id <> p_order_id) then
    raise exception 'Unlink the TTN from the primary order.';
  end if;
  if p_ttn is null or target.nova_poshta_ttn is distinct from p_ttn then
    raise exception 'The TTN has changed. Refresh the order and try again.';
  end if;
  perform o.id from public.orders o join public.order_merge_members m on m.order_id = o.id
    where m.root_id = p_order_id order by o.id for update of o;
  if target.status = 'COMPLETED' or exists (
    select from public.order_merge_members m join public.orders o on o.id = m.order_id
    where m.root_id = p_order_id and o.nova_poshta_ttn = p_ttn and o.status = 'COMPLETED'
  ) then
    raise sqlstate 'PT409' using message = 'The TTN of a completed order cannot be unlinked.';
  end if;
  update public.orders o set nova_poshta_ttn = null, nova_poshta_document_ref = null,
      nova_poshta_ttn_created_at = null, nova_poshta_status = null, nova_poshta_status_code = null,
      nova_poshta_status_updated_at = null, manual_tracking_status_code = null
    where o.store_id = target.store_id and o.nova_poshta_ttn = p_ttn and
      (o.id = p_order_id or exists (
        select from public.order_merge_members m where m.root_id = p_order_id and m.order_id = o.id
      ));
end;
$$;

-- 20261122121000_new_order_filter.sql
do $$
declare
  definition text;
  old_condition text := '(p_status = ''ALL'' or (p_status = ''NO_TTN''';
  new_condition text := '(p_status = ''ALL'' or (p_status = ''NEW'' and o.is_new) or (p_status = ''NO_TTN''';
begin
  select pg_get_functiondef('public.crm_orders_page(uuid,integer,integer,text,text,date,date,uuid[],uuid)'::regprocedure) into definition;
  if position(old_condition in definition) = 0 then
    raise exception 'Unexpected crm_orders_page definition; new order filter was not installed';
  end if;
  execute replace(definition, old_condition, new_condition);
end;
$$;

-- 20261122121100_customer_web_push.sql
create table public.customer_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth_secret text not null,
  language text not null check (language in ('uk', 'en'))
);
create index customer_push_subscriptions_user on public.customer_push_subscriptions(user_id);

create table public.customer_push_deliveries (
  id uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references public.customer_push_subscriptions(id) on delete cascade,
  kind text not null,
  path text not null,
  created_at timestamptz not null default now(),
  next_attempt_at timestamptz not null default now(),
  attempts integer not null default 0
);
create index customer_push_deliveries_due on public.customer_push_deliveries(next_attempt_at)
  where attempts < 4;

create table public.customer_push_job_secret (
  singleton boolean primary key default true check (singleton),
  token text not null default encode(extensions.gen_random_bytes(32), 'hex')
);
insert into public.customer_push_job_secret default values;

alter table public.customer_push_subscriptions enable row level security;
alter table public.customer_push_deliveries enable row level security;
alter table public.customer_push_job_secret enable row level security;
revoke all on public.customer_push_subscriptions, public.customer_push_deliveries, public.customer_push_job_secret
  from public, anon, authenticated, service_role;
grant delete on public.customer_push_subscriptions, public.customer_push_deliveries to service_role;
grant select(id) on public.customer_push_subscriptions, public.customer_push_deliveries to service_role;

create function public.set_customer_push_subscription(
  p_endpoint text, p_p256dh text default null, p_auth text default null, p_language text default 'uk'
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise insufficient_privilege; end if;
  if p_p256dh is null and p_auth is null then
    delete from public.customer_push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
    return;
  end if;
  if p_endpoint is null or length(p_endpoint) > 2048
    or p_endpoint !~ '^https://((web[.]|[a-z0-9-]+[.])?push[.]apple[.]com|fcm[.]googleapis[.]com|updates[.]push[.]services[.]mozilla[.]com|[a-z0-9-]+[.]notify[.]windows[.]com)/[[:graph:]]+$'
    or p_p256dh is null or p_p256dh !~ '^[A-Za-z0-9_-]{87}=?$'
    or p_auth is null or p_auth !~ '^[A-Za-z0-9_-]{22}={0,2}$' then
    raise exception 'Invalid push subscription';
  end if;
  -- An installation may be reused after signing in to a different account.
  delete from public.customer_push_subscriptions where endpoint = p_endpoint and user_id <> auth.uid();
  insert into public.customer_push_subscriptions (endpoint, user_id, p256dh, auth_secret, language)
  values (p_endpoint, auth.uid(), rtrim(p_p256dh, '='), rtrim(p_auth, '='), case when p_language = 'en' then 'en' else 'uk' end)
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth_secret = excluded.auth_secret, language = excluded.language
    where customer_push_subscriptions.user_id = auth.uid();
end;
$$;

create function public.has_customer_push_subscription(p_endpoint text) returns boolean
  language sql stable security definer set search_path = '' as $$
  select exists(select from public.customer_push_subscriptions where endpoint = p_endpoint and user_id = auth.uid());
$$;

create function public.queue_customer_order_push() returns trigger
  language plpgsql security definer set search_path = '' as $$
begin
  insert into public.customer_push_deliveries(subscription_id, kind, path)
  select id, new.kind, '/receipt/' || new.receipt_code
  from public.customer_push_subscriptions where user_id = new.user_id;
  return new;
end;
$$;
create trigger queue_customer_order_push after insert on public.customer_notifications
  for each row execute function public.queue_customer_order_push();

create function public.queue_customer_restock_push() returns trigger
  language plpgsql security definer set search_path = '' as $$
begin
  insert into public.customer_push_deliveries(subscription_id, kind, path)
  select s.id, 'restock', '/product/' || v.product_id::text
  from public.customer_push_subscriptions s cross join public.product_variants v
  where s.user_id = new.user_id and v.id = new.variant_id;
  return new;
end;
$$;
create trigger queue_customer_restock_push after update of notified_at on public.restock_subscriptions
  for each row when (old.notified_at is null and new.notified_at is not null)
  execute function public.queue_customer_restock_push();

create function public.claim_customer_push_deliveries(p_token text)
returns table(id uuid, subscription_id uuid, endpoint text, p256dh text, auth_secret text, language text, kind text, path text)
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select from public.customer_push_job_secret where
    extensions.digest(token, 'sha256') = extensions.digest(p_token, 'sha256')) then
    raise insufficient_privilege;
  end if;
  return query with batch as (
    select d.id from public.customer_push_deliveries d
    where d.attempts < 4 and d.next_attempt_at <= now() and d.created_at > now() - interval '1 day'
    order by d.next_attempt_at, d.id limit 30 for update skip locked
  ), leased as (
    update public.customer_push_deliveries d
    set attempts = d.attempts + 1, next_attempt_at = now() + interval '2 minutes'
    from batch where d.id = batch.id
    returning d.id, d.subscription_id, d.kind, d.path
  )
  select d.id, s.id, s.endpoint, s.p256dh, s.auth_secret, s.language, d.kind, d.path
  from leased d join public.customer_push_subscriptions s on s.id = d.subscription_id;
end;
$$;

create function public.run_customer_push_job() returns bigint
language plpgsql security definer set search_path = '' as $$
declare request_id bigint;
begin
  delete from public.customer_push_deliveries where created_at <= now() - interval '1 day';
  if not exists (select from public.customer_push_deliveries where attempts < 4 and next_attempt_at <= now()) then
    return null;
  end if;
  select net.http_post(
    url := s.project_url || '/functions/v1/customer-push',
    headers := jsonb_build_object('X-Push-Job', j.token, 'Content-Type', 'application/json'),
    body := '{}'::jsonb, timeout_milliseconds := 115000
  ) into request_id from public.nova_poshta_tracking_schedule s cross join public.customer_push_job_secret j
  where s.project_url is not null;
  return request_id;
end;
$$;

revoke all on function public.set_customer_push_subscription(text, text, text, text),
  public.has_customer_push_subscription(text), public.queue_customer_order_push(),
  public.queue_customer_restock_push(), public.claim_customer_push_deliveries(text),
  public.run_customer_push_job() from public, anon, authenticated, service_role;
grant execute on function public.set_customer_push_subscription(text, text, text, text),
  public.has_customer_push_subscription(text) to authenticated;
grant execute on function public.claim_customer_push_deliveries(text) to service_role;
select cron.schedule('tatami-customer-push', '* * * * *', 'select public.run_customer_push_job()');
notify pgrst, 'reload schema';

-- 20261122121200_customer_push_order_updates.sql
create or replace function public.queue_customer_order_push() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.customer_push_deliveries(subscription_id, kind, path)
  select id,
    case when new.kind = 'status' and new.value is not null then 'status:' || new.value else new.kind end,
    '/receipt/' || new.receipt_code
  from public.customer_push_subscriptions where user_id = new.user_id;
  return new;
end;
$$;

-- A consolidated shipment can generate a waybill event for several receipts.
create unique index customer_push_one_waybill_per_device
  on public.customer_push_deliveries(subscription_id, kind)
  where kind like 'ttn_ready:%';

create function public.queue_customer_waybill_push() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  customer_id uuid;
  receipt_path text;
begin
  select o.user_id, '/receipt/' || o.receipt_code
    into customer_id, receipt_path from public.orders o where o.id = new.order_id;
  if customer_id is null then return new; end if;

  delete from public.customer_push_deliveries d
    using public.customer_push_subscriptions s
    where d.subscription_id = s.id and s.user_id = customer_id
      and d.path = receipt_path and d.kind like 'ttn_ready:%';

  if new.kind = 'ttn_linked' and new.new_value ~ '^[0-9]{14}$' then
    insert into public.customer_push_deliveries(subscription_id, kind, path)
    select id, 'ttn_ready:' || new.new_value, receipt_path
    from public.customer_push_subscriptions where user_id = customer_id
    on conflict (subscription_id, kind) where kind like 'ttn_ready:%' do nothing;
  end if;
  return new;
end;
$$;

revoke all on function public.queue_customer_waybill_push() from public, anon, authenticated, service_role;
create trigger queue_customer_waybill_push after insert on public.order_events
  for each row when (new.kind in ('ttn_linked', 'ttn_unlinked')) execute function public.queue_customer_waybill_push();

-- 20261122121300_actionable_customer_push.sql
create or replace function public.queue_customer_order_push() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  order_row public.orders;
  push_kind text;
  target_path text := '/receipt/' || new.receipt_code;
begin
  push_kind := new.kind;
  if new.kind in ('status', 'payment_status') and new.value is not null then
    push_kind := new.kind || ':' || new.value;
  end if;

  if new.kind = 'status' and new.value = 'IN_PROGRESS' and exists (
    select from public.orders o join public.order_events e on e.id = new.event_id
    where o.id = new.order_id and o.payment_method = 'CASH_ON_DELIVERY'
      and e.old_value is null
  ) then
    push_kind := 'status:IN_PROGRESS:cod';
  end if;

  if new.kind = 'status' and new.value = 'DELIVERED' and exists (
    select from public.orders o where o.id = new.order_id
      and o.nova_poshta_status_code in ('7', '8')
      and o.nova_poshta_ttn = current_setting('tatami.customer_push_tracking_ttn', true)
  ) then
    -- The tracking update queues the more useful pickup message.
    return new;
  end if;

  if new.kind = 'status' and new.value = 'COMPLETED' and exists (
    select from public.orders o where o.id = new.order_id
      and o.nova_poshta_status_code in ('9', '10', '11')
  ) then
    push_kind := 'status:COMPLETED:received';
  end if;

  if (new.kind = 'payment_status' and new.value = 'PAID')
    or (new.kind = 'status' and new.value in ('CANCELLED_BY_USER', 'CANCELLED_BY_STORE')) then
    delete from public.customer_push_deliveries d using public.customer_push_subscriptions s
    where d.subscription_id = s.id and s.user_id = new.user_id
      and d.kind = 'payment_retry:reserved:' || new.order_id::text;
  end if;

  if new.kind = 'payment_status' then
    select * into order_row from public.orders where id = new.order_id;
    if new.value = 'PENDING' and order_row.payment_method = 'CASH_ON_DELIVERY' then
      -- The order confirmation already covers the initial COD state.
      return new;
    elsif new.value = 'FAILED' and order_row.status in ('CANCELLED_BY_USER', 'CANCELLED_BY_STORE') then
      -- Cancelling an unpaid reservation also sets FAILED. It is no longer payable.
      return new;
    elsif new.value = 'FAILED' and order_row.status = 'PENDING' and order_row.payment_method = 'ONLINE' then
      push_kind := 'payment_retry:reserved:' || new.order_id::text;
      target_path := '/account#order-' || new.order_id::text;
    elsif new.value = 'REFUNDED' and exists (
      select from public.order_events e where e.order_id = new.order_id and e.kind = 'return'
        and e.created_at = new.created_at
    ) then
      -- A confirmed full refund already wrote a return event in this transaction.
      return new;
    end if;
  end if;

  insert into public.customer_push_deliveries(subscription_id, kind, path)
  select id, push_kind, target_path
  from public.customer_push_subscriptions where user_id = new.user_id;
  return new;
end;
$$;

create function public.queue_customer_checkout_failure() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'PAID' then
    delete from public.customer_push_deliveries d using public.customer_push_subscriptions s
    where d.subscription_id = s.id and s.user_id = new.user_id
      and d.kind = 'payment_retry:checkout:' || new.id::text;
    return new;
  end if;
  if new.user_id is not null and new.provider_order_id is not null
    and not exists (select from public.orders o where o.id = new.id) then
    insert into public.customer_push_deliveries(subscription_id, kind, path)
    select id, 'payment_retry:checkout:' || new.id::text, '/checkout'
    from public.customer_push_subscriptions where user_id = new.user_id;
  end if;
  return new;
end;
$$;

create trigger queue_customer_checkout_failure after update of status on public.online_checkouts
  for each row when ((old.status = 'PENDING' and new.status = 'FAILED')
    or (old.status is distinct from new.status and new.status = 'PAID'))
  execute function public.queue_customer_checkout_failure();

create unique index customer_push_one_shipment_update_per_device
  on public.customer_push_deliveries(subscription_id, kind)
  where kind like 'pickup:%' or kind like 'shipment:%';

create function public.queue_customer_shipment_push() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  paid_storage_from text := '';
  push_kind text;
begin
  if new.user_id is null or coalesce(new.nova_poshta_ttn, '') !~ '^[0-9]{14}$'
    or new.status in ('COMPLETED', 'CANCELLED_BY_USER', 'CANCELLED_BY_STORE') then
    return new;
  end if;

  if new.nova_poshta_status_code in ('7', '8') then
    if new.nova_poshta_status_code = '7'
      and new.nova_poshta_ttn = current_setting('tatami.customer_push_tracking_ttn', true) then
      paid_storage_from := coalesce(current_setting('tatami.customer_push_paid_storage_from', true), '');
    end if;
    push_kind := 'pickup:' || new.nova_poshta_status_code || ':' || paid_storage_from;
  elsif new.nova_poshta_status_code in ('4', '5', '6', '101')
    and coalesce(old.nova_poshta_status_code, '') not in ('4', '5', '6', '101')
    and new.status not in ('IN_TRANSIT', 'DELIVERED') then
    push_kind := 'shipment:in_transit';
  elsif new.nova_poshta_status_code in ('9', '10', '11')
    and coalesce(old.nova_poshta_status_code, '') not in ('9', '10', '11') then
    push_kind := 'shipment:received';
  elsif new.nova_poshta_status_code in ('102', '103')
    and coalesce(old.nova_poshta_status_code, '') not in ('102', '103') then
    push_kind := 'shipment:refused';
  else
    push_kind := case new.nova_poshta_status_code
      when '104' then 'shipment:rerouted'
      when '105' then 'shipment:storage_ended'
      when '111' then 'shipment:missed'
      when '112' then 'shipment:rescheduled'
    end;
  end if;
  if push_kind is null then return new; end if;

  insert into public.customer_push_deliveries(subscription_id, kind, path)
  select id, push_kind || ':' || new.nova_poshta_ttn, '/receipt/' || new.receipt_code
  from public.customer_push_subscriptions where user_id = new.user_id
  on conflict (subscription_id, kind) where kind like 'pickup:%' or kind like 'shipment:%' do nothing;
  return new;
end;
$$;

create trigger queue_customer_shipment_push after update of nova_poshta_status_code on public.orders
  for each row when (new.nova_poshta_status_code is not null and old.nova_poshta_status_code is distinct from new.nova_poshta_status_code)
  execute function public.queue_customer_shipment_push();

create function public.apply_nova_poshta_tracking_with_storage(
  p_store_id uuid, p_ttn text, p_code text, p_status text, p_checked_at timestamptz,
  p_paid_storage_from date
) returns boolean language plpgsql set search_path = '' as $$
declare
  changed boolean;
begin
  perform set_config('tatami.customer_push_tracking_ttn', coalesce(p_ttn, ''), true);
  perform set_config('tatami.customer_push_paid_storage_from', coalesce(to_char(p_paid_storage_from, 'YYYY-MM-DD'), ''), true);
  changed := public.apply_nova_poshta_tracking(p_store_id, p_ttn, p_code, p_status, p_checked_at);
  perform set_config('tatami.customer_push_tracking_ttn', '', true);
  perform set_config('tatami.customer_push_paid_storage_from', '', true);
  return changed;
end;
$$;

revoke all on function public.queue_customer_checkout_failure(), public.queue_customer_shipment_push(),
  public.apply_nova_poshta_tracking_with_storage(uuid, text, text, text, timestamptz, date)
  from public, anon, authenticated, service_role;
grant execute on function public.apply_nova_poshta_tracking_with_storage(uuid, text, text, text, timestamptz, date)
  to service_role;
notify pgrst, 'reload schema';

-- 20261122121400_customer_discount_push.sql
create or replace function public.set_customer_discount(
  p_store_id uuid, p_customer_id uuid, p_user_id uuid, p_percent numeric, p_mode text,
  p_order_limit integer default null, p_starts_on date default null, p_ends_on date default null
) returns void language plpgsql security definer set search_path = '' as $$
declare
  previous_discount public.customer_discounts;
  saved_discount public.customer_discounts;
  kind_prefix text := 'discount:' || p_store_id::text || ':';
  kind text;
begin
  if not exists (select from public.crm_customer_accounts(p_store_id, p_customer_id) a where a.user_id = p_user_id) then
    raise exception 'Registered customer account required' using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_store_id::text || p_user_id::text, 1));
  update public.customer_discounts set enabled = false
  where store_id = p_store_id and user_id = p_user_id and enabled
  returning * into previous_discount;

  if p_percent is not null then
    insert into public.customer_discounts(store_id, user_id, percent, mode, order_limit, starts_on, ends_on)
    values (p_store_id, p_user_id, p_percent, p_mode,
      case when p_mode = 'orders' then p_order_limit end,
      case when p_mode = 'period' then p_starts_on end, case when p_mode = 'period' then p_ends_on end)
    returning * into saved_discount;

    if row(saved_discount.percent, saved_discount.mode, saved_discount.order_limit, saved_discount.starts_on, saved_discount.ends_on)
      is not distinct from
       row(previous_discount.percent, previous_discount.mode, previous_discount.order_limit, previous_discount.starts_on, previous_discount.ends_on) then
      return;
    end if;
  end if;

  -- Withdraw a queued message when the discount is replaced or removed before delivery.
  delete from public.customer_push_deliveries d using public.customer_push_subscriptions s
  where d.subscription_id = s.id and s.user_id = p_user_id and d.kind like kind_prefix || '%';

  if saved_discount.id is null or saved_discount.ends_on < (now() at time zone 'Europe/Kyiv')::date then
    return;
  end if;

  kind := kind_prefix || concat_ws(':',
    case when previous_discount.id is null then 'assigned' else 'updated' end,
    saved_discount.percent, saved_discount.mode, saved_discount.order_limit,
    to_char(saved_discount.starts_on, 'YYYY-MM-DD'), to_char(saved_discount.ends_on, 'YYYY-MM-DD'));
  insert into public.customer_push_deliveries(subscription_id, kind, path)
  select id, kind, '/account' from public.customer_push_subscriptions where user_id = p_user_id;
end;
$$;

-- 20261123120000_split_order_items.sql
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

-- 20261123120100_manual_customer_push.sql
alter table public.customer_notifications
  alter column event_id drop not null,
  alter column order_id drop not null,
  alter column receipt_code drop not null,
  add constraint customer_notification_source check (
    (kind = 'manual' and event_id is null and order_id is null and receipt_code is null
      and value is not null and char_length(value) between 1 and 500)
    or (kind <> 'manual' and event_id is not null and order_id is not null and receipt_code is not null)
  );

drop trigger queue_customer_order_push on public.customer_notifications;
create trigger queue_customer_order_push after insert on public.customer_notifications
  for each row when (new.order_id is not null) execute function public.queue_customer_order_push();

create function public.crm_customer_push_recipients(p_store_id uuid, p_customer_id uuid)
returns table(user_id uuid, email text, phone_suffix text, push_available boolean)
language sql stable security definer set search_path = '' as $$
  select a.user_id, nullif(a.email, ''), right(nullif(u.phone, ''), 4),
    exists (select from public.customer_push_subscriptions s where s.user_id = a.user_id)
  from public.crm_customer_accounts(p_store_id, p_customer_id) a
  join auth.users u on u.id = a.user_id;
$$;

create function public.queue_crm_customer_push(
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
  return true;
end;
$$;

revoke all on function public.crm_customer_push_recipients(uuid, uuid),
  public.queue_crm_customer_push(uuid, uuid, uuid, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.crm_customer_push_recipients(uuid, uuid),
  public.queue_crm_customer_push(uuid, uuid, uuid, uuid, text) to authenticated;
notify pgrst, 'reload schema';

-- 20261123120200_customer_push_broadcast.sql
create table public.customer_push_broadcasts (
  id uuid primary key,
  store_id uuid not null references public.shop_settings(id) on delete cascade,
  message_hash bytea not null,
  recipient_count integer not null default 0
);
alter table public.customer_push_broadcasts enable row level security;
revoke all on public.customer_push_broadcasts from public, anon, authenticated, service_role;

create function public.crm_push_broadcast_audience(p_store_id uuid)
returns table(subscription_id uuid, user_id uuid)
language sql stable set search_path = '' as $$
  select s.id, s.user_id
  from public.customer_push_subscriptions s
  join public.crm_customer_keys k on k.store_id = p_store_id and k.key = 'user:' || s.user_id::text
  join auth.users u on u.id = s.user_id
  where u.deleted_at is null and not u.is_anonymous;
$$;

create function public.crm_push_broadcast_size(p_store_id uuid)
returns integer language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (select from public.store_members m
    where m.store_id = p_store_id and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then
    raise exception 'Manager access required' using errcode = '42501';
  end if;

  return (select count(distinct a.user_id)::integer from public.crm_push_broadcast_audience(p_store_id) a);
end;
$$;

create function public.queue_crm_push_broadcast(p_store_id uuid, p_request_id uuid, p_message text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  message text := btrim(p_message, E' \t\r\n');
  body_hash bytea;
  recipients integer;
begin
  if not exists (select from public.store_members m
    where m.store_id = p_store_id and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then
    raise exception 'Manager access required' using errcode = '42501';
  end if;
  if p_request_id is null or message is null or char_length(message) not between 1 and 500 then
    raise exception 'Enter a notification between 1 and 500 characters.' using errcode = '22023';
  end if;

  body_hash := extensions.digest(message, 'sha256');
  insert into public.customer_push_broadcasts(id, store_id, message_hash)
  values (p_request_id, p_store_id, body_hash) on conflict (id) do nothing;
  if not found then
    select b.recipient_count into recipients from public.customer_push_broadcasts b
    where b.id = p_request_id and b.store_id = p_store_id and b.message_hash = body_hash;
    if not found then raise insufficient_privilege; end if;
    return recipients;
  end if;

  -- Lock the current devices so an opt-out can safely remove pending deliveries after this transaction.
  with devices as materialized (
    select s.id, s.user_id
    from public.crm_push_broadcast_audience(p_store_id) a
    join public.customer_push_subscriptions s on s.id = a.subscription_id
    for key share of s
  ), notices as (
    insert into public.customer_notifications(store_id, user_id, kind, value)
    select distinct p_store_id, d.user_id, 'manual', message from devices d
    returning user_id
  ), queued as (
    insert into public.customer_push_deliveries(subscription_id, kind, path)
    select d.id, 'manual:' || message, '/account' from devices d join notices n on n.user_id = d.user_id
  )
  select count(*)::integer into recipients from notices;

  update public.customer_push_broadcasts set recipient_count = recipients where id = p_request_id;
  return recipients;
end;
$$;

revoke all on function public.crm_push_broadcast_audience(uuid), public.crm_push_broadcast_size(uuid),
  public.queue_crm_push_broadcast(uuid, uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.crm_push_broadcast_size(uuid), public.queue_crm_push_broadcast(uuid, uuid, text) to authenticated;
notify pgrst, 'reload schema';

-- 20261123120300_staff_order_push.sql
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

-- 20261123120400_sms_notifications.sql
-- The legacy SMS-named setting controlled restock subscriptions and their existing push channel.
alter table public.shop_settings
  add column restock_sms_enabled boolean not null default false,
  add column order_push_enabled boolean not null default true,
  add column order_sms_enabled boolean not null default false;

create function public.set_customer_notification_channel(p_store_id uuid, p_topic text, p_channel text, p_enabled boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare saved public.shop_settings;
begin
  if p_topic is null or p_topic not in ('restock', 'order')
    or p_channel is null or p_channel not in ('push', 'sms') or p_enabled is null then
    raise invalid_parameter_value;
  end if;
  update public.shop_settings s set
    sms_notifications_enabled = case when (p_topic, p_channel) = ('restock', 'push') then p_enabled else s.sms_notifications_enabled end,
    restock_sms_enabled = case when (p_topic, p_channel) = ('restock', 'sms') then p_enabled else s.restock_sms_enabled end,
    order_push_enabled = case when (p_topic, p_channel) = ('order', 'push') then p_enabled else s.order_push_enabled end,
    order_sms_enabled = case when (p_topic, p_channel) = ('order', 'sms') then p_enabled else s.order_sms_enabled end
  where s.id = p_store_id and exists (select from public.store_members m
    where m.store_id = s.id and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER'))
  returning s.* into saved;
  if not found then raise insufficient_privilege; end if;
  if not p_enabled and p_channel = 'sms' then
    delete from public.customer_sms_deliveries d where d.store_id = p_store_id and d.topic = p_topic and d.claimed_at is null;
  elsif not p_enabled and p_topic = 'restock' then
    delete from public.customer_push_deliveries d using public.products p
      where d.kind = 'restock' and d.path = '/product/' || p.id::text and p.store_id = p_store_id;
  elsif not p_enabled then
    delete from public.customer_push_deliveries d using public.orders o
      where (d.kind like 'status:%' or d.kind like 'pickup:%' or d.kind like 'shipment:%')
        and d.path = '/receipt/' || o.receipt_code and o.store_id = p_store_id;
  end if;
  return jsonb_build_object('restockPush', saved.sms_notifications_enabled, 'restockSms', saved.restock_sms_enabled,
    'orderPush', saved.order_push_enabled, 'orderSms', saved.order_sms_enabled);
end;
$$;

create function public.notification_sms_phone(p_phone text)
returns text language plpgsql immutable set search_path = '' as $$
begin
  return ltrim(public.validate_checkout_phone(p_phone), '+');
exception when invalid_parameter_value then return null;
end;
$$;

create table public.crm_staff_sms_preferences (
  store_id uuid not null,
  user_id uuid not null,
  primary key (store_id, user_id),
  foreign key (store_id, user_id) references public.store_members(store_id, user_id) on delete cascade
);
alter table public.crm_staff_sms_preferences enable row level security;
revoke all on public.crm_staff_sms_preferences from public, anon, authenticated, service_role;

create table public.customer_sms_deliveries (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.shop_settings(id) on delete cascade,
  phone text not null check (phone ~ '^[1-9][0-9]{7,14}$'),
  body text not null check (char_length(body) between 1 and 500),
  topic text not null check (topic in ('manual', 'order', 'restock', 'staff')),
  staff_user_id uuid,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  result text check (result in ('accepted', 'failed')),
  foreign key (store_id, staff_user_id) references public.crm_staff_sms_preferences(store_id, user_id) on delete cascade
);
create index customer_sms_deliveries_pending on public.customer_sms_deliveries(created_at, id) where claimed_at is null;
create index customer_sms_deliveries_staff on public.customer_sms_deliveries(store_id, staff_user_id) where staff_user_id is not null;
alter table public.customer_sms_deliveries enable row level security;
revoke all on public.customer_sms_deliveries from public, anon, authenticated, service_role;

create table public.crm_sms_requests (
  id uuid primary key,
  store_id uuid not null references public.shop_settings(id) on delete cascade,
  payload_hash bytea not null,
  recipient_count integer not null default 0
);
alter table public.crm_sms_requests enable row level security;
revoke all on public.crm_sms_requests from public, anon, authenticated, service_role;

create function public.crm_sms_numbers(p_store_id uuid, p_customer_id uuid)
returns setof text language sql stable set search_path = '' as $$
  select distinct n.phone
  from public.crm_customers c cross join lateral (select public.notification_sms_phone(c.phone) as phone) n
  where c.store_id = p_store_id and (p_customer_id is null or c.id = p_customer_id) and n.phone is not null;
$$;

create function public.crm_sms_audience(p_store_id uuid, p_customer_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare recipient_count integer; recipient_phone text;
begin
  if not exists (select from public.store_members m where m.store_id = p_store_id
    and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then raise insufficient_privilege; end if;
  select count(*)::integer, case when p_customer_id is not null then max(phone) end
  into recipient_count, recipient_phone from public.crm_sms_numbers(p_store_id, p_customer_id) phone;
  return jsonb_build_object('count', recipient_count, 'phone', case when recipient_phone is not null then '+' || recipient_phone end,
    'confirmed', p_customer_id is not null and recipient_count > 0 and public.crm_customer_phone_confirmed(p_store_id, p_customer_id));
end;
$$;

create function public.queue_crm_sms(p_store_id uuid, p_request_id uuid, p_message text, p_expected_count integer,
  p_customer_id uuid default null, p_expected_phone text default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  message text := btrim(p_message, E' \t\r\n');
  body_hash bytea;
  queued integer;
begin
  if not exists (select from public.store_members m where m.store_id = p_store_id
    and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then raise insufficient_privilege; end if;
  if p_request_id is null or message is null or char_length(message) not between 1 and 500
    or p_expected_count is null or p_expected_count < 1 then raise invalid_parameter_value; end if;
  body_hash := extensions.digest(jsonb_build_array(p_customer_id, p_expected_phone, message)::text, 'sha256');
  insert into public.crm_sms_requests(id, store_id, payload_hash)
  values (p_request_id, p_store_id, body_hash) on conflict (id) do nothing;
  if not found then
    select r.recipient_count into queued from public.crm_sms_requests r
    where r.id = p_request_id and r.store_id = p_store_id and r.payload_hash = body_hash;
    if not found then raise insufficient_privilege; end if;
    return queued;
  end if;

  with deliveries as (
    insert into public.customer_sms_deliveries(store_id, phone, body, topic)
    select p_store_id, phone, message, 'manual' from public.crm_sms_numbers(p_store_id, p_customer_id) phone
    where p_customer_id is null or phone = public.notification_sms_phone(p_expected_phone)
    returning phone
  ), notices as (
    insert into public.customer_notifications(store_id, user_id, kind, value)
    select distinct p_store_id, u.id, 'manual', message
    from deliveries d
    join auth.users u on u.phone in (d.phone, '+' || d.phone)
    join public.crm_customer_keys k on k.store_id = p_store_id and k.key = 'user:' || u.id::text
      and (p_customer_id is null or k.customer_id = p_customer_id)
    where u.phone_confirmed_at is not null and u.deleted_at is null and not u.is_anonymous
  ) select count(*)::integer into queued from deliveries;
  if queued <> p_expected_count then
    raise sqlstate 'PT409' using message = 'SMS recipient list changed. Check it before sending.';
  end if;
  update public.crm_sms_requests set recipient_count = queued where id = p_request_id;
  return queued;
end;
$$;

create function public.set_crm_staff_sms_enabled(p_store_id uuid, p_user_id uuid, p_enabled boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select from public.store_members m where m.store_id = p_store_id and m.user_id = auth.uid()
    and m.role in ('OWNER', 'MANAGER')) then raise insufficient_privilege; end if;
  if p_enabled is null then raise invalid_parameter_value; end if;
  perform 1 from public.store_members m where m.store_id = p_store_id and m.user_id = p_user_id
    and m.role in ('OWNER', 'MANAGER') for update;
  if not found then raise insufficient_privilege; end if;
  if p_enabled then
    insert into public.crm_staff_sms_preferences values (p_store_id, p_user_id) on conflict do nothing;
  else
    delete from public.crm_staff_sms_preferences where store_id = p_store_id and user_id = p_user_id;
  end if;
end;
$$;

drop function public.crm_staff_push_settings(uuid);
create function public.crm_staff_push_settings(p_store_id uuid)
returns table(user_id uuid, display_name text, role public.staff_role, enabled boolean, has_subscription boolean,
  sms_enabled boolean, has_sms_phone boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (select from public.store_members m where m.store_id = p_store_id
    and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then raise insufficient_privilege; end if;
  return query
  select m.user_id, coalesce(nullif(btrim(profile.name), ''), nullif(u.email::text, ''),
    '•••• ' || right(nullif(u.phone, ''), 4)), m.role, prefs.user_id is not null,
    exists (select from public.customer_push_subscriptions s where s.user_id = m.user_id),
    sms.user_id is not null, u.phone_confirmed_at is not null and public.notification_sms_phone(u.phone) is not null
  from public.store_members m
  join auth.users u on u.id = m.user_id
  left join public.profiles profile on profile.id = m.user_id
  left join public.crm_staff_push_preferences prefs on prefs.store_id = m.store_id and prefs.user_id = m.user_id
  left join public.crm_staff_sms_preferences sms on sms.store_id = m.store_id and sms.user_id = m.user_id
  where m.store_id = p_store_id and m.role in ('OWNER', 'MANAGER') and u.deleted_at is null and not u.is_anonymous
  order by m.role, 2, m.user_id;
end;
$$;

create or replace function public.clear_demoted_staff_push_preference() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.crm_staff_push_preferences where store_id = new.store_id and user_id = new.user_id;
  delete from public.crm_staff_sms_preferences where store_id = new.store_id and user_id = new.user_id;
  return new;
end;
$$;

create function public.queue_order_sms() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  destination text;
  status_text text;
  starts_work boolean;
begin
  if new.split_origin_id is not null then return new; end if;
  if tg_op = 'UPDATE' then
    if old.status is not distinct from new.status then return new; end if;
    starts_work := new.is_new and not old.is_new and new.status = 'IN_PROGRESS';
  else
    starts_work := new.status = 'IN_PROGRESS' and (new.payment_method = 'CASH_ON_DELIVERY' or new.payment_status = 'PAID');
    if not starts_work then return new; end if;
  end if;

  if starts_work then
    insert into public.customer_sms_deliveries(store_id, phone, body, topic, staff_user_id)
    select new.store_id, n.phone, 'Tatami: Нове замовлення в CRM.', 'staff', p.user_id
    from public.crm_staff_sms_preferences p
    join public.store_members m on (m.store_id, m.user_id) = (p.store_id, p.user_id)
    join auth.users u on u.id = m.user_id
    cross join lateral (select public.notification_sms_phone(u.phone) as phone) n
    where p.store_id = new.store_id and m.role in ('OWNER', 'MANAGER') and u.phone_confirmed_at is not null
      and u.deleted_at is null and not u.is_anonymous and n.phone is not null
    for key share of p;
  end if;

  if not exists (select from public.shop_settings where id = new.store_id and order_sms_enabled) then return new; end if;
  destination := public.notification_sms_phone(new.customer_phone);
  if destination is null then return new; end if;
  status_text := case new.status::text
    when 'IN_PROGRESS' then 'Замовлення в обробці.'
    when 'WAITING_FOR_STOCK' then 'Замовлення очікує надходження.'
    when 'PREPARING_SHIPMENT' then 'Замовлення готується до відправлення.'
    when 'IN_TRANSIT' then 'Замовлення в дорозі.'
    when 'READY_FOR_PICKUP' then 'Замовлення готове до видачі.'
    when 'DELIVERED' then 'Замовлення доставлено.'
    when 'COMPLETED' then 'Замовлення завершено.'
    when 'CANCELLED_BY_USER' then 'Замовлення скасовано.'
    when 'CANCELLED_BY_STORE' then 'Замовлення скасовано.'
  end;
  if status_text is not null then
    insert into public.customer_sms_deliveries(store_id, phone, body, topic)
    values (new.store_id, destination, 'Tatami: ' || status_text, 'order');
  end if;
  return new;
end;
$$;
create trigger queue_order_sms after insert or update of status on public.orders
  for each row execute function public.queue_order_sms();

create function public.queue_restock_sms() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.customer_sms_deliveries(store_id, phone, body, topic)
  select p.store_id, n.phone, 'Tatami: ' || left(p.name, 90) || ' (' || left(v.name, 30) || ') знову в наявності.', 'restock'
  from public.product_variants v join public.products p on p.id = v.product_id
  join public.shop_settings sh on sh.id = p.store_id
  join auth.users u on u.id = new.user_id
  cross join lateral (select public.notification_sms_phone(u.phone) as phone) n
  where v.id = new.variant_id and sh.restock_sms_enabled and u.phone_confirmed_at is not null
    and u.deleted_at is null and not u.is_anonymous and n.phone is not null;
  return new;
end;
$$;
create trigger queue_restock_sms after update of notified_at on public.restock_subscriptions
  for each row when (old.notified_at is null and new.notified_at is not null) execute function public.queue_restock_sms();

-- Preserve manual pushes, payment events and discount notices when a status channel is disabled.
create function public.filter_customer_notification_push() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.kind = 'restock' and exists (
    select from public.products p join public.shop_settings sh on sh.id = p.store_id
    where p.id = split_part(new.path, '/', 3)::uuid and not sh.sms_notifications_enabled
  ) then return null; end if;
  if (new.kind like 'status:%' or new.kind like 'shipment:%' or new.kind like 'pickup:%') and exists (
    select from public.orders o join public.shop_settings sh on sh.id = o.store_id
    where o.receipt_code = split_part(new.path, '/', 3) and not sh.order_push_enabled
  ) then return null; end if;
  return new;
end;
$$;

create trigger filter_customer_notification_push before insert on public.customer_push_deliveries
  for each row execute function public.filter_customer_notification_push();

create function public.customer_sms_job_authorized(p_token text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select from public.customer_push_job_secret where
    extensions.digest(token, 'sha256') = extensions.digest(p_token, 'sha256'));
$$;

create function public.claim_customer_sms_deliveries(p_token text)
returns table(id uuid, phone text, body text) language plpgsql security definer set search_path = '' as $$
begin
  if not public.customer_sms_job_authorized(p_token) then raise insufficient_privilege; end if;
  return query with batch as (
    select d.id from public.customer_sms_deliveries d
    join public.shop_settings sh on sh.id = d.store_id
    where d.claimed_at is null and d.created_at > now() - interval '1 day'
      and (d.topic <> 'order' or sh.order_sms_enabled) and (d.topic <> 'restock' or sh.restock_sms_enabled)
    order by d.created_at, d.id limit 30 for update of d skip locked
  )
  update public.customer_sms_deliveries d set claimed_at = now()
  from batch where d.id = batch.id returning d.id, d.phone, d.body;
end;
$$;

create function public.complete_customer_sms_delivery(p_token text, p_id uuid, p_accepted boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.customer_sms_job_authorized(p_token) then raise insufficient_privilege; end if;
  update public.customer_sms_deliveries set result = case when p_accepted then 'accepted' else 'failed' end
  where id = p_id and claimed_at is not null and result is null;
end;
$$;

create function public.run_customer_sms_job() returns bigint
language plpgsql security definer set search_path = '' as $$
declare request_id bigint;
begin
  delete from public.customer_sms_deliveries where created_at <= now() - interval '1 day';
  if not exists (select from public.customer_sms_deliveries d join public.shop_settings sh on sh.id = d.store_id
    where d.claimed_at is null and (d.topic <> 'order' or sh.order_sms_enabled)
      and (d.topic <> 'restock' or sh.restock_sms_enabled)) then return null; end if;
  select net.http_post(
    url := s.project_url || '/functions/v1/customer-sms',
    headers := jsonb_build_object('X-Push-Job', j.token, 'Content-Type', 'application/json'),
    body := '{}'::jsonb, timeout_milliseconds := 115000
  ) into request_id from public.nova_poshta_tracking_schedule s cross join public.customer_push_job_secret j
  where s.project_url is not null;
  return request_id;
end;
$$;

revoke all on function public.set_customer_notification_channel(uuid,text,text,boolean), public.notification_sms_phone(text),
  public.crm_sms_numbers(uuid,uuid), public.crm_sms_audience(uuid,uuid), public.queue_crm_sms(uuid,uuid,text,integer,uuid,text),
  public.set_crm_staff_sms_enabled(uuid,uuid,boolean), public.crm_staff_push_settings(uuid), public.queue_order_sms(),
  public.queue_restock_sms(), public.filter_customer_notification_push(), public.customer_sms_job_authorized(text), public.claim_customer_sms_deliveries(text),
  public.complete_customer_sms_delivery(text,uuid,boolean), public.run_customer_sms_job()
from public, anon, authenticated, service_role;
grant execute on function public.set_customer_notification_channel(uuid,text,text,boolean),
  public.crm_sms_audience(uuid,uuid), public.queue_crm_sms(uuid,uuid,text,integer,uuid,text),
  public.set_crm_staff_sms_enabled(uuid,uuid,boolean), public.crm_staff_push_settings(uuid) to authenticated;
grant execute on function public.customer_sms_job_authorized(text), public.claim_customer_sms_deliveries(text),
  public.complete_customer_sms_delivery(text,uuid,boolean) to service_role;

select cron.schedule('tatami-customer-sms', '* * * * *', 'select public.run_customer_sms_job()');
notify pgrst, 'reload schema';

-- 20261123120500_sms_outside_customer_profile.sql
create or replace function public.queue_crm_sms(p_store_id uuid, p_request_id uuid, p_message text, p_expected_count integer,
  p_customer_id uuid default null, p_expected_phone text default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  message text := btrim(p_message, E' \t\r\n');
  body_hash bytea;
  queued integer;
begin
  if not exists (select from public.store_members m where m.store_id = p_store_id
    and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then raise insufficient_privilege; end if;
  if p_request_id is null or message is null or char_length(message) not between 1 and 500
    or p_expected_count is null or p_expected_count < 1 then raise invalid_parameter_value; end if;
  body_hash := extensions.digest(jsonb_build_array(p_customer_id, p_expected_phone, message)::text, 'sha256');
  insert into public.crm_sms_requests(id, store_id, payload_hash)
  values (p_request_id, p_store_id, body_hash) on conflict (id) do nothing;
  if not found then
    select r.recipient_count into queued from public.crm_sms_requests r
    where r.id = p_request_id and r.store_id = p_store_id and r.payload_hash = body_hash;
    if not found then raise insufficient_privilege; end if;
    return queued;
  end if;

  insert into public.customer_sms_deliveries(store_id, phone, body, topic)
  select p_store_id, phone, message, 'manual' from public.crm_sms_numbers(p_store_id, p_customer_id) phone
  where p_customer_id is null or phone = public.notification_sms_phone(p_expected_phone);
  get diagnostics queued = row_count;
  if queued <> p_expected_count then
    raise sqlstate 'PT409' using message = 'SMS recipient list changed. Check it before sending.';
  end if;
  update public.crm_sms_requests set recipient_count = queued where id = p_request_id;
  return queued;
end;
$$;

alter table public.customer_notifications add column hidden_in_profile boolean not null default false;

-- Older SMS requests wrote the profile copy in the same transaction as the SMS delivery.
update public.customer_notifications n set hidden_in_profile = true
from public.customer_sms_deliveries d
join auth.users u on u.phone in (d.phone, '+' || d.phone)
where n.kind = 'manual' and d.topic = 'manual' and n.user_id = u.id
  and n.store_id = d.store_id and n.created_at = d.created_at and n.value = d.body;

alter policy "read own notifications" on public.customer_notifications
  using (user_id = auth.uid() and not hidden_in_profile);

-- 20261123120600_suppress_payment_accepted_push.sql
create or replace function public.filter_customer_notification_push() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- The order status already tells the buyer that the store has started processing the order.
  if new.kind in ('payment_status:PAID', 'payment_status:MOCK_PAID', 'status:PAID') then return null; end if;

  if new.kind = 'restock' and exists (
    select from public.products p join public.shop_settings sh on sh.id = p.store_id
    where p.id = split_part(new.path, '/', 3)::uuid and not sh.sms_notifications_enabled
  ) then return null; end if;
  if (new.kind like 'status:%' or new.kind like 'shipment:%' or new.kind like 'pickup:%') and exists (
    select from public.orders o join public.shop_settings sh on sh.id = o.store_id
    where o.receipt_code = split_part(new.path, '/', 3) and not sh.order_push_enabled
  ) then return null; end if;
  return new;
end;
$$;

delete from public.customer_push_deliveries
where kind in ('payment_status:PAID', 'payment_status:MOCK_PAID', 'status:PAID');

-- 20261123120700_dashboard_net_successful_payments.sql
create index if not exists order_returns_order_id_idx on public.order_returns(order_id);

create or replace function public.crm_dashboard_payment_stats(p_store_id uuid, p_from date, p_to date, p_currency text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not coalesce(public.is_store_member(p_store_id), false) then
    raise exception 'Access denied' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Invalid date range'; end if;

  return (select jsonb_build_object(
    'paid', count(*) filter (where c.status = 'PAID' and c.created_at is not null
      and p.status is distinct from 'REFUNDED'
      and not coalesce(refunds.whole_order_refunded, false)
      and coalesce(refunds.amount, 0) < c.total_price),
    'failed', count(*) filter (where c.status = 'FAILED' and c.created_at is not null),
    'pending', count(*) filter (where c.status = 'PENDING' and c.created_at is not null and c.expires_at > now()),
    'expired', count(*) filter (where c.status = 'PENDING' and c.created_at is not null and c.expires_at <= now()),
    'undated', count(*) filter (where c.created_at is null)
  )
  from public.online_checkouts c
  left join public.payments p on p.order_id = c.id
  left join lateral (
    select bool_or(o.split_origin_id is null and o.payment_status = 'REFUNDED') as whole_order_refunded,
      sum(greatest(coalesce(r.amount, 0), case when o.payment_status = 'REFUNDED' then o.total_price else 0 end)) as amount
    from public.orders o
    left join lateral (select sum(amount) as amount from public.order_returns where order_id = o.id) r on true
    where c.status = 'PAID' and c.created_at is not null and o.store_id = c.store_id
      and (o.id = c.id or o.split_origin_id = c.id)
  ) refunds on true
  where c.store_id = p_store_id and c.currency = p_currency
    and (c.created_at is null or (c.created_at >= (p_from::timestamp at time zone 'Europe/Kyiv')
      and c.created_at < ((p_to + 1)::timestamp at time zone 'Europe/Kyiv'))));
end;
$$;

-- 20261124160740_selected_customer_broadcast.sql
-- Keep existing RPC calls working through default arguments.
-- A null selection means all customers. An empty array selects nobody.
drop function public.queue_crm_push_broadcast(uuid, uuid, text);
drop function public.crm_push_broadcast_size(uuid);
drop function public.crm_push_broadcast_audience(uuid);
drop function public.queue_crm_sms(uuid, uuid, text, integer, uuid, text);
drop function public.crm_sms_audience(uuid, uuid);
drop function public.crm_sms_numbers(uuid, uuid);

create function public.crm_push_broadcast_audience(p_store_id uuid, p_customer_ids uuid[])
returns table(subscription_id uuid, user_id uuid)
language sql stable set search_path = '' as $$
  select s.id, s.user_id
  from public.customer_push_subscriptions s
  join public.crm_customer_keys k on k.store_id = p_store_id and k.key = 'user:' || s.user_id::text
  join auth.users u on u.id = s.user_id
  where u.deleted_at is null and not u.is_anonymous
    and (p_customer_ids is null or k.customer_id = any(p_customer_ids));
$$;

create function public.crm_push_broadcast_size(p_store_id uuid, p_customer_ids uuid[] default null)
returns integer language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (select from public.store_members m
    where m.store_id = p_store_id and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then
    raise exception 'Manager access required' using errcode = '42501';
  end if;

  return (select count(distinct a.user_id)::integer from public.crm_push_broadcast_audience(p_store_id, p_customer_ids) a);
end;
$$;

create function public.queue_crm_push_broadcast(p_store_id uuid, p_request_id uuid, p_message text, p_customer_ids uuid[] default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  message text := btrim(p_message, E' \t\r\n');
  body_hash bytea;
  recipients integer;
begin
  if not exists (select from public.store_members m
    where m.store_id = p_store_id and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then
    raise exception 'Manager access required' using errcode = '42501';
  end if;
  if p_request_id is null or message is null or char_length(message) not between 1 and 500 then
    raise exception 'Enter a notification between 1 and 500 characters.' using errcode = '22023';
  end if;

  if p_customer_ids is not null then
    p_customer_ids := array(select distinct id from unnest(p_customer_ids) as selected(id) order by id);
  end if;
  body_hash := extensions.digest(case when p_customer_ids is null then message
    else jsonb_build_array(p_customer_ids, message)::text end, 'sha256');
  insert into public.customer_push_broadcasts(id, store_id, message_hash)
  values (p_request_id, p_store_id, body_hash) on conflict (id) do nothing;
  if not found then
    select b.recipient_count into recipients from public.customer_push_broadcasts b
    where b.id = p_request_id and b.store_id = p_store_id and b.message_hash = body_hash;
    if not found then raise insufficient_privilege; end if;
    return recipients;
  end if;

  -- Lock the current devices so an opt-out can safely remove pending deliveries after this transaction.
  with devices as materialized (
    select s.id, s.user_id
    from public.crm_push_broadcast_audience(p_store_id, p_customer_ids) a
    join public.customer_push_subscriptions s on s.id = a.subscription_id
    for key share of s
  ), notices as (
    insert into public.customer_notifications(store_id, user_id, kind, value)
    select distinct p_store_id, d.user_id, 'manual', message from devices d
    returning user_id
  ), queued as (
    insert into public.customer_push_deliveries(subscription_id, kind, path)
    select d.id, 'manual:' || message, '/account' from devices d join notices n on n.user_id = d.user_id
  )
  select count(*)::integer into recipients from notices;

  update public.customer_push_broadcasts set recipient_count = recipients where id = p_request_id;
  return recipients;
end;
$$;

create function public.crm_sms_numbers(p_store_id uuid, p_customer_id uuid, p_customer_ids uuid[])
returns setof text language sql stable set search_path = '' as $$
  select distinct n.phone
  from public.crm_customers c cross join lateral (select public.notification_sms_phone(c.phone) as phone) n
  where c.store_id = p_store_id and (p_customer_id is null or c.id = p_customer_id)
    and (p_customer_ids is null or c.id = any(p_customer_ids)) and n.phone is not null;
$$;

create function public.crm_sms_audience(p_store_id uuid, p_customer_id uuid default null, p_customer_ids uuid[] default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare recipient_count integer; recipient_phone text;
begin
  if not exists (select from public.store_members m where m.store_id = p_store_id
    and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then raise insufficient_privilege; end if;
  select count(*)::integer, case when p_customer_id is not null then max(phone) end
  into recipient_count, recipient_phone from public.crm_sms_numbers(p_store_id, p_customer_id, p_customer_ids) phone;
  return jsonb_build_object('count', recipient_count, 'phone', case when recipient_phone is not null then '+' || recipient_phone end,
    'confirmed', p_customer_id is not null and recipient_count > 0 and public.crm_customer_phone_confirmed(p_store_id, p_customer_id));
end;
$$;

create function public.queue_crm_sms(p_store_id uuid, p_request_id uuid, p_message text, p_expected_count integer,
  p_customer_id uuid default null, p_expected_phone text default null, p_customer_ids uuid[] default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  message text := btrim(p_message, E' \t\r\n');
  body_hash bytea;
  queued integer;
begin
  if not exists (select from public.store_members m where m.store_id = p_store_id
    and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then raise insufficient_privilege; end if;
  if p_request_id is null or message is null or char_length(message) not between 1 and 500
    or p_expected_count is null or p_expected_count < 1 then raise invalid_parameter_value; end if;
  if p_customer_ids is not null then
    p_customer_ids := array(select distinct id from unnest(p_customer_ids) as selected(id) order by id);
  end if;
  body_hash := extensions.digest(case when p_customer_ids is null
    then jsonb_build_array(p_customer_id, p_expected_phone, message)::text
    else jsonb_build_array(p_customer_ids, p_customer_id, p_expected_phone, message)::text end, 'sha256');
  insert into public.crm_sms_requests(id, store_id, payload_hash)
  values (p_request_id, p_store_id, body_hash) on conflict (id) do nothing;
  if not found then
    select r.recipient_count into queued from public.crm_sms_requests r
    where r.id = p_request_id and r.store_id = p_store_id and r.payload_hash = body_hash;
    if not found then raise insufficient_privilege; end if;
    return queued;
  end if;

  insert into public.customer_sms_deliveries(store_id, phone, body, topic)
  select p_store_id, phone, message, 'manual' from public.crm_sms_numbers(p_store_id, p_customer_id, p_customer_ids) phone
  where p_customer_id is null or phone = public.notification_sms_phone(p_expected_phone);
  get diagnostics queued = row_count;
  if queued <> p_expected_count then
    raise sqlstate 'PT409' using message = 'SMS recipient list changed. Check it before sending.';
  end if;
  update public.crm_sms_requests set recipient_count = queued where id = p_request_id;
  return queued;
end;
$$;

revoke all on function public.crm_push_broadcast_audience(uuid, uuid[]),
  public.crm_push_broadcast_size(uuid, uuid[]), public.queue_crm_push_broadcast(uuid, uuid, text, uuid[]),
  public.crm_sms_numbers(uuid, uuid, uuid[]), public.crm_sms_audience(uuid, uuid, uuid[]),
  public.queue_crm_sms(uuid, uuid, text, integer, uuid, text, uuid[])
  from public, anon, authenticated, service_role;
grant execute on function public.crm_push_broadcast_size(uuid, uuid[]),
  public.queue_crm_push_broadcast(uuid, uuid, text, uuid[]), public.crm_sms_audience(uuid, uuid, uuid[]),
  public.queue_crm_sms(uuid, uuid, text, integer, uuid, text, uuid[]) to authenticated;

notify pgrst, 'reload schema';

-- 20261124161810_verified_sms_broadcast.sql
drop function public.queue_crm_sms(uuid, uuid, text, integer, uuid, text, uuid[]);
drop function public.crm_sms_audience(uuid, uuid, uuid[]);
drop function public.crm_sms_numbers(uuid, uuid, uuid[]);

create function public.crm_sms_numbers(p_store_id uuid, p_customer_id uuid, p_customer_ids uuid[], p_verified_only boolean)
returns setof text language sql stable set search_path = '' as $$
  select distinct n.phone
  from public.crm_customers c cross join lateral (select public.notification_sms_phone(c.phone) as phone) n
  where c.store_id = p_store_id and (p_customer_id is null or c.id = p_customer_id)
    and (p_customer_ids is null or c.id = any(p_customer_ids)) and n.phone is not null
    and (p_verified_only is not true or exists (
      select from public.crm_verified_phone_customers(p_store_id, n.phone)
    ));
$$;

create function public.crm_sms_audience(p_store_id uuid, p_customer_id uuid default null,
  p_customer_ids uuid[] default null, p_verified_only boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare recipient_count integer; recipient_phone text;
begin
  if not exists (select from public.store_members m where m.store_id = p_store_id
    and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then raise insufficient_privilege; end if;
  select count(*)::integer, case when p_customer_id is not null then max(phone) end
  into recipient_count, recipient_phone from public.crm_sms_numbers(p_store_id, p_customer_id, p_customer_ids, p_verified_only) phone;
  return jsonb_build_object('count', recipient_count, 'phone', case when recipient_phone is not null then '+' || recipient_phone end,
    'confirmed', p_customer_id is not null and recipient_count > 0 and public.crm_customer_phone_confirmed(p_store_id, p_customer_id));
end;
$$;

create function public.queue_crm_sms(p_store_id uuid, p_request_id uuid, p_message text, p_expected_count integer,
  p_customer_id uuid default null, p_expected_phone text default null, p_customer_ids uuid[] default null,
  p_verified_only boolean default false)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  message text := btrim(p_message, E' \t\r\n');
  body_hash bytea;
  queued integer;
begin
  if not exists (select from public.store_members m where m.store_id = p_store_id
    and m.user_id = auth.uid() and m.role in ('OWNER', 'MANAGER')) then raise insufficient_privilege; end if;
  if p_request_id is null or message is null or char_length(message) not between 1 and 500
    or p_expected_count is null or p_expected_count < 1 then raise invalid_parameter_value; end if;
  if p_customer_ids is not null then
    p_customer_ids := array(select distinct id from unnest(p_customer_ids) as selected(id) order by id);
  end if;
  -- Keep existing request hashes for the unfiltered audience.
  body_hash := extensions.digest(case
    when p_verified_only then jsonb_build_array(p_customer_ids, p_customer_id, p_expected_phone, message, true)::text
    when p_customer_ids is null then jsonb_build_array(p_customer_id, p_expected_phone, message)::text
    else jsonb_build_array(p_customer_ids, p_customer_id, p_expected_phone, message)::text end, 'sha256');
  insert into public.crm_sms_requests(id, store_id, payload_hash)
  values (p_request_id, p_store_id, body_hash) on conflict (id) do nothing;
  if not found then
    select r.recipient_count into queued from public.crm_sms_requests r
    where r.id = p_request_id and r.store_id = p_store_id and r.payload_hash = body_hash;
    if not found then raise insufficient_privilege; end if;
    return queued;
  end if;

  insert into public.customer_sms_deliveries(store_id, phone, body, topic)
  select p_store_id, phone, message, 'manual' from public.crm_sms_numbers(p_store_id, p_customer_id, p_customer_ids, p_verified_only) phone
  where p_customer_id is null or phone = public.notification_sms_phone(p_expected_phone);
  get diagnostics queued = row_count;
  if queued <> p_expected_count then
    raise sqlstate 'PT409' using message = 'SMS recipient list changed. Check it before sending.';
  end if;
  update public.crm_sms_requests set recipient_count = queued where id = p_request_id;
  return queued;
end;
$$;

revoke all on function public.crm_sms_numbers(uuid, uuid, uuid[], boolean),
  public.crm_sms_audience(uuid, uuid, uuid[], boolean),
  public.queue_crm_sms(uuid, uuid, text, integer, uuid, text, uuid[], boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.crm_sms_audience(uuid, uuid, uuid[], boolean),
  public.queue_crm_sms(uuid, uuid, text, integer, uuid, text, uuid[], boolean) to authenticated;

notify pgrst, 'reload schema';

-- Обновление курсов начинается по расписанию, даже если НБУ недоступен при установке.
SELECT cron.schedule('tatami-catalog-exchange-rates', '*/15 * * * *',
                     'select public.refresh_catalog_exchange_rates()');

NOTIFY pgrst, 'reload schema';
COMMIT;
