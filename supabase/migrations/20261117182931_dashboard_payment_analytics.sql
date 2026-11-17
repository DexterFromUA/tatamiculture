-- Keep undated historical attempts unknown instead of assigning them today's date.
alter table public.online_checkouts add column created_at timestamptz;
alter table public.online_checkouts alter column created_at set default now();
create index online_checkouts_dashboard_period on public.online_checkouts(store_id,created_at) where not test_mode;

create function public.crm_dashboard_payment_stats(p_store_id uuid, p_from date, p_to date, p_currency text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
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
revoke all on function public.crm_dashboard_payment_stats(uuid,date,date,text) from public,anon;
grant execute on function public.crm_dashboard_payment_stats(uuid,date,date,text) to authenticated;
