begin;

set local lock_timeout = '5s';
lock table public.orders in share row exclusive mode;
lock table public.order_status_history in access exclusive mode;

-- Backfilling historical events must not notify customers again.
alter table public.order_events disable trigger order_event_notification;

-- Restore the recorded customer when the matching event was attributed to the system.
with legacy_authors as (
  select order_id, status::text as status, created_at, (array_agg(author_id))[1] as author_id
  from public.order_status_history
  group by order_id, status, created_at
  having count(*) = 1 and bool_and(author_id is not null)
)
update public.order_events e
set author_id = legacy.author_id
from legacy_authors legacy
where e.order_id = legacy.order_id and e.kind = 'status' and e.new_value = legacy.status
  and e.created_at = legacy.created_at and e.author_id is null
  and not exists (
    select from public.order_events other
    where other.id <> e.id and other.order_id = e.order_id and other.kind = 'status'
      and other.new_value = e.new_value and other.created_at = e.created_at
  );

with history as (
  select h.*, row_number() over (partition by order_id, status, author_id, created_at order by id) as occurrence
  from public.order_status_history h
)
insert into public.order_events (id, order_id, kind, new_value, author_id, created_at)
select h.id, h.order_id, 'status', h.status::text, h.author_id, h.created_at
from history h
where h.occurrence > (
  select count(*) from public.order_events e
  where e.order_id = h.order_id and e.kind = 'status' and e.new_value = h.status::text
    and e.author_id is not distinct from h.author_id and e.created_at = h.created_at
);

alter table public.order_events enable trigger order_event_notification;

do $$
declare
  routine record;
  rewritten text;
  replacement text;
  legacy_write constant text := '[ \t]*insert into public[.]order_status_history[[:space:]]*[(][^;]+;';
begin
  if exists (
    select order_id, status::text, author_id, created_at from public.order_status_history
    except all
    select order_id, new_value, author_id, created_at from public.order_events where kind = 'status'
  ) then
    raise exception 'Some legacy status history is missing from order_events';
  end if;

  for routine in
    select p.proname, pg_get_functiondef(p.oid) as definition
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosrc ~ '\morder_status_history\M'
  loop
    -- Service-role calls can supply the customer even when auth.uid() is null.
    replacement := case routine.proname
      when 'cancel_customer_reservation' then $body$  update public.order_events
  set author_id = p_user_id
  where order_id = p_order_id and kind = 'status' and new_value = 'CANCELLED_BY_USER'
    and created_at = transaction_timestamp() and author_id is null;$body$
      when 'create_priced_catalog_order' then $body$  if p_user_id is not null then
    update public.order_events
    set author_id = p_user_id
    where order_id = created_order.id and kind = 'status' and new_value = created_order.status::text
      and created_at = transaction_timestamp() and author_id is null;
  end if;$body$
      when 'apply_admin_order_update' then ''
      when 'confirm_online_checkout' then ''
      when 'create_crm_order' then ''
      when 'restore_stock_and_cancel_order' then ''
      else null
    end;
    if replacement is null then
      raise exception 'Unexpected status history dependency in %', routine.proname;
    end if;
    rewritten := regexp_replace(routine.definition, legacy_write, replacement, 'i');
    if rewritten ~ '\morder_status_history\M' then
      raise exception 'Could not remove the status history dependency in %', routine.proname;
    end if;
    execute rewritten;
  end loop;
end;
$$;

drop table public.order_status_history;

notify pgrst, 'reload schema';
commit;
