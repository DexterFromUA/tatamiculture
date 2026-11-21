begin;

create function public.can_review_order_refund(p_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select from public.order_cancellation_refunds
    where id = p_id and status = 'processing' and method = 'automatic'
      and updated_at <= now() - interval '15 minutes');
$$;
revoke all on function public.can_review_order_refund(uuid) from public, anon, authenticated;
grant execute on function public.can_review_order_refund(uuid) to service_role;

create function public.resolve_order_cancellation_refund(
  p_order_id uuid, p_attempt_id uuid, p_actor uuid, p_resolution text
) returns text language plpgsql security definer set search_path = '' as $$
declare
  target public.orders;
  operation public.order_cancellation_refunds;
  outcome text;
begin
  select * into target from public.orders where id = p_order_id for update;
  if not found or not exists (select from public.store_members
      where store_id = target.store_id and user_id = p_actor) then
    raise insufficient_privilege using message = 'Store staff access required';
  end if;
  if target.status not in ('CANCELLED_BY_STORE', 'CANCELLED_BY_USER')
    or coalesce(target.payment_test_mode, target.monobank_test_mode) then
    raise exception 'Only cancelled live orders can be refunded';
  end if;
  select * into operation from public.order_cancellation_refunds where order_id = target.id for update;
  if operation.id is distinct from p_attempt_id or not public.can_review_order_refund(operation.id) then
    raise exception 'The refund has changed or is still being processed. Check its status again.';
  end if;
  if p_resolution = 'record_paid' then
    update public.order_cancellation_refunds set requested_by = p_actor, method = 'manual' where id = operation.id;
    outcome := public.finish_order_cancellation_refund(operation.id, 'completed');
  elsif p_resolution = 'not_started' then
    outcome := public.finish_order_cancellation_refund(operation.id, 'failed',
      'The bank did not start this refund. You can try again.');
  else
    raise exception 'Invalid refund resolution';
  end if;
  insert into public.order_events (order_id, kind, new_value, author_id)
    values (target.id, 'refund_review', case when p_resolution = 'record_paid'
      then 'Refund recorded after checking the bank' else 'The bank did not start this refund. You can try again.' end, p_actor);
  return outcome;
end;
$$;
revoke all on function public.resolve_order_cancellation_refund(uuid, uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.resolve_order_cancellation_refund(uuid, uuid, uuid, text) to service_role;

notify pgrst, 'reload schema';

commit;
