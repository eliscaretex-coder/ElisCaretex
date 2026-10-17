begin;

-- Workstation accounts intentionally do not have a staff_members row. During a
-- MOP correction the operational operator is nevertheless known from the MOP
-- batch. Preserve that attribution on the append-only revision and on the ABS
-- evidence automatically superseded by the correction.
create or replace function public.preserve_mop_terminal_staff_attribution()
returns trigger
language plpgsql
set search_path = public, auth, pg_temp
as $$
begin
  if tg_table_name = 'sorting_mop_production_batches' then
    if new.recorded_by_staff_id is null then
      new.recorded_by_staff_id := new.operator_staff_id;
    end if;
    return new;
  end if;

  if tg_table_name = 'production_flow_external_batches'
     and new.recorded_by_staff_id is null
     and new.external_system_code = 'ABS'
     and new.supersedes_external_batch_id is not null then
    select old_batch.recorded_by_staff_id
      into new.recorded_by_staff_id
    from public.production_flow_external_batches old_batch
    where old_batch.production_flow_external_batch_id = new.supersedes_external_batch_id;

    if new.recorded_by_staff_id is null then
      select mop.operator_staff_id
        into new.recorded_by_staff_id
      from public.sorting_mop_production_batches mop
      where mop.production_flow_item_id = new.production_flow_item_id
        and mop.status = 'RECORDED'
      order by mop.revision_no desc, mop.recorded_at desc, mop.mop_production_batch_id desc
      limit 1;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists preserve_mop_terminal_staff_on_batch_insert
  on public.sorting_mop_production_batches;
create trigger preserve_mop_terminal_staff_on_batch_insert
before insert on public.sorting_mop_production_batches
for each row execute function public.preserve_mop_terminal_staff_attribution();

drop trigger if exists preserve_mop_terminal_staff_on_abs_insert
  on public.production_flow_external_batches;
create trigger preserve_mop_terminal_staff_on_abs_insert
before insert on public.production_flow_external_batches
for each row execute function public.preserve_mop_terminal_staff_attribution();

revoke all on function public.preserve_mop_terminal_staff_attribution()
  from public, anon, authenticated;

comment on function public.preserve_mop_terminal_staff_attribution()
  is 'Preserves the recorded MOP operator as staff attribution when a workstation-authenticated correction creates an append-only MOP revision and synchronized ABS evidence.';

commit;
