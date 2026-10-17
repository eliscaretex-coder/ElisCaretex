do $$
declare
  v_definition text;
begin
  if to_regprocedure('public.preserve_mop_terminal_staff_attribution()') is null then
    raise exception 'MOP terminal staff attribution trigger function is missing.';
  end if;

  if not exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'sorting_mop_production_batches'
      and t.tgname = 'preserve_mop_terminal_staff_on_batch_insert'
      and not t.tgisinternal
  ) then
    raise exception 'MOP batch attribution trigger is missing.';
  end if;

  if not exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'production_flow_external_batches'
      and t.tgname = 'preserve_mop_terminal_staff_on_abs_insert'
      and not t.tgisinternal
  ) then
    raise exception 'MOP ABS attribution trigger is missing.';
  end if;

  select lower(pg_get_functiondef('public.preserve_mop_terminal_staff_attribution()'::regprocedure))
    into v_definition;

  if position('new.recorded_by_staff_id := new.operator_staff_id' in v_definition) = 0
     or position('new.supersedes_external_batch_id is not null' in v_definition) = 0
     or position('mop.operator_staff_id' in v_definition) = 0 then
    raise exception 'MOP terminal staff attribution fallback is incomplete.';
  end if;

  if has_function_privilege('authenticated',
       'public.preserve_mop_terminal_staff_attribution()', 'EXECUTE') then
    raise exception 'Trigger-only MOP attribution function must not be directly executable by authenticated users.';
  end if;
end;
$$;
