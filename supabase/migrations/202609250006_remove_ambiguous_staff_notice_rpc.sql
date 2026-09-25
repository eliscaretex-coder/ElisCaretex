-- PostgREST cannot resolve the old five-argument overload when the new
-- six-argument version also has a default final argument.
drop function if exists public.send_staff_notice(text,text,text,boolean,uuid[]);
notify pgrst,'reload schema';
