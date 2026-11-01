-- `declared_value` was initially entered in minor units.  Nova Poshta's
-- declared value is expressed in UAH, so preserve existing settings while
-- changing the stored unit to hryvnias.
update public.delivery_settings
set declared_value = round(declared_value / 100.0)::integer
where declared_value >= 100;

alter table public.delivery_settings
  alter column declared_value set default 500;
