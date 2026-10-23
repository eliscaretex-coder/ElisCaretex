-- =====================================================================
-- ElisCaretex V2
-- The public Production Roster link only shows the roster
--
-- Owner decision 2026-10-23. The staff-portal token is one shared code for
-- everyone, so anyone holding the link could submit a Day Off / Holiday
-- request for any staff_id and read anyone's recent requests. Leave
-- requests now go only through My Production Roster, which uses the staff
-- member's own sign-in (submit_my_account_leave_request /
-- get_my_account_leave_requests). The public link keeps showing the
-- published roster (get_published_production_roster_portal).
-- The functions are kept for history; only execution is revoked.
-- =====================================================================

begin;

revoke all on function public.submit_production_roster_leave_request(text, uuid, text, date, date, text) from public, anon, authenticated;
revoke all on function public.get_my_production_roster_leave_requests(text, uuid) from public, anon, authenticated;

commit;
