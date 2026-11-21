-- Commit the enum additions before using the new values in data or constraints.
alter type public.order_status add value if not exists 'WAITING_FOR_STOCK';
alter type public.order_status add value if not exists 'PREPARING_SHIPMENT';
alter type public.order_status add value if not exists 'IN_TRANSIT';
alter type public.order_status add value if not exists 'COMPLETED';
