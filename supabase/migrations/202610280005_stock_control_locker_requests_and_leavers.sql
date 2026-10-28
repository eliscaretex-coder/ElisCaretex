-- =====================================================================
-- ElisCaretex V2
-- Stock Control: locker key requests and leaving dates
--
-- Owner request 2026-10-28, after trying My PPE & Uniform with a staff
-- account:
-- * Staff see their locker key. Without a key, or with a problem (lost key,
--   wrong locker), they send a locker key request. A supervisor or manager
--   answers it by assigning a free locker, marking it as solved, or
--   declining it.
-- * When Staff Master has a last working day for the person (a scheduled
--   or past deactivation), My PPE & Uniform tells them to return their PPE
--   and key, and Stock Control lists them under Returns due before they
--   leave.
-- Depends on 202610280003_stock_control.sql.
-- =====================================================================

begin;

alter table public.stock_requests
  add column request_kind text not null default 'ITEMS' check (request_kind in ('ITEMS','LOCKER_KEY')),
  add column locker_id uuid references public.stock_lockers(locker_id) on delete restrict;

comment on column public.stock_requests.request_kind is 'ITEMS: PPE and uniform lines. LOCKER_KEY: a locker key request (no lines).';
comment on column public.stock_requests.locker_id is 'Locker assigned when a LOCKER_KEY request was answered with a locker.';

create index stock_requests_open_kind_idx on public.stock_requests(staff_id,request_kind) where request_status in ('REQUESTED','APPROVED');

create or replace function public.stock_request_json(p_request public.stock_requests)
returns jsonb language sql stable security definer set search_path=public,auth,pg_temp as $$
  select to_jsonb(p_request) || jsonb_build_object(
    'staff_name',(select display_name from public.staff_members where staff_id=p_request.staff_id),
    'employee_code',(select employee_code from public.staff_members where staff_id=p_request.staff_id),
    'decided_by_name',(select coalesce(ap.display_name,u.email) from auth.users u left join public.account_access_profiles ap on ap.auth_user_id=u.id where u.id=p_request.decided_by),
    'locker_label',(select label from public.stock_lockers where locker_id=p_request.locker_id),
    'current_lockers',coalesce((select jsonb_agg(l.label order by l.label) from public.stock_lockers l
      where l.locker_status='ASSIGNED' and (l.staff_id=p_request.staff_id
        or l.driver_id in (select d.driver_id from public.distribution_drivers d where d.staff_id=p_request.staff_id and d.deleted_at is null))),'[]'::jsonb),
    'issued_by_name',(select coalesce(ap.display_name,u.email) from auth.users u left join public.account_access_profiles ap on ap.auth_user_id=u.id where u.id=p_request.issued_by),
    'lines',coalesce((select jsonb_agg(jsonb_build_object('line_id',l.line_id,'item_id',l.item_id,'item_name',i.item_name,'category_name',c.category_name,
        'unit',i.unit,'size',l.size,'qty',l.qty,'issued_qty',l.issued_qty,'stock_qty',i.stock_qty,'size_options',i.size_options) order by l.line_id)
      from public.stock_request_lines l join public.stock_items i on i.item_id=l.item_id join public.stock_categories c on c.category_code=i.category_code
      where l.request_id=p_request.request_id),'[]'::jsonb))
$$;

create or replace function public.get_my_stock()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_staff uuid:=public.current_staff_id(); v_drivers uuid[];
begin
  if not public.can_request_stock_items() then raise exception using errcode='42501',message='Sign in with a staff account linked to Staff Master to request PPE and uniforms.'; end if;
  -- A driver account also holds what was issued to its Distribution driver record.
  select coalesce(array_agg(driver_id),array[]::uuid[]) into v_drivers from public.distribution_drivers where staff_id=v_staff and deleted_at is null;
  return jsonb_build_object(
    'staff_name',(select display_name from public.staff_members where staff_id=v_staff),
    -- Last working day set in Staff Master: items and keys must be returned.
    'leaving_on',(select deactivated_on from public.staff_members where staff_id=v_staff),
    'can_view_stock',public.can_view_stock(),
    'can_operate_stock',public.can_operate_stock(),
    'holding',coalesce((select jsonb_agg(to_jsonb(b) order by b.item_type,b.description) from public.stock_ppe_balances() b where b.staff_id=v_staff or b.driver_id=any(v_drivers)),'[]'::jsonb),
    'lockers',coalesce((select jsonb_agg(jsonb_build_object('label',l.label,'assigned_at',l.assigned_at) order by l.label) from public.stock_lockers l
      where l.locker_status='ASSIGNED' and (l.staff_id=v_staff or l.driver_id=any(v_drivers))),'[]'::jsonb),
    -- Exact quantities stay with the store; staff only see whether it is available.
    'items',coalesce((select jsonb_agg(jsonb_build_object('item_id',i.item_id,'item_name',i.item_name,'category_code',i.category_code,'category_name',c.category_name,
        'unit',i.unit,'size_options',i.size_options,'available',i.stock_qty>0) order by c.display_order,i.item_name)
      from public.stock_items i join public.stock_categories c on c.category_code=i.category_code where i.active and i.requestable),'[]'::jsonb),
    'requests',coalesce((select jsonb_agg(public.stock_request_json(r) order by r.created_at desc) from (
      select * from public.stock_requests where staff_id=v_staff and (request_status in ('REQUESTED','APPROVED') or created_at>=now()-interval '180 days') order by created_at desc limit 30) r),'[]'::jsonb),
    'history',coalesce((select jsonb_agg(jsonb_build_object('recorded_at',e.recorded_at,'ppe_action',e.ppe_action,'item_type',e.item_type,'description',e.description,'size',e.size,'qty',e.qty) order by e.recorded_at desc)
      from (select * from public.stock_ppe_events where staff_id=v_staff or driver_id=any(v_drivers) order by recorded_at desc limit 50) e),'[]'::jsonb)
  );
end;$$;

-- A locker key request: without a key, or a problem with the key held.
create or replace function public.submit_my_locker_request(p_reason text default null)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_staff uuid:=public.current_staff_id(); v_request public.stock_requests%rowtype; v_reason text:=public.stock_clean_text(p_reason,500); v_has_key boolean;
begin
  if not public.can_request_stock_items() then raise exception using errcode='42501',message='Sign in with a staff account linked to Staff Master to request PPE and uniforms.'; end if;
  if exists(select 1 from public.stock_requests where staff_id=v_staff and request_kind='LOCKER_KEY' and request_status in ('REQUESTED','APPROVED')) then
    raise exception using errcode='22023',message='You already have an open locker key request.';
  end if;
  if (select count(*) from public.stock_requests where staff_id=v_staff and request_status in ('REQUESTED','APPROVED'))>=5 then
    raise exception using errcode='22023',message='You already have 5 open requests. Wait for them to be answered before asking again.';
  end if;
  select exists(select 1 from public.stock_lockers l where l.locker_status='ASSIGNED' and (l.staff_id=v_staff
    or l.driver_id in (select d.driver_id from public.distribution_drivers d where d.staff_id=v_staff and d.deleted_at is null))) into v_has_key;
  if v_has_key and v_reason is null then raise exception using errcode='22023',message='Tell your supervisor what is wrong with your key.'; end if;
  insert into public.stock_requests(staff_id,requested_by,reason,request_kind)
  values(v_staff,auth.uid(),coalesce(v_reason,'I need a locker key.'),'LOCKER_KEY') returning * into v_request;
  return public.stock_request_json(v_request);
end;$$;

-- ASSIGN: give the person a free locker and close the request. With
--         p_return_current, the keys the person holds now are returned
--         first (wrong locker, or a key swapped for another one).
-- SOLVED: close the request with a note (for example, key replaced or the
--         record corrected in Locker keys).
-- Declining uses decide_stock_request(..., 'REJECT', ...).
create or replace function public.resolve_locker_request(p_request_id uuid,p_action text,p_locker_id uuid,p_note text,p_row_version integer,p_return_current boolean default false)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_old public.stock_requests%rowtype; v_row public.stock_requests%rowtype; v_locker public.stock_lockers%rowtype;
  v_action text:=upper(trim(coalesce(p_action,''))); v_note text:=public.stock_clean_text(p_note,500); v_name text; v_old_key public.stock_lockers%rowtype;
begin
  perform public.stock_require('OPERATE');
  select * into v_old from public.stock_requests where request_id=p_request_id for update;
  if not found then raise exception using errcode='P0002',message='Request not found.'; end if;
  if v_old.request_kind<>'LOCKER_KEY' then raise exception using errcode='22023',message='This is not a locker key request.'; end if;
  if v_old.row_version<>p_row_version then raise exception using errcode='40001',message='This request was changed by someone else. Reload and try again.'; end if;
  if v_old.request_status not in ('REQUESTED','APPROVED') then raise exception using errcode='22023',message='This request was already answered.'; end if;
  if v_action='ASSIGN' then
    v_name:=public.stock_holder_name(v_old.staff_id,null,true);
    select * into v_locker from public.stock_lockers where locker_id=p_locker_id for update;
    if not found then raise exception using errcode='P0002',message='Locker not found.'; end if;
    if v_locker.locker_status<>'AVAILABLE' then raise exception using errcode='22023',message=format('Locker %s is not available.',v_locker.label); end if;
    if coalesce(p_return_current,false) then
      for v_old_key in select * from public.stock_lockers l where l.locker_status='ASSIGNED' and l.staff_id=v_old.staff_id for update loop
        update public.stock_lockers set locker_status='AVAILABLE',staff_id=null,driver_id=null,holder_name=null,assigned_at=null,
          updated_at=now(),updated_by=auth.uid(),row_version=row_version+1 where locker_id=v_old_key.locker_id;
        insert into public.stock_locker_events(locker_id,label,locker_action,staff_id,holder_name,notes,recorded_by,recorded_by_name)
        values(v_old_key.locker_id,v_old_key.label,'RETURNED',v_old.staff_id,v_old_key.holder_name,
          format('Replaced by locker %s (request #%s)',v_locker.label,v_old.request_number),auth.uid(),public.stock_actor_name());
      end loop;
    end if;
    update public.stock_lockers set locker_status='ASSIGNED',staff_id=v_old.staff_id,driver_id=null,holder_name=v_name,assigned_at=now(),
      updated_at=now(),updated_by=auth.uid(),row_version=row_version+1 where locker_id=v_locker.locker_id returning * into v_locker;
    insert into public.stock_locker_events(locker_id,label,locker_action,staff_id,holder_name,notes,recorded_by,recorded_by_name)
    values(v_locker.locker_id,v_locker.label,'ASSIGNED',v_old.staff_id,v_name,format('Request #%s',v_old.request_number),auth.uid(),public.stock_actor_name());
  elsif v_action='SOLVED' then
    if v_note is null then raise exception using errcode='22023',message='Tell the person what was done.'; end if;
  else raise exception using errcode='22023',message='Choose Assign locker or Mark as solved.';
  end if;
  update public.stock_requests set request_status='ISSUED',locker_id=case when v_action='ASSIGN' then v_locker.locker_id end,
    decision_note=coalesce(v_note,format('Locker %s is yours.',v_locker.label)),decided_at=now(),decided_by=auth.uid(),
    issued_at=now(),issued_by=auth.uid(),updated_at=now(),row_version=row_version+1
  where request_id=p_request_id returning * into v_row;
  return public.stock_request_json(v_row);
end;$$;

create or replace function public.decide_stock_request(p_request_id uuid,p_decision text,p_note text,p_lines jsonb,p_row_version integer)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_old public.stock_requests%rowtype; v_row public.stock_requests%rowtype; v_decision text:=upper(trim(coalesce(p_decision,'')));
  v_line record; v_override jsonb; v_qty numeric; v_size text; v_move public.stock_movements%rowtype; v_issued integer:=0; v_name text;
begin
  perform public.stock_require('OPERATE');
  select * into v_old from public.stock_requests where request_id=p_request_id for update;
  if not found then raise exception using errcode='P0002',message='Request not found.'; end if;
  if v_old.row_version<>p_row_version then raise exception using errcode='40001',message='This request was changed by someone else. Reload and try again.'; end if;
  if v_old.request_status not in ('REQUESTED','APPROVED') then raise exception using errcode='22023',message='This request was already answered.'; end if;
  if v_old.request_kind='LOCKER_KEY' and v_decision<>'REJECT' then
    raise exception using errcode='22023',message='Answer a locker key request with Assign locker or Mark as solved.';
  end if;
  if v_decision='APPROVE' then
    if v_old.request_status<>'REQUESTED' then raise exception using errcode='22023',message='This request is already approved.'; end if;
    update public.stock_requests set request_status='APPROVED',decision_note=public.stock_clean_text(p_note,500),decided_at=now(),decided_by=auth.uid(),
      updated_at=now(),row_version=row_version+1 where request_id=p_request_id returning * into v_row;
  elsif v_decision='REJECT' then
    if public.stock_clean_text(p_note,500) is null then raise exception using errcode='22023',message='Tell the person why the request was declined.'; end if;
    update public.stock_requests set request_status='REJECTED',decision_note=public.stock_clean_text(p_note,500),decided_at=now(),decided_by=auth.uid(),
      updated_at=now(),row_version=row_version+1 where request_id=p_request_id returning * into v_row;
  elsif v_decision='ISSUE' then
    v_name:=public.stock_holder_name(v_old.staff_id,null,true);
    for v_line in select l.*,i.item_name,i.size_options,i.category_code from public.stock_request_lines l join public.stock_items i on i.item_id=l.item_id
                  where l.request_id=p_request_id order by l.line_id loop
      v_override:=null;
      select x into v_override from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) x where (x->>'line_id')::bigint=v_line.line_id limit 1;
      v_qty:=coalesce(nullif(v_override->>'qty','')::numeric,v_line.qty);
      v_size:=case when v_override ? 'size' then public.stock_clean_text(v_override->>'size',20) else v_line.size end;
      if v_qty<0 or v_qty>v_line.qty or v_qty<>trunc(v_qty) then raise exception using errcode='22023',message=format('Hand over from 0 to %s of %s.',trim(to_char(v_line.qty,'FM990')),v_line.item_name); end if;
      if v_qty>0 and cardinality(v_line.size_options)>0 and (v_size is null or not v_size=any(v_line.size_options)) then
        raise exception using errcode='22023',message=format('Choose the size for %s.',v_line.item_name);
      end if;
      update public.stock_request_lines set issued_qty=v_qty,size=v_size where line_id=v_line.line_id;
      if v_qty>0 then
        v_move:=public.stock_apply_movement(v_line.item_id,'OUT',v_qty,v_old.staff_id,null,null,null,
          format('Request #%s%s',v_old.request_number,coalesce(' (size '||v_size||')','')),p_request_id,null);
        insert into public.stock_ppe_events(staff_id,holder_name,item_id,item_type,description,size,qty,ppe_action,request_id,movement_id,recorded_by,recorded_by_name)
        values(v_old.staff_id,v_name,v_line.item_id,(select category_name from public.stock_categories where category_code=v_line.category_code),
          v_line.item_name,v_size,v_qty,'ISSUED',p_request_id,v_move.movement_id,auth.uid(),v_move.recorded_by_name);
        v_issued:=v_issued+1;
      end if;
    end loop;
    if v_issued=0 then raise exception using errcode='22023',message='Nothing to hand over. Decline the request instead.'; end if;
    update public.stock_requests set request_status='ISSUED',decision_note=coalesce(public.stock_clean_text(p_note,500),decision_note),
      decided_at=coalesce(decided_at,now()),decided_by=coalesce(decided_by,auth.uid()),issued_at=now(),issued_by=auth.uid(),
      updated_at=now(),row_version=row_version+1 where request_id=p_request_id returning * into v_row;
  else raise exception using errcode='22023',message='Choose Approve, Decline or Hand over.';
  end if;
  return public.stock_request_json(v_row);
end;$$;

create or replace function public.get_stock_workspace()
returns jsonb language plpgsql stable security definer set search_path=public,auth,pg_temp as $$
declare v_settings public.stock_settings%rowtype;
begin
  perform public.stock_require('VIEW');
  select * into v_settings from public.stock_settings limit 1;
  return jsonb_build_object(
    'can_operate',public.can_operate_stock(),
    'can_manage',public.can_manage_stock(),
    'settings',to_jsonb(v_settings),
    'categories',coalesce((select jsonb_agg(to_jsonb(c) order by c.display_order) from public.stock_categories c where c.active),'[]'::jsonb),
    'items',coalesce((select jsonb_agg(public.stock_item_json(i) || jsonb_build_object('per_week',u.per_week,'weeks_cover',u.weeks_cover,'days_since_count',u.days_since_count) order by i.item_name)
      from public.stock_items i left join public.stock_usage_stats() u on u.item_id=i.item_id),'[]'::jsonb),
    'people',coalesce((select jsonb_agg(to_jsonb(p) order by p.display_name) from public.stock_people() p),'[]'::jsonb),
    'customers',coalesce((select jsonb_agg(jsonb_build_object('customer_id',c.customer_id,'customer_name',c.customer_name) order by c.customer_name)
      from public.customers c where c.active and c.deleted_at is null),'[]'::jsonb),
    'lockers',coalesce((select jsonb_agg(to_jsonb(l) order by l.label) from public.stock_lockers l),'[]'::jsonb),
    'requests',coalesce((select jsonb_agg(public.stock_request_json(r) order by r.created_at) from public.stock_requests r where r.request_status in ('REQUESTED','APPROVED')),'[]'::jsonb),
    'overdue_counts',coalesce((select jsonb_agg(jsonb_build_object('item_id',i.item_id,'item_name',i.item_name,'last_counted_at',i.last_counted_at) order by i.last_counted_at nulls first)
      from public.stock_items i where i.active and i.track_by='NONE'
        and (i.last_counted_at is null or i.last_counted_at<now()-make_interval(days=>v_settings.chemical_count_days))),'[]'::jsonb),
    -- People who left, or whose last day is set, and still hold items.
    'pending_returns',coalesce((select jsonb_agg(to_jsonb(p) || jsonb_build_object('leaving_on',x.leaving_on,
        'ppe',(select coalesce(jsonb_agg(to_jsonb(b)),'[]'::jsonb) from public.stock_ppe_balances(p.staff_id,p.driver_id) b
        where b.staff_id is not distinct from p.staff_id and b.driver_id is not distinct from p.driver_id)) order by p.is_active,x.leaving_on nulls last,p.display_name)
      from public.stock_people() p
      cross join lateral (select coalesce((select s.deactivated_on from public.staff_members s where s.staff_id=p.staff_id),
        (select d.deactivated_on from public.distribution_drivers d where d.driver_id=p.driver_id)) leaving_on) x
      where (not p.is_active or x.leaving_on>=current_date) and (p.ppe_items>0 or cardinality(p.locker_labels)>0)),'[]'::jsonb),
    'recent',coalesce((select jsonb_agg(to_jsonb(m) || jsonb_build_object('item_name',i.item_name,'unit',i.unit) order by m.recorded_at desc,m.movement_id desc)
      from (select * from public.stock_movements order by recorded_at desc,movement_id desc limit 40) m join public.stock_items i on i.item_id=m.item_id),'[]'::jsonb)
  );
end;$$;

revoke all on function public.submit_my_locker_request(text),public.resolve_locker_request(uuid,text,uuid,text,integer,boolean) from public,anon,authenticated;
grant execute on function public.submit_my_locker_request(text),public.resolve_locker_request(uuid,text,uuid,text,integer,boolean) to authenticated;

commit;
