create or replace function public.filter_customer_notification_push() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- The order status already tells the buyer that the store has started processing the order.
  if new.kind in ('payment_status:PAID', 'payment_status:MOCK_PAID', 'status:PAID') then return null; end if;

  if new.kind = 'restock' and exists (
    select from public.products p join public.shop_settings sh on sh.id = p.store_id
    where p.id = split_part(new.path, '/', 3)::uuid and not sh.sms_notifications_enabled
  ) then return null; end if;
  if (new.kind like 'status:%' or new.kind like 'shipment:%' or new.kind like 'pickup:%') and exists (
    select from public.orders o join public.shop_settings sh on sh.id = o.store_id
    where o.receipt_code = split_part(new.path, '/', 3) and not sh.order_push_enabled
  ) then return null; end if;
  return new;
end;
$$;

delete from public.customer_push_deliveries
where kind in ('payment_status:PAID', 'payment_status:MOCK_PAID', 'status:PAID');
