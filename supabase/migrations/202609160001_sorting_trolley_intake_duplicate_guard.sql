create or replace function public.prevent_duplicate_sorting_trolley_intake_4h()
returns trigger
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  v_existing record;
begin
  select
    sti.sorting_trolley_intake_id,
    sti.arrived_at,
    sti.trolley_code_snapshot,
    sm.display_name as operator_name
  into v_existing
  from public.sorting_trolley_intakes sti
  left join public.staff_members sm
    on sm.staff_id=sti.operator_staff_id
  where sti.trolley_id=new.trolley_id
    and sti.business_date=new.business_date
    and sti.shift_id=new.shift_id
    and coalesce(to_jsonb(sti)->>'record_status','RECORDED') <> 'CANCELLED'
    and sti.arrived_at >= coalesce(new.arrived_at,now()) - interval '4 hours'
    and sti.arrived_at <= coalesce(new.arrived_at,now()) + interval '1 minute'
  order by sti.arrived_at desc
  limit 1;

  if found then
    raise exception using
      errcode='23505',
      message=format(
        '%s was already scanned in this shift at %s%s. Use Edit/Remove on the existing receipt, or wait 4 hours before scanning it again.',
        coalesce(new.trolley_code_snapshot,v_existing.trolley_code_snapshot,'This trolley'),
        to_char(v_existing.arrived_at,'HH24:MI'),
        case when v_existing.operator_name is null then '' else ' by ' || v_existing.operator_name end
      );
  end if;

  return new;
end;
$$;

drop trigger if exists sorting_trolley_intakes_no_duplicate_4h
  on public.sorting_trolley_intakes;

create trigger sorting_trolley_intakes_no_duplicate_4h
before insert on public.sorting_trolley_intakes
for each row
execute function public.prevent_duplicate_sorting_trolley_intake_4h();

comment on function public.prevent_duplicate_sorting_trolley_intake_4h() is
  'Blocks the same physical trolley from being received twice in the same Sorting shift within four hours while preserving correction workflows.';
