# Customer Studio direct edit flow

The frontend presents schedule maintenance as `Edit Schedule -> Save Changes -> Confirm Update`.

The database revision lifecycle remains unchanged internally:

- a protected working revision is created by `create_customer_schedule_management_draft`;
- the full document is saved by `save_customer_schedule_draft`;
- differences are calculated automatically by `compare_customer_schedule_draft`;
- confirmation publishes through `publish_customer_schedule_draft`;
- discarded or no-change work is cancelled through `cancel_customer_schedule_draft`.

This keeps immutable published history, audit reasons and optimistic concurrency while reducing the number of visible operator steps.
