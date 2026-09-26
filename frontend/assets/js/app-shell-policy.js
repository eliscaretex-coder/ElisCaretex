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
    customers: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="9" cy="8" r="3"/><path d="M3.5 20a5.5 5.5 0 0 1 11 0"/><path d="M16 8h5M18.5 5.5v5"/><path d="M16 15h5M16 19h5"/></svg>',
    tracker: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 19V9M10 19V5M16 19v-7M22 19V3"/><path d="M2.5 19.5h21"/></svg>',
    results: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 20V10M10 20V4M16 20v-6M22 20V7"/><path d="M2.5 20.5h21"/></svg>',
    sorting: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 5h16M7 10h10M9 15h6M11 20h2"/></svg>',
    finish: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 4h14v5H5zM7 9v11h10V9"/><path d="M9 13h6M9 16h6"/></svg>',
    mop: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m14 3-3 9"/><path d="M9 12h6l3 8H6z"/><path d="M10 16h4"/></svg>',
    distribution: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h12v11H3z"/><path d="M15 9h4l2 3v5h-6z"/><circle cx="7" cy="18" r="2"/><circle cx="18" cy="18" r="2"/></svg>',
    trolley: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 5h2l2 10h9l2-7H7"/><circle cx="10" cy="19" r="1.5"/><circle cx="17" cy="19" r="1.5"/></svg>',
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
    MY_ROSTER: "self.my-roster",
    NOTIFICATIONS: "self.notifications",
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
    NOTIFICATIONS: [NAVIGATION_PERMISSIONS.NOTIFICATIONS],
    CUSTOMERS: [NAVIGATION_PERMISSIONS.CUSTOMER_WORKSPACE],
    PRODUCTION_ROSTER: [NAVIGATION_PERMISSIONS.PRODUCTION_ROSTER],
    SORTING: [NAVIGATION_PERMISSIONS.SORTING],
    FINISH: [NAVIGATION_PERMISSIONS.FINISH,NAVIGATION_PERMISSIONS.FINISH_RESULTS],
    MOP: [NAVIGATION_PERMISSIONS.MOP_PRODUCTION],
    DISTRIBUTION: [NAVIGATION_PERMISSIONS.DISTRIBUTION],
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
      id: "my-roster", label: "My Roster", description: "My published schedule and leave requests",
      href: "./pages/roster-view.html", icon: "schedule", group: "Self service",
      permission: NAVIGATION_PERMISSIONS.MY_ROSTER
    },
    {
      id: "notifications", label: "Notifications", description: "Requests, decisions and updates",
      href: "./pages/notifications.html", icon: "schedule", group: "Self service",
      permission: NAVIGATION_PERMISSIONS.NOTIFICATIONS
    },
    {
      id: "customer-workspace", label: "Customer Workspace",
      description: "Customers, weekly planner and distribution routes",
      href: "./pages/customers.html", icon: "customers", group: "Customer Planning",
      permission: NAVIGATION_PERMISSIONS.CUSTOMER_WORKSPACE,
      children: [
        { id:"customer-workspace-schedule", label:"Schedule Planner", href:"./pages/customers.html?view=schedule" },
        { id:"customer-workspace-master", label:"Customer Master", href:"./pages/customers.html?view=master" },
        { id:"customer-workspace-reports", label:"Operational Reports", href:"./pages/customers.html?view=reports" }
      ]
    },
    {
      id: "production-roster", label: "Production Roster",
      description: "Published and planned production staffing",
      href: "./pages/roster.html", icon: "schedule", group: "Customer Planning",
      permission: NAVIGATION_PERMISSIONS.PRODUCTION_ROSTER
    },
    {
      id: "sorting", label: "Sorting",
      description: "Roster-led trolley receipt and washing preparation",
      href: "./pages/sorting.html", icon: "sorting", group: "Operations",
      permission: NAVIGATION_PERMISSIONS.SORTING,
      children: [
        { id:"sorting-washing", label:"Washing", href:"./pages/sorting.html#washing" },
        { id:"sorting-trolley", label:"Trolley Intake", href:"./pages/sorting.html#trolley" },
        { id:"sorting-mop", label:"MOP Production", href:"./pages/mop-production.html" },
        { id:"sorting-tracker", label:"Production Tracker", href:"./pages/sorting.html#tracker" },
        { id:"sorting-staff", label:"Staff", href:"./pages/sorting.html#staff" }
      ]
    },
    {
      id: "finish", label: "Finish",
      description: "Finish production by table and shift",
      href: "./pages/finish-production.html", icon: "finish", group: "Operations",
      permission: NAVIGATION_PERMISSIONS.FINISH,
      children: [
        { id:"finish-production", label:"Production", href:"./pages/finish-production.html" },
        { id:"finish-staff", label:"Staff", href:"./pages/finish-production.html?view=staff" }
      ]
    },
    {
      id: "finish-results", label: "Finish Results",
      description: "Daily Finish performance by table and shift",
      href: "./pages/finish-results.html", icon: "results", group: "Operations",
      permission: NAVIGATION_PERMISSIONS.FINISH_RESULTS
    },
    {
      id: "mop-production", label: "MOP Production",
      description: "MOP production recording",
      href: "./pages/mop-production.html", icon: "mop", group: "Operations",
      permission: NAVIGATION_PERMISSIONS.MOP_PRODUCTION
    },
    {
      id: "distribution", label: "Distribution",
      description: "Daily routes, drivers, fleet and delivery execution",
      href: "./pages/distribution.html", icon: "distribution", group: "Operations",
      permission: NAVIGATION_PERMISSIONS.DISTRIBUTION,
      children: [
        { id:"distribution-board", label:"Daily board", href:"./pages/distribution.html#board" },
        { id:"distribution-customers", label:"Route customers", href:"./pages/distribution.html#customers" },
        { id:"distribution-roster", label:"Weekly roster", href:"./pages/distribution.html#roster" },
        { id:"distribution-actuals", label:"Actuals", href:"./pages/distribution.html#actuals" },
        { id:"distribution-drivers", label:"Drivers", href:"./pages/distribution.html#drivers" },
        { id:"distribution-fleet", label:"Fleet", href:"./pages/distribution.html#fleet" },
        { id:"distribution-routes", label:"Routes", href:"./pages/distribution.html#routes" },
        { id:"distribution-history", label:"History", href:"./pages/distribution.html#history" }
      ]
    },
    {
      id: "production-tracker", label: "Production Tracker",
      description: "Shared Clothes and MOP production trace",
      href: "./pages/production-tracker.html", icon: "tracker", group: "Operations",
      permission: NAVIGATION_PERMISSIONS.PRODUCTION_TRACKER,
      children: [
        { id:"production-tracker-board", label:"Route board", href:"./pages/production-tracker.html?view=board" },
        { id:"production-tracker-list", label:"Operational list", href:"./pages/production-tracker.html?view=list" }
      ]
    },
    {
      id: "trolleys", label: "Trolleys",
      description: "Current trolley locations and custody history",
      href: "./pages/trolleys.html", icon: "trolley", group: "Operations",
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
      href: "./pages/production-insights.html", icon: "results", group: "Management",
      permission: NAVIGATION_PERMISSIONS.PRODUCTION_INSIGHTS
    },
    {
      id: "staff-master", label: "Staff Master",
      description: "Operational staff and work roles",
      href: "./pages/staff.html", icon: "user", group: "Administration",
      permission: NAVIGATION_PERMISSIONS.STAFF_MASTER,
      children: [
        { id:"staff-master-directory", label:"Staff directory", href:"./pages/staff.html" },
        { id:"staff-master-accounts", label:"Accounts & access", href:"./pages/staff.html?view=accounts", permission:"administration.accounts-access" }
      ]
    }
  ]);

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
