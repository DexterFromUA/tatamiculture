do $$
declare
  definition text;
  old_condition text := '(p_status = ''ALL'' or (p_status = ''NO_TTN''';
  new_condition text := '(p_status = ''ALL'' or (p_status = ''NEW'' and o.is_new) or (p_status = ''NO_TTN''';
begin
  select pg_get_functiondef('public.crm_orders_page(uuid,integer,integer,text,text,date,date,uuid[],uuid)'::regprocedure) into definition;
  if position(old_condition in definition) = 0 then
    raise exception 'Unexpected crm_orders_page definition; new order filter was not installed';
  end if;
  execute replace(definition, old_condition, new_condition);
end;
$$;
