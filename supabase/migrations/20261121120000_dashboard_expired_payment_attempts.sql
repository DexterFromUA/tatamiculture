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
  where store_id = p_store_id and not test_mode and currency = p_currency
    and (created_at is null or (created_at >= (p_from::timestamp at time zone 'Europe/Kyiv')
      and created_at < ((p_to + 1)::timestamp at time zone 'Europe/Kyiv'))));
end;
$$;
