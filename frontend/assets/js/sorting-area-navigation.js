"use strict";

(function initSortingAreaNavigation() {
  document.addEventListener("DOMContentLoaded", async () => {
    const container = document.querySelector("[data-sorting-area-navigation]");
    const client = window.elisSupabase;
    const policy = window.ELIS_APP_SHELL_POLICY;
    if (!container || !client || !policy) return;

    function dublinDateKey() {
      const parts = new Intl.DateTimeFormat("en-CA", {
        timeZone: "Europe/Dublin",
        year: "numeric",
        month: "2-digit",
        day: "2-digit"
      }).formatToParts(new Date());
      const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
      return `${values.year}-${values.month}-${values.day}`;
    }

    function roleIsEffective(staffRole) {
      if (!staffRole?.active || !staffRole.roles?.role_code) return false;
      const today = dublinDateKey();
      const from = staffRole.effective_from ? String(staffRole.effective_from).slice(0, 10) : null;
      const until = staffRole.effective_until ? String(staffRole.effective_until).slice(0, 10) : null;
      return (!from || from <= today) && (!until || until >= today);
    }

    function currentModuleId() {
      return document.body.classList.contains("mop-standalone-page") ? "mop-production" : "sorting";
    }

    function moduleHref(module) {
      const frontendRoot = new URL("../", location.href);
      return new URL(String(module.href || "").replace(/^\.\//, ""), frontendRoot).href;
    }

    function createModuleLink(module, activeId) {
      const link = document.createElement("a");
      link.className = "sorting-area-link";
      link.href = moduleHref(module);
      link.title = module.label;
      if (module.id === activeId) {
        link.classList.add("active");
        link.setAttribute("aria-current", "page");
      }

      const icon = document.createElement("span");
      icon.className = "sorting-area-link-icon";
      icon.innerHTML = policy.ICONS[module.icon] || policy.ICONS.home;
      const copy = document.createElement("span");
      copy.className = "sorting-area-link-copy";
      const label = document.createElement("strong");
      label.textContent = module.label;
      const description = document.createElement("small");
      description.textContent = module.description;
      copy.append(label, description);
      link.append(icon, copy);
      return link;
    }

    function render(modules) {
      const activeId = currentModuleId();
      const groupOrder = ["Home", "Planning", "Operations", "Master Data"];
      const grouped = new Map(groupOrder.map((name) => [name, []]));
      modules.forEach((module) => {
        const group = grouped.has(module.group) ? module.group : "Operations";
        grouped.get(group).push(module);
      });

      const details = document.createElement("details");
      details.className = "sorting-area-switcher";
      const summary = document.createElement("summary");
      summary.title = "Open area navigation";
      summary.innerHTML = `<span class="sorting-area-switcher-icon">${policy.ICONS.home}</span><span class="sorting-area-switcher-copy">All areas</span>`;
      details.append(summary);

      const menu = document.createElement("div");
      menu.className = "sorting-area-menu";
      groupOrder.forEach((group) => {
        const items = grouped.get(group);
        if (!items.length) return;
        const section = document.createElement("section");
        const heading = document.createElement("h2");
        heading.textContent = group;
        const links = document.createElement("div");
        links.className = "sorting-area-links";
        links.append(...items.map((module) => createModuleLink(module, activeId)));
        section.append(heading, links);
        menu.append(section);
      });
      details.append(menu);
      container.replaceChildren(details);
    }

    try {
      const { data: { session }, error: sessionError } = await client.auth.getSession();
      if (sessionError || !session?.user) return;
      const { data: profile, error } = await client
        .from("staff_members")
        .select("staff_roles(active,effective_from,effective_until,roles(role_code,role_name))")
        .eq("auth_user_id", session.user.id)
        .eq("active", true)
        .is("deleted_at", null)
        .maybeSingle();
      if (error || !profile) return;
      const roleCodes = policy.uniqueRoleCodes(
        (profile.staff_roles || []).filter(roleIsEffective).map((row) => row.roles?.role_code)
      );
      render(policy.operationalModules(roleCodes));
    } catch (error) {
      console.warn("Sorting area navigation could not be loaded.", error);
    }
  });
})();
