create table public.storefront_contacts (
  store_id uuid primary key references public.stores(id) on delete cascade,
  email text not null default '' check (length(email) <= 254),
  instagram_url text not null default '' check (length(instagram_url) <= 500 and (instagram_url = '' or instagram_url ~* '^https://(www\.)?instagram\.com/[A-Za-z0-9._]+/?$'))
);

alter table public.storefront_contacts enable row level security;
grant select on public.storefront_contacts to anon, authenticated;
grant insert, update, delete on public.storefront_contacts to authenticated;
create policy "public read storefront contacts" on public.storefront_contacts for select to anon, authenticated using (true);
create policy "staff manage storefront contacts" on public.storefront_contacts for all to authenticated
  using (public.is_store_member(store_id)) with check (public.is_store_member(store_id));

insert into public.storefront_contacts (store_id, email, instagram_url)
select id, 'shalimovvlad@gmail.com', 'https://www.instagram.com/tatami.culture'
from public.stores where slug = 'tatami'
on conflict (store_id) do nothing;

notify pgrst, 'reload schema';
