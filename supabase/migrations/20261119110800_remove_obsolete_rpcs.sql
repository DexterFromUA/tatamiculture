begin;

drop function public.cancel_merged_unpaid_order(uuid);
drop function public.cancel_unpaid_order(uuid);
drop function public.change_merged_order_status(uuid, public.order_status);
drop function public.change_order_status(uuid, public.order_status);
drop function public.create_store_order(uuid, jsonb, text, text, text, text, text, text, text, text, text);
drop function public.nova_poshta_order_weight_grams(uuid);
drop function public.record_order_return(uuid, integer, text);
drop function public.set_order_cost(uuid, integer);

notify pgrst, 'reload schema';
commit;
