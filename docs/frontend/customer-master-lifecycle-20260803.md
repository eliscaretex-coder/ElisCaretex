# Customer Master Lifecycle — 2026-08-03

## Decision

Keep the Customer Master interaction direct while preserving database security and audit requirements.

The browser presents ordinary user actions:

```text
Add Customer -> Save -> Schedule Setup
Edit Customer -> Save
Deactivate Customer -> Confirm
Reactivate Customer -> Save -> Schedule Setup
```

The browser does not expose optimistic-concurrency terminology. The existing `row_version` value is still sent to `update_customer()` and stale writes remain rejected by PostgreSQL.

## Usability changes

- The save button is enabled only for valid, changed data.
- Closing a changed form requires confirmation.
- Eircode input is normalized to uppercase.
- The audit note is optional in the interface; a deterministic reason is generated when the user leaves it blank.
- Add and Reactivate continue directly to Customer Studio by default.
- Reactivation is immediately actionable when the existing service selection is already correct; the user is not forced to make a fake change.
- A Customer Master row without a published schedule is clearly marked **Schedule setup required**.
- Service eligibility changes recommend an immediate schedule review.
- A product that remains in a working schedule after its service was removed from Customer Master stays visible in orange and may be unticked. It is not silently hidden.

## Security preserved

- No direct `SELECT`, `INSERT`, `UPDATE` or `DELETE` privilege was added for authenticated users on `public.customers`.
- Customer Master writes continue through controlled security-definer functions.
- ADMIN, MANAGER and PLANNER may create/update according to the existing policy.
- ADMIN and MANAGER may deactivate/reactivate.
- Deactivation remains logical and preserves history.
- Published schedule history remains immutable.

## Validation evidence required

The canonical test is:

```text
supabase/tests/202607300008_customer_master_management_api_validation.sql
```

A successful SQL Editor result and a complete browser lifecycle recording are required before changing the INIT status from pending validation to confirmed.
