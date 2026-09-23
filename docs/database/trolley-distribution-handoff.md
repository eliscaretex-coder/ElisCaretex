# Physical Trolley Distribution Handoff

## Decision

Distribution receives a read-only physical trolley load handoff derived from:

```text
Production trolley assignment
+
immutable source Customer Schedule day
+
next Distribution business date
```

The source schedule day determines Route, delivery order, delivery window, alert and Distribution instructions. The physical assignment determines the trolley code, trolley type, customer, production area and planned delivery date.

## Governance boundary

The handoff must not:

- create a manual Distribution Daily Plan;
- change the default Route;
- change delivery order;
- claim scanner-confirmed delivery;
- grant direct browser reads on protected trolley tables.

Until portable scanning exists, custody provenance remains:

```text
PRODUCTION_NEXT_DAY_INFERENCE
```

## Historical behaviour

The handoff includes assignments for the selected delivery date even after a trolley later returns to Sorting. This preserves the historical physical load list for that date.

## Controlled read model

```text
get_trolley_distribution_handoff(p_delivery_date date)
```

The RPC groups output as:

```text
Delivery date
→ Route
→ Customer / delivery order
→ Physical trolley codes
```
