-- Подставь User UID своего аккаунта из Authentication → Users.
-- Выполни файл в SQL Editor проекта с уже созданным магазином Tatami.
do $$
declare
  owner_id constant uuid := null; -- Замени null на User UID в одинарных кавычках.
  tatami_store_id uuid;
begin
  if owner_id is null then
    raise exception 'Укажи User UID из Authentication → Users';
  end if;

  select id into tatami_store_id from public.shop_settings;
  if not found then
    raise exception 'Настройки магазина Tatami не найдены в этом проекте';
  end if;

  if not exists (select from public.profiles where id = owner_id) then
    raise exception 'Профиль пользователя % не найден. Проверь User UID и регистрацию в этом проекте', owner_id;
  end if;

  insert into public.store_members (store_id, user_id, role)
  values (tatami_store_id, owner_id, 'OWNER')
  on conflict (store_id, user_id) do update set role = excluded.role
  where store_members.role is distinct from excluded.role;
end;
$$;
