-- Governed onboarding: sequential server-generated employee codes and a
-- creation API that never accepts a caller-provided code.

create sequence if not exists public.staff_employee_code_seq;

do $$
declare v_next bigint;
begin
 select coalesce(max((substring(employee_code from '^EMP-([0-9]+)$'))::bigint),0)+1 into v_next
 from public.staff_members where employee_code ~ '^EMP-[0-9]+$';
 perform setval('public.staff_employee_code_seq',greatest(v_next,1),false);
end $$;

create or replace function public.generate_staff_employee_code()
returns text language plpgsql volatile security definer set search_path=public,auth,pg_temp as $$
declare v_code text;
begin
 loop
   v_code:='EMP-'||lpad(nextval('public.staff_employee_code_seq')::text,5,'0');
   exit when not exists(select 1 from public.staff_members where employee_code=v_code);
 end loop;
 return v_code;
end; $$;

revoke all on function public.generate_staff_employee_code() from public,anon,authenticated;

create or replace function public.create_staff_master_auto_code(
 p_display_name text,p_default_shift_code text default null,p_primary_role_code text default null,
 p_default_area_code text default null,p_default_station_code text default null,p_roster_eligible boolean default true,
 p_cover_role_codes text[] default array[]::text[],p_fire_training boolean default false,p_first_aid_training boolean default false,
 p_eod_capable boolean default false,p_joined_on date default null,p_notes text default null,p_change_reason text default null,
 p_source_application text default 'STAFF_MASTER_UI'
) returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
begin
 return public.create_staff_master(p_display_name,null,p_default_shift_code,p_primary_role_code,p_default_area_code,p_default_station_code,
   p_roster_eligible,p_cover_role_codes,p_fire_training,p_first_aid_training,p_eod_capable,p_joined_on,p_notes,p_change_reason,p_source_application);
end; $$;

revoke all on function public.create_staff_master_auto_code(text,text,text,text,text,boolean,text[],boolean,boolean,boolean,date,text,text,text) from public,anon;
grant execute on function public.create_staff_master_auto_code(text,text,text,text,text,boolean,text[],boolean,boolean,boolean,date,text,text,text) to authenticated;
