-- The trolley-plan report is shared by Finish and MOP. Keep its existing
-- authenticated grant while Finish terminal calls remain station-validated.

grant execute on function public.report_customer_trolley_requirement_issue(uuid,text,jsonb,text[],text) to authenticated;
