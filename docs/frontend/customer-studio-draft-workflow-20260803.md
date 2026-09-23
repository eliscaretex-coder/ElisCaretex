# Customer Studio Draft Workflow — 2026-08-03

## Status

Frontend implementation prepared for real-environment validation.

## Backend contract

This UI uses only the protected RPCs introduced by:

```text
supabase/migrations/202607310002_customer_schedule_management_api.sql
```

Connected RPCs:

```text
get_customer_schedule_management_state
create_customer_schedule_management_draft
save_customer_schedule_draft
compare_customer_schedule_draft
publish_customer_schedule_draft
cancel_customer_schedule_draft
```

## Frontend behaviour

The existing read-only Customer Studio remains available for users without schedule-management permissions. ADMIN, MANAGER and PLANNER users receive the management state and the following controlled modes:

### Published mode

- all fields are read only;
- the selected published revision is identified;
- the only write entry point is **Create Draft**.

### Draft mode

- the complete weekly document is edited in browser state;
- structural changes mark the draft as dirty;
- save requires an audit reason;
- save sends the expected schedule `row_version`;
- comparison is available only after the current changes are saved;
- publication is available only after a comparison reports changes;
- cancellation requires a reason;
- close and reload operations warn before discarding unsaved changes.

## Full-document save model

The frontend sends only business fields accepted by `save_customer_schedule_draft()`:

```text
effective_from
effective_until
general_instructions
days[]
  production_weekday
  delivery_weekday
  default_route_id
  delivery_window_start
  delivery_window_end
  delivery_order
  day_alert
  distribution_instructions
  products[]
    product_code
    production_order
    expected_kg
    expected_units
    production_instructions
    variant_codes[]
  trolley_requirements[]
    trolley_type_code
    owner_product_code
    quantity
    empty_trolley
    notes
    serves_product_codes[]
```

Technical child IDs from snapshots are intentionally not submitted. The database resolves controlled business references and recreates only the mutable DRAFT children transactionally.

## Validation performed in this package

- JavaScript syntax validation with Node.js;
- HTML duplicate-ID validation;
- CSS parsing with `tinycss2`;
- headless Chromium workflow test with simulated protected RPC responses;
- tested sequence: open draft → edit → save → compare → publish → create next draft → cancel;
- confirmed return to protected published mode after publish and cancel.

Real Supabase authentication, RLS, role membership and production customer data still require validation in the user's development environment.
