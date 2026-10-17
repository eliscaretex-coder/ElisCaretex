begin;

create or replace function public.update_driver_guide(p_guide_id uuid,p_guide jsonb)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_old public.customer_driver_guides%rowtype; v_row public.customer_driver_guides%rowtype;
begin
 if not public.can_manage_driver_guides() then raise exception using errcode='42501',message='Distribution management access is required.'; end if;
 select * into v_old from public.customer_driver_guides where guide_id=p_guide_id for update;
 if not found then raise exception using errcode='P0002',message='Guide not found.'; end if;
 update public.customer_driver_guides set
  customer_id=coalesce(nullif(p_guide->>'customer_id','')::uuid,customer_id),
  title=coalesce(nullif(trim(p_guide->>'title'),''),title),
  description=case when p_guide ? 'description' then nullif(trim(p_guide->>'description'),'') else description end,
  storage_path=coalesce(nullif(p_guide->>'storage_path',''),storage_path),
  original_file_name=coalesce(nullif(p_guide->>'original_file_name',''),original_file_name),
  mime_type=coalesce(nullif(p_guide->>'mime_type',''),mime_type),
  sort_order=coalesce(nullif(p_guide->>'sort_order','')::integer,sort_order),active=true,
  updated_at=now(),updated_by=auth.uid(),row_version=row_version+1
 where guide_id=p_guide_id returning * into v_row;
 return jsonb_build_object('guide',to_jsonb(v_row),'old_storage_path',v_old.storage_path);
end;$$;

create or replace function public.delete_driver_guide(p_guide_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth,pg_temp as $$
declare v_row public.customer_driver_guides%rowtype;
begin
 if not public.can_manage_driver_guides() then raise exception using errcode='42501',message='Distribution management access is required.'; end if;
 delete from public.customer_driver_guides where guide_id=p_guide_id returning * into v_row;
 if not found then raise exception using errcode='P0002',message='Guide not found.'; end if;
 return to_jsonb(v_row);
end;$$;

revoke all on function public.update_driver_guide(uuid,jsonb),public.delete_driver_guide(uuid) from public,anon;
grant execute on function public.update_driver_guide(uuid,jsonb),public.delete_driver_guide(uuid) to authenticated;
commit;
