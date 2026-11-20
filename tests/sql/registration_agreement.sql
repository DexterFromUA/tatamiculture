-- All synthetic Auth users and acceptance records are rolled back; no SMS is sent.
begin;
do $$
declare
  buyer uuid := gen_random_uuid();
  legacy uuid := gen_random_uuid();
  rejected boolean := false;
begin
  insert into auth.users(id, raw_user_meta_data)
  values (buyer, '{"name":"Agreement test","terms_accepted":true,"terms_version":"2026-11-20"}'::jsonb);
  if not exists (select 1 from public.user_agreement_acceptances where user_id=buyer and version='2026-11-20' and accepted_at is not null) then
    raise exception 'Acceptance was not captured';
  end if;
  update auth.users set raw_user_meta_data='{}'::jsonb where id=buyer;
  if not exists (select 1 from public.user_agreement_acceptances where user_id=buyer) then
    raise exception 'Editable metadata affected acceptance evidence';
  end if;
  insert into auth.users(id) values (legacy);
  if exists (select 1 from public.user_agreement_acceptances where user_id=legacy) then
    raise exception 'Legacy account was falsely marked as accepting';
  end if;
  begin
    insert into auth.users(id, raw_user_meta_data)
    values (gen_random_uuid(), '{"terms_accepted":false,"terms_version":"2026-11-20"}'::jsonb);
  exception when check_violation then rejected := true;
  end;
  if not rejected then raise exception 'False acceptance was accepted'; end if;
  rejected := false;
  begin
    insert into auth.users(id, raw_user_meta_data)
    values (gen_random_uuid(), '{"terms_accepted":true,"terms_version":"1900-01-01"}'::jsonb);
  exception when check_violation then rejected := true;
  end;
  if not rejected then raise exception 'Unknown agreement version was accepted'; end if;
  if has_table_privilege('authenticated', 'public.user_agreement_acceptances', 'insert')
     or has_table_privilege('authenticated', 'public.user_agreement_acceptances', 'update')
     or has_table_privilege('anon', 'public.user_agreement_acceptances', 'select') then
    raise exception 'Acceptance permissions are too broad';
  end if;
  perform set_config('request.jwt.claim.sub', buyer::text, true);
  set local role authenticated;
  if (select count(*) from public.user_agreement_acceptances) <> 1
     or exists (select 1 from public.user_agreement_acceptances where user_id <> buyer) then
    raise exception 'Acceptance RLS exposed another user or hid the owner record';
  end if;
  begin
    update public.user_agreement_acceptances set accepted_at = now() where user_id=buyer;
    raise exception 'A user was allowed to edit acceptance evidence';
  exception when insufficient_privilege then null;
  end;
  reset role;
  if not exists (select 1 from public.legal_agreement_versions where version='2026-11-20' and document->'seller'->>'taxId'='3620003508') then
    raise exception 'Published agreement text is missing';
  end if;
end;
$$;
rollback;
