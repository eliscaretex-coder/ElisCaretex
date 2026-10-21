"use strict";

(function initOperationalPageNavigation() {
  // Resolve the frontend root from this script's own URL so the same sidebar
  // works on index.html and on every page under pages/.
  const scriptUrl = document.currentScript?.src || new URL("assets/js/operational-page-nav.js", location.href).href;
  const frontendRoot = new URL("../../", scriptUrl);
  const sidebarPreferenceKey = "elis.operational.sidebar.expanded";
  const navigationProfileCacheKey = "elis.operational.navigation.profile";

  let shell = null;

  function currentPage() {
    return location.pathname.split("/").pop() || "index.html";
  }

  function initials(value) {
    const parts = String(value || "").trim().split(/\s+/).filter(Boolean);
    return parts.length ? parts.slice(0, 2).map((part) => part[0]).join("").toUpperCase() : "—";
  }

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
  }

  function readStorage(storage, key) {
    try {
      return window[storage].getItem(key);
    } catch (_) {
      return null;
    }
  }

  function writeStorage(storage, key, value) {
    try {
      window[storage].setItem(key, value);
    } catch (_) {
      // Navigation still works when browser storage is unavailable.
    }
  }

  function createShell(root, policy, client) {
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
      ".trolleys-header",
      ".production-insights-header"
    ].join(","));
    pageHeader?.classList.add("operational-page-header");

    const homeHref = new URL("index.html", frontendRoot).href;
    const logoSrc = new URL("assets/img/elis-logo.svg", frontendRoot).href;

    const mobileBar = document.createElement("header");
    mobileBar.className = "operational-mobile-bar";
    mobileBar.innerHTML = `
      <button class="operational-mobile-menu" type="button" aria-label="Open navigation" aria-expanded="false">${policy.ICONS.menu}</button>
      <a href="${homeHref}" aria-label="Home"><img src="${logoSrc}" alt="Elis"></a>
      <span class="operational-mobile-title"></span>`;

    const backdrop = document.createElement("div");
    backdrop.className = "operational-nav-backdrop";

    const aside = document.createElement("aside");
    aside.className = "operational-sidebar operational-tool-sidebar";
    aside.setAttribute("aria-label", "Main navigation");
    aside.id = "operationalSidebar";
    aside.innerHTML = `
      <div class="operational-sidebar-brand">
        <img class="operational-sidebar-logo" src="${logoSrc}" alt="Elis">
        <div class="operational-brand-copy"><strong>ElisCaretex</strong><span>Laundry operations</span></div>
        <button class="operational-sidebar-close" type="button" aria-label="Close navigation">&times;</button>
      </div>
      <button class="operational-sidebar-toggle" type="button" aria-label="Expand navigation" aria-expanded="false" title="Expand navigation">
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="m9 5 7 7-7 7"></path></svg>
      </button>
      <nav class="operational-nav" aria-label="Workspaces"></nav>
      <div class="operational-sidebar-footer">
        <div class="operational-user-mini" title="Signed-in user">
          <span class="operational-user-avatar">—</span>
          <div class="operational-user-copy"><strong>Loading...</strong><span>&nbsp;</span></div>
        </div>
        <button class="operational-sign-out" type="button" title="Sign out">
          <span>${policy.ICONS.signout}</span><strong>Sign out</strong>
        </button>
      </div>`;
    root.prepend(mobileBar, aside, backdrop);

    const toggle = aside.querySelector(".operational-sidebar-toggle");
    const nav = aside.querySelector(".operational-nav");
    const menuButton = mobileBar.querySelector(".operational-mobile-menu");
    const desktopNavigation = window.matchMedia("(min-width: 701px)");
    let navigationInProgress = false;
    let currentModules = [];
    let finishWorkspace = false;

    function updateSidebarState() {
      const expanded = root.classList.contains("sidebar-expanded") || root.classList.contains("sidebar-hover-expanded");
      toggle.setAttribute("aria-expanded", String(expanded));
      toggle.setAttribute("aria-label", expanded ? "Collapse navigation" : "Expand navigation");
      toggle.setAttribute("title", root.classList.contains("sidebar-expanded") ? "Unpin navigation" : "Keep navigation open");
    }

    // Sub-pages are only visible while the menu is open, so scroll the current
    // one into view whenever the menu opens.
    function revealActive() {
      window.requestAnimationFrame(() => {
        const activeLink = nav.querySelector(".operational-nav-subitem.active") || nav.querySelector(".operational-nav-item.active");
        if (!activeLink || !activeLink.offsetHeight) return;
        const top = activeLink.offsetTop;
        if (top < nav.scrollTop || top + activeLink.offsetHeight > nav.scrollTop + nav.clientHeight) {
          nav.scrollTop = Math.max(0, top - nav.clientHeight / 2);
        }
      });
    }

    function setSidebarExpanded(expanded, persist = true) {
      root.classList.toggle("sidebar-expanded", expanded);
      if (persist) writeStorage("sessionStorage", sidebarPreferenceKey, String(expanded));
      updateSidebarState();
      if (expanded) revealActive();
    }

    function setSidebarHover(expanded) {
      const wasExpanded = root.classList.contains("sidebar-hover-expanded");
      root.classList.toggle("sidebar-hover-expanded", desktopNavigation.matches && expanded);
      updateSidebarState();
      if (expanded && !wasExpanded) revealActive();
    }

    function setDrawerOpen(open) {
      root.classList.toggle("nav-open", open);
      document.body.classList.toggle("nav-drawer-open", open);
      menuButton.setAttribute("aria-expanded", String(open));
      menuButton.setAttribute("aria-label", open ? "Close navigation" : "Open navigation");
      if (open) {
        aside.querySelector(".operational-nav-item.active, .operational-nav-item")?.focus({ preventScroll: true });
        revealActive();
      }
    }

    setSidebarExpanded(desktopNavigation.matches && readStorage("sessionStorage", sidebarPreferenceKey) === "true", false);

    toggle.addEventListener("click", () => setSidebarExpanded(!root.classList.contains("sidebar-expanded")));
    menuButton.addEventListener("click", () => setDrawerOpen(!root.classList.contains("nav-open")));
    backdrop.addEventListener("click", () => setDrawerOpen(false));
    aside.querySelector(".operational-sidebar-close").addEventListener("click", () => {
      setDrawerOpen(false);
      menuButton.focus();
    });
    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape" && root.classList.contains("nav-open")) {
        setDrawerOpen(false);
        menuButton.focus();
      }
    });

    aside.addEventListener("mouseenter", () => setSidebarHover(true));
    aside.addEventListener("mouseleave", () => {
      if (!navigationInProgress) setSidebarHover(false);
    });
    aside.addEventListener("focusin", () => setSidebarHover(true));
    aside.addEventListener("focusout", () => {
      window.setTimeout(() => {
        if (!aside.contains(document.activeElement)) setSidebarHover(false);
      }, 0);
    });
    desktopNavigation.addEventListener("change", () => {
      setDrawerOpen(false);
      if (!desktopNavigation.matches) {
        setSidebarHover(false);
        setSidebarExpanded(false, false);
      }
    });

    aside.querySelector(".operational-sign-out").addEventListener("click", async () => {
      try {
        await client.auth.signOut();
      } finally {
        try {
          window.sessionStorage.removeItem(navigationProfileCacheKey);
        } catch (_) {
          // Nothing cached.
        }
        window.location.href = homeHref;
      }
    });

    function resolveHref(href, moduleId) {
      const url = new URL(String(href || "").replace(/^\.\//, ""), frontendRoot);
      const current = new URLSearchParams(location.search);
      const finishTable = current.get("table") || current.get("finishTable");
      if (finishTable) {
        if (moduleId === "finish") url.searchParams.set("table", finishTable);
        else if (["production-tracker", "trolleys"].includes(moduleId)) url.searchParams.set("finishTable", finishTable);
      }
      if (finishWorkspace && ["production-tracker", "trolleys"].includes(moduleId)) url.searchParams.set("workspace", "finish");
      return url.href;
    }

    // The sub-page whose link matches the current address best: same page and
    // the same ?view= and #hash when the link names them; otherwise the first
    // sub-page of the current page (its default view).
    function activeSubmoduleId(module) {
      const children = Array.isArray(module?.children) ? module.children : [];
      const candidates = children
        .map((child) => ({ child, url: new URL(String(child.href || "").replace(/^\.\//, ""), frontendRoot) }))
        .filter(({ url }) => url.pathname === location.pathname);
      const currentView = new URLSearchParams(location.search).get("view");
      const siblingHasView = candidates.some(({ url }) => currentView && url.searchParams.get("view") === currentView);
      const match = candidates.find(({ url }) => {
        const view = url.searchParams.get("view");
        if (view ? view !== currentView : siblingHasView) return false;
        return !url.hash || url.hash === location.hash;
      });
      return (match || candidates[0])?.child.id || "";
    }

    function createNavItem(module, activeId) {
      const item = document.createElement("a");
      item.className = "operational-nav-item available";
      item.title = module.label;
      item.href = resolveHref(module.href, module.id);
      item.dataset.moduleId = module.id;
      if (module.id === activeId) {
        item.classList.add("active");
        item.setAttribute("aria-current", "page");
      }
      item.innerHTML = `
        <span class="operational-nav-icon">${policy.ICONS[module.icon] || policy.ICONS.home}</span>
        <span class="operational-nav-copy"><strong>${escapeHtml(module.label)}</strong><small>${escapeHtml(module.description)}</small></span>
        ${module.id === "notifications" ? '<span class="operational-nav-badge" hidden></span>' : ""}`;
      return item;
    }

    function createSubnavItem(child, module, activeSubId) {
      const item = document.createElement("a");
      item.className = "operational-nav-subitem";
      item.href = resolveHref(child.href || module.href, module.id);
      item.textContent = child.label;
      item.title = child.label;
      item.dataset.childId = child.id;
      if (child.id === activeSubId) {
        item.classList.add("active");
        item.setAttribute("aria-current", "page");
      }
      return item;
    }

    function syncActiveSubitem() {
      const activeId = policy.PAGE_MODULES[currentPage()] || "";
      const module = currentModules.find((candidate) => candidate.id === activeId);
      const activeSubId = activeSubmoduleId(module);
      nav.querySelectorAll(".operational-nav-subitem").forEach((item) => {
        const active = item.dataset.childId === activeSubId;
        item.classList.toggle("active", active);
        if (active) item.setAttribute("aria-current", "page");
        else item.removeAttribute("aria-current");
      });
      const child = module?.children?.find((candidate) => candidate.id === activeSubId);
      mobileBar.querySelector(".operational-mobile-title").textContent = module
        ? (child && child.label !== module.label ? `${module.label} · ${child.label}` : module.label)
        : document.title.split("|")[0].trim();
    }

    function renderNavigation(modules) {
      currentModules = modules;
      const activeId = policy.PAGE_MODULES[currentPage()] || "";
      const query = new URLSearchParams(location.search);
      finishWorkspace = activeId === "finish" || activeId === "finish-results" || query.get("workspace") === "finish";
      const activeModule = modules.find((module) => module.id === activeId);
      const activeSubId = activeSubmoduleId(activeModule);
      const groups = policy.NAVIGATION_GROUPS;
      const grouped = new Map(groups.map((name) => [name, []]));
      modules.forEach((module) => {
        const group = grouped.has(module.group) ? module.group : groups[groups.length - 1];
        grouped.get(group).push(module);
      });
      const sections = [];
      groups.forEach((group) => {
        const items = grouped.get(group);
        if (!items.length) return;
        const section = document.createElement("section");
        section.className = "operational-nav-group";
        if (group === "Home") section.classList.add("home");
        else section.innerHTML = `<h2>${escapeHtml(group)}</h2>`;
        const list = document.createElement("div");
        list.className = "operational-nav-group-items";
        items.forEach((module) => {
          list.append(createNavItem(module, activeId));
          if (module.id === activeId && Array.isArray(module.children) && module.children.length > 1) {
            const subnav = document.createElement("div");
            subnav.className = "operational-nav-sublist";
            subnav.append(...module.children.map((child) => createSubnavItem(child, module, activeSubId)));
            list.append(subnav);
          }
        });
        section.append(list);
        sections.push(section);
      });
      nav.replaceChildren(...sections);
      syncActiveSubitem();
      revealActive();
    }

    function renderUser(displayName, roleName) {
      aside.querySelector(".operational-user-avatar").textContent = initials(displayName);
      aside.querySelector(".operational-user-copy strong").textContent = displayName || "Signed in";
      aside.querySelector(".operational-user-copy span").textContent = roleName || "";
    }

    function setNotificationCount(count) {
      const item = nav.querySelector('[data-module-id="notifications"]');
      const badge = item?.querySelector(".operational-nav-badge");
      const attention = count > 0;
      item?.classList.toggle("has-attention", attention);
      menuButton.classList.toggle("has-attention", attention);
      if (badge) {
        badge.hidden = !attention;
        badge.textContent = count > 99 ? "99+" : String(count);
      }
      if (item) item.title = attention ? `Notifications (${count} need attention)` : "Notifications";
    }

    nav.addEventListener("click", (event) => {
      const link = event.target.closest("a.operational-nav-item, a.operational-nav-subitem");
      if (!link || event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      const target = new URL(link.href, window.location.href);
      if (target.href === window.location.href) {
        event.preventDefault();
        setDrawerOpen(false);
        return;
      }
      event.preventDefault();
      if (target.origin === location.origin && target.pathname === location.pathname && target.search === location.search && target.hash) {
        location.hash = target.hash;
        setDrawerOpen(false);
        syncActiveSubitem();
        return;
      }
      writeStorage("sessionStorage", sidebarPreferenceKey, String(root.classList.contains("sidebar-expanded")));
      navigationInProgress = true;
      window.location.href = target.href;
    });

    // In-page tabs change the address with history.replaceState, which fires no
    // event; re-check after clicks and on history navigation.
    window.addEventListener("hashchange", syncActiveSubitem);
    window.addEventListener("popstate", syncActiveSubitem);
    document.addEventListener("click", (event) => {
      if (!aside.contains(event.target)) window.setTimeout(syncActiveSubitem, 60);
    });

    function remove() {
      mobileBar.remove();
      aside.remove();
      backdrop.remove();
      root.classList.remove("operational-shell", "sidebar-expanded", "sidebar-hover-expanded", "nav-open");
      document.body.classList.remove("elis-operational-mode", "elis-operational-tool-page", "nav-drawer-open");
    }

    return { renderNavigation, renderUser, setNotificationCount, remove };
  }

  function cacheNavigationProfile(profile, roleCodes) {
    writeStorage("sessionStorage", navigationProfileCacheKey, JSON.stringify({
      displayName: profile.display_name || "Signed in",
      roleCodes,
      accountType: profile.account_type || "",
      permissions: Array.isArray(profile.permissions) ? profile.permissions : []
    }));
  }

  function renderCachedNavigation(policy) {
    try {
      const cached = JSON.parse(readStorage("sessionStorage", navigationProfileCacheKey) || "null");
      if (!cached || !Array.isArray(cached.roleCodes)) return;
      const cachedProfile = { account_type: cached.accountType, permissions: cached.permissions || [] };
      shell.renderNavigation(policy.operationalModules(cached.roleCodes, policy.permissionOverrides(cachedProfile)));
      shell.renderUser(cached.displayName, policy.operationalContext(cached.roleCodes).roleName);
    } catch (_) {
      // Ignore stale or unavailable cache and continue with the live profile.
    }
  }

  // Pages that redirect home when the account lacks the workspace permission.
  // Data access is still enforced by the database; this only avoids empty screens.
  function currentRequiredPermission(policy) {
    const page = currentPage();
    const permissions = policy.NAVIGATION_PERMISSIONS;
    if (page === "staff.html" && new URLSearchParams(location.search).get("view") === "accounts") return "administration.accounts-access";
    return {
      "customers.html": permissions.CUSTOMER_WORKSPACE,
      "roster.html": permissions.PRODUCTION_ROSTER,
      "sorting.html": permissions.SORTING,
      "mop-production.html": permissions.MOP_PRODUCTION,
      "finish-production.html": permissions.FINISH,
      "finish-results.html": permissions.FINISH_RESULTS,
      "production-tracker.html": permissions.PRODUCTION_TRACKER,
      "distribution.html": permissions.DISTRIBUTION,
      "trolleys.html": permissions.TROLLEYS,
      "staff.html": permissions.STAFF_MASTER
    }[page] || "";
  }

  async function loadNotificationCount(client, policy, access) {
    if (!access.can(policy.NAVIGATION_PERMISSIONS.NOTIFICATIONS)) return;
    try {
      const { data, error } = await client.rpc("get_my_notification_summary");
      if (error) throw error;
      shell?.setNotificationCount(Number(data?.attention_count || 0));
    } catch (error) {
      console.warn("Notification summary could not be loaded.", error);
    }
  }

  // Trolley plan checks reported by Finish or MOP. Managers and Distribution see an
  // alert on every page until someone resolves each check; it cannot be dismissed.
  const trolleyChecks = { client: null, canHandle: false, items: [], timer: 0, saving: false, onChange: null };

  function trolleyCheckAge(hours) {
    const value = Number(hours || 0);
    if (value < 1) return "less than 1 hour";
    if (value < 24) return `${Math.floor(value)} hour${Math.floor(value) === 1 ? "" : "s"}`;
    const days = Math.floor(value / 24);
    return `${days} day${days === 1 ? "" : "s"}`;
  }

  function trolleyCheckLevel(hours) {
    const value = Number(hours || 0);
    return value >= 24 ? "overdue" : value >= 4 ? "late" : "urgent";
  }

  function trolleyRequirementText(snapshot) {
    const requirements = Array.isArray(snapshot?.requirements) ? snapshot.requirements : [];
    if (!requirements.length) return "No trolley";
    return requirements.map((item) => `${Number(item.quantity || 0)} × ${item.display_code || item.trolley_type_name || item.trolley_type_code || "Trolley"}`).join(" · ");
  }

  function trolleyCheckDate(value, withTime) {
    if (!value) return "—";
    const date = withTime ? new Date(value) : new Date(`${value}T12:00:00`);
    return new Intl.DateTimeFormat("en-IE", withTime ? { day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" } : { weekday: "short", day: "2-digit", month: "short" }).format(date);
  }

  function trolleyCheckContentHost() {
    const root = document.querySelector("[data-operational-shell-root]");
    return root?.querySelector(":scope > :not(.operational-sidebar):not(.operational-mobile-bar):not(.operational-nav-backdrop)") || null;
  }

  function renderTrolleyCheckBanner() {
    let banner = document.getElementById("trolleyCheckAlert");
    const items = trolleyChecks.items;
    if (!items.length) {
      banner?.remove();
      return;
    }
    const host = trolleyCheckContentHost();
    if (!host) return;
    if (!banner) {
      banner = document.createElement("section");
      banner.id = "trolleyCheckAlert";
      banner.setAttribute("role", "alert");
      banner.addEventListener("click", (event) => {
        if (event.target.closest("[data-trolley-check-open]")) openTrolleyCheckDialog();
      });
    }
    if (banner.parentElement !== host || host.firstElementChild !== banner) host.prepend(banner);
    const oldest = items[0];
    const level = trolleyCheckLevel(oldest.open_hours);
    const customers = items.slice(0, 3).map((item) => escapeHtml(item.customer_name)).join(", ") + (items.length > 3 ? ` +${items.length - 3}` : "");
    banner.className = `trolley-check-alert ${level}`;
    banner.innerHTML = `
      <span class="trolley-check-alert-icon" aria-hidden="true">!</span>
      <span class="trolley-check-alert-copy">
        <strong>${items.length === 1 ? "Trolley check needed" : `${items.length} trolley checks needed`} · ${level === "overdue" ? "overdue" : "urgent"}</strong>
        <span>Production reported a trolley quantity to check: ${customers}. Oldest open for ${escapeHtml(trolleyCheckAge(oldest.open_hours))}.</span>
      </span>
      <button type="button" data-trolley-check-open>Review now</button>`;
  }

  function ensureTrolleyCheckDialog() {
    let dialog = document.getElementById("trolleyCheckDialog");
    if (dialog) return dialog;
    dialog = document.createElement("dialog");
    dialog.id = "trolleyCheckDialog";
    dialog.className = "trolley-check-dialog";
    dialog.innerHTML = `
      <div class="trolley-check-dialog-head">
        <div><p>Urgent · from Production</p><h2>Trolley checks</h2><span>Check the quantity with the customer plan, then record what you did. The alert stays for everyone until each check is resolved.</span></div>
        <button type="button" class="trolley-check-close" aria-label="Close">&times;</button>
      </div>
      <div class="trolley-check-list"></div>`;
    document.body.append(dialog);
    dialog.querySelector(".trolley-check-close").addEventListener("click", () => dialog.close());
    dialog.addEventListener("click", (event) => {
      if (event.target === dialog) dialog.close();
      const button = event.target.closest("[data-trolley-check-action]");
      if (button) reviewTrolleyCheck(button.dataset.trolleyCheckId, button.dataset.trolleyCheckAction);
    });
    return dialog;
  }

  function renderTrolleyCheckDialog() {
    const dialog = document.getElementById("trolleyCheckDialog");
    if (!dialog) return;
    const list = dialog.querySelector(".trolley-check-list");
    if (!trolleyChecks.items.length) {
      list.innerHTML = '<p class="trolley-check-empty">All trolley checks are resolved.</p>';
      return;
    }
    list.innerHTML = trolleyChecks.items.map((item) => {
      const id = escapeHtml(item.operational_report_id);
      const scanned = Array.isArray(item.observed_snapshot?.trolleys) ? item.observed_snapshot.trolleys.map((t) => t.trolley_code).filter(Boolean) : [];
      return `
        <article class="trolley-check-item ${trolleyCheckLevel(item.open_hours)}" data-trolley-check-item="${id}">
          <header>
            <div><strong>${escapeHtml(item.customer_name)}</strong><span>${escapeHtml([item.route_display_name || item.route_code, item.product_code === "MOP" ? "MOP" : "Clothes", trolleyCheckDate(item.business_date, false)].filter(Boolean).join(" · "))}</span></div>
            <em>Open ${escapeHtml(trolleyCheckAge(item.open_hours))}</em>
          </header>
          <div class="trolley-check-compare">
            <div><span>Customer plan</span><strong>${escapeHtml(trolleyRequirementText(item.planned_snapshot))}</strong></div>
            <div class="reported"><span>${escapeHtml(item.source_area_code === "MOP" ? "MOP" : "Finish")} says it should be</span><strong>${escapeHtml(trolleyRequirementText(item.reported_snapshot))}</strong></div>
          </div>
          <p class="trolley-check-reason"><strong>${escapeHtml(item.reported_by || "Production")}</strong> · ${escapeHtml(trolleyCheckDate(item.reported_at, true))}: ${escapeHtml(item.reason)}${scanned.length ? ` <small>Scanned: ${escapeHtml(scanned.join(", "))}</small>` : ""}</p>
          <label class="trolley-check-note"><span>What did you do? (required)</span><textarea rows="2" maxlength="1000" data-trolley-check-note="${id}" placeholder="For example: customer plan updated to 3 large trolleys"></textarea></label>
          <p class="trolley-check-message" data-trolley-check-message="${id}" hidden></p>
          <footer>
            <button type="button" class="secondary" data-trolley-check-action="REJECTED" data-trolley-check-id="${id}">Plan was right</button>
            <button type="button" data-trolley-check-action="RESOLVED" data-trolley-check-id="${id}">Plan corrected</button>
          </footer>
        </article>`;
    }).join("");
  }

  function openTrolleyCheckDialog() {
    const dialog = ensureTrolleyCheckDialog();
    renderTrolleyCheckDialog();
    if (!dialog.open) dialog.showModal();
  }

  async function reviewTrolleyCheck(id, action) {
    if (trolleyChecks.saving || !trolleyChecks.client) return;
    const dialog = document.getElementById("trolleyCheckDialog");
    const note = dialog.querySelector(`[data-trolley-check-note="${CSS.escape(id)}"]`);
    const message = dialog.querySelector(`[data-trolley-check-message="${CSS.escape(id)}"]`);
    const text = note?.value.trim() || "";
    if (!text) {
      message.hidden = false;
      message.textContent = "Write what you checked or changed before closing this check.";
      note?.focus();
      return;
    }
    const buttons = dialog.querySelectorAll(`[data-trolley-check-id="${CSS.escape(id)}"]`);
    trolleyChecks.saving = true;
    buttons.forEach((button) => { button.disabled = true; });
    try {
      const { error } = await trolleyChecks.client.rpc("review_operational_schedule_report", { p_operational_report_id: id, p_action: action, p_notes: text });
      if (error) throw error;
      trolleyChecks.saving = false;
      await loadTrolleyChecks();
      trolleyChecks.onChange?.();
      document.dispatchEvent(new CustomEvent("elis:trolley-checks-changed"));
    } catch (error) {
      message.hidden = false;
      message.textContent = error.message || "The check could not be saved. Try again.";
      buttons.forEach((button) => { button.disabled = false; });
    } finally {
      trolleyChecks.saving = false;
    }
  }

  async function loadTrolleyChecks() {
    if (!trolleyChecks.client) return;
    try {
      const { data, error } = await trolleyChecks.client.rpc("get_open_trolley_checks");
      if (error) throw error;
      trolleyChecks.canHandle = Boolean(data?.can_handle);
      trolleyChecks.items = trolleyChecks.canHandle && Array.isArray(data.items) ? data.items : [];
    } catch (error) {
      console.warn("Trolley checks could not be loaded.", error);
      return;
    }
    renderTrolleyCheckBanner();
    if (document.getElementById("trolleyCheckDialog")?.open && !trolleyChecks.saving) renderTrolleyCheckDialog();
  }

  async function startTrolleyChecks(client, onChange) {
    trolleyChecks.client = client;
    trolleyChecks.onChange = onChange;
    window.clearInterval(trolleyChecks.timer);
    await loadTrolleyChecks();
    if (!trolleyChecks.canHandle) return;
    // Pages such as Distribution stay open all day; keep the alert current.
    trolleyChecks.timer = window.setInterval(loadTrolleyChecks, 5 * 60 * 1000);
    if (new URLSearchParams(location.search).get("trolleyChecks") === "open" && trolleyChecks.items.length) openTrolleyCheckDialog();
  }

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && trolleyChecks.canHandle) loadTrolleyChecks();
  });

  // Renders the navigation for a loaded account profile. index.html calls this
  // after sign-in; other pages call it from start() below.
  function renderProfile(profile, roleCodes) {
    const client = window.elisSupabase;
    const policy = window.ELIS_APP_SHELL_POLICY;
    if (!shell || !policy) return null;
    const codes = policy.uniqueRoleCodes(roleCodes || profile.role_codes || []);
    const overrides = policy.permissionOverrides(profile);
    const access = policy.navigationAccess(codes, overrides);
    shell.renderNavigation(policy.operationalModules(codes, overrides));
    shell.renderUser(profile.display_name, policy.operationalContext(codes).roleName);
    cacheNavigationProfile(profile, codes);
    if (client) {
      loadNotificationCount(client, policy, access);
      startTrolleyChecks(client, () => loadNotificationCount(client, policy, access));
    }
    return access;
  }

  async function start(root) {
    const client = window.elisSupabase;
    const policy = window.ELIS_APP_SHELL_POLICY;
    shell = createShell(root, policy, client);
    renderCachedNavigation(policy);

    try {
      const { data: { session }, error: sessionError } = await client.auth.getSession();
      if (sessionError) throw sessionError;
      if (!session?.user) {
        // Public token links (for example a shared roster) have no account.
        shell.remove();
        shell = null;
        return;
      }

      const { data: profile, error } = await client.rpc("get_current_account_access");
      if (error) throw error;
      if (!profile) return;
      if (profile.account_enabled === false) {
        await client.auth.signOut();
        window.location.replace(new URL("index.html?access=inactive", frontendRoot).href);
        return;
      }

      const access = renderProfile(profile);
      const requiredPermission = currentRequiredPermission(policy);
      if (requiredPermission && !access.can(requiredPermission)) {
        window.location.replace(new URL("index.html?access=denied", frontendRoot).href);
      }
    } catch (error) {
      console.warn("Navigation profile could not be loaded.", error);
      shell?.renderNavigation(policy.NAVIGATION_MODULES.filter((module) => module.id === "home"));
    }
  }

  window.ELIS_OPERATIONAL_NAV = Object.freeze({
    // index.html mounts the shell itself once the signed-in profile is known.
    mount(root, profile, roleCodes) {
      if (!root || !window.ELIS_APP_SHELL_POLICY) return;
      if (!shell) shell = createShell(root, window.ELIS_APP_SHELL_POLICY, window.elisSupabase);
      renderProfile(profile, roleCodes);
    },
    unmount() {
      shell?.remove();
      shell = null;
    }
  });

  document.addEventListener("DOMContentLoaded", () => {
    const root = document.querySelector("[data-operational-shell-root]");
    if (!root || root.hasAttribute("data-shell-manual") || !window.elisSupabase || !window.ELIS_APP_SHELL_POLICY) return;
    start(root);
  });
})();
