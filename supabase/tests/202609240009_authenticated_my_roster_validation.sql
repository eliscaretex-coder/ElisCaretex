do $$ begin
 if to_regprocedure('public.get_my_account_roster_portal()') is null then raise exception 'My Roster RPC is missing'; end if;
 if to_regprocedure('public.get_my_account_leave_requests()') is null then raise exception 'My leave list RPC is missing'; end if;
 if to_regprocedure('public.submit_my_account_leave_request(text,date,date,text)') is null then raise exception 'My leave submission RPC is missing'; end if;
 if has_function_privilege('anon','public.get_my_account_roster_portal()','execute') then raise exception 'anon must not access authenticated My Roster'; end if;
 if has_function_privilege('anon','public.submit_my_account_leave_request(text,date,date,text)','execute') then raise exception 'anon must not submit authenticated leave requests'; end if;
end $$;
