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
