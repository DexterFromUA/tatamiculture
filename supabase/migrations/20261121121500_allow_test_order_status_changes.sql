begin;

alter table public.orders drop constraint test_payment_order_status_check;

notify pgrst, 'reload schema';

commit;
