# Trolley Workflow

## Send

```text
Operator selects customer
        |
Operator scans trolley
        |
send_trolley_to_customer()
        |
Database verifies:
- trolley exists and is active;
- trolley is not out of service;
- customer is active;
- no other open stay exists.
        |
Open stay is created
Trolley status becomes AT_CUSTOMER
Audit and trolley event are recorded
```

## Receive with open stay

```text
Operator scans trolley
        |
suggest_trolley_customer()
        |
Open customer is displayed
        |
Operator confirms
        |
receive_trolley_from_customer()
        |
received_on is stored
days_out becomes available
Trolley status becomes AVAILABLE
```

## Receive without outbound record

```text
Operator scans trolley
        |
No open stay exists
        |
Last known customer is suggested
        |
Operator confirms or selects another customer
        |
A received-only record is created
sent_on remains NULL
exception_type = MISSING_OUTBOUND_RECORD
```

## Reports

- Trolleys currently at customers
- Days outside
- Warning and overdue groups
- Missing outbound records
- Customer mismatches requiring review
- Trolley-days by customer for future charging
