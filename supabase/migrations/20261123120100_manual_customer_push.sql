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
