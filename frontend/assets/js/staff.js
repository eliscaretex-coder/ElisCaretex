"use strict";

document.addEventListener("DOMContentLoaded", async () => {
  const client = window.elisSupabase;

  const elements = {
    signOut: document.getElementById("staffSignOutButton"),
    pageMessage: document.getElementById("staffPageMessage"),
    main: document.getElementById("staffMainPanel"),
    editorModal: document.getElementById("staffEditorModal"),
    editorBackdrop: document.getElementById("staffEditorBackdrop"),
    editorClose: document.getElementById("staffEditorClose"),
    editorCancel: document.getElementById("staffEditorCancel"),
    editorForm: document.getElementById("staffEditorForm"),
    editorTitle: document.getElementById("staffEditorTitle"),
    editorSubtitle: document.getElementById("staffEditorSubtitle"),
    editorId: document.getElementById("staffEditorId"),
    editorRowVersion: document.getElementById("staffEditorRowVersion"),
    displayName: document.getElementById("staffDisplayName"),
    employeeCode: document.getElementById("staffEmployeeCode"),
    defaultShift: document.getElementById("staffDefaultShift"),
    rosterEligible: document.getElementById("staffRosterEligible"),
    joinedOn: document.getElementById("staffJoinedOn"),
    primaryRole: document.getElementById("staffPrimaryRole"),
    transferDriver: document.getElementById("staffTransferDriver"),
    driverTransferFields: document.getElementById("staffDriverTransferFields"),
    driverExisting: document.getElementById("staffDriverExisting"),
    driverCode: document.getElementById("staffDriverCode"),
    driverPhone: document.getElementById("staffDriverPhone"),
    driverEmail: document.getElementById("staffDriverEmail"),
    driverLicence: document.getElementById("staffDriverLicence"),
    driverCategories: document.getElementById("staffDriverCategories"),
    driverLicenceExpiry: document.getElementById("staffDriverLicenceExpiry"),
    driverCpcExpiry: document.getElementById("staffDriverCpcExpiry"),
    driverNotes: document.getElementById("staffDriverNotes"),
    defaultArea: document.getElementById("staffDefaultArea"),
    defaultStation: document.getElementById("staffDefaultStation"),
    coverOptions: document.getElementById("staffCoverOptions"),
    fireTraining: document.getElementById("staffFireTraining"),
    firstAidTraining: document.getElementById("staffFirstAidTraining"),
    eodCapable: document.getElementById("staffEodCapable"),
    importReviewSection: document.getElementById("staffImportReviewSection"),
    importReviewRequired: document.getElementById("staffImportReviewRequired"),
    importReviewNotes: document.getElementById("staffImportReviewNotes"),
    notes: document.getElementById("staffNotes"),
    changeReason: document.getElementById("staffChangeReason"),
    editorMessage: document.getElementById("staffEditorMessage"),
    editorSave: document.getElementById("staffEditorSave"),
    rosterRoleModal: document.getElementById("staffRosterRoleModal"),
    rosterRoleBackdrop: document.getElementById("staffRosterRoleBackdrop"),
    rosterRoleClose: document.getElementById("staffRosterRoleClose"),
    rosterRoleTitle: document.getElementById("staffRosterRoleTitle"),
    rosterRoleSubtitle: document.getElementById("staffRosterRoleSubtitle"),
    rosterRoleSummary: document.getElementById("staffRosterRoleSummary"),
    rosterRoleCancel: document.getElementById("staffRosterRoleCancel"),
    rosterRoleKeep: document.getElementById("staffRosterRoleKeep"),
    rosterRoleApply: document.getElementById("staffRosterRoleApply"),
    statusModal: document.getElementById("staffStatusModal"),
    statusBackdrop: document.getElementById("staffStatusBackdrop"),
    statusClose: document.getElementById("staffStatusClose"),
    statusCancel: document.getElementById("staffStatusCancel"),
    statusForm: document.getElementById("staffStatusForm"),
    statusTitle: document.getElementById("staffStatusTitle"),
    statusSubtitle: document.getElementById("staffStatusSubtitle"),
    statusId: document.getElementById("staffStatusId"),
    statusRowVersion: document.getElementById("staffStatusRowVersion"),
    statusAction: document.getElementById("staffStatusAction"),
    deactivatedDateField: document.getElementById("staffDeactivatedDateField"),
    deactivatedOn: document.getElementById("staffDeactivatedOn"),
    reactivateRosterField: document.getElementById("staffReactivateRosterField"),
    reactivateRosterEligible: document.getElementById("staffReactivateRosterEligible"),
    statusReason: document.getElementById("staffStatusReason"),
    statusMessage: document.getElementById("staffStatusMessage"),
    statusConfirm: document.getElementById("staffStatusConfirm"),
    accountModal: document.getElementById("accountEditorModal"),
    accountBackdrop: document.getElementById("accountEditorBackdrop"),
    accountClose: document.getElementById("accountEditorClose"),
    accountCancel: document.getElementById("accountEditorCancel"),
    accountForm: document.getElementById("accountEditorForm"),
    accountTitle: document.getElementById("accountEditorTitle"),
    accountSubtitle: document.getElementById("accountEditorSubtitle"),
    accountId: document.getElementById("accountEditorId"),
    accountType: document.getElementById("accountEditorType"),
    accountName: document.getElementById("accountEditorName"),
    accountJobTitle: document.getElementById("accountEditorJobTitle"),
    accountJobTitleField: document.getElementById("accountJobTitleField"),
    accountLoginMethod: document.getElementById("accountEditorLoginMethod"),
    accountLoginMethodField: document.getElementById("accountLoginMethodField"),
    accountEmailField: document.getElementById("accountEmailField"),
    accountEmail: document.getElementById("accountEditorEmail"),
    accountUsernameField: document.getElementById("accountUsernameField"),
    accountUsername: document.getElementById("accountEditorUsername"),
    accountPasswordField: document.getElementById("accountPasswordField"),
    accountPassword: document.getElementById("accountEditorPassword"),
    accountStaff: document.getElementById("accountEditorStaff"),
    accountRoleOptions: document.getElementById("accountEditorRoleOptions"),
    accountPermissionOptions: document.getElementById("accountEditorPermissionOptions"),
    accountTerminalFields: document.getElementById("accountTerminalFields"),
    accountTerminalCode: document.getElementById("accountTerminalCode"),
    accountTerminalName: document.getElementById("accountTerminalName"),
    accountTerminalStation: document.getElementById("accountTerminalStation"),
    accountMessage: document.getElementById("accountEditorMessage"),
    accountSave: document.getElementById("accountEditorSave"),
    terminalPasswordModal: document.getElementById("terminalPasswordResetModal"),
    terminalPasswordBackdrop: document.getElementById("terminalPasswordResetBackdrop"),
    terminalPasswordClose: document.getElementById("terminalPasswordResetClose"),
    terminalPasswordCancel: document.getElementById("terminalPasswordResetCancel"),
    terminalPasswordForm: document.getElementById("terminalPasswordResetForm"),
    terminalPasswordAccountId: document.getElementById("terminalPasswordResetAccountId"),
    terminalPasswordComputer: document.getElementById("terminalPasswordResetComputer"),
    terminalPassword: document.getElementById("terminalPasswordResetValue"),
    terminalPasswordConfirmation: document.getElementById("terminalPasswordResetConfirmation"),
    terminalPasswordShow: document.getElementById("terminalPasswordResetShow"),
    terminalPasswordMessage: document.getElementById("terminalPasswordResetMessage"),
    terminalPasswordSave: document.getElementById("terminalPasswordResetSave")
  };

  const state = {
    reference: null,
    accessProfile: null,
    view: new URLSearchParams(location.search).get("view") === "accounts" ? "accounts" : "directory",
    canViewAccounts: false,
    canCreateAccounts: false,
    canEditAccounts: false,
    canManageAccounts: false,
    canCreateStaff: false,
    canEditStaff: false,
    canManageStaff: false,
    statusFilter: "ACTIVE",
    shiftFilter: "ALL",
    search: "",
    accountSearch: "",
    driverTransferOptions: [],
    accounts: [],
    accountRoles: [],
    accountModules: [],
    accountJobTitles: [],
    directoryStaff: [],
    busy: false,
    editorPrimaryRoleCode: "",
    resolveRosterRoleChoice: null
  };

  function escapeHtml(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#039;");
  }

  function localDateValue(date = new Date()) {
    const local = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
    return local.toISOString().slice(0, 10);
  }

  function formatDate(value) {
    if (!value) return "—";
    const parsed = new Date(`${String(value).slice(0, 10)}T12:00:00`);
    return new Intl.DateTimeFormat("en-IE", {
      day: "2-digit",
      month: "short",
      year: "numeric"
    }).format(parsed);
  }

  function setMessage(element, text = "", type = "") {
    element.textContent = text;
    element.className = element === elements.pageMessage
      ? "staff-page-message"
      : "staff-inline-message";
    if (type) element.classList.add(type);
  }

  function friendlyError(error) {
    const message = String(error?.message || "The operation could not be completed.");
    const known = [
      "Staff name is required.",
      "Employee code already exists.",
      "Employee code is required.",
      "A creation reason is required.",
      "A change reason is required.",
      "A deactivation reason is required.",
      "A reactivation reason is required.",
      "Primary operational role is invalid or inactive.",
      "Default work area is invalid or inactive.",
      "Default station is invalid or inactive.",
      "Default station does not belong to the selected work area.",
      "Staff record changed in another session. Reload before saving.",
      "You cannot deactivate your own signed-in staff profile."
    ];
    return known.find((item) => message.includes(item)) || message;
  }

  async function rpc(name, args = {}) {
    const { data, error } = await client.rpc(name, args);
    if (error) throw error;
    return data;
  }

  function renderLoading(label = "Loading Staff Master...") {
    elements.main.innerHTML = `
      <div class="staff-loading">
        <span class="staff-spinner" aria-hidden="true"></span>
        <p>${escapeHtml(label)}</p>
      </div>
    `;
  }

  function kpi(value, label, tone = "") {
    return `
      <article class="staff-kpi ${escapeHtml(tone)}">
        <strong>${Number(value || 0)}</strong>
        <span>${escapeHtml(label)}</span>
      </article>
    `;
  }

  function workspaceTabs() {
    return `
      <nav class="staff-workspace-tabs" aria-label="Staff workspace">
        <button type="button" class="staff-workspace-tab${state.view === "directory" ? " active" : ""}" data-staff-view="directory">Staff directory</button>
        ${state.canViewAccounts ? `<button type="button" class="staff-workspace-tab${state.view === "accounts" ? " active" : ""}" data-staff-view="accounts">Accounts &amp; access</button>` : ""}
      </nav>
    `;
  }

  function formatDateTime(value) {
    if (!value) return "Never";
    return new Intl.DateTimeFormat("en-IE", { day:"2-digit", month:"short", year:"numeric", hour:"2-digit", minute:"2-digit", hour12:false }).format(new Date(value));
  }

  function accountModules(roleCodes) {
    const policy = window.ELIS_APP_SHELL_POLICY;
    if (!policy) return [];
    const access = policy.navigationAccess(roleCodes || []);
    return policy.NAVIGATION_MODULES
      .filter((module) => module.id !== "home" && (!module.permission || access.can(module.permission)))
      .map((module) => module.label);
  }

  function coverChips(roles) {
    if (!Array.isArray(roles) || roles.length === 0) return '<span class="staff-subtext">None</span>';
    return `<div class="staff-cover-list">${roles.map((role) => `<span class="staff-cover-chip">${escapeHtml(role.role_name)}</span>`).join("")}</div>`;
  }

  function trainingChips(item) {
    const values = [
      ["Fire", item.fire_training],
      ["First Aid", item.first_aid_training],
      ["EOD", item.eod_capable]
    ];
    return `<div class="staff-training-list">${values.map(([label, enabled]) => `<span class="staff-training-chip ${enabled ? "yes" : "no"}">${escapeHtml(label)}: ${enabled ? "Yes" : "No"}</span>`).join("")}</div>`;
  }

  function assignmentText(item) {
    const location = [item.default_area_name, item.default_station_name].filter(Boolean).join(" · ");
    return `
      <strong>${escapeHtml(item.primary_role_name || "—")}</strong>
      <span class="staff-subtext">${escapeHtml(location || "No default location")}</span>
    `;
  }

  function rowActions(item) {
    if (!state.canEditStaff && !state.canManageStaff) return '<span class="staff-subtext">Read only</span>';
    const lifecycle = !state.canManageStaff ? "" : item.active
      ? `<button class="staff-row-button danger" type="button" data-staff-deactivate="${escapeHtml(item.staff_id)}" data-row-version="${Number(item.row_version)}" data-staff-name="${escapeHtml(item.display_name)}">Deactivate</button>`
      : `<button class="staff-row-button" type="button" data-staff-reactivate="${escapeHtml(item.staff_id)}" data-row-version="${Number(item.row_version)}" data-staff-name="${escapeHtml(item.display_name)}">Reactivate</button>`;
    return `
      <div class="staff-row-actions">
        ${state.canEditStaff ? `<button class="staff-row-button" type="button" data-staff-edit="${escapeHtml(item.staff_id)}">Edit</button>` : ""}
        ${lifecycle}
      </div>
    `;
  }

  function staffRow(item) {
    return `
      <tr>
        <td>
          <button class="staff-name-button" type="button" data-staff-open="${escapeHtml(item.staff_id)}">${escapeHtml(item.display_name)}</button>
        </td>
        <td><span class="staff-status ${item.active ? "active" : "inactive"}">${item.active ? "Active" : "Inactive"}</span></td>
        <td>${escapeHtml(item.default_shift_name || "—")}</td>
        <td>${assignmentText(item)}</td>
        <td>${coverChips(item.cover_roles)}</td>
        <td><span class="staff-roster-status ${item.roster_eligible ? "yes" : "no"}">${item.roster_eligible ? "Yes" : "No"}</span></td>
        <td>${trainingChips(item)}</td>
        <td>
          <strong>Joined:</strong> ${formatDate(item.joined_on)}<br>
          <span class="staff-subtext">Deactivated: ${formatDate(item.deactivated_on)}</span>
        </td>
        <td>${item.import_review_required ? `<span class="staff-review-chip" title="${escapeHtml(item.import_review_notes || "Review required")}">Review required</span>` : '<span class="staff-subtext">—</span>'}</td>
        <td>${rowActions(item)}</td>
      </tr>
    `;
  }

  async function loadDirectory() {
    renderLoading("Loading staff directory...");

    try {
      const data = await rpc("get_staff_directory", {
        p_status: state.statusFilter,
        p_shift_code: state.shiftFilter === "ALL" ? null : state.shiftFilter,
        p_search: state.search || null
      });
      state.directoryStaff = Array.isArray(data?.staff) ? data.staff : [];
      renderDirectory(data || {});
    } catch (error) {
      console.error("Failed to load Staff Master:", error);
      elements.main.innerHTML = `<div class="staff-empty">${escapeHtml(friendlyError(error))}</div>`;
      setMessage(elements.pageMessage, friendlyError(error), "error");
    }
  }

  async function loadAccounts() {
    renderLoading("Loading accounts and access...");
    try {
      const [data, jobAccess] = await Promise.all([rpc("get_admin_account_access_directory", { p_search:state.accountSearch || null }), rpc("get_admin_account_job_access")]);
      const profileMap = new Map((jobAccess?.profiles || []).map((profile) => [profile.auth_user_id,profile]));
      (data?.accounts || []).forEach((account) => Object.assign(account,profileMap.get(account.auth_user_id) || {}));
      state.accounts = Array.isArray(data?.accounts) ? data.accounts : [];
      state.accountRoles = Array.isArray(data?.available_roles) ? data.available_roles : [];
      state.accountModules = Array.isArray(data?.available_modules) ? data.available_modules : [];
      state.accountJobTitles = Array.isArray(jobAccess?.job_titles) ? jobAccess.job_titles : [];
      renderAccounts(data || {});
    } catch (error) {
      console.error("Failed to load accounts and access:", error);
      elements.main.innerHTML = `${workspaceTabs()}<div class="staff-empty">${escapeHtml(friendlyError(error))}</div>`;
      setMessage(elements.pageMessage, friendlyError(error), "error");
    }
  }

  function renderDirectory(data) {
    const summary = data.summary || {};
    const staff = Array.isArray(data.staff) ? data.staff : [];
    const shiftOptions = (state.reference?.shifts || []).map((shift) => `
      <option value="${escapeHtml(shift.shift_code)}"${state.shiftFilter === shift.shift_code ? " selected" : ""}>${escapeHtml(shift.shift_name)}</option>
    `).join("");

    elements.main.innerHTML = `
      ${workspaceTabs()}
      <section class="staff-kpi-grid">
        ${kpi(summary.total, "Total staff")}
        ${kpi(summary.active, "Active")}
        ${kpi(summary.inactive, "Inactive")}
        ${kpi(summary.roster_eligible, "Active and roster eligible")}
        ${kpi(summary.review_required, "Import review required", summary.review_required ? "warning" : "")}
      </section>

      <div class="staff-info-callout">
        Staff Master stores the original operational role. Temporary COVER work is planned separately and may currently use Team Leader, Sorting Area or Supervisor capability.
      </div>

      <section class="staff-card">
        <header class="staff-card-header">
          <div>
            <p class="staff-section-eyebrow">Operational people</p>
            <h2>Staff directory</h2>
            <p>Deactivate instead of deleting so all past rosters and operational history remain traceable.</p>
          </div>
          <form id="staffDirectoryFilters" class="staff-toolbar">
            <input id="staffDirectorySearch" type="search" placeholder="Search name, code, role or table" value="${escapeHtml(state.search)}">
            <select id="staffStatusFilter">
              ${[
                ["ACTIVE", "Active"],
                ["INACTIVE", "Inactive"],
                ["ALL", "All staff"],
                ["REVIEW", "Import review"]
              ].map(([value, label]) => `<option value="${value}"${state.statusFilter === value ? " selected" : ""}>${label}</option>`).join("")}
            </select>
            <select id="staffShiftFilter">
              <option value="ALL">All shifts</option>
              ${shiftOptions}
            </select>
            <button class="staff-secondary-button" type="submit">Apply</button>
            <button id="staffDirectoryReload" class="staff-secondary-button" type="button">Reload</button>
            ${state.canCreateStaff ? '<button id="staffAddButton" class="staff-primary-button" type="button">Add Staff</button>' : ""}
          </form>
        </header>

        <div class="staff-table-wrap">
          ${staff.length ? `
            <table class="staff-table">
              <thead>
                <tr>
                  <th>Staff</th>
                  <th>Status</th>
                  <th>Shift</th>
                  <th>Primary assignment</th>
                  <th>COVER capability</th>
                  <th>Roster</th>
                  <th>Training</th>
                  <th>Dates</th>
                  <th>Review</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>${staff.map(staffRow).join("")}</tbody>
            </table>
          ` : '<div class="staff-empty">No staff records match the selected filters.</div>'}
        </div>
      </section>
    `;
  }

  function accountModuleSummary(roles, permissions = []) {
    const explicit = permissions.map((grant) => {
      const module = state.accountModules.find((item) => item.module_code === grant.module_code);
      return module?.module_name || grant.module_code;
    });
    const modules = explicit.length ? explicit : accountModules(roles);
    if (!modules.length) return '<span class="staff-subtext">No modules assigned</span>';
    const visible = modules.slice(0,3);
    return `<div class="account-module-summary">${visible.map((module) => `<span>${escapeHtml(module)}</span>`).join("")}${modules.length > visible.length ? `<span class="account-module-more">+${modules.length-visible.length}</span>` : ""}</div>`;
  }

  function accountActions(account) {
    const terminal = Boolean(account.terminal?.device_code);
    const lifecycle = account.is_active
      ? `<button class="staff-row-button danger" type="button" data-account-disable="${escapeHtml(account.auth_user_id)}">Disable</button>`
      : `<button class="staff-row-button" type="button" data-account-enable="${escapeHtml(account.auth_user_id)}">Enable</button>`;
    if (!state.canEditAccounts && !state.canManageAccounts) return '<span class="staff-subtext">Read only</span>';
    return `<div class="staff-row-actions account-row-actions">
      ${state.canEditAccounts ? `<button class="staff-row-button account-edit-button" type="button" data-account-edit="${escapeHtml(account.auth_user_id)}">Edit</button>` : ""}
      ${state.canManageAccounts ? `<details class="account-actions-menu"><summary>More</summary><div>
        ${terminal ? `<button class="staff-row-button" type="button" data-account-reset-password="${escapeHtml(account.auth_user_id)}">Reset password</button>` : ""}
        ${!terminal && account.login_method !== "USERNAME" ? `<button class="staff-row-button" type="button" data-account-send-setup="${escapeHtml(account.auth_user_id)}">Send setup link</button>` : ""}
        ${lifecycle}
        ${terminal ? "" : `<button class="staff-row-button danger" type="button" data-account-delete="${escapeHtml(account.auth_user_id)}" data-account-email="${escapeHtml(account.email || "this account")}">Delete</button>`}
      </div></details>` : ""}
    </div>`;
  }

  function accountStaffOptions(selectedId = "") {
    return option("", "No linked staff", selectedId) + state.directoryStaff
      .filter((item) => item.active)
      .map((item) => option(item.staff_id, `${item.display_name} (${item.employee_code || "no code"})`, selectedId))
      .join("");
  }

  function renderAccountRoleOptions(selectedRoles = []) {
    const selected = new Set(selectedRoles);
    const disabled = elements.accountType.value !== "TERMINAL" || !state.canManageAccounts;
    elements.accountRoleOptions.innerHTML = state.accountRoles.length
      ? state.accountRoles.map((role) => `<label class="staff-cover-option">
          <input type="checkbox" name="accountRole" value="${escapeHtml(role.role_code)}"${selected.has(role.role_code) ? " checked" : ""}${disabled ? " disabled" : ""}>
          <span>${escapeHtml(role.role_name)}</span>
        </label>`).join("")
      : '<span class="staff-subtext">No active access roles are configured.</span>';
  }

  function selectedAccountRoles() {
    return [...elements.accountRoleOptions.querySelectorAll('input[name="accountRole"]:checked')].map((input) => input.value);
  }

  function canAccountAction(moduleCode,action) {
    const grant = (state.accessProfile?.permissions || []).find((item) => item.module_code === moduleCode);
    if (!grant) return false;
    if (action === "VIEW") return grant.can_view || grant.can_create || grant.can_edit || grant.can_approve || grant.can_manage;
    if (action === "CREATE") return grant.can_create || grant.can_manage;
    if (action === "EDIT") return grant.can_edit || grant.can_manage;
    if (action === "APPROVE") return grant.can_approve || grant.can_manage;
    return action === "MANAGE" && grant.can_manage;
  }

  function accountAccessScope() {
    return (state.accessProfile?.permissions || []).find((item) => item.module_code === "ACCOUNTS_ACCESS")?.access_scope || "OWN";
  }

  function availableAccountJobTitles() {
    const scope = accountAccessScope();
    if (scope === "ALL") return state.accountJobTitles;
    return state.accountJobTitles.filter((item) => item.department_scope === scope);
  }

  function renderAccountPermissionOptions(grants = []) {
    const byModule = new Map(grants.map((grant) => [grant.module_code, grant]));
    const job = selectedJobTitle();
    const templates = job?.permissions || [];
    const disabled = !state.canManageAccounts;
    const labels = { can_view:"View",can_create:"Create",can_edit:"Edit",can_approve:"Approve",can_manage:"Manage" };
    elements.accountPermissionOptions.innerHTML = templates.map((template) => {
      const module = state.accountModules.find((item) => item.module_code === template.module_code) || { module_code:template.module_code,module_name:template.module_code.replaceAll("_"," ") };
      const grant = byModule.get(module.module_code) || {};
      return `<div class="staff-permission-row" data-permission-module="${escapeHtml(module.module_code)}">
        <strong>${escapeHtml(module.module_name)}</strong>
        ${Object.entries(labels).filter(([key]) => template[key]).map(([key,label]) => `<label class="staff-permission-action"><input type="checkbox" data-permission-action="${key}"${grant[key] ? " checked" : ""}${disabled ? " disabled" : ""}><span>${label}</span></label>`).join("")}
        <select data-permission-scope aria-label="${escapeHtml(module.module_name)} scope"${disabled ? " disabled" : ""}>
          ${permissionScopeOptions(template.access_scope).map(([value,label]) => option(value,label,grant.access_scope || template.access_scope)).join("")}
        </select>
      </div>`;
    }).join("") || '<div class="staff-permission-empty">Select a job title to see its relevant permissions.</div>';
  }

  function permissionScopeOptions(maximumScope) {
    const options = [["OWN","Own"]];
    if (["TEAM","PRODUCTION","DISTRIBUTION","ALL"].includes(maximumScope)) options.push(["TEAM","Team"]);
    if (["PRODUCTION","ALL"].includes(maximumScope)) options.push(["PRODUCTION","Production"]);
    if (["DISTRIBUTION","ALL"].includes(maximumScope)) options.push(["DISTRIBUTION","Distribution"]);
    if (maximumScope === "ALL") options.push(["ALL","All"]);
    return options;
  }

  function selectedAccountPermissions() {
    return [...elements.accountPermissionOptions.querySelectorAll("[data-permission-module]")].map((row) => {
      const result = { module_code:row.dataset.permissionModule, access_scope:row.querySelector("[data-permission-scope]").value };
      row.querySelectorAll("[data-permission-action]").forEach((input) => { result[input.dataset.permissionAction] = input.checked; });
      return result;
    }).filter((grant) => grant.can_view || grant.can_create || grant.can_edit || grant.can_approve || grant.can_manage);
  }

  function selectedJobTitle() { return state.accountJobTitles.find((item) => item.job_title_code === elements.accountJobTitle.value); }

  function applyJobTitleTemplate(force = false) {
    const job = selectedJobTitle();
    if (!job) return;
    if (force || !selectedAccountPermissions().length) renderAccountPermissionOptions(job.permissions || []);
    renderAccountRoleOptions(job.legacy_roles || []);
  }

  function applyLoginMethod() {
    const terminal = elements.accountType.value === "TERMINAL";
    const username = !terminal && elements.accountLoginMethod.value === "USERNAME";
    elements.accountEmailField.classList.toggle("hidden", terminal || username);
    elements.accountUsernameField.classList.toggle("hidden", terminal || !username);
    elements.accountEmail.required = !terminal && !username;
    elements.accountUsername.required = username;
    const emailInvitation = !terminal && !username;
    elements.accountPasswordField.classList.toggle("hidden", emailInvitation || (Boolean(elements.accountId.value) && (terminal || !state.canManageAccounts)));
    elements.accountPassword.required = !elements.accountId.value && !emailInvitation;
  }

  function resetAccountEditor() {
    elements.accountForm.reset();
    elements.accountId.value = "";
    elements.accountType.value = "USER";
    elements.accountType.disabled = false;
    elements.accountName.value = "";
    elements.accountJobTitle.innerHTML = option("","Select job title") + availableAccountJobTitles().map((item) => option(item.job_title_code,item.job_title_name)).join("");
    elements.accountJobTitle.disabled = false;
    const terminalOption = elements.accountType.querySelector('option[value="TERMINAL"]');
    if (terminalOption) terminalOption.disabled = !state.canManageAccounts || accountAccessScope() !== "ALL";
    elements.accountLoginMethod.value = "EMAIL";
    elements.accountPassword.required = false;
    elements.accountPassword.placeholder = "Minimum 12 characters";
    elements.accountStaff.innerHTML = accountStaffOptions();
    elements.accountTerminalStation.innerHTML = option("", "Select station") + (state.reference?.stations || []).map((station) => option(station.station_id, station.station_name)).join("");
    applyAccountType();
    renderAccountRoleOptions([]);
    renderAccountPermissionOptions([]);
    applyLoginMethod();
    setMessage(elements.accountMessage);
  }

  function openAccountEditor(accountId = "") {
    if ((!accountId && !state.canCreateAccounts) || (accountId && !state.canEditAccounts)) return;
    resetAccountEditor();
    const account = state.accounts.find((item) => item.auth_user_id === accountId);
    if (accountId && !account) return;
    elements.accountModal.classList.remove("hidden");
    document.body.style.overflow = "hidden";
    if (!account) {
      elements.accountTitle.textContent = "Add account";
      elements.accountSubtitle.textContent = "Create a sign-in and optionally link it to an active Staff Master record.";
      elements.accountSave.textContent = "Create account";
      elements.accountName.focus();
      return;
    }
    elements.accountTitle.textContent = "Edit account";
    elements.accountSubtitle.textContent = account.terminal?.device_code ? "This terminal account has a protected station binding." : "Update sign-in details or the linked Staff Master record.";
    elements.accountSave.textContent = "Save account";
    elements.accountId.value = account.auth_user_id;
    elements.accountType.value = account.terminal?.device_code ? "TERMINAL" : "USER";
    elements.accountType.disabled = true;
    elements.accountName.value = account.display_name || account.terminal?.device_name || "";
    elements.accountJobTitle.value = account.job_title_code || "";
    elements.accountJobTitle.disabled = !state.canManageAccounts;
    elements.accountLoginMethod.value = account.login_method === "USERNAME" ? "USERNAME" : "EMAIL";
    elements.accountUsername.value = account.login_identifier || "";
    elements.accountEmail.value = account.email || "";
    elements.accountPassword.required = false;
    elements.accountPassword.placeholder = "Leave empty to keep the current password";
    elements.accountStaff.innerHTML = accountStaffOptions(account.staff_id || "");
    elements.accountTerminalCode.value = account.terminal?.device_code || "";
    elements.accountTerminalName.value = account.terminal?.device_name || "";
    elements.accountTerminalStation.value = account.terminal?.station_id || (state.reference?.stations || []).find((station) => station.station_code === account.terminal?.station_code)?.station_id || "";
    applyAccountType();
    renderAccountRoleOptions(account.role_codes || []);
    renderAccountPermissionOptions(account.permissions || []);
    applyLoginMethod();
    (account.login_method === "USERNAME" ? elements.accountUsername : elements.accountName).focus();
  }

  function applyAccountType() {
    const terminal = elements.accountType.value === "TERMINAL";
    elements.accountTerminalFields.classList.toggle("hidden", !terminal);
    elements.accountName.closest(".staff-field").classList.toggle("hidden", terminal);
    elements.accountEmail.closest(".staff-field").classList.toggle("hidden", terminal);
    elements.accountStaff.closest(".staff-field").classList.toggle("hidden", terminal);
    elements.accountJobTitleField.classList.toggle("hidden", terminal);
    elements.accountLoginMethodField.classList.toggle("hidden", terminal);
    applyLoginMethod();
    elements.accountName.required = !terminal;
    elements.accountTerminalCode.required = terminal;
    elements.accountTerminalName.required = terminal;
    elements.accountTerminalStation.required = terminal;
  }

  function closeAccountEditor(force = false) {
    if (state.busy && !force) return;
    elements.accountModal.classList.add("hidden");
    document.body.style.overflow = "";
    resetAccountEditor();
  }

  async function accountAdmin(action, payload = {}) {
    const { data, error } = await client.functions.invoke("admin-account-management", { body:{ action, ...payload } });
    if (error) throw error;
    if (!data?.ok) throw new Error(data?.error || "The account operation could not be completed.");
    return data;
  }

  function resetTerminalPasswordForm() {
    elements.terminalPasswordForm.reset();
    elements.terminalPasswordAccountId.value = "";
    elements.terminalPasswordComputer.textContent = "";
    elements.terminalPassword.type = "password";
    elements.terminalPasswordConfirmation.type = "password";
    setMessage(elements.terminalPasswordMessage);
  }

  function toggleTerminalPasswordVisibility() {
    const type = elements.terminalPasswordShow.checked ? "text" : "password";
    elements.terminalPassword.type = type;
    elements.terminalPasswordConfirmation.type = type;
  }

  function openTerminalPasswordReset(accountId) {
    if (!state.canManageAccounts) return;
    const account = state.accounts.find((item) => item.auth_user_id === accountId);
    if (!account?.terminal?.device_code) return;
    resetTerminalPasswordForm();
    elements.terminalPasswordAccountId.value = account.auth_user_id;
    elements.terminalPasswordComputer.textContent = `${account.terminal.device_code} - ${account.terminal.device_name || "Production computer"}`;
    elements.terminalPasswordModal.classList.remove("hidden");
    document.body.style.overflow = "hidden";
    elements.terminalPassword.focus();
  }

  function closeTerminalPasswordReset(force = false) {
    if (state.busy && !force) return;
    elements.terminalPasswordModal.classList.add("hidden");
    document.body.style.overflow = "";
    resetTerminalPasswordForm();
  }

  async function saveTerminalPasswordReset(event) {
    event.preventDefault();
    if (state.busy) return;
    const password = elements.terminalPassword.value;
    const confirmation = elements.terminalPasswordConfirmation.value;
    if (password.length < 12) {
      setMessage(elements.terminalPasswordMessage, "Use a new password with at least 12 characters.", "error");
      return;
    }
    if (password !== confirmation) {
      setMessage(elements.terminalPasswordMessage, "The password confirmation does not match.", "error");
      return;
    }
    state.busy = true;
    elements.terminalPasswordSave.disabled = true;
    setMessage(elements.terminalPasswordMessage, "Resetting terminal password...");
    try {
      await accountAdmin("reset_password", { auth_user_id: elements.terminalPasswordAccountId.value, password });
      const computer = elements.terminalPasswordComputer.textContent;
      closeTerminalPasswordReset(true);
      setMessage(elements.pageMessage, `Password reset for ${computer}. Use the new password at the next terminal sign-in.`, "success");
      await loadAccounts();
    } catch (error) {
      setMessage(elements.terminalPasswordMessage, friendlyError(error), "error");
    } finally {
      state.busy = false;
      elements.terminalPasswordSave.disabled = false;
    }
  }

  async function saveAccountEditor(event) {
    event.preventDefault();
    if (state.busy) return;
    const accountId = elements.accountId.value;
    const terminal = elements.accountType.value === "TERMINAL";
    const email = elements.accountEmail.value.trim();
    const username = elements.accountUsername.value.trim();
    const password = elements.accountPassword.value;
    const roleCodes = selectedAccountRoles();
    const emailInvitation = !terminal && elements.accountLoginMethod.value === "EMAIL";
    const operationalJob = ["GENERAL_OPERATIVE","TEAM_LEADER","LABEL_OPERATIVE","CLEANER","MAINTENANCE","PRODUCTION_SUPERVISOR","PRODUCTION_MANAGER"].includes(elements.accountJobTitle.value);
    if (operationalJob && !elements.accountStaff.value) {
      setMessage(elements.accountMessage, "Select the employee's Staff Master record for this operational account.", "error");
      return;
    }
    if ((!terminal && (!elements.accountName.value.trim() || !elements.accountJobTitle.value || (emailInvitation ? !email : !username) || (operationalJob && !elements.accountStaff.value))) || (!accountId && !emailInvitation && password.length < 12) || (terminal && (!elements.accountTerminalCode.value.trim() || !elements.accountTerminalName.value.trim() || !elements.accountTerminalStation.value))) {
      setMessage(elements.accountMessage, emailInvitation ? "Complete the account name, job title and personal email." : "Complete the account details and use an initial password with at least 12 characters.", "error");
      return;
    }
    state.busy = true;
    elements.accountSave.disabled = true;
    setMessage(elements.accountMessage, accountId ? "Saving account..." : "Creating account...");
    try {
      const result = await accountAdmin(accountId ? "update" : "create", { auth_user_id: accountId || undefined, account_type: elements.accountType.value, display_name: terminal ? elements.accountTerminalName.value.trim() : elements.accountName.value.trim(), job_title_code:terminal ? undefined : elements.accountJobTitle.value, login_method:terminal ? "TERMINAL" : elements.accountLoginMethod.value, login_identifier:username || undefined, email: email || undefined, password: emailInvitation ? undefined : password || undefined, redirect_to:new URL("../pages/update-password.html",window.location.href).href, staff_id: terminal ? null : elements.accountStaff.value || null, role_codes: roleCodes, permissions:selectedAccountPermissions(), device_code: elements.accountTerminalCode.value.trim(), device_name: elements.accountTerminalName.value.trim(), station_id: elements.accountTerminalStation.value || undefined });
      closeAccountEditor(true);
      setMessage(elements.pageMessage, result.technical_email ? `Production computer created. Technical sign-in: ${result.technical_email}` : result.invitation_sent ? "Account created. A secure password setup invitation was sent by email." : accountId ? "Account updated." : "Account created.", "success");
      await loadAccounts();
    } catch (error) {
      setMessage(elements.accountMessage, friendlyError(error), "error");
    } finally {
      state.busy = false;
      elements.accountSave.disabled = false;
    }
  }

  function renderAccounts(data) {
    const summary = data.summary || {};
    const accounts = Array.isArray(data.accounts) ? data.accounts : [];
    elements.main.innerHTML = `
      ${workspaceTabs()}
      <section class="staff-card">
        <header class="staff-card-header">
          <div><p class="staff-section-eyebrow">Administration</p><h2>Accounts &amp; access</h2><p>Manage personal sign-ins and production computers.</p></div>
          <div class="account-overview" aria-label="Account summary">
            <span><strong>${escapeHtml(summary.total_accounts || 0)}</strong> total</span>
            <span><strong>${escapeHtml(summary.linked_staff || 0)}</strong> linked staff</span>
            <span><strong>${escapeHtml(summary.terminal_accounts || 0)}</strong> terminals</span>
          </div>
          <form id="accountAccessFilters" class="staff-toolbar">
            <input id="accountAccessSearch" type="search" placeholder="Search email, staff or terminal" value="${escapeHtml(state.accountSearch)}">
            <button class="staff-secondary-button" type="submit">Apply</button>
            <button id="accountAccessReload" class="staff-secondary-button" type="button">Reload</button>
            ${state.canCreateAccounts ? '<button id="accountAccessAdd" class="staff-primary-button" type="button">Add account</button>' : ""}
          </form>
        </header>
        <div class="account-guidance">Job title supplies the default access. Open <strong>Edit</strong> only when an account needs an exception.</div>
        <div class="staff-table-wrap">
          ${accounts.length ? `<table class="staff-table staff-access-table account-directory-table"><thead><tr><th>Account</th><th>Assignment</th><th>Access</th><th>Last activity</th><th>Actions</th></tr></thead><tbody>${accounts.map((account) => `
            <tr>
              <td><div class="account-identity"><div><strong>${escapeHtml(account.login_method === "USERNAME" ? account.login_identifier : account.email || "No email")}</strong><span class="staff-status ${account.is_active ? "active" : "inactive"}">${account.is_active ? "Active" : "Disabled"}</span></div><span class="staff-subtext">${account.terminal?.device_code ? "Production terminal" : "Personal account"}</span></div></td>
              <td>${account.terminal?.device_code ? `<strong>${escapeHtml(account.terminal.device_code)}</strong><span class="staff-subtext">${escapeHtml(account.terminal.station_name || "No station")}</span>` : account.staff_id ? `<strong>${escapeHtml(account.display_name || "Unnamed staff")}</strong><span class="staff-subtext">${escapeHtml(account.employee_code || "No employee code")}</span>` : '<strong>Not linked</strong><span class="staff-subtext">No Staff Master record</span>'}</td>
              <td><div class="account-access-summary"><strong>${account.terminal?.device_code ? escapeHtml((account.role_codes || []).map((role) => role.replaceAll("_"," ")).join(", ") || "Terminal access") : escapeHtml(state.accountJobTitles.find((item) => item.job_title_code === account.job_title_code)?.job_title_name || "Not assigned")}</strong>${accountModuleSummary(account.role_codes,account.permissions)}</div></td>
              <td><strong>${escapeHtml(formatDateTime(account.last_sign_in_at))}</strong><span class="staff-subtext">Created ${escapeHtml(formatDateTime(account.created_at))}</span></td>
              <td>${accountActions(account)}</td>
            </tr>`).join("")}</tbody></table>` : '<div class="staff-empty">No accounts match this search.</div>'}
        </div>
      </section>
    `;
  }

  function option(value, label, selectedValue = "") {
    return `<option value="${escapeHtml(value)}"${value === selectedValue ? " selected" : ""}>${escapeHtml(label)}</option>`;
  }

  function populateStationOptions(selectedCode = "") {
    const selectedAreaCode = elements.defaultArea.value;
    const area = (state.reference?.areas || []).find((item) => item.area_code === selectedAreaCode);
    const stations = (state.reference?.stations || []).filter((item) => !area || item.area_id === area.area_id);
    elements.defaultStation.innerHTML = option("", "No default station", selectedCode) + stations.map((station) => option(station.station_code, station.station_name, selectedCode)).join("");
  }

  function populateEditorReference(record = {}) {
    const shifts = state.reference?.shifts || [];
    const primaryRoles = (state.reference?.operational_roles || []).filter((role) => role.allow_as_primary);
    const coverRoles = (state.reference?.operational_roles || []).filter((role) => role.allow_as_cover);
    const areas = state.reference?.areas || [];

    elements.defaultShift.innerHTML = option("", "No default shift", record.default_shift_code || "") + shifts.map((shift) => option(shift.shift_code, shift.shift_name, record.default_shift_code || "")).join("");
    elements.primaryRole.innerHTML = option("", "Select role", record.primary_role_code || "") + primaryRoles.map((role) => option(role.role_code, role.role_name, record.primary_role_code || "")).join("");
    elements.defaultArea.innerHTML = option("", "No default area", record.default_area_code || "") + areas.map((area) => option(area.area_code, area.area_name, record.default_area_code || "")).join("");
    populateStationOptions(record.default_station_code || "");

    const selectedCover = new Set(record.cover_role_codes || []);
    elements.coverOptions.innerHTML = coverRoles.map((role) => `
      <label class="staff-cover-option">
        <input type="checkbox" name="staffCoverRole" value="${escapeHtml(role.role_code)}"${selectedCover.has(role.role_code) ? " checked" : ""}>
        <span>${escapeHtml(role.role_name)}</span>
      </label>
    `).join("");
  }

  function resetEditor() {
    elements.editorForm.reset();
    elements.editorId.value = "";
    elements.editorRowVersion.value = "";
    elements.rosterEligible.checked = true;
    elements.importReviewSection.classList.add("hidden");
    elements.importReviewRequired.checked = false;
    elements.importReviewNotes.value = "";
    elements.transferDriver.classList.add("hidden");
    elements.driverTransferFields.classList.add("hidden");
    elements.driverExisting.innerHTML = '<option value="">Create a new Driver record</option>';
    state.driverTransferOptions = [];
    state.editorPrimaryRoleCode = "";
    setMessage(elements.editorMessage);
  }

  function canTransferToDriver() {
    if (!state.canManageStaff) return false;
    const roles = state.reference?.operational_roles || [];
    const areas = state.reference?.areas || [];
    return roles.some((role) => role.role_code === "DRIVER" && role.allow_as_primary)
      && areas.some((area) => area.area_code === "DISTRIBUTION");
  }

  function fillDriverTransferFields(driver = {}) {
    elements.driverCode.value = driver.driver_code || elements.employeeCode.value.replace(/^LEG-/i, "DRV-") || "";
    elements.driverPhone.value = driver.phone || "";
    elements.driverEmail.value = driver.email || "";
    elements.driverLicence.value = driver.licence_number || "";
    elements.driverCategories.value = Array.isArray(driver.licence_categories) ? driver.licence_categories.join(", ") : "";
    elements.driverLicenceExpiry.value = driver.licence_expires_on || "";
    elements.driverCpcExpiry.value = driver.cpc_expires_on || "";
    elements.driverNotes.value = driver.notes || "";
  }

  async function prepareDriverTransfer() {
    if (!canTransferToDriver()) {
      setMessage(elements.editorMessage, "Driver role or Distribution area is not configured yet.", "error");
      return;
    }
    try {
      setMessage(elements.editorMessage, "Loading available Driver records...");
      const data = await rpc("get_staff_driver_transfer_options");
      state.driverTransferOptions = Array.isArray(data?.drivers) ? data.drivers : [];
      elements.driverExisting.innerHTML = '<option value="">Create a new Driver record</option>' + state.driverTransferOptions.map((driver) => option(driver.driver_id, `${driver.display_name} · ${driver.driver_code}`)).join("");
      fillDriverTransferFields();
      elements.primaryRole.value = "DRIVER";
      elements.defaultArea.value = "DISTRIBUTION";
      populateStationOptions("");
      elements.defaultStation.value = "";
      elements.rosterEligible.checked = false;
      elements.changeReason.value = `Transfer ${elements.displayName.value || "staff member"} to Driver / Distribution.`;
      elements.driverTransferFields.classList.remove("hidden");
      elements.transferDriver.classList.add("hidden");
      elements.editorSave.textContent = "Complete Driver transfer";
      setMessage(elements.editorMessage, "Complete the Driver record. Saving will remove this person from Production Staff Master.", "success");
      elements.driverExisting.focus();
    } catch (error) {
      setMessage(elements.editorMessage, friendlyError(error), "error");
    }
  }

  async function openEditor(staffId = "") {
    if ((!staffId && !state.canCreateStaff) || (staffId && !state.canEditStaff)) return;
    resetEditor();
    elements.editorModal.classList.remove("hidden");
    document.body.style.overflow = "hidden";

    try {
      if (!staffId) {
        elements.editorTitle.textContent = "Add Staff";
        elements.editorSubtitle.textContent = "Create a governed operational staff record.";
        elements.editorSave.textContent = "Add Staff";
        populateEditorReference({});
        elements.displayName.focus();
        return;
      }

      elements.editorTitle.textContent = "Edit Staff";
      elements.editorSubtitle.textContent = "Update the staff member without changing historical roster records.";
      elements.editorSave.textContent = "Save Changes";
      setMessage(elements.editorMessage, "Loading staff record...");
      const record = await rpc("get_staff_master_record", { p_staff_id: staffId });
      elements.editorId.value = record.staff_id;
      elements.editorRowVersion.value = record.row_version;
      state.editorPrimaryRoleCode = record.primary_role_code || "";
      elements.displayName.value = record.display_name || "";
      elements.employeeCode.value = record.employee_code || "";
      elements.rosterEligible.checked = Boolean(record.roster_eligible);
      elements.joinedOn.value = record.joined_on || "";
      elements.fireTraining.checked = Boolean(record.fire_training);
      elements.firstAidTraining.checked = Boolean(record.first_aid_training);
      elements.eodCapable.checked = Boolean(record.eod_capable);
      elements.notes.value = record.notes || "";
      elements.importReviewSection.classList.remove("hidden");
      elements.importReviewRequired.checked = Boolean(record.import_review_required);
      elements.importReviewNotes.value = record.import_review_notes || "";
      populateEditorReference(record);
      elements.transferDriver.textContent = record.primary_role_code === "DRIVER" ? "Complete Driver transfer" : "Transfer to Driver";
      elements.transferDriver.classList.toggle("hidden", !record.active || !record.production_staff || !canTransferToDriver());
      setMessage(elements.editorMessage);
      elements.displayName.focus();
    } catch (error) {
      console.error("Failed to open staff record:", error);
      setMessage(elements.editorMessage, friendlyError(error), "error");
    }
  }

  function closeEditor(force = false) {
    if (state.busy && !force) return;
    elements.editorModal.classList.add("hidden");
    document.body.style.overflow = "";
    resetEditor();
  }

  function selectedCoverRoles() {
    return [...elements.coverOptions.querySelectorAll('input[name="staffCoverRole"]:checked')].map((input) => input.value);
  }

  function closeRosterRoleChoice(choice = null) {
    elements.rosterRoleModal.classList.add("hidden");
    const resolve = state.resolveRosterRoleChoice;
    state.resolveRosterRoleChoice = null;
    if (resolve) resolve(choice);
  }

  function chooseRosterRoleChange(impact) {
    const draftBaseCount = Number(impact?.draft_base_assignment_count || 0);
    const draftSnapshotCount = Number(impact?.draft_staff_snapshot_count || 0);
    const publishedBaseCount = Number(impact?.published_base_assignment_count || 0);
    const publishedSnapshotCount = Number(impact?.published_staff_snapshot_count || 0);
    const canApply = draftBaseCount > 0 || draftSnapshotCount > 0;
    const drafts = Array.isArray(impact?.drafts) ? impact.drafts : [];
    const affectedWeeks = [...new Set(drafts.map((draft) => String(draft.week_start || "")).filter(Boolean))]
      .map((weekStart) => weekStart.split("-").reverse().join("/"));
    const affectedWeeksText = affectedWeeks.length
      ? affectedWeeks.join(", ")
      : String(impact?.from_week_start || "").split("-").reverse().join("/");

    elements.rosterRoleTitle.textContent = canApply ? "Apply this role to editable rosters?" : "Keep published roster history";
    elements.rosterRoleSubtitle.textContent = impact.role_changed
      ? `${impact.staff_name} is changing from ${impact.previous_role_name} to ${impact.new_role_name}.`
      : `${impact.staff_name} already has this Staff Master role, but an editable roster still carries an earlier role.`;
    elements.rosterRoleSummary.innerHTML = canApply
      ? `<p><strong>${draftBaseCount}</strong> base assignment${draftBaseCount === 1 ? "" : "s"} in editable roster draft${draftBaseCount === 1 ? "" : "s"} still use the old role. Applying this update refreshes only the drafts for ${escapeHtml(affectedWeeksText)}.</p><p class="staff-role-change-note">COVER assignments and the table/area plan stay unchanged. ${publishedSnapshotCount > 0 || publishedBaseCount > 0 ? "Published versions remain preserved as history." : ""}</p>`
      : `<p>There is no editable current or future roster draft for this staff member. The Staff Master role will be corrected for future planning, while ${publishedSnapshotCount || publishedBaseCount ? "published roster versions remain unchanged as history." : "there is no editable roster to update."}</p><p class="staff-role-change-note staff-role-change-warning">Published roster versions are intentionally not changed from Staff Master.</p>`;
    elements.rosterRoleApply.hidden = !canApply;
    elements.rosterRoleKeep.textContent = canApply ? "Keep existing drafts" : "Save Master only";
    elements.rosterRoleApply.textContent = "Apply to editable drafts";
    elements.rosterRoleModal.classList.remove("hidden");

    return new Promise((resolve) => {
      state.resolveRosterRoleChoice = resolve;
      (canApply ? elements.rosterRoleApply : elements.rosterRoleKeep).focus();
    });
  }

  async function saveEditor(event) {
    event.preventDefault();
    if (state.busy) return;

    const staffId = elements.editorId.value;
    const displayName = elements.displayName.value.trim();
    const reason = elements.changeReason.value.trim();

    if (!displayName || !elements.primaryRole.value || !reason) {
      setMessage(elements.editorMessage, "Complete the staff name, primary role and audit reason.", "error");
      return;
    }

    state.busy = true;
    elements.editorSave.disabled = true;
    setMessage(elements.editorMessage, staffId ? "Saving changes..." : "Adding staff...");

    try {
      const common = {
        p_display_name: displayName,
        p_employee_code: elements.employeeCode.value.trim() || null,
        p_default_shift_code: elements.defaultShift.value || null,
        p_primary_role_code: elements.primaryRole.value,
        p_default_area_code: elements.defaultArea.value || null,
        p_default_station_code: elements.defaultStation.value || null,
        p_roster_eligible: elements.rosterEligible.checked,
        p_cover_role_codes: selectedCoverRoles(),
        p_fire_training: elements.fireTraining.checked,
        p_first_aid_training: elements.firstAidTraining.checked,
        p_eod_capable: elements.eodCapable.checked,
        p_joined_on: elements.joinedOn.value || null,
        p_notes: elements.notes.value.trim() || null,
        p_change_reason: reason,
        p_source_application: "STAFF_MASTER_UI"
      };

      if (staffId && !elements.driverTransferFields.classList.contains("hidden")) {
        const categories = elements.driverCategories.value.split(",").map((value) => value.trim().toUpperCase()).filter(Boolean);
        if (!elements.driverCode.value.trim() || !elements.driverPhone.value.trim() || !elements.driverLicence.value.trim()
            || !categories.length || !elements.driverLicenceExpiry.value || !elements.driverCpcExpiry.value) {
          setMessage(elements.editorMessage, "Complete the Driver code, phone, licence, category, licence expiry and CPC expiry.", "error");
          return;
        }
        const result = await rpc("transfer_staff_to_distribution_driver", {
          p_staff_id: staffId,
          p_expected_row_version: Number(elements.editorRowVersion.value),
          p_existing_driver_id: elements.driverExisting.value || null,
          p_driver_code: elements.driverCode.value.trim(),
          p_phone: elements.driverPhone.value.trim(),
          p_email: elements.driverEmail.value.trim() || null,
          p_licence_number: elements.driverLicence.value.trim(),
          p_licence_categories: categories,
          p_licence_expires_on: elements.driverLicenceExpiry.value,
          p_cpc_expires_on: elements.driverCpcExpiry.value,
          p_notes: elements.driverNotes.value.trim() || null,
          p_change_reason: reason,
          p_source_application: "STAFF_MASTER_UI"
        });
        closeEditor(true);
        setMessage(elements.pageMessage, `Driver ${result?.driver_code || ""} created and removed from Production Staff Master.`, "success");
        await loadDirectory();
        return;
      }

      let applyCurrentRosterRole = false;
      if (staffId) {
        const impact = await rpc("get_staff_primary_role_change_impact", {
          p_staff_id: staffId,
          p_new_primary_role_code: common.p_primary_role_code
        });
        const hasCurrentRosterImpact = Number(impact?.draft_base_assignment_count || 0) > 0
          || Number(impact?.draft_staff_snapshot_count || 0) > 0
          || Number(impact?.published_base_assignment_count || 0) > 0
          || Number(impact?.published_staff_snapshot_count || 0) > 0;
        if (hasCurrentRosterImpact) {
          const choice = await chooseRosterRoleChange(impact);
          if (choice === null) {
            setMessage(elements.editorMessage, "Staff change was not saved.");
            return;
          }
          applyCurrentRosterRole = choice === true;
        }
      }

      if (staffId) {
        const result = await rpc("update_staff_master_with_current_roster_role", {
          p_staff_id: staffId,
          p_expected_row_version: Number(elements.editorRowVersion.value),
          ...common,
          p_import_review_required: elements.importReviewRequired.checked,
          p_import_review_notes: elements.importReviewNotes.value.trim() || null,
          p_apply_current_roster_role: applyCurrentRosterRole
        });
        const updatedCount = Number(result?.current_roster_base_assignments_updated || 0);
        const snapshotCount = Number(result?.current_roster_staff_snapshots_updated || 0);
        if (applyCurrentRosterRole) setMessage(elements.pageMessage, `Staff record updated. ${updatedCount} base assignment${updatedCount === 1 ? "" : "s"} and ${snapshotCount} editable roster row${snapshotCount === 1 ? "" : "s"} refreshed.`, "success");
      } else {
        await rpc("create_staff_master", common);
      }

      closeEditor(true);
      if (!applyCurrentRosterRole) setMessage(elements.pageMessage, staffId ? "Staff record updated." : "Staff member added.", "success");
      await loadDirectory();
    } catch (error) {
      console.error("Failed to save staff record:", error);
      setMessage(elements.editorMessage, friendlyError(error), "error");
    } finally {
      state.busy = false;
      elements.editorSave.disabled = false;
    }
  }

  function openStatusModal(action, staffId, rowVersion, staffName) {
    if (!state.canManageStaff) return;
    const isDeactivate = action === "DEACTIVATE";
    elements.statusForm.reset();
    elements.statusId.value = staffId;
    elements.statusRowVersion.value = rowVersion;
    elements.statusAction.value = action;
    elements.statusTitle.textContent = isDeactivate ? "Deactivate Staff" : "Reactivate Staff";
    elements.statusSubtitle.textContent = `${isDeactivate ? "Remove" : "Restore"} ${staffName} ${isDeactivate ? "from active operational planning without deleting history." : "as an active staff member."}`;
    elements.deactivatedDateField.classList.toggle("hidden", !isDeactivate);
    elements.reactivateRosterField.classList.toggle("hidden", isDeactivate);
    elements.deactivatedOn.value = localDateValue();
    elements.reactivateRosterEligible.checked = true;
    elements.statusConfirm.textContent = isDeactivate ? "Deactivate" : "Reactivate";
    elements.statusConfirm.className = isDeactivate ? "staff-danger-button" : "staff-primary-button";
    setMessage(elements.statusMessage);
    elements.statusModal.classList.remove("hidden");
    document.body.style.overflow = "hidden";
    elements.statusReason.focus();
  }

  function closeStatusModal(force = false) {
    if (state.busy && !force) return;
    elements.statusModal.classList.add("hidden");
    document.body.style.overflow = "";
    elements.statusForm.reset();
    setMessage(elements.statusMessage);
  }

  async function saveStatus(event) {
    event.preventDefault();
    if (state.busy) return;
    const reason = elements.statusReason.value.trim();
    if (!reason) {
      setMessage(elements.statusMessage, "A reason is required.", "error");
      return;
    }

    state.busy = true;
    elements.statusConfirm.disabled = true;
    const action = elements.statusAction.value;
    setMessage(elements.statusMessage, action === "DEACTIVATE" ? "Deactivating staff..." : "Reactivating staff...");

    try {
      if (action === "DEACTIVATE") {
        await rpc("deactivate_staff_member", {
          p_staff_id: elements.statusId.value,
          p_expected_row_version: Number(elements.statusRowVersion.value),
          p_deactivated_on: elements.deactivatedOn.value || localDateValue(),
          p_reason: reason,
          p_source_application: "STAFF_MASTER_UI"
        });
      } else {
        await rpc("reactivate_staff_member", {
          p_staff_id: elements.statusId.value,
          p_expected_row_version: Number(elements.statusRowVersion.value),
          p_roster_eligible: elements.reactivateRosterEligible.checked,
          p_reason: reason,
          p_source_application: "STAFF_MASTER_UI"
        });
      }

      closeStatusModal(true);
      setMessage(elements.pageMessage, action === "DEACTIVATE" ? "Staff member deactivated." : "Staff member reactivated.", "success");
      await loadDirectory();
    } catch (error) {
      console.error("Failed to change staff status:", error);
      setMessage(elements.statusMessage, friendlyError(error), "error");
    } finally {
      state.busy = false;
      elements.statusConfirm.disabled = false;
    }
  }

  elements.main.addEventListener("submit", async (event) => {
    if (event.target.id === "accountAccessFilters") {
      event.preventDefault();
      state.accountSearch = document.getElementById("accountAccessSearch")?.value.trim() || "";
      return loadAccounts();
    }
    if (event.target.id !== "staffDirectoryFilters") return;
    event.preventDefault();
    state.search = document.getElementById("staffDirectorySearch")?.value.trim() || "";
    state.statusFilter = document.getElementById("staffStatusFilter")?.value || "ACTIVE";
    state.shiftFilter = document.getElementById("staffShiftFilter")?.value || "ALL";
    await loadDirectory();
  });

  elements.main.addEventListener("click", async (event) => {
    const viewButton = event.target.closest("[data-staff-view]");
    if (viewButton && viewButton.dataset.staffView !== state.view) {
      state.view = viewButton.dataset.staffView === "accounts" ? "accounts" : "directory";
      const url = new URL(location.href);
      if (state.view === "accounts") url.searchParams.set("view", "accounts");
      else url.searchParams.delete("view");
      history.replaceState(null, "", url);
      return state.view === "accounts" ? loadAccounts() : loadDirectory();
    }

    const addButton = event.target.closest("#staffAddButton");
    if (addButton) return openEditor();

    const reloadButton = event.target.closest("#staffDirectoryReload");
    if (reloadButton) return loadDirectory();

    const accountReloadButton = event.target.closest("#accountAccessReload");
    if (accountReloadButton) return loadAccounts();

    const accountAddButton = event.target.closest("#accountAccessAdd");
    if (accountAddButton) return openAccountEditor();

    const accountEditButton = event.target.closest("[data-account-edit]");
    if (accountEditButton) return openAccountEditor(accountEditButton.dataset.accountEdit);

    const resetTerminalPasswordButton = event.target.closest("[data-account-reset-password]");
    if (resetTerminalPasswordButton) return openTerminalPasswordReset(resetTerminalPasswordButton.dataset.accountResetPassword);

    const sendSetupButton = event.target.closest("[data-account-send-setup]");
    if (sendSetupButton) {
      sendSetupButton.disabled = true;
      try {
        await accountAdmin("send_setup_link", { auth_user_id:sendSetupButton.dataset.accountSendSetup, redirect_to:new URL("../pages/update-password.html",window.location.href).href });
        setMessage(elements.pageMessage, "A secure password setup link was sent by email.", "success");
      } catch (error) { setMessage(elements.pageMessage, friendlyError(error), "error"); }
      finally { sendSetupButton.disabled = false; }
      return;
    }

    const disableAccountButton = event.target.closest("[data-account-disable]");
    if (disableAccountButton) {
      if (!window.confirm("Disable this account? The user will be signed out and cannot sign in again.")) return;
      try { await accountAdmin("disable", { auth_user_id:disableAccountButton.dataset.accountDisable }); setMessage(elements.pageMessage, "Account disabled.", "success"); await loadAccounts(); }
      catch (error) { setMessage(elements.pageMessage, friendlyError(error), "error"); }
      return;
    }

    const enableAccountButton = event.target.closest("[data-account-enable]");
    if (enableAccountButton) {
      try { await accountAdmin("enable", { auth_user_id:enableAccountButton.dataset.accountEnable }); setMessage(elements.pageMessage, "Account enabled.", "success"); await loadAccounts(); }
      catch (error) { setMessage(elements.pageMessage, friendlyError(error), "error"); }
      return;
    }

    const deleteAccountButton = event.target.closest("[data-account-delete]");
    if (deleteAccountButton) {
      const email = deleteAccountButton.dataset.accountEmail || "this account";
      if (!window.confirm(`Delete ${email}? This cannot be undone.`)) return;
      try { await accountAdmin("delete", { auth_user_id:deleteAccountButton.dataset.accountDelete }); setMessage(elements.pageMessage, "Account deleted.", "success"); await loadAccounts(); }
      catch (error) { setMessage(elements.pageMessage, friendlyError(error), "error"); }
      return;
    }

    const editButton = event.target.closest("[data-staff-edit], [data-staff-open]");
    if (editButton && state.canEditStaff) {
      return openEditor(editButton.dataset.staffEdit || editButton.dataset.staffOpen);
    }

    const deactivateButton = event.target.closest("[data-staff-deactivate]");
    if (deactivateButton) {
      return openStatusModal(
        "DEACTIVATE",
        deactivateButton.dataset.staffDeactivate,
        deactivateButton.dataset.rowVersion,
        deactivateButton.dataset.staffName
      );
    }

    const reactivateButton = event.target.closest("[data-staff-reactivate]");
    if (reactivateButton) {
      return openStatusModal(
        "REACTIVATE",
        reactivateButton.dataset.staffReactivate,
        reactivateButton.dataset.rowVersion,
        reactivateButton.dataset.staffName
      );
    }
  });

  elements.defaultArea.addEventListener("change", () => populateStationOptions(""));
  elements.editorForm.addEventListener("submit", saveEditor);
  elements.transferDriver.addEventListener("click", prepareDriverTransfer);
  elements.driverExisting.addEventListener("change", () => {
    const driver = state.driverTransferOptions.find((item) => item.driver_id === elements.driverExisting.value);
    fillDriverTransferFields(driver || {});
  });
  elements.editorBackdrop.addEventListener("click", closeEditor);
  elements.editorClose.addEventListener("click", closeEditor);
  elements.editorCancel.addEventListener("click", closeEditor);
  elements.rosterRoleBackdrop.addEventListener("click", () => closeRosterRoleChoice(null));
  elements.rosterRoleClose.addEventListener("click", () => closeRosterRoleChoice(null));
  elements.rosterRoleCancel.addEventListener("click", () => closeRosterRoleChoice(null));
  elements.rosterRoleKeep.addEventListener("click", () => closeRosterRoleChoice(false));
  elements.rosterRoleApply.addEventListener("click", () => closeRosterRoleChoice(true));
  elements.statusForm.addEventListener("submit", saveStatus);
  elements.statusBackdrop.addEventListener("click", closeStatusModal);
  elements.statusClose.addEventListener("click", closeStatusModal);
  elements.statusCancel.addEventListener("click", closeStatusModal);
  elements.accountForm.addEventListener("submit", saveAccountEditor);
  elements.accountJobTitle.addEventListener("change", () => applyJobTitleTemplate(true));
  elements.accountLoginMethod.addEventListener("change", applyLoginMethod);
  elements.accountBackdrop.addEventListener("click", closeAccountEditor);
  elements.accountClose.addEventListener("click", closeAccountEditor);
  elements.accountCancel.addEventListener("click", closeAccountEditor);
  elements.accountType.addEventListener("change", applyAccountType);
  elements.terminalPasswordForm.addEventListener("submit", saveTerminalPasswordReset);
  elements.terminalPasswordBackdrop.addEventListener("click", closeTerminalPasswordReset);
  elements.terminalPasswordClose.addEventListener("click", closeTerminalPasswordReset);
  elements.terminalPasswordCancel.addEventListener("click", closeTerminalPasswordReset);
  elements.terminalPasswordShow.addEventListener("change", toggleTerminalPasswordVisibility);
  elements.signOut.addEventListener("click", async () => {
    await client.auth.signOut();
    window.location.replace("../index.html");
  });

  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape") return;
    if (!elements.rosterRoleModal.classList.contains("hidden")) {
      closeRosterRoleChoice(null);
      return;
    }
    if (!elements.editorModal.classList.contains("hidden")) closeEditor();
    if (!elements.statusModal.classList.contains("hidden")) closeStatusModal();
    if (!elements.accountModal.classList.contains("hidden")) closeAccountEditor();
    if (!elements.terminalPasswordModal.classList.contains("hidden")) closeTerminalPasswordReset();
  });

  try {
    const { data: sessionData, error: sessionError } = await client.auth.getSession();
    if (sessionError) throw sessionError;
    if (!sessionData.session) {
      window.location.replace("../index.html");
      return;
    }

    const [reference,accessProfile] = await Promise.all([rpc("get_staff_master_reference_data"),rpc("get_current_account_access")]);
    state.reference = reference;
    state.accessProfile = accessProfile || {};
    const hasExplicitPermissions = Array.isArray(state.accessProfile.permissions) && state.accessProfile.permissions.length > 0;
    state.canViewAccounts = canAccountAction("ACCOUNTS_ACCESS","VIEW");
    state.canCreateAccounts = canAccountAction("ACCOUNTS_ACCESS","CREATE");
    state.canEditAccounts = canAccountAction("ACCOUNTS_ACCESS","EDIT");
    state.canManageAccounts = canAccountAction("ACCOUNTS_ACCESS","MANAGE");
    state.canCreateStaff = hasExplicitPermissions ? canAccountAction("STAFF_MASTER","CREATE") : Boolean(reference?.can_edit_staff);
    state.canEditStaff = hasExplicitPermissions ? canAccountAction("STAFF_MASTER","EDIT") : Boolean(reference?.can_edit_staff);
    state.canManageStaff = hasExplicitPermissions ? canAccountAction("STAFF_MASTER","MANAGE") : Boolean(reference?.can_deactivate_staff);
    if (state.view === "accounts" && !state.canViewAccounts) {
      state.view = "directory";
      const url = new URL(location.href);
      url.searchParams.delete("view");
      history.replaceState(null, "", url);
    }
    await (state.view === "accounts" && state.canViewAccounts ? loadAccounts() : loadDirectory());
  } catch (error) {
    console.error("Staff Master initialization failed:", error);
    elements.main.innerHTML = `<div class="staff-empty">${escapeHtml(friendlyError(error))}</div>`;
    setMessage(elements.pageMessage, friendlyError(error), "error");
  }
});
