"use strict";

document.addEventListener("DOMContentLoaded", async () => {
  const loginView = document.getElementById("loginView");
  const appView = document.getElementById("appView");
  const operationalShell = document.getElementById("operationalShell");

  const loginForm = document.getElementById("loginForm");
  const emailInput = document.getElementById("email");
  const passwordInput = document.getElementById("password");
  const loginButton = document.getElementById("loginButton");
  const loginMessage = document.getElementById("loginMessage");
  const operationalAppMessage = document.getElementById("operationalAppMessage");

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
  const client = window.elisSupabase;
  const shellPolicy = window.ELIS_APP_SHELL_POLICY;

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

  function showLogin() {
    window.ELIS_OPERATIONAL_NAV?.unmount();
    document.body.classList.remove("elis-operational-mode");
    appView.classList.add("hidden");
    operationalShell.classList.add("hidden");
    loginView.classList.remove("hidden");
    operationalModuleGrid.replaceChildren();
  }

  function showHome() {
    document.body.classList.add("elis-operational-mode");
    loginView.classList.add("hidden");
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

  function createModuleIcon(iconName) {
    const icon = document.createElement("span");
    icon.className = "operational-module-card-icon";
    icon.innerHTML = shellPolicy.ICONS[iconName] || shellPolicy.ICONS.home;
    return icon;
  }

  function createOperationalModuleCard(module) {
    const element = document.createElement("a");
    element.className = "operational-module-card available";
    element.href = module.href;
    element.dataset.moduleId = module.id;
    element.appendChild(createModuleIcon(module.icon));

    const copy = document.createElement("div");
    copy.className = "operational-module-card-copy";
    const title = document.createElement("strong");
    title.textContent = module.label;
    const description = document.createElement("span");
    description.textContent = module.description;
    const status = document.createElement("small");
    status.textContent = "Open";
    copy.append(title, description, status);
    element.appendChild(copy);
    return element;
  }

  // Home cards follow the same sections and order as the side menu.
  function renderModuleGroups(modules) {
    const sections = shellPolicy.NAVIGATION_GROUPS
      .map((group) => ({ group, items: modules.filter((module) => module.group === group) }))
      .filter(({ items }) => items.length)
      .map(({ group, items }) => {
        const section = document.createElement("section");
        section.className = "operational-module-group";
        const heading = document.createElement("h3");
        heading.textContent = group;
        const grid = document.createElement("div");
        grid.className = "operational-module-group-grid";
        grid.append(...items.map(createOperationalModuleCard));
        section.append(heading, grid);
        return section;
      });
    operationalModuleGrid.replaceChildren(...sections);
  }

  function renderOperationalPrimaryAction(primaryModule) {
    operationalPrimaryAction.replaceChildren();
    if (!primaryModule) return;

    const link = document.createElement("a");
    link.className = "operational-primary-action";
    link.href = primaryModule.href;
    link.innerHTML = `${shellPolicy.ICONS[primaryModule.icon] || shellPolicy.ICONS.schedule}<span></span>`;
    link.querySelector("span").textContent = `Open ${primaryModule.label}`;
    operationalPrimaryAction.appendChild(link);
  }

  function renderHome(profile, roleCodes) {
    const administrative = shellPolicy.resolveAccountShell(profile, roleCodes) === "administrative";
    const context = shellPolicy.operationalContext(roleCodes);
    const permissionOverrides = shellPolicy.permissionOverrides(profile);
    const modules = shellPolicy.operationalModules(roleCodes, permissionOverrides)
      .filter((module) => module.id !== "home");
    const roleName = administrative
      ? (shellPolicy.ROLE_LABELS[roleCodes[0]] || context.roleName)
      : context.roleName;

    window.ELIS_OPERATIONAL_NAV?.mount(operationalShell, profile, roleCodes);

    operationalAreaCode.textContent = administrative ? "ElisCaretex" : context.areaName;
    operationalAreaName.textContent = "Home";
    operationalGreeting.textContent = `Welcome, ${profile.display_name || ""}`.trim();
    operationalIntroduction.textContent = administrative
      ? "Choose a workspace below or from the side menu."
      : context.introduction;
    operationalProfileName.textContent = profile.display_name || "—";
    operationalEmployeeCode.textContent = profile.employee_code || "Not provided";
    operationalRoleName.textContent = roleName || "—";
    operationalDate.textContent = new Intl.DateTimeFormat("en-IE", {
      weekday: "long",
      day: "2-digit",
      month: "short",
      year: "numeric"
    }).format(new Date());

    renderModuleGroups(modules);
    renderOperationalPrimaryAction(
      administrative ? null : shellPolicy.primaryOperationalModule(roleCodes, permissionOverrides)
    );

    const access = new URLSearchParams(location.search).get("access");
    if (access === "denied") {
      setMessage(operationalAppMessage, "Your account does not have access to that workspace.", "error");
    } else {
      setMessage(operationalAppMessage, "");
    }
  }

  async function renderNotificationAttention(canViewNotifications) {
    if (!canViewNotifications) return;

    try {
      const { data, error } = await client.rpc("get_my_notification_summary");
      if (error) throw error;
      const count = Number(data?.attention_count || 0);
      const card = operationalModuleGrid.querySelector('[data-module-id="notifications"]');
      if (!card) return;
      card.classList.toggle("has-attention", count > 0);
      let badge = card.querySelector(".notification-home-badge");
      if (!badge && count > 0) {
        badge = document.createElement("b");
        badge.className = "notification-home-badge";
        card.appendChild(badge);
      }
      if (badge) {
        badge.textContent = count > 99 ? "99+" : String(count);
        badge.classList.toggle("hidden", count === 0);
      }
      if (count > 0) {
        card.querySelector(".operational-module-card-copy span").textContent =
          `${count} notification${count === 1 ? "" : "s"} need your attention`;
      }
    } catch (error) {
      console.warn("Notification summary could not be loaded:", error);
    }
  }

  async function loadAuthenticatedProfile() {
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
    const access = shellPolicy.navigationAccess(
      roleCodes,
      shellPolicy.permissionOverrides(profile)
    );

    if (roleCodes.length === 0 && !(profile.permissions || []).length) {
      throw new Error("This account has no active access permission.");
    }

    renderHome(profile, roleCodes);
    showHome();
    await renderNotificationAttention(
      access.can(shellPolicy.NAVIGATION_PERMISSIONS.NOTIFICATIONS)
    );
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
      await loadAuthenticatedProfile();
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

      await loadAuthenticatedProfile();
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

  client.auth.onAuthStateChange((event) => {
    if (event === "SIGNED_OUT" && !loginView.classList.contains("hidden")) {
      return;
    }

    if (event === "SIGNED_OUT") {
      showLogin();
    }
  });
});
