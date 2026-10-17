do $$
declare
  v_definition text;
begin
  if to_regprocedure('public.publish_distribution_roster_week(uuid,integer)') is null then
    raise exception 'Distribution roster publication function is missing.';
  end if;

  select lower(pg_get_functiondef(
    'public.publish_distribution_roster_week(uuid,integer)'::regprocedure
  )) into v_definition;

  if position('assignment_status = ''planned''' in v_definition) = 0
     or position('and assignment_status = ''planned''' in v_definition) = 0 then
    raise exception 'Distribution roster publication must create route runs only for PLANNED entries.';
  end if;

  if position('e.route_id is null' in v_definition) = 0 then
    raise exception 'Planned Distribution roster entries must validate route_id before publication.';
  end if;

  if has_function_privilege('anon',
       'public.publish_distribution_roster_week(uuid,integer)', 'EXECUTE') then
    raise exception 'Anonymous users must not publish Distribution rosters.';
  end if;

  if not has_function_privilege('authenticated',
       'public.publish_distribution_roster_week(uuid,integer)', 'EXECUTE') then
    raise exception 'Authenticated application users need guarded RPC execution.';
  end if;
end;
$$;
