"use strict";

(function initOperationalPageNavigation() {
  document.addEventListener("DOMContentLoaded", async () => {
    const root = document.querySelector("[data-operational-shell-root]");
    const client = window.elisSupabase;
    const policy = window.ELIS_APP_SHELL_POLICY;
    if (!root || !client || !policy) return;

    document.body.classList.add("elis-operational-mode", "elis-operational-tool-page");
    root.classList.add("operational-shell");

    const pageHeader = document.querySelector([
      ".customers-header",
      ".staff-header",
      ".roster-app-header",
      ".sorting-topbar",
      ".finish-topbar",
      ".finish-results-topbar",
      ".production-tracker-header",
      ".trolleys-header"
    ].join(","));
    pageHeader?.classList.add("operational-page-header");

    const aside = document.createElement("aside");
    aside.className = "operational-sidebar operational-tool-sidebar";
    aside.setAttribute("aria-label", "Operational navigation");
    aside.innerHTML = `
      <div class="operational-sidebar-brand">
        <img class="operational-sidebar-logo" src="../assets/img/elis-logo.svg" alt="Elis">
        <div class="operational-brand-copy"><strong>ElisCaretex</strong><span>Operational workspace</span></div>
      </div>
      <button class="operational-sidebar-toggle" type="button" aria-label="Expand navigation" aria-expanded="false" title="Expand navigation">
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="m9 5 7 7-7 7"></path></svg>
      </button>
      <nav class="operational-nav"></nav>
      <div class="operational-sidebar-footer">
        <div class="operational-user-mini" title="Signed-in staff member">
          <span class="operational-user-avatar">—</span>
          <div class="operational-user-copy"><strong>Loading...</strong><span>Operational User</span></div>
        </div>
        <button class="operational-sign-out" type="button" title="Sign out">
          <span>${policy.ICONS.signout}</span><strong>Sign out</strong>
        </button>
      </div>`;
    root.prepend(aside);

    const toggle = aside.querySelector(".operational-sidebar-toggle");
    const nav = aside.querySelector(".operational-nav");
    const avatar = aside.querySelector(".operational-user-avatar");
    const userName = aside.querySelector(".operational-user-copy strong");
    const userRole = aside.querySelector(".operational-user-copy span");
    const signOut = aside.querySelector(".operational-sign-out");

    const desktopNavigation = window.matchMedia("(min-width: 701px)");
    let navigationInProgress = false;

    function updateSidebarState() {
      const expanded = root.classList.contains("sidebar-expanded") || root.classList.contains("sidebar-hover-expanded");
      toggle.setAttribute("aria-expanded", String(expanded));
      toggle.setAttribute("aria-label", expanded ? "Collapse navigation" : "Expand navigation");
      toggle.setAttribute("title", expanded ? "Collapse navigation" : "Expand navigation");
    }

    const sidebarPreferenceKey = "elis.operational.sidebar.expanded";
    const navigationProfileCacheKey = "elis.operational.navigation.profile";

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
        // Navigation still works when browser storage is unavailable.
      }
    }

    function setSidebarExpanded(expanded, persist = true) {
      root.classList.toggle("sidebar-expanded", expanded);
      if (persist) saveSidebarPreference(expanded);
      updateSidebarState();
    }

    function setSidebarHover(expanded) {
      root.classList.toggle("sidebar-hover-expanded", desktopNavigation.matches && expanded);
      updateSidebarState();
    }

    setSidebarExpanded(desktopNavigation.matches && savedSidebarPreference(), false);

    toggle.addEventListener("click", () => {
      const expanded = !root.classList.contains("sidebar-expanded");
      setSidebarExpanded(expanded);
    });

    aside.addEventListener("mouseenter", () => setSidebarHover(true));
    aside.addEventListener("mouseleave", () => {
      if (navigationInProgress) return;
      setSidebarHover(false);
      setSidebarExpanded(false);
    });
    aside.addEventListener("focusin", () => setSidebarHover(true));
    aside.addEventListener("focusout", () => {
      window.setTimeout(() => {
        if (!aside.contains(document.activeElement)) setSidebarHover(false);
      }, 0);
    });
    desktopNavigation.addEventListener("change", () => {
      if (!desktopNavigation.matches) {
        setSidebarHover(false);
        setSidebarExpanded(false);
      }
    });

    signOut.addEventListener("click", async () => {
      try {
        await client.auth.signOut();
      } finally {
        window.location.href = "../index.html";
      }
    });

    function initials(value) {
      const parts = String(value || "").trim().split(/\s+/).filter(Boolean);
      return parts.length ? parts.slice(0, 2).map((part) => part[0]).join("").toUpperCase() : "—";
    }

    function dublinDateKey() {
      const parts = new Intl.DateTimeFormat("en-CA", {
        timeZone: "Europe/Dublin",
        year: "numeric",
        month: "2-digit",
        day: "2-digit"
      }).formatToParts(new Date());
      const map = Object.fromEntries(parts.map((part) => [part.type, part.value]));
      return `${map.year}-${map.month}-${map.day}`;
    }

    function roleIsEffective(staffRole) {
      if (!staffRole?.active || !staffRole.roles?.role_code) return false;
      const today = dublinDateKey();
      const from = staffRole.effective_from ? String(staffRole.effective_from).slice(0, 10) : null;
      const until = staffRole.effective_until ? String(staffRole.effective_until).slice(0, 10) : null;
      return (!from || from <= today) && (!until || until >= today);
    }

    function currentModuleId() {
      const page = location.pathname.split("/").pop();
      if (page === "finish-production.html") {
        return "finish";
      }
      if (page === "finish-results.html") return "finish-results";
      if (page === "production-tracker.html") return "production-tracker";
      if (page === "distribution.html") return "distribution";
      if (page === "trolleys.html") return "trolleys";
      if (page === "customers.html") {
        return "customer-workspace";
      }
      if (page === "staff.html") return "staff-master";
      if (page === "sorting.html") return "sorting";
      if (page === "mop-production.html") return "sorting";
      if (page === "roster.html") return "production-roster";
      return "";
    }

    function currentRequiredPermission() {
      const page = location.pathname.split("/").pop();
      const permissions = policy.NAVIGATION_PERMISSIONS;
      if (page === "customers.html") return permissions.CUSTOMER_WORKSPACE;
      if (page === "roster.html") return permissions.PRODUCTION_ROSTER;
      if (page === "sorting.html") return permissions.SORTING;
      if (page === "mop-production.html") return permissions.MOP_PRODUCTION;
      if (page === "finish-production.html") return permissions.FINISH;
      if (page === "finish-results.html") return permissions.FINISH_RESULTS;
      if (page === "production-tracker.html") return permissions.PRODUCTION_TRACKER;
      if (page === "distribution.html") return permissions.DISTRIBUTION;
      if (page === "trolleys.html") return permissions.TROLLEYS;
      if (page === "staff.html" && new URLSearchParams(location.search).get("view") === "accounts") return "administration.accounts-access";
      if (page === "staff.html") return permissions.STAFF_MASTER;
      return "";
    }

    function currentSubmoduleId(activeId) {
      const query = new URLSearchParams(location.search);
      if (activeId === "sorting") {
        if (location.pathname.endsWith("/mop-production.html")) return "sorting-mop";
        const view = String(location.hash || "").replace("#", "") || query.get("view") || "washing";
        return `sorting-${["washing","trolley","mop","tracker","staff"].includes(view) ? view : "washing"}`;
      }
      if (activeId === "finish") {
        return query.get("view") === "staff" ? "finish-staff" : "finish-production";
      }
      if (activeId === "production-tracker") {
        return String(query.get("view") || "").toLowerCase() === "list" ? "production-tracker-list" : "production-tracker-board";
      }
      if (activeId === "staff-master") {
        return query.get("view") === "accounts" ? "staff-master-accounts" : "staff-master-directory";
      }
      if (activeId === "trolleys") {
        const view = String(location.hash || "").replace("#", "") || "locations";
        return `trolleys-${["locations","master","types"].includes(view) ? view : "locations"}`;
      }
      if (activeId === "customer-workspace") {
        const view = query.get("view") || "schedule";
        return `customer-workspace-${["schedule","master","reports"].includes(view) ? view : "schedule"}`;
      }
      if (activeId === "distribution") {
        const view = String(location.hash || "").replace("#", "") || "board";
        return `distribution-${["board","customers","roster","actuals","drivers","fleet","routes","history"].includes(view) ? view : "board"}`;
      }
      return "";
    }

    function resolveHref(href, moduleId, finishWorkspace) {
      const frontendRoot = new URL("../", location.href);
      const url = new URL(String(href || "").replace(/^\.\//, ""), frontendRoot);
      const current = new URLSearchParams(location.search);
      const finishTable = current.get("table") || current.get("finishTable");
      if (finishTable) {
        if (moduleId === "finish") url.searchParams.set("table", finishTable);
        else if (["production-tracker","trolleys"].includes(moduleId)) url.searchParams.set("finishTable", finishTable);
      }
      if (finishWorkspace && ["production-tracker","trolleys"].includes(moduleId)) url.searchParams.set("workspace","finish");
      return url.href;
    }

    function createNavItem(module, activeId, finishWorkspace) {
      const item = module.status === "available" ? document.createElement("a") : document.createElement("button");
      item.className = `operational-nav-item ${module.status}`;
      item.title = module.label;
      if (module.status === "available") item.href = resolveHref(module.href, module.id, finishWorkspace);
      else { item.type = "button"; item.disabled = true; }
      if (module.id === activeId) {
        item.classList.add("active");
        item.setAttribute("aria-current", "page");
      }
      item.innerHTML = `
        <span class="operational-nav-icon">${policy.ICONS[module.icon] || policy.ICONS.home}</span>
        <span class="operational-nav-copy"><strong>${module.label}</strong><small>${module.description}</small></span>
        ${module.status === "available" ? "" : '<span class="operational-nav-status">Planned</span>'}`;
      return item;
    }

    function createSubnavItem(child, module, activeSubId, finishWorkspace) {
      const item = document.createElement("a");
      item.className = "operational-nav-subitem";
      item.href = resolveHref(child.href || module.href, module.id, finishWorkspace);
      item.textContent = child.label;
      item.title = child.label;
      if (child.id === activeSubId) {
        item.classList.add("active");
        item.setAttribute("aria-current", "page");
      }
      return item;
    }

    function renderNavigation(modules, activeId, finishWorkspace) {
      const groupOrder = ["Home", "Customer Planning", "Operations", "Administration"];
      const grouped = new Map(groupOrder.map((name) => [name, []]));
      const activeSubId = currentSubmoduleId(activeId);
      modules.forEach((module) => {
        const group = grouped.has(module.group) ? module.group : "Operations";
        grouped.get(group).push(module);
      });
      const fragments = [];
      groupOrder.forEach((group) => {
        const items = grouped.get(group);
        if (!items.length) return;
        const section = document.createElement("section");
        section.className = "operational-nav-group";
        if (group !== "Home") section.innerHTML = `<h2>${group}</h2>`;
        else section.classList.add("home");
        const list = document.createElement("div");
        list.className = "operational-nav-group-items";
        const nodes = [];
        items.forEach((module) => {
          nodes.push(createNavItem(module, activeId, finishWorkspace));
          if (module.id === activeId && Array.isArray(module.children) && module.children.length) {
            const subnav = document.createElement("div");
            subnav.className = "operational-nav-sublist";
            subnav.replaceChildren(...module.children.map((child) => createSubnavItem(child, module, activeSubId, finishWorkspace)));
            nodes.push(subnav);
          }
        });
        list.replaceChildren(...nodes);
        section.append(list);
        fragments.push(section);
      });
      nav.replaceChildren(...fragments);
    }

    function cacheNavigationProfile(profile, roleCodes) {
      try {
        window.sessionStorage.setItem(navigationProfileCacheKey, JSON.stringify({
          displayName: profile.display_name || "Signed in",
          roleCodes,
          accountType:profile.account_type || "",
          permissions:Array.isArray(profile.permissions) ? profile.permissions : []
        }));
      } catch (_) {
        // The live profile below remains the source of truth.
      }
    }

    function renderCachedNavigation() {
      try {
        const cached = JSON.parse(window.sessionStorage.getItem(navigationProfileCacheKey) || "null");
        if (!cached || !Array.isArray(cached.roleCodes) || !cached.roleCodes.length) return;
        const currentId = currentModuleId();
        const query = new URLSearchParams(location.search);
        const finishWorkspace = currentId === "finish" || currentId === "finish-results" || query.get("workspace") === "finish";
        const cachedProfile = { account_type:cached.accountType,permissions:cached.permissions || [] };
        renderNavigation(policy.operationalModules(cached.roleCodes,policy.permissionOverrides(cachedProfile)), currentId, finishWorkspace);
        avatar.textContent = initials(cached.displayName);
        userName.textContent = cached.displayName;
        userRole.textContent = policy.operationalContext(cached.roleCodes).roleName;
      } catch (_) {
        // Ignore stale or unavailable cache and continue with the live profile.
      }
    }

    renderCachedNavigation();

    nav.addEventListener("click", (event) => {
      const link = event.target.closest("a.operational-nav-item, a.operational-nav-subitem");
      if (!link || event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      const target = new URL(link.href, window.location.href);
      if (target.href === window.location.href) return;
      event.preventDefault();
      if (target.origin === location.origin && target.pathname === location.pathname && target.search === location.search && target.hash) {
        location.hash = target.hash;
        nav.querySelectorAll(".operational-nav-subitem").forEach((item) => item.classList.toggle("active", item.href === target.href));
        return;
      }
      saveSidebarPreference(root.classList.contains("sidebar-expanded") || root.classList.contains("sidebar-hover-expanded"));
      navigationInProgress = true;
      window.location.href = target.href;
    });

    try {
      const { data: { session }, error: sessionError } = await client.auth.getSession();
      if (sessionError) throw sessionError;
      if (!session?.user) return;

      const { data: profile, error } = await client.rpc("get_current_account_access");
      if (error) throw error;
      if (!profile) return;

      const roleCodes = policy.uniqueRoleCodes(profile.role_codes || []);
      const permissionOverrides = policy.permissionOverrides(profile);
      const access = policy.navigationAccess(roleCodes,permissionOverrides);
      const requiredPermission = currentRequiredPermission();
      if (requiredPermission && !access.can(requiredPermission)) {
        window.location.replace("../index.html?access=denied");
        return;
      }
      const currentId = currentModuleId();
      const query = new URLSearchParams(location.search);
      const finishWorkspace = currentId === "finish" || currentId === "finish-results" || query.get("workspace") === "finish";
      const modules = policy.operationalModules(roleCodes,permissionOverrides);
      renderNavigation(modules, currentId, finishWorkspace);
      cacheNavigationProfile(profile, roleCodes);
      avatar.textContent = initials(profile.display_name);
      userName.textContent = profile.display_name || "Signed in";
      userRole.textContent = policy.operationalContext(roleCodes).roleName;
    } catch (error) {
      console.warn("Operational navigation profile could not be loaded.", error);
      nav.innerHTML = `<a class="operational-nav-item available" href="../index.html" title="Home"><span class="operational-nav-icon">${policy.ICONS.home}</span><span class="operational-nav-copy"><strong>Home</strong><small>Operational start page</small></span></a>`;
    }
  });
})();
