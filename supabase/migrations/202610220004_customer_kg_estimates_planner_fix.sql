-- Speed up customer KG estimates, which every Distribution screen loads.
--
-- public.customer_kg_estimates(date, uuid) took about 1.9 s per call: the planner
-- estimates 3 schedule slots and a few hundred history rows (actual: about 500 and
-- 12,000), so it joins them with nested loops that compare millions of row pairs.
-- get_distribution_operations_dashboard_v2 calls it twice (about 3.9 s) and
-- get_distribution_weekly_planner once (about 1.9 s).
--
-- Turning nested loops off for this function only lets the planner use hash joins.
-- Measured on ElisCaretex-dev with the same setting for the session: estimates 163 ms,
-- dashboard 364 ms, weekly planner 189 ms. Results are unchanged; only the plan differs.

alter function public.customer_kg_estimates(date, uuid) set enable_nestloop = off;
