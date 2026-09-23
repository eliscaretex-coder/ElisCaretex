# Customer Read API

## Purpose

Migration `202607300007_customer_read_api.sql` creates a read-only contract
between the frontend and the Customer/Schedule database model.

The frontend should call RPC functions instead of joining operational tables.

## Functions

### `get_customer_read_capabilities()`

Returns separate read and edit capabilities for the authenticated staff account. Read access never implies edit access. In particular, an Auditor may view the directory and history but cannot edit customers or schedules.

### `get_customer_directory(...)`

Management-only Customer Directory. Distribution-only fields are not returned.

Supported status filters:

- `ACTIVE`
- `INACTIVE`
- `ALL`

Supported service filters:

- `ALL`
- `CLOTHES`
- `MOP`
- `CLOTHES_ONLY`
- `MOP_ONLY`
- `CLOTHES_AND_MOP`

### `get_customer_overview(customer_id, effective_date)`

Returns general customer information, active services and the effective
published revision. It deliberately excludes estimated distribution weight,
stops, routes and delivery instructions.

### `get_customer_weekly_schedule(customer_id, effective_date)`

Returns the published weekly production schedule. Product visibility is
role-based:

- management roles: Clothes and Mop;
- Sorting and Finish roles: Clothes;
- Mop role: Mop.

### `get_customer_schedule_history(customer_id)`

Management-only revision history.

### `get_clothes_weekly_planner(...)`

Clothes production planner. It does not return Distribution-only fields.

### `get_mop_weekly_planner(...)`

Mop production planner. It does not return Distribution-only fields.

### `get_customer_distribution_overview(...)`

Distribution-only customer fields and default schedule routes.

### `get_distribution_weekly_planner(...)`

Distribution weekly view. Routes in this payload are customer default routes.
A future daily Distribution plan may assign collection, ad hoc or support
routes without rewriting the customer schedule.

## Frontend example

```javascript
const { data, error } = await supabaseClient.rpc(
  "get_customer_directory",
  {
    p_status: "ACTIVE",
    p_service_filter: "ALL",
    p_search: null,
    p_effective_date: "2026-07-30",
    p_limit: 200,
    p_offset: 0
  }
);
```

The application must first call `get_customer_read_capabilities()` and render
only the tabs permitted by the returned flags.
