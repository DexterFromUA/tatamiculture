create function public.mark_all_notifications_read(p_store_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.customer_notifications
  set read_at = now()
  where user_id = auth.uid() and store_id = p_store_id and read_at is null;

  -- Restock notices are one-time subscriptions. Dismiss delivered notices only.
  delete from public.restock_subscriptions as subscription
  using public.product_variants as variant, public.products as product
  where subscription.user_id = auth.uid()
    and subscription.notified_at is not null
    and subscription.variant_id = variant.id
    and variant.product_id = product.id
    and product.store_id = p_store_id;
end;
$$;
revoke all on function public.mark_all_notifications_read(uuid) from public;
grant execute on function public.mark_all_notifications_read(uuid) to authenticated;
