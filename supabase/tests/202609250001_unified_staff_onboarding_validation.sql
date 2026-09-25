begin;
select plan(3);
select has_sequence('public','staff_employee_code_seq','employee code sequence exists');
select has_function('public','create_staff_master_auto_code',array['text','text','text','text','text','boolean','text[]','boolean','boolean','boolean','date','text','text','text'],'auto-code staff creation exists');
select function_privs_are('public','create_staff_master_auto_code',array['text','text','text','text','text','boolean','text[]','boolean','boolean','boolean','date','text','text','text'],'authenticated',array['EXECUTE'],'authenticated staff managers can use governed creation');
select * from finish();
rollback;
