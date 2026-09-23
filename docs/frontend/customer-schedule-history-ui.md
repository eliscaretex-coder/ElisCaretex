# Customer Schedule History UI

## Navigation

Customer Studio now exposes two views:

- `Current Schedule`
- `Version History`

The history view remains inside the existing Customer Studio modal so the operator does not lose customer context.

## Version list

Each version displays:

- revision number;
- current, previous, pending, discarded or published status;
- effective period;
- responsible staff display name;
- relevant timestamp;
- day, product and trolley totals.

## Selected revision

The detail area displays:

- revision metadata;
- reason recorded in the audit flow;
- automatic comparison with the schedule currently effective on the selected date;
- weekly schedule preview;
- restore action when permitted.

## Restore interaction

The visible flow is:

```text
Version History
→ Select Revision
→ Restore as New Update
→ Review Comparison
→ Confirm Restore
```

The UI does not expose the internal working-revision terminology. The database still uses a protected revision internally to preserve immutability, concurrency protection and audit history.

## Pending changes

When a saved schedule update already exists, the history tab shows a small warning indicator and restore is disabled until the update is confirmed or discarded.
