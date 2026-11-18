-- Create the store in a fresh Supabase database.
insert into public.stores (id, slug, name, currency)
values ('11111111-1111-4111-8111-111111111111', 'tatami', 'tatami.culture', 'UAH')
on conflict (slug) do update set name = excluded.name, currency = excluded.currency;
