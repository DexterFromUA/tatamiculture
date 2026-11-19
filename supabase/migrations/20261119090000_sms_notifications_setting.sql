begin;

alter table public.stores
  add column sms_notifications_enabled boolean not null default true;

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

notify pgrst, 'reload schema';

commit;
