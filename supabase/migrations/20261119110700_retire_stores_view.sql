begin;

set local lock_timeout = '5s';
drop view public.stores;

notify pgrst, 'reload schema';
commit;
