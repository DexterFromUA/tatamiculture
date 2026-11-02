-- Customers use receipt_events, which returns only public event fields.
-- Direct access to the internal journal (costs and staff author IDs) is staff-only.
drop policy "read own or managed events" on public.order_events;
create policy "staff read internal events" on public.order_events for select to authenticated using (
  exists(select 1 from public.orders o where o.id=order_id and public.is_store_member(o.store_id))
);
