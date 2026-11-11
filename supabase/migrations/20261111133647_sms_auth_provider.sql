create table public.sms_auth_settings (
  singleton boolean primary key default true check (singleton),
  provider text not null default 'kyivstar' check (provider in ('kyivstar', 'twilio'))
);

alter table public.sms_auth_settings enable row level security;
revoke all on public.sms_auth_settings from public, anon, authenticated;
grant select, update on public.sms_auth_settings to service_role;

insert into public.sms_auth_settings default values;
