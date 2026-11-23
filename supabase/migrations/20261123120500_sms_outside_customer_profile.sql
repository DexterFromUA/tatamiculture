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
