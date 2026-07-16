# Legacy Application Inventory

The supplied applications will be reviewed before the production modules are
implemented.

```text
legacy-applications/
├── CentralDB
│   ├── CentralDB(13).xlsx
│   └── db(33).txt
│
├── Distribution
│   ├── viewer_distribuition_db.txt
│   ├── index_distribuition_db.txt
│   ├── Gs_distribuition_db.txt
│   └── CustomerPlanner_db.txt
│
├── Finish
│   ├── Index_finih.txt
│   ├── style_finish.txt
│   ├── Table_finish.txt
│   ├── app_finish.txt
│   ├── tracker_finish.txt
│   ├── results_finish.txt
│   ├── Staff_finish.txt
│   └── gs_finish_db.txt
│
├── Sorting
│   ├── Index_sorting1_db.txt.html
│   ├── Customer_sorting_db.txt
│   ├── gs_sorting_db.txt
│   ├── staff_sorting_db.txt
│   ├── TROLLEY.txt
│   ├── Performance_db.txt
│   ├── MOP_production.txt
│   └── TRACKER.txt
│
├── Roster
│   ├── RosterViewer_roster_db.txt
│   ├── index_roster_db.txt
│   ├── Customer_roster_db.txt
│   ├── gs_roster_db.txt
│   ├── Roster_db.txt
│   └── performance_roster_db.txt
│
└── Data Management
    ├── Index.html
    └── Code.gs
```

Approximate supplied legacy code size: 78,049 lines.

## Review order

1. Customers and customer schedules
2. Product types and area routing
3. Trolley rules
4. Sorting and wash loads
5. Finish production
6. Mop production
7. Staff and Roster
8. Distribution
9. Reports and email
10. Security, permissions and audit

## Rule classification

Every rule found will be classified as:

- KEEP
- CHANGE
- REMOVE
- MOVE_TO_DATABASE
- MOVE_TO_SHARED_FRONTEND
- NEEDS_CONFIRMATION
