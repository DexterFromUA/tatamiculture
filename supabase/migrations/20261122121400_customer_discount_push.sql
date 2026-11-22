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
