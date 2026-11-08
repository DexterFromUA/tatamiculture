-- Create the store in a fresh Supabase database.
insert into public.stores (id, slug, name, description, contact_email, contact_phone, contact_city, currency, primary_color)
values ('11111111-1111-4111-8111-111111111111', 'tatami', 'tatami.culture', 'Спортивний одяг для тренувань, руху та щоденного ритму.', '', '', '', 'UAH', '#203f36')
on conflict (slug) do update set name = excluded.name, description = excluded.description, currency = excluded.currency;
