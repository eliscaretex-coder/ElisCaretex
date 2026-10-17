begin;

create or replace function public.record_customer_driver_guide_event()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_row public.customer_driver_guides%rowtype := case when tg_op='DELETE' then old else new end;
  v_customer_name text;
  v_event_type text;
  v_detail text;
begin
  select c.customer_name into v_customer_name
  from public.customers c
  where c.customer_id=v_row.customer_id;

  v_event_type := case
    when tg_op='INSERT' then 'GUIDE_ADDED'
    when tg_op='DELETE' then 'GUIDE_DELETED'
    when old.storage_path is distinct from new.storage_path then 'GUIDE_FILE_REPLACED'
    when old.active is distinct from new.active and new.active then 'GUIDE_ACTIVATED'
    when old.active is distinct from new.active and not new.active then 'GUIDE_DEACTIVATED'
    else 'GUIDE_UPDATED'
  end;
  v_detail := format('%s — %s%s',coalesce(v_customer_name,'Customer'),v_row.title,case when nullif(v_row.original_file_name,'') is not null then format(' (%s)',v_row.original_file_name) else '' end);

  insert into public.distribution_master_events(entity_table,entity_id,event_type,event_payload,recorded_by)
  values('customer_driver_guides',v_detail,v_event_type,jsonb_build_object(
    'customer_id',v_row.customer_id,
    'customer_name',v_customer_name,
    'old',case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end,
    'new',case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end
  ),auth.uid());
  return case when tg_op='DELETE' then old else new end;
end;
$$;

drop trigger if exists customer_driver_guides_history_event on public.customer_driver_guides;
create trigger customer_driver_guides_history_event
after insert or update or delete on public.customer_driver_guides
for each row execute function public.record_customer_driver_guide_event();

revoke all on function public.record_customer_driver_guide_event() from public,anon,authenticated;

commit;
