"use strict";

document.addEventListener("DOMContentLoaded", async () => {
  const loginView = document.getElementById("loginView");
  const appView = document.getElementById("appView");
  const administrativeShell = document.getElementById("administrativeShell");
  const operationalShell = document.getElementById("operationalShell");

  const loginForm = document.getElementById("loginForm");
  const emailInput = document.getElementById("email");
  const passwordInput = document.getElementById("password");
  const loginButton = document.getElementById("loginButton");
  const adminLogoutButton = document.getElementById("adminLogoutButton");
  const operationalLogoutButton = document.getElementById("operationalLogoutButton");

  const loginMessage = document.getElementById("loginMessage");
  const adminAppMessage = document.getElementById("adminAppMessage");
  const operationalAppMessage = document.getElementById("operationalAppMessage");

  const adminProfileName = document.getElementById("adminProfileName");
  const adminProfileEmail = document.getElementById("adminProfileEmail");
  const adminEmployeeCode = document.getElementById("adminEmployeeCode");
  const adminRoleList = document.getElementById("adminRoleList");
  const adminCustomersModule = document.getElementById("adminCustomersModule");
  const adminTrolleysModule = document.getElementById("adminTrolleysModule");
  const adminSortingModule = document.getElementById("adminSortingModule");
  const adminProductionTrackerModule = document.getElementById("adminProductionTrackerModule");
  const adminDistributionModule = document.getElementById("adminDistributionModule");
  const adminMopModule = document.getElementById("adminMopModule");
  const adminFinishModule = document.getElementById("adminFinishModule");
  const adminStaffModule = document.getElementById("adminStaffModule");
  const adminRosterModule = document.getElementById("adminRosterModule");
  const adminMyRosterModule = document.getElementById("adminMyRosterModule");

  const operationalSidebarToggle = document.getElementById("operationalSidebarToggle");
  const operationalNav = document.getElementById("operationalNav");
  const sidebarPreferenceKey = "elis.operational.sidebar.expanded";

  function savedSidebarPreference() {
    try {
      return window.sessionStorage.getItem(sidebarPreferenceKey) === "true";
    } catch (_) {
      return false;
    }
  }

  function saveSidebarPreference(expanded) {
    try {
      window.sessionStorage.setItem(sidebarPreferenceKey, String(expanded));
    } catch (_) {
      // Navigation remains functional without browser storage.
    }
  }
  const operationalModuleGrid = document.getElementById("operationalModuleGrid");
  const operationalPrimaryAction = document.getElementById("operationalPrimaryAction");
  const operationalAreaCode = document.getElementById("operationalAreaCode");
  const operationalAreaName = document.getElementById("operationalAreaName");
  const operationalDate = document.getElementById("operationalDate");
  const operationalGreeting = document.getElementById("operationalGreeting");
  const operationalIntroduction = document.getElementById("operationalIntroduction");
  const operationalProfileName = document.getElementById("operationalProfileName");
  const operationalEmployeeCode = document.getElementById("operationalEmployeeCode");
  const operationalRoleName = document.getElementById("operationalRoleName");
  const operationalUserAvatar = document.getElementById("operationalUserAvatar");
  const operationalSidebarUserName = document.getElementById("operationalSidebarUserName");
  const operationalSidebarUserRole = document.getElementById("operationalSidebarUserRole");

  const client = window.elisSupabase;
  const shellPolicy = window.ELIS_APP_SHELL_POLICY;
  let activeShell = "";

  function setMessage(element, text = "", type = "") {
    if (!element) {
      return;
    }

    element.textContent = text;
    element.className = element === operationalAppMessage
      ? "message operational-message"
      : "message";

    if (type) {
      element.classList.add(type);
    }
  }

  function resetShellClasses() {
    document.body.classList.remove(
      "elis-administrative-mode",
      "elis-operational-mode"
    );
  }

  function showLogin() {
    activeShell = "";
    resetShellClasses();

    appView.classList.add("hidden");
    administrativeShell.classList.add("hidden");
    operationalShell.classList.add("hidden");
    loginView.classList.remove("hidden");

    adminProfileName.textContent = "";
    adminProfileEmail.textContent = "";
    adminEmployeeCode.textContent = "—";
    adminRoleList.replaceChildren();
    operationalNav.replaceChildren();
    operationalModuleGrid.replaceChildren();
  }

  function showAdministrativeShell() {
    activeShell = "administrative";
    resetShellClasses();
    document.body.classList.add("elis-administrative-mode");

    loginView.classList.add("hidden");
    operationalShell.classList.add("hidden");
    administrativeShell.classList.remove("hidden");
    appView.classList.remove("hidden");
  }

  function showOperationalShell() {
    activeShell = "operational";
    resetShellClasses();
    document.body.classList.add("elis-operational-mode");

    loginView.classList.add("hidden");
    administrativeShell.classList.add("hidden");
    operationalShell.classList.remove("hidden");
    appView.classList.remove("hidden");
  }

  function roleIsEffective(staffRole) {
    if (!staffRole?.active || !staffRole.roles?.role_code) {
      return false;
    }

    const today = new Date().toISOString().slice(0, 10);
    const effectiveFrom = staffRole.effective_from
      ? String(staffRole.effective_from).slice(0, 10)
      : null;
    const effectiveUntil = staffRole.effective_until
      ? String(staffRole.effective_until).slice(0, 10)
      : null;

    return (!effectiveFrom || effectiveFrom <= today) &&
      (!effectiveUntil || effectiveUntil >= today);
  }

  function activeRoles(profile) {
    if (Array.isArray(profile?.roles)) return profile.roles;
    return (profile?.staff_roles || [])
      .filter(roleIsEffective)
      .map((staffRole) => staffRole.roles)
      .filter(Boolean);
  }

  function activeRoleCodes(profile) {
    return shellPolicy.uniqueRoleCodes(
      activeRoles(profile).map((role) => role.role_code)
    );
  }

  function renderAdministrativeRoles(roles) {
    adminRoleList.replaceChildren();

    if (roles.length === 0) {
      const empty = document.createElement("span");
      empty.textContent = "No active roles";
      empty.className = "muted";
      adminRoleList.appendChild(empty);
      return;
    }

    roles.forEach((role) => {
      const badge = document.createElement("span");
      badge.className = "role-badge";
      badge.textContent = role.role_code;
      badge.title = role.role_name;
      adminRoleList.appendChild(badge);
    });
  }

  function initials(value) {
    const words = String(value || "")
      .trim()
      .split(/\s+/)
      .filter(Boolean);

    if (words.length === 0) {
      return "—";
    }

    return words.slice(0, 2).map((word) => word[0]).join("").toUpperCase();
  }

  function createModuleIcon(iconName) {
    const icon = document.createElement("span");
    icon.className = "operational-module-card-icon";
    icon.innerHTML = shellPolicy.ICONS[iconName] || shellPolicy.ICONS.home;
    return icon;
  }

  function createOperationalModuleCard(module) {
    const element = module.status === "available"
      ? document.createElement("a")
      : document.createElement("div");

    element.className = `operational-module-card ${module.status}`;

    if (module.status === "available") {
      element.href = module.href;
    } else {
      element.setAttribute("aria-disabled", "true");
    }

    element.appendChild(createModuleIcon(module.icon));

    const copy = document.createElement("div");
    copy.className = "operational-module-card-copy";

    const title = document.createElement("strong");
    title.textContent = module.label;

    const description = document.createElement("span");
    description.textContent = module.description;

    const status = document.createElement("small");
    status.textContent = module.status === "available" ? "Open tool" : "Planned";

    copy.append(title, description, status);
    element.appendChild(copy);

    return element;
  }

  function createOperationalNavItem(module) {
    const element = module.status === "available"
      ? document.createElement("a")
      : document.createElement("button");

    element.className = `operational-nav-item ${module.status}`;
    element.title = module.label;

    if (module.id === "home") {
      element.classList.add("active");
      element.setAttribute("aria-current", "page");
    }

    if (module.status === "available") {
      element.href = module.href;
    } else {
      element.type = "button";
      element.disabled = true;
    }

    const icon = document.createElement("span");
    icon.className = "operational-nav-icon";
    icon.innerHTML = shellPolicy.ICONS[module.icon] || shellPolicy.ICONS.home;

    const copy = document.createElement("span");
    copy.className = "operational-nav-copy";

    const label = document.createElement("strong");
    label.textContent = module.label;

    const description = document.createElement("small");
    description.textContent = module.description;

    copy.append(label, description);
    element.append(icon, copy);

    if (module.status !== "available") {
      const status = document.createElement("span");
      status.className = "operational-nav-status";
      status.textContent = "Planned";
      element.appendChild(status);
    }

    return element;
  }

  function renderOperationalPrimaryAction(primaryModule) {
    operationalPrimaryAction.replaceChildren();

    if (!primaryModule) {
      const note = document.createElement("span");
      note.className = "operational-primary-action";
      note.textContent = "Operational module is being prepared";
      operationalPrimaryAction.appendChild(note);
      return;
    }

    const link = document.createElement("a");
    link.className = "operational-primary-action";
    link.href = primaryModule.href;
    link.innerHTML = `${shellPolicy.ICONS[primaryModule.icon] || shellPolicy.ICONS.schedule}<span>Open ${primaryModule.label}</span>`;
    operationalPrimaryAction.appendChild(link);
  }

  function renderOperationalShell(profile, roleCodes) {
    const sidebarExpanded = savedSidebarPreference();
    operationalShell.classList.toggle("sidebar-expanded", sidebarExpanded);
    operationalSidebarToggle.setAttribute("aria-expanded", String(sidebarExpanded));
    const context = shellPolicy.operationalContext(roleCodes);
    const permissionOverrides = shellPolicy.permissionOverrides(profile);
    const modules = shellPolicy.operationalModules(roleCodes,permissionOverrides);
    const primaryModule = shellPolicy.primaryOperationalModule(roleCodes,permissionOverrides);
    const visibleModules = modules.filter((module) => module.id !== "home");

    operationalAreaCode.textContent = context.areaCode;
    operationalAreaName.textContent = context.areaName;
    operationalGreeting.textContent = `Welcome, ${profile.display_name}`;
    operationalIntroduction.textContent = context.introduction;
    operationalProfileName.textContent = profile.display_name;
    operationalEmployeeCode.textContent = profile.employee_code || "Not provided";
    operationalRoleName.textContent = context.roleName;
    operationalUserAvatar.textContent = initials(profile.display_name);
    operationalSidebarUserName.textContent = profile.display_name;
    operationalSidebarUserRole.textContent = context.roleName;
    operationalDate.textContent = new Intl.DateTimeFormat("en-IE", {
      weekday: "long",
      day: "2-digit",
      month: "short",
      year: "numeric"
    }).format(new Date());

    operationalLogoutButton.innerHTML = shellPolicy.ICONS.signout;

    operationalNav.replaceChildren(
      ...modules.map(createOperationalNavItem)
    );

    operationalModuleGrid.replaceChildren(
      ...visibleModules.map(createOperationalModuleCard)
    );

    renderOperationalPrimaryAction(primaryModule);
    setMessage(operationalAppMessage, "Sign-in confirmed.", "success");
  }

  function renderAdministrativeShell(profile, user) {
    const roles = activeRoles(profile);
    const roleCodes = new Set(roles.map((role) => role.role_code));
    const access = shellPolicy.navigationAccess([...roleCodes],shellPolicy.permissionOverrides(profile));

    if (adminCustomersModule) {
      adminCustomersModule.classList.toggle(
        "hidden",
        !access.can(shellPolicy.NAVIGATION_PERMISSIONS.CUSTOMER_WORKSPACE)
      );
    }

    if (adminTrolleysModule) {
      adminTrolleysModule.classList.toggle(
        "hidden",
        !access.can(shellPolicy.NAVIGATION_PERMISSIONS.TROLLEYS)
      );
    }

    if (adminSortingModule) {
      adminSortingModule.classList.toggle(
        "hidden",
        !access.can(shellPolicy.NAVIGATION_PERMISSIONS.SORTING)
      );
    }

    if (adminProductionTrackerModule) {
      adminProductionTrackerModule.classList.toggle(
        "hidden",
        !access.can(shellPolicy.NAVIGATION_PERMISSIONS.PRODUCTION_TRACKER)
      );
    }

    if (adminDistributionModule) {
      adminDistributionModule.classList.toggle(
        "hidden",
        !access.can(shellPolicy.NAVIGATION_PERMISSIONS.DISTRIBUTION)
      );
    }

    if (adminMopModule) {
      adminMopModule.classList.toggle(
        "hidden",
        !access.can(shellPolicy.NAVIGATION_PERMISSIONS.MOP_PRODUCTION)
      );
    }

    if (adminFinishModule) {
      adminFinishModule.classList.toggle(
        "hidden",
        !access.can(shellPolicy.NAVIGATION_PERMISSIONS.FINISH)
      );
    }

    if (adminStaffModule) {
      adminStaffModule.classList.toggle(
        "hidden",
        !access.can(shellPolicy.NAVIGATION_PERMISSIONS.STAFF_MASTER)
      );
    }

    if (adminRosterModule) {
      adminRosterModule.classList.toggle(
        "hidden",
        !access.can(shellPolicy.NAVIGATION_PERMISSIONS.PRODUCTION_ROSTER)
      );
    }

    if (adminMyRosterModule) {
      adminMyRosterModule.classList.toggle(
        "hidden",
        !access.can(shellPolicy.NAVIGATION_PERMISSIONS.MY_ROSTER)
      );
    }

    const adminNotificationsModule = document.getElementById("adminNotificationsModule");
    if (adminNotificationsModule) adminNotificationsModule.classList.toggle("hidden",!access.can(shellPolicy.NAVIGATION_PERMISSIONS.NOTIFICATIONS));

    adminProfileName.textContent = profile.display_name;
    adminProfileEmail.textContent = user.email || "";
    adminEmployeeCode.textContent = profile.employee_code || "Not provided";
    renderAdministrativeRoles(roles);
    setMessage(adminAppMessage, "Sign-in confirmed.", "success");
  }

  async function loadAuthenticatedProfile(user) {
    setMessage(adminAppMessage, "Loading account access...");
    setMessage(operationalAppMessage, "Loading account access...");

    const { data: profile, error } = await client.rpc("get_current_account_access");

    if (error) {
      console.error("Failed to load staff profile:", error);
      throw new Error(
        "Authentication succeeded, but account access could not be loaded."
      );
    }

    if (!profile) {
      throw new Error(
        "The user is authenticated but has no account access profile."
      );
    }

    if (profile.account_enabled === false) {
      await client.auth.signOut();
      throw new Error("This staff account is no longer active. Contact your manager if you believe this is incorrect.");
    }

    const roleCodes = activeRoleCodes(profile);

    if (roleCodes.length === 0 && !(profile.permissions || []).length) {
      throw new Error("This account has no active access permission.");
    }

    const shell = shellPolicy.resolveAccountShell(profile,roleCodes);

    if (shell === "administrative") {
      renderAdministrativeShell(profile, user);
      showAdministrativeShell();
    } else {
      renderOperationalShell(profile, roleCodes);
      showOperationalShell();
    }
  }

  async function signOut(button) {
    const originalLabel = button.getAttribute("aria-label") || button.textContent;
    button.disabled = true;

    if (button === adminLogoutButton) {
      button.textContent = "Signing out...";
    } else {
      button.setAttribute("aria-label", "Signing out");
    }

    try {
      const { error } = await client.auth.signOut();

      if (error) {
        throw error;
      }

      emailInput.value = "";
      passwordInput.value = "";
      setMessage(loginMessage, "You have signed out.", "success");
      showLogin();
    } catch (error) {
      console.error("Sign-out failed:", error);

      const target = activeShell === "operational"
        ? operationalAppMessage
        : adminAppMessage;
      setMessage(target, "The session could not be closed.", "error");
    } finally {
      button.disabled = false;

      if (button === adminLogoutButton) {
        button.textContent = "Sign out";
      } else {
        button.setAttribute("aria-label", originalLabel);
        button.innerHTML = shellPolicy.ICONS.signout;
      }
    }
  }

  if (window.ELIS_SUPABASE_ERROR || !client || !shellPolicy) {
    setMessage(
      loginMessage,
      window.ELIS_SUPABASE_ERROR ||
        (!shellPolicy
          ? "The app shell policy could not be loaded."
          : "The Supabase connection could not be initialized."),
      "error"
    );

    loginButton.disabled = true;
    return;
  }

  try {
    const {
      data: { session },
      error
    } = await client.auth.getSession();

    if (error) {
      throw error;
    }

    if (session?.user) {
      await loadAuthenticatedProfile(session.user);
    } else {
      showLogin();
    }
  } catch (error) {
    console.error("Failed to restore the session:", error);
    showLogin();
    setMessage(loginMessage, error.message, "error");
  }

  loginForm.addEventListener("submit", async (event) => {
    event.preventDefault();

    const loginIdentifier = emailInput.value.trim();
    const password = passwordInput.value;
    const loginCandidates = loginIdentifier.includes("@") ? [loginIdentifier] : [
      `${loginIdentifier.toLowerCase()}@staff.eliscaretex.local`,
      `${loginIdentifier.toLowerCase()}@workstation.eliscaretex.local`,
      `${loginIdentifier.toLowerCase()}@terminal.eliscaretex.local`
    ];

    if (!loginIdentifier || !password) {
      setMessage(loginMessage, "Enter your email, employee username or workstation user and password.", "error");
      return;
    }

    loginButton.disabled = true;
    loginButton.textContent = "Signing in...";
    setMessage(loginMessage, "");

    try {
      let data = null;
      let lastError = null;
      for (const email of loginCandidates) {
        const attempt = await client.auth.signInWithPassword({ email, password });
        if (!attempt.error) { data = attempt.data; lastError = null; break; }
        lastError = attempt.error;
      }
      if (lastError) throw lastError;

      if (!data.user) {
        throw new Error("Supabase did not return the authenticated user.");
      }

      await loadAuthenticatedProfile(data.user);
      passwordInput.value = "";
    } catch (error) {
      console.error("Sign-in failed:", error);
      await client.auth.signOut();
      showLogin();

      const friendlyMessage = error.message === "Invalid login credentials"
        ? "Incorrect email or password."
        : error.message;

      setMessage(loginMessage, friendlyMessage, "error");
    } finally {
      loginButton.disabled = false;
      loginButton.textContent = "Sign in";
    }
  });

  adminLogoutButton.addEventListener("click", () => signOut(adminLogoutButton));
  operationalLogoutButton.addEventListener("click", () => signOut(operationalLogoutButton));

  operationalSidebarToggle.addEventListener("click", () => {
    const expanded = operationalShell.classList.toggle("sidebar-expanded");
    saveSidebarPreference(expanded);
    operationalSidebarToggle.setAttribute("aria-expanded", String(expanded));
    operationalSidebarToggle.setAttribute(
      "aria-label",
      expanded ? "Collapse navigation" : "Expand navigation"
    );
    operationalSidebarToggle.title = expanded
      ? "Collapse navigation"
      : "Expand navigation";
  });

  operationalNav.addEventListener("click", () => {
    saveSidebarPreference(operationalShell.classList.contains("sidebar-expanded"));
  });

  client.auth.onAuthStateChange((event) => {
    if (event === "SIGNED_OUT" && !loginView.classList.contains("hidden")) {
      return;
    }

    if (event === "SIGNED_OUT") {
      showLogin();
    }
  });
});
