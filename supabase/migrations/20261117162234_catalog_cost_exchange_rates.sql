create extension if not exists http with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

create table public.catalog_exchange_rates (
  currency text primary key check (currency in ('USD', 'EUR', 'PLN')),
  uah_rate numeric not null check (uah_rate > 0),
  rate_date date not null
);

alter table public.catalog_exchange_rates enable row level security;
revoke all on public.catalog_exchange_rates from public, anon, authenticated;
grant select on public.catalog_exchange_rates to authenticated;
create policy "authenticated read catalogue exchange rates"
  on public.catalog_exchange_rates for select to authenticated using (true);

-- Existing rows retain their UAH value in cost_amount.
alter table public.product_costs
  add column currency text not null default 'UAH' check (currency in ('UAH', 'USD', 'EUR', 'PLN')),
  add column source_amount integer check (source_amount >= 0),
  add check (currency = 'UAH' or source_amount is not null);
alter table public.variant_costs
  add column currency text not null default 'UAH' check (currency in ('UAH', 'USD', 'EUR', 'PLN')),
  add column source_amount integer check (source_amount >= 0),
  add check (currency = 'UAH' or source_amount is not null);

create function public.refresh_catalog_exchange_rates()
returns void language plpgsql set search_path = '' as $$
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

revoke all on function public.refresh_catalog_exchange_rates() from public, anon, authenticated;
select cron.schedule('tatami-catalog-exchange-rates', '*/15 * * * *', 'select public.refresh_catalog_exchange_rates()');

create function public.catalog_cost_in_uah(p_amount integer, p_currency text)
returns numeric language sql stable set search_path = '' as $$
  select case when p_currency = 'UAH' then p_amount::numeric
    else round(p_amount * (select r.uah_rate from public.catalog_exchange_rates r where r.currency = p_currency))
  end;
$$;
revoke all on function public.catalog_cost_in_uah(integer, text) from public, anon;
grant execute on function public.catalog_cost_in_uah(integer, text) to authenticated;

create function public.save_catalog_costs_in_currency(
  p_product_id uuid, p_update_default boolean, p_default_cost integer, p_default_currency text, p_variant_costs jsonb
)
returns void language plpgsql security invoker set search_path = '' as $$
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
revoke all on function public.save_catalog_costs_in_currency(uuid, boolean, integer, text, jsonb) from public, anon;
grant execute on function public.save_catalog_costs_in_currency(uuid, boolean, integer, text, jsonb) to authenticated;

create or replace function public.snapshot_item_cost()
returns trigger language plpgsql security definer set search_path = '' as $$
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

notify pgrst, 'reload schema';
