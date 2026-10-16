begin;

do $$
declare
  v_view text;
  v_options text[];
begin
  foreach v_view in array array[
    'v_active_customers',
    'v_customer_management',
    'v_customer_distribution_management',
    'v_customer_schedule_history',
    'v_distribution_current_schedule',
    'v_finish_current_schedule',
    'v_mop_current_schedule'
  ] loop
    select c.reloptions into v_options
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = v_view;

    if not ('security_invoker=true' = any(coalesce(v_options, array[]::text[]))) then
      raise exception 'Validation failed: %.% is not security invoker.', 'public', v_view;
    end if;
    if has_table_privilege('anon', format('public.%I', v_view), 'select') then
      raise exception 'Validation failed: anon can select public.%.', v_view;
    end if;
  end loop;

  if has_function_privilege('anon', 'public.create_customer(text,text,text,numeric,integer,text,text,text[],text,text)', 'execute')
     or has_function_privilege('anon', 'public.get_distribution_roster_context(date)', 'execute')
     or has_function_privilege('anon', 'public.update_customer(uuid,integer,text,text,text,numeric,integer,text,text,text[],text,text)', 'execute') then
    raise exception 'Validation failed: anon retains an internal RPC grant.';
  end if;

  if not has_function_privilege('anon', 'public.get_published_production_roster_portal(text)', 'execute')
     or not has_function_privilege('anon', 'public.submit_production_roster_leave_request(text,uuid,text,date,date,text)', 'execute') then
    raise exception 'Validation failed: a token-protected public roster RPC lost anon access.';
  end if;
end
$$;

rollback;
