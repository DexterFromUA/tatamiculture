alter table public.orders
  drop constraint monobank_test_order_has_no_fulfilment,
  drop constraint test_payment_has_no_fulfilment,
  add constraint test_payment_order_status_check check (
    (payment_test_mode is not true and not monobank_test_mode)
    or status in ('PENDING', 'PAID', 'CANCELLED_BY_USER', 'CANCELLED_BY_STORE')
  );
