"use strict";

(function exposeAppShellPolicy() {
  const ADMINISTRATIVE_SHELL_ROLES = new Set([
    "ADMIN",
    "MANAGER",
    "PLANNER",
    "ROSTER_MANAGER",
    "AUDITOR"
  ]);

  const ROLE_LABELS = {
    ADMIN: "Administrator",
    MANAGER: "Manager",
    PLANNER: "Production Planner",
    ROSTER_MANAGER: "Roster Manager",
    AUDITOR: "Auditor",
    SUPERVISOR: "Supervisor",
    SORTING_OPERATOR: "Sorting Operator",
    FINISH_OPERATOR: "Finish Operator",
    MOP_OPERATOR: "MOP Operator",
    DISTRIBUTION_OPERATOR: "Distribution Operator"
  };

  const OPERATIONAL_ROLE_PRIORITY = [
    "DISTRIBUTION_OPERATOR",
    "MOP_OPERATOR",
    "FINISH_OPERATOR",
    "SORTING_OPERATOR",
    "SUPERVISOR"
  ];

  const OPERATIONAL_CONTEXTS = {
    DISTRIBUTION_OPERATOR: {
      areaCode: "DISTRIBUTION",
      areaName: "Distribution",
      introduction: "Routes, deliveries and trolley movements for the current operation."
    },
    MOP_OPERATOR: {
      areaCode: "MOP",
      areaName: "Mop Production",
      introduction: "Mop production schedules and operational work for the current shift."
    },
    FINISH_OPERATOR: {
      areaCode: "FINISH",
      areaName: "Finish Area",
      introduction: "Clothes production work for the assigned table and shift."
    },
    SORTING_OPERATOR: {
      areaCode: "SORTING",
      areaName: "Sorting Area",
      introduction: "Sorting, washing preparation and trolley receipt work."
    },
    SUPERVISOR: {
      areaCode: "OPERATIONS",
      areaName: "Operations",
      introduction: "Operational schedules and controlled supervision tools."
    }
  };

  const ICONS = {
    home: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 11.5 12 4l9 7.5"/><path d="M5.5 10.5V20h13v-9.5"/><path d="M9.5 20v-6h5v6"/></svg>',
    schedule: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="4.5" width="18" height="16" rx="2"/><path d="M8 2.5v4M16 2.5v4M3 9h18"/><path d="M7 13h3M14 13h3M7 17h3M14 17h3"/></svg>',
    support: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 13v-1a8 8 0 0 1 16 0v1"/><rect x="3" y="13" width="4" height="6" rx="1.5"/><rect x="17" y="13" width="4" height="6" rx="1.5"/><path d="M19 19a4 4 0 0 1-4 3h-2"/></svg>',
    customers: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="9" cy="8" r="3"/><path d="M3.5 20a5.5 5.5 0 0 1 11 0"/><path d="M16 8h5M18.5 5.5v5"/><path d="M16 15h5M16 19h5"/></svg>',
    tracker: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 19V9M10 19V5M16 19v-7M22 19V3"/><path d="M2.5 19.5h21"/></svg>',
    results: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 20V10M10 20V4M16 20v-6M22 20V7"/><path d="M2.5 20.5h21"/></svg>',
    sorting: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 5h16M7 10h10M9 15h6M11 20h2"/></svg>',
    finish: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 4h14v5H5zM7 9v11h10V9"/><path d="M9 13h6M9 16h6"/></svg>',
    mop: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m14 3-3 9"/><path d="M9 12h6l3 8H6z"/><path d="M10 16h4"/></svg>',
    distribution: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h12v11H3z"/><path d="M15 9h4l2 3v5h-6z"/><circle cx="7" cy="18" r="2"/><circle cx="18" cy="18" r="2"/></svg>',
    trolley: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 5h2l2 10h9l2-7H7"/><circle cx="10" cy="19" r="1.5"/><circle cx="17" cy="19" r="1.5"/></svg>',
    myRoster: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="4.5" width="18" height="16" rx="2"/><path d="M8 2.5v4M16 2.5v4M3 9h18"/><circle cx="12" cy="13.5" r="2"/><path d="M8.5 19a3.5 3.5 0 0 1 7 0"/></svg>',
    route: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="6" cy="18" r="2.5"/><circle cx="18" cy="6" r="2.5"/><path d="M8.5 18H16a3 3 0 0 0 0-6H8a3 3 0 0 1 0-6h7.5"/></svg>',
    bell: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15z"/><path d="M10 20.5a2.2 2.2 0 0 0 4 0"/></svg>',
    roster: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3" y="4.5" width="18" height="16" rx="2"/><path d="M8 2.5v4M16 2.5v4M3 9h18"/><path d="M7 13h3M14 13h3M7 17h3M14 17h3"/></svg>',
    insights: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 20.5h18"/><path d="m4 16 5-5 4 3 7-8"/><path d="M15 6h5v5"/></svg>',
    documents: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 3.5h7l4 4v13H7z"/><path d="M14 3.5v4h4"/><path d="m9.5 14 1.8 1.8 3.4-3.6"/></svg>',
    checklist: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="5" y="3.5" width="14" height="17" rx="2"/><path d="M9 3.5h6v3H9z"/><path d="m8.5 12 1.5 1.5 3-3M8.5 17h7"/></svg>',
    menu: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16M4 12h16M4 17h16"/></svg>',
    user: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="8" r="4"/><path d="M4.5 21a7.5 7.5 0 0 1 15 0"/></svg>',
    signout: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M10 5H5v14h5"/><path d="m14 8 4 4-4 4M18 12H9"/></svg>'
  };

  function uniqueRoleCodes(roleCodes) {
    return [...new Set((roleCodes || []).map((value) => String(value || "").toUpperCase()).filter(Boolean))];
  }

  function resolveShell(roleCodes) {
    const normalized = uniqueRoleCodes(roleCodes);
    return normalized.some((roleCode) => ADMINISTRATIVE_SHELL_ROLES.has(roleCode))
      ? "administrative"
      : "operational";
  }

  function resolveAccountShell(profile = {},roleCodes = []) {
    if (profile.account_type === "TERMINAL") return "operational";
    const administrativeTitles = new Set(["ADMINISTRATOR","IT_MANAGER","GENERAL_MANAGER","PRODUCTION_MANAGER","LOGISTICS_MANAGER","PRODUCTION_SUPERVISOR","AUDITOR","CUSTOMER_SERVICE"]);
    if (administrativeTitles.has(String(profile.job_title_code || "").toUpperCase())) return "administrative";
    return resolveShell(roleCodes);
  }

  function primaryRole(roleCodes) {
    const normalized = uniqueRoleCodes(roleCodes);

    for (const roleCode of OPERATIONAL_ROLE_PRIORITY) {
      if (normalized.includes(roleCode)) {
        return roleCode;
      }
    }

    return normalized[0] || "";
  }

  function operationalContext(roleCodes) {
    const roleCode = primaryRole(roleCodes);
    return {
      roleCode,
      roleName: ROLE_LABELS[roleCode] || roleCode || "Operational User",
      ...(OPERATIONAL_CONTEXTS[roleCode] || {
        areaCode: "OPERATIONS",
        areaName: "Operations",
        introduction: "Operational tools available for this account."
      })
    };
  }

  // Navigation is intentionally based on product permissions, not page names.
  // Server-side RPC guards remain the authority for data access; this registry
  // defines the workspace entry points that should be visible to each role.
  const NAVIGATION_PERMISSIONS = Object.freeze({
    CUSTOMER_WORKSPACE: "customer.workspace",
    CUSTOMER_SERVICE: "customer.service",
    MY_ROSTER: "self.my-roster",
    MY_DRIVER_ROSTER: "self.my-driver-roster",
    NOTIFICATIONS: "self.notifications",
    COMPANY_DOCUMENTS: "self.company-documents",
    STAFF_MASTER: "staff.master",
    PRODUCTION_ROSTER: "production.roster",
    SORTING: "operations.sorting",
    FINISH: "operations.finish",
    FINISH_RESULTS: "operations.finish-results",
    MOP_PRODUCTION: "operations.mop-production",
    DISTRIBUTION: "operations.distribution",
    PRODUCTION_TRACKER: "operations.production-tracker",
    TROLLEYS: "operations.trolleys",
    PRODUCTION_INSIGHTS: "management.production-insights"
  });

  const MODULE_NAVIGATION_PERMISSIONS = Object.freeze({
    MY_ROSTER: [NAVIGATION_PERMISSIONS.MY_ROSTER],
    MY_DRIVER_ROSTER: [NAVIGATION_PERMISSIONS.MY_DRIVER_ROSTER],
    NOTIFICATIONS: [NAVIGATION_PERMISSIONS.NOTIFICATIONS],
    COMPANY_DOCUMENTS: [NAVIGATION_PERMISSIONS.COMPANY_DOCUMENTS],
    CUSTOMERS: [NAVIGATION_PERMISSIONS.CUSTOMER_WORKSPACE],
    CUSTOMER_SERVICE: [NAVIGATION_PERMISSIONS.CUSTOMER_SERVICE],
    PRODUCTION_ROSTER: [NAVIGATION_PERMISSIONS.PRODUCTION_ROSTER],
    SORTING: [NAVIGATION_PERMISSIONS.SORTING],
    FINISH: [NAVIGATION_PERMISSIONS.FINISH,NAVIGATION_PERMISSIONS.FINISH_RESULTS],
    MOP: [NAVIGATION_PERMISSIONS.MOP_PRODUCTION],
    // Distribution maintains customers, trolley quantities and route order (202610230001).
    DISTRIBUTION: [NAVIGATION_PERMISSIONS.DISTRIBUTION,NAVIGATION_PERMISSIONS.CUSTOMER_WORKSPACE],
    PRODUCTION_TRACKER: [NAVIGATION_PERMISSIONS.PRODUCTION_TRACKER],
    TROLLEYS: [NAVIGATION_PERMISSIONS.TROLLEYS],
    PRODUCTION_INSIGHTS: [NAVIGATION_PERMISSIONS.PRODUCTION_INSIGHTS],
    STAFF_MASTER: [NAVIGATION_PERMISSIONS.STAFF_MASTER],
    ACCOUNTS_ACCESS: ["administration.accounts-access"]
  });

  const NAVIGATION_MODULES = Object.freeze([
    {
      id: "home", label: "Home", description: "Operational start page",
      href: "./index.html", icon: "home", group: "Home"
    },
    {
      id: "my-roster", label: "My Production Roster", description: "My published production schedule and leave requests",
      href: "./pages/roster-view.html", icon: "myRoster", group: "My work",
      permission: NAVIGATION_PERMISSIONS.MY_ROSTER
    },
    {
      id: "my-driver-roster", label: "My Driver Roster", description: "My routes, customers and leave requests",
      href: "./pages/driver-roster.html", icon: "route", group: "My work",
      permission: NAVIGATION_PERMISSIONS.MY_DRIVER_ROSTER
    },
    {
      id: "notifications", label: "Notifications", description: "Requests, decisions and updates",
      href: "./pages/notifications.html", icon: "bell", group: "My work",
      permission: NAVIGATION_PERMISSIONS.NOTIFICATIONS
    },
    {
      id: "company-documents", label: "Company Documents", description: "Company policies and SSOW to read and confirm",
      href: "./pages/company-documents.html", icon: "documents", group: "My work",
      permission: NAVIGATION_PERMISSIONS.COMPANY_DOCUMENTS
    },
    {
      id: "customer-workspace", label: "Customer Workspace",
      description: "Customers, weekly planner and distribution routes",
      href: "./pages/customers.html", icon: "customers", group: "Planning",
      permission: NAVIGATION_PERMISSIONS.CUSTOMER_WORKSPACE,
      children: [
        { id:"customer-workspace-schedule", label:"Schedule Planner", href:"./pages/customers.html?view=schedule" },
        { id:"customer-workspace-master", label:"Customer Master", href:"./pages/customers.html?view=master" },
        { id:"customer-workspace-reports", label:"Operational Reports", href:"./pages/customers.html?view=reports" }
      ]
    },
    {
      id: "customer-service", label: "Customer Service",
      description: "Complaints, customer alerts, department tasks and results",
      href: "./pages/customer-service.html", icon: "support", group: "Customer Service",
      permission: NAVIGATION_PERMISSIONS.CUSTOMER_SERVICE,
      children: [
        { id:"customer-service-complaints", label:"Complaints", href:"./pages/customer-service.html#complaints" },
        { id:"customer-service-alerts", label:"Customer alerts", href:"./pages/customer-service.html#alerts" },
        { id:"customer-service-tasks", label:"Tasks", href:"./pages/customer-service.html#tasks" },
        { id:"customer-service-results", label:"Results", href:"./pages/customer-service.html#results" },
        { id:"customer-service-settings", label:"Settings", href:"./pages/customer-service.html#settings" }
      ]
    },
    {
      id: "production-roster", label: "Production Roster",
      description: "Published and planned production staffing",
      href: "./pages/roster.html", icon: "roster", group: "Planning",
      permission: NAVIGATION_PERMISSIONS.PRODUCTION_ROSTER
    },
    {
      id: "sorting", label: "Sorting",
      description: "Roster-led trolley receipt and washing preparation",
      href: "./pages/sorting.html", icon: "sorting", group: "Production",
      permission: NAVIGATION_PERMISSIONS.SORTING,
      children: [
        { id:"sorting-washing", label:"Washing", href:"./pages/sorting.html#washing" },
        { id:"sorting-trolley", label:"Trolley Intake", href:"./pages/sorting.html#trolley" },
        { id:"sorting-mop", label:"MOP Production", href:"./pages/mop-production.html" },
        { id:"sorting-staff", label:"Staff", href:"./pages/sorting.html#staff" },
        { id:"sorting-results", label:"Results", href:"./pages/sorting-results.html" }
      ]
    },
    {
      id: "finish", label: "Finish",
      description: "Finish production by table and shift",
      href: "./pages/finish-production.html", icon: "finish", group: "Production",
      permission: NAVIGATION_PERMISSIONS.FINISH,
      children: [
        { id:"finish-production", label:"Production", href:"./pages/finish-production.html" },
        { id:"finish-staff", label:"Staff", href:"./pages/finish-production.html?view=staff" }
      ]
    },
    {
      id: "finish-results", label: "Finish Results",
      description: "Daily Finish performance by table and shift",
      href: "./pages/finish-results.html", icon: "checklist", group: "Production",
      permission: NAVIGATION_PERMISSIONS.FINISH_RESULTS
    },
    {
      id: "mop-production", label: "MOP Production",
      description: "MOP production recording",
      href: "./pages/mop-production.html", icon: "mop", group: "Production",
      permission: NAVIGATION_PERMISSIONS.MOP_PRODUCTION
    },
    {
      id: "distribution", label: "Distribution",
      description: "Daily routes, drivers, fleet and delivery execution",
      href: "./pages/distribution.html", icon: "distribution", group: "Logistics",
      permission: NAVIGATION_PERMISSIONS.DISTRIBUTION,
      children: [
        { id:"distribution-board", label:"Daily board", href:"./pages/distribution.html#board" },
        { id:"distribution-customers", label:"Route customers", href:"./pages/distribution.html#customers" },
        { id:"distribution-roster", label:"Weekly roster", href:"./pages/distribution.html#roster" },
        { id:"distribution-leave", label:"Leave calendar", href:"./pages/distribution.html#leave" },
        { id:"distribution-actuals", label:"Actuals", href:"./pages/distribution.html#actuals" },
        { id:"distribution-drivers", label:"Drivers", href:"./pages/distribution.html#drivers" },
        { id:"distribution-fleet", label:"Fleet", href:"./pages/distribution.html#fleet" },
        { id:"distribution-routes", label:"Routes", href:"./pages/distribution.html#routes" },
        { id:"distribution-history", label:"History", href:"./pages/distribution.html#history" },
        { id:"distribution-guides", label:"Customer guides", href:"./pages/distribution.html#guides" }
      ]
    },
    {
      id: "production-tracker", label: "Production Tracker",
      description: "Shared Clothes and MOP production trace",
      href: "./pages/production-tracker.html", icon: "tracker", group: "Production",
      permission: NAVIGATION_PERMISSIONS.PRODUCTION_TRACKER,
      children: [
        { id:"production-tracker-map", label:"Production map", href:"./pages/production-tracker.html?view=map" },
        { id:"production-tracker-board", label:"Route board", href:"./pages/production-tracker.html?view=board" }
      ]
    },
    {
      id: "trolleys", label: "Trolleys",
      description: "Current trolley locations and custody history",
      href: "./pages/trolleys.html", icon: "trolley", group: "Logistics",
      permission: NAVIGATION_PERMISSIONS.TROLLEYS,
      children: [
        { id:"trolleys-locations", label:"Locations", href:"./pages/trolleys.html#locations" },
        { id:"trolleys-master", label:"Trolley Master", href:"./pages/trolleys.html#master" },
        { id:"trolleys-types", label:"Trolley Types", href:"./pages/trolleys.html#types" }
      ]
    },
    {
      id: "production-insights", label: "Production Intelligence",
      description: "Official production history, demand learning and management indicators",
      href: "./pages/production-insights.html", icon: "insights", group: "Management",
      permission: NAVIGATION_PERMISSIONS.PRODUCTION_INSIGHTS,
      children: [
        { id:"production-insights-overview", label:"Overview", href:"./pages/production-insights.html?view=overview" },
        { id:"production-insights-daily", label:"Daily report", href:"./pages/production-insights.html?view=daily" },
        { id:"production-insights-customers", label:"Customers", href:"./pages/production-insights.html?view=customers" },
        { id:"production-insights-performance", label:"Shifts & tables", href:"./pages/production-insights.html?view=performance" },
        { id:"production-insights-staff", label:"Staff", href:"./pages/production-insights.html?view=staff" },
        { id:"production-insights-planning", label:"Planning", href:"./pages/production-insights.html?view=planning" }
      ]
    },
    {
      id: "staff-master", label: "Staff Master",
      description: "Operational staff and work roles",
      href: "./pages/staff.html", icon: "user", group: "Management",
      permission: NAVIGATION_PERMISSIONS.STAFF_MASTER,
      children: [
        { id:"staff-master-directory", label:"Staff directory", href:"./pages/staff.html" },
        { id:"staff-master-accounts", label:"Accounts & access", href:"./pages/staff.html?view=accounts", permission:"administration.accounts-access" }
      ]
    }
  ]);

  // Sidebar sections, in display order. Every module group must be listed here.
  const NAVIGATION_GROUPS = Object.freeze(["Home", "My work", "Customer Service", "Planning", "Production", "Logistics", "Management"]);

  // Which sidebar workspace owns each page. Pages not listed (sign-in, password
  // recovery, privacy, token review links) render without the sidebar.
  const PAGE_MODULES = Object.freeze({
    "index.html": "home",
    "roster-view.html": "my-roster",
    "driver-roster.html": "my-driver-roster",
    "notifications.html": "notifications",
    "company-documents.html": "company-documents",
    "customers.html": "customer-workspace",
    "customer-service.html": "customer-service",
    "roster.html": "production-roster",
    "sorting.html": "sorting",
    "mop-production.html": "sorting",
    "sorting-results.html": "sorting",
    "finish-production.html": "finish",
    "finish-results.html": "finish-results",
    "production-tracker.html": "production-tracker",
    "trolleys.html": "trolleys",
    "distribution.html": "distribution",
    "driver-guides.html": "distribution",
    "production-insights.html": "production-insights",
    "staff.html": "staff-master"
  });

  const ROLE_NAVIGATION_PERMISSIONS = Object.freeze({
    ADMIN: ["*"],
    MANAGER: ["*"],
    PLANNER: [NAVIGATION_PERMISSIONS.CUSTOMER_WORKSPACE],
    ROSTER_MANAGER: [NAVIGATION_PERMISSIONS.STAFF_MASTER, NAVIGATION_PERMISSIONS.PRODUCTION_ROSTER],
    AUDITOR: [
      NAVIGATION_PERMISSIONS.CUSTOMER_WORKSPACE,
      NAVIGATION_PERMISSIONS.DISTRIBUTION,
      NAVIGATION_PERMISSIONS.STAFF_MASTER,
      NAVIGATION_PERMISSIONS.PRODUCTION_ROSTER,
      NAVIGATION_PERMISSIONS.PRODUCTION_TRACKER,
      NAVIGATION_PERMISSIONS.TROLLEYS
    ],
    SUPERVISOR: [
      NAVIGATION_PERMISSIONS.CUSTOMER_WORKSPACE,
      NAVIGATION_PERMISSIONS.STAFF_MASTER,
      NAVIGATION_PERMISSIONS.PRODUCTION_ROSTER,
      NAVIGATION_PERMISSIONS.SORTING,
      NAVIGATION_PERMISSIONS.FINISH,
      NAVIGATION_PERMISSIONS.FINISH_RESULTS,
      NAVIGATION_PERMISSIONS.MOP_PRODUCTION,
      NAVIGATION_PERMISSIONS.DISTRIBUTION,
      NAVIGATION_PERMISSIONS.PRODUCTION_TRACKER,
      NAVIGATION_PERMISSIONS.TROLLEYS
    ],
    SORTING_OPERATOR: [
      NAVIGATION_PERMISSIONS.CUSTOMER_WORKSPACE,
      NAVIGATION_PERMISSIONS.SORTING,
      NAVIGATION_PERMISSIONS.MOP_PRODUCTION,
      NAVIGATION_PERMISSIONS.PRODUCTION_TRACKER,
      NAVIGATION_PERMISSIONS.TROLLEYS
    ],
    FINISH_OPERATOR: [
      NAVIGATION_PERMISSIONS.CUSTOMER_WORKSPACE,
      NAVIGATION_PERMISSIONS.FINISH,
      NAVIGATION_PERMISSIONS.FINISH_RESULTS,
      NAVIGATION_PERMISSIONS.PRODUCTION_TRACKER,
      NAVIGATION_PERMISSIONS.TROLLEYS
    ],
    MOP_OPERATOR: [
      NAVIGATION_PERMISSIONS.CUSTOMER_WORKSPACE,
      NAVIGATION_PERMISSIONS.MOP_PRODUCTION,
      NAVIGATION_PERMISSIONS.PRODUCTION_TRACKER,
      NAVIGATION_PERMISSIONS.TROLLEYS
    ],
    DISTRIBUTION_OPERATOR: [
      NAVIGATION_PERMISSIONS.CUSTOMER_WORKSPACE,
      NAVIGATION_PERMISSIONS.DISTRIBUTION,
      NAVIGATION_PERMISSIONS.PRODUCTION_TRACKER,
      NAVIGATION_PERMISSIONS.TROLLEYS
    ]
  });

  function navigationAccess(roleCodes, overrides = {}) {
    const granted = new Set();
    if (!overrides.replaceRoles) {
      uniqueRoleCodes(roleCodes).forEach((roleCode) => {
        (ROLE_NAVIGATION_PERMISSIONS[roleCode] || []).forEach((permission) => granted.add(permission));
      });
    }
    (overrides.grant || []).forEach((permission) => granted.add(permission));
    const denied = new Set(overrides.deny || []);

    return Object.freeze({
      can(permission) {
        return !denied.has(permission) && (granted.has("*") || granted.has(permission));
      },
      granted: Object.freeze([...granted]),
      denied: Object.freeze([...denied])
    });
  }

  function permissionOverrides(profile = {}) {
    const grants = [];
    (profile.permissions || []).forEach((permission) => {
      const canEnter = permission.can_view || permission.can_create || permission.can_edit || permission.can_approve || permission.can_manage;
      if (!canEnter) return;
      (MODULE_NAVIGATION_PERMISSIONS[String(permission.module_code || "").toUpperCase()] || []).forEach((item) => grants.push(item));
    });
    // Every personal account reads and confirms company documents; production
    // terminals do not (get_my_company_documents enforces the same rule).
    if (profile.account_type && profile.account_type !== "TERMINAL") grants.push(NAVIGATION_PERMISSIONS.COMPANY_DOCUMENTS);
    return {
      grant:[...new Set(grants)],
      replaceRoles:profile.account_type === "USER" && Array.isArray(profile.permissions) && profile.permissions.length > 0
    };
  }

  function operationalModules(roleCodes, overrides) {
    const access = navigationAccess(roleCodes, overrides);
    return NAVIGATION_MODULES
      .filter((module) => {
        if (module.id === "mop-production") return false;
        if (module.id === "sorting") {
          return access.can(NAVIGATION_PERMISSIONS.SORTING) || access.can(NAVIGATION_PERMISSIONS.MOP_PRODUCTION);
        }
        return !module.permission || access.can(module.permission);
      })
      .map((module) => {
        if (module.id !== "sorting") return { ...module, status: "available" };
        const sortingAccess = access.can(NAVIGATION_PERMISSIONS.SORTING);
        return {
          ...module,
          href: sortingAccess ? module.href : "./pages/mop-production.html",
          children: sortingAccess ? module.children : module.children.filter((child) => child.id === "sorting-mop"),
          status: "available"
        };
      })
      .map((module) => ({ ...module,children:Array.isArray(module.children) ? module.children.filter((child) => !child.permission || access.can(child.permission)) : module.children }));
  }

  function primaryOperationalModule(roleCodes,overrides) {
    const modules = operationalModules(roleCodes,overrides);
    const roleCode = primaryRole(roleCodes);
    const preferredByRole = {
      MOP_OPERATOR: "sorting",
      FINISH_OPERATOR: "finish",
      SORTING_OPERATOR: "sorting"
    };
    const preferredId = preferredByRole[roleCode];
    if (preferredId) {
      const preferred = modules.find((module) => module.id === preferredId && module.status === "available");
      if (preferred) return preferred;
    }
    return modules.find(
      (module) => module.id !== "home" && module.status === "available"
    ) || null;
  }

  window.ELIS_APP_SHELL_POLICY = Object.freeze({
    ROLE_LABELS,
    ICONS,
    NAVIGATION_PERMISSIONS,
    NAVIGATION_MODULES,
    NAVIGATION_GROUPS,
    PAGE_MODULES,
    ROLE_NAVIGATION_PERMISSIONS,
    MODULE_NAVIGATION_PERMISSIONS,
    resolveShell,
    resolveAccountShell,
    operationalContext,
    operationalModules,
    primaryOperationalModule,
    navigationAccess,
    permissionOverrides,
    uniqueRoleCodes
  });
})();
