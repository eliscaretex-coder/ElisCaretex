import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function respond(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}

function message(error: unknown) {
  return String(error instanceof Error ? error.message : error || "Account operation failed.").replace(/[\r\n]+/g, " ").slice(0, 500);
}

function value(body: Record<string, unknown>, key: string) {
  return String(body[key] || "").trim();
}

async function isAdministrator(client: ReturnType<typeof createClient>, authUserId: string) {
  const { data: accessProfile } = await client.from("account_access_profiles").select("auth_user_id").eq("auth_user_id", authUserId).maybeSingle();
  if (accessProfile) {
    const { data: directAdmin } = await client.from("account_roles").select("account_role_id,roles!inner(role_code)").eq("auth_user_id", authUserId).eq("active", true).eq("roles.role_code", "ADMIN").limit(1).maybeSingle();
    return Boolean(directAdmin);
  }
  const { data: staff, error: staffError } = await client
    .from("staff_members")
    .select("staff_id")
    .eq("auth_user_id", authUserId)
    .is("deleted_at", null)
    .maybeSingle();
  if (staffError || !staff) return false;

  const { data: adminRole, error: roleError } = await client
    .from("roles")
    .select("role_id")
    .eq("role_code", "ADMIN")
    .eq("active", true)
    .maybeSingle();
  if (roleError || !adminRole) return false;

  const today = new Date().toISOString().slice(0, 10);
  const { data: role, error: assignmentError } = await client
    .from("staff_roles")
    .select("staff_role_id")
    .eq("staff_id", staff.staff_id)
    .eq("role_id", adminRole.role_id)
    .eq("active", true)
    .lte("effective_from", today)
    .or(`effective_until.is.null,effective_until.gte.${today}`)
    .limit(1)
    .maybeSingle();
  return !assignmentError && Boolean(role);
}

async function accountCapabilities(client: ReturnType<typeof createClient>,authUserId: string) {
  if (await isAdministrator(client,authUserId)) return { isAdmin:true,canCreate:true,canEdit:true,canManage:true,accessScope:"ALL" };
  const today = new Date().toISOString().slice(0,10);
  const { data,error } = await client.from("account_permission_grants")
    .select("can_create,can_edit,can_manage,access_scope")
    .eq("auth_user_id",authUserId).eq("module_code","ACCOUNTS_ACCESS").eq("active",true)
    .lte("effective_from",today).or(`effective_until.is.null,effective_until.gte.${today}`).maybeSingle();
  if (error) throw error;
  return { isAdmin:false,canCreate:Boolean(data?.can_create || data?.can_manage),canEdit:Boolean(data?.can_edit || data?.can_manage),canManage:Boolean(data?.can_manage),accessScope:String(data?.access_scope || "OWN") };
}

const SCOPE_COVERS: Record<string,string[]> = {
  OWN:["OWN"], TEAM:["OWN","TEAM"], PRODUCTION:["OWN","TEAM","PRODUCTION"],
  DISTRIBUTION:["OWN","TEAM","DISTRIBUTION"], ALL:["OWN","TEAM","PRODUCTION","DISTRIBUTION","ALL"]
};
type Grant = { module_code:string; access_scope:string; can_view:boolean; can_create:boolean; can_edit:boolean; can_approve:boolean; can_manage:boolean };

function maskEmail(email: string) {
  const value = String(email || "").trim().toLowerCase();
  if (!value.includes("@")) return value;
  const [local, domain] = value.split("@");
  const tld = domain.includes(".") ? domain.slice(domain.lastIndexOf(".")) : "";
  return `${local.slice(0, local.length <= 3 ? 1 : 2)}***@${domain.slice(0, 1)}***${tld}`;
}

async function activeGrants(client: ReturnType<typeof createClient>, authUserId: string) {
  const today = new Date().toISOString().slice(0,10);
  const { data,error } = await client.from("account_permission_grants")
    .select("module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage")
    .eq("auth_user_id",authUserId).eq("active",true)
    .lte("effective_from",today).or(`effective_until.is.null,effective_until.gte.${today}`);
  if (error) throw error;
  return (data || []) as Grant[];
}

async function activeRoleCodes(client: ReturnType<typeof createClient>, authUserId: string) {
  const { data,error } = await client.from("account_roles").select("roles!inner(role_code)").eq("auth_user_id",authUserId).eq("active",true);
  if (error) throw error;
  return (data || []).map((item) => String((item.roles as unknown as { role_code:string }).role_code));
}

// "You cannot give (or manage someone who has) more than you have."
// Every grant must be covered by the caller's own grant on the same module:
// same or wider scope, and every action flag the caller also holds.
function assertGrantsCovered(grants: Grant[], callerGrants: Grant[], what: string) {
  const byModule = new Map<string,Grant[]>();
  for (const grant of callerGrants) byModule.set(grant.module_code,[...(byModule.get(grant.module_code) || []),grant]);
  for (const grant of grants) {
    const covered = (byModule.get(grant.module_code) || []).some((own) =>
      (SCOPE_COVERS[own.access_scope] || []).includes(grant.access_scope)
      && (!grant.can_view || own.can_view || own.can_create || own.can_edit || own.can_approve || own.can_manage)
      && (!grant.can_create || own.can_create || own.can_manage)
      && (!grant.can_edit || own.can_edit || own.can_manage)
      && (!grant.can_approve || own.can_approve || own.can_manage)
      && (!grant.can_manage || own.can_manage));
    if (!covered) throw new Error(`${what} has ${grant.module_code} access beyond your own permissions.`);
  }
}

function assertRolesCovered(roles: string[], callerRoles: string[], what: string) {
  const own = new Set(callerRoles);
  const missing = roles.filter((role) => !own.has(role));
  if (missing.length) throw new Error(`${what} has system roles (${missing.join(", ")}) that your account does not have.`);
}

async function jobTitleRank(client: ReturnType<typeof createClient>, jobTitleCode: string) {
  if (!jobTitleCode) return null;
  const { data,error } = await client.from("account_job_titles").select("hierarchy_rank").eq("job_title_code",jobTitleCode).eq("active",true).maybeSingle();
  if (error) throw error;
  return data?.hierarchy_rank === null || data?.hierarchy_rank === undefined ? null : Number(data.hierarchy_rank);
}

async function accountRank(client: ReturnType<typeof createClient>, authUserId: string) {
  const { data,error } = await client.from("account_access_profiles").select("job_title_code").eq("auth_user_id",authUserId).maybeSingle();
  if (error) throw error;
  return jobTitleRank(client,String(data?.job_title_code || ""));
}

async function assertJobTitleScope(client: ReturnType<typeof createClient>,jobTitleCode: string,accessScope: string) {
  const { data,error } = await client.from("account_job_titles").select("department_scope").eq("job_title_code",jobTitleCode).eq("active",true).maybeSingle();
  if (error || !data) throw new Error("The selected job title is not available.");
  if (accessScope === "ALL") return;
  if (accessScope === "PRODUCTION" && data.department_scope === "PRODUCTION") return;
  if (accessScope === "DISTRIBUTION" && data.department_scope === "DISTRIBUTION") return;
  throw new Error("The selected job title is outside this account's permitted scope.");
}

async function assertAccountScope(client: ReturnType<typeof createClient>,accountId: string,callerId: string,accessScope: string) {
  if (accessScope === "ALL" || accountId === callerId) return;
  const { data,error } = await client.from("account_access_profiles").select("account_type,job_title_code").eq("auth_user_id",accountId).maybeSingle();
  if (error || !data) throw new Error("The selected account is outside this account's permitted scope.");
  if (data.account_type === "TERMINAL" || !data.job_title_code) throw new Error("All scope is required to manage this account.");
  await assertJobTitleScope(client,String(data.job_title_code),accessScope);
}

async function existingAccountConfiguration(client: ReturnType<typeof createClient>,accountId: string) {
  const [{ data:profile,error:profileError },{ data:grants,error:grantError },{ data:roleRows,error:roleError }] = await Promise.all([
    client.from("account_access_profiles").select("account_type,job_title_code").eq("auth_user_id",accountId).maybeSingle(),
    client.from("account_permission_grants").select("module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage").eq("auth_user_id",accountId).eq("active",true),
    client.from("account_roles").select("roles!inner(role_code)").eq("auth_user_id",accountId).eq("active",true)
  ]);
  if (profileError || grantError || roleError) throw profileError || grantError || roleError;
  return {
    profile,
    permissions:(grants || []) as ReturnType<typeof permissionGrants>,
    roles:(roleRows || []).map((item) => String((item.roles as unknown as { role_code:string }).role_code))
  };
}

async function assertLinkableStaff(client: ReturnType<typeof createClient>, staffId: string, accountId: string) {
  if (!staffId) return;
  const { data, error } = await client
    .from("staff_members")
    .select("staff_id,active,deleted_at,auth_user_id")
    .eq("staff_id", staffId)
    .maybeSingle();
  if (error || !data || !data.active || data.deleted_at) throw new Error("The selected Staff Master record is not active.");
  if (data.auth_user_id && data.auth_user_id !== accountId) throw new Error("The selected Staff Master record is already linked to another account.");
}

async function setStaffLink(client: ReturnType<typeof createClient>, accountId: string, staffId: string) {
  const { error: unlinkError } = await client.from("staff_members").update({ auth_user_id: null }).eq("auth_user_id", accountId);
  if (unlinkError) throw unlinkError;
  if (!staffId) return;
  const { error: linkError } = await client.from("staff_members").update({ auth_user_id: accountId }).eq("staff_id", staffId);
  if (linkError) throw linkError;
}

function roleCodes(body: Record<string, unknown>) {
  return [...new Set(Array.isArray(body.role_codes)
    ? body.role_codes.map((item) => String(item || "").trim()).filter(Boolean)
    : [])];
}

function permissionGrants(body: Record<string, unknown>) {
  if (!Array.isArray(body.permissions)) return [];
  return body.permissions.map((item) => {
    const grant = (item && typeof item === "object" ? item : {}) as Record<string, unknown>;
    return {
      module_code: String(grant.module_code || "").trim().toUpperCase(),
      access_scope: String(grant.access_scope || "OWN").trim().toUpperCase(),
      can_view: Boolean(grant.can_view), can_create: Boolean(grant.can_create), can_edit: Boolean(grant.can_edit),
      can_approve: Boolean(grant.can_approve), can_manage: Boolean(grant.can_manage),
    };
  }).filter((grant) => grant.module_code && (grant.can_view || grant.can_create || grant.can_edit || grant.can_approve || grant.can_manage));
}

async function resolveJobAccess(client: ReturnType<typeof createClient>, jobTitleCode: string, submittedPermissions: ReturnType<typeof permissionGrants>) {
  const { data: jobTitle, error: titleError } = await client.from("account_job_titles").select("job_title_code").eq("job_title_code", jobTitleCode).eq("active", true).maybeSingle();
  if (titleError || !jobTitle) throw new Error("The selected job title is not available.");

  const { data: mappings, error: mappingError } = await client.from("job_title_legacy_roles").select("roles!inner(role_code)").eq("job_title_code", jobTitleCode);
  if (mappingError) throw mappingError;
  const roleCodes = (mappings || []).map((item) => String((item.roles as unknown as { role_code: string }).role_code));

  const { data: templates, error: templateError } = await client.from("job_title_permission_templates").select("module_code,access_scope,can_view,can_create,can_edit,can_approve,can_manage").eq("job_title_code", jobTitleCode);
  if (templateError) throw templateError;
  const jobTemplates = (templates || []) as ReturnType<typeof permissionGrants>;
  if (!submittedPermissions.length || jobTitleCode === "ADMINISTRATOR") return { roleCodes, permissions:jobTemplates };

  const submittedByModule = new Map(submittedPermissions.map((grant) => [grant.module_code,grant]));
  const permissions = jobTemplates.map((template) => {
    const requested = submittedByModule.get(template.module_code);
    if (!requested) return null;
    const allowedScopes: Record<string,string[]> = {
      OWN:["OWN"], TEAM:["OWN","TEAM"], PRODUCTION:["OWN","TEAM","PRODUCTION"],
      DISTRIBUTION:["OWN","TEAM","DISTRIBUTION"], ALL:["OWN","TEAM","PRODUCTION","DISTRIBUTION","ALL"]
    };
    if (!(allowedScopes[template.access_scope] || []).includes(requested.access_scope)) throw new Error(`The scope selected for ${template.module_code} is not valid for this job title.`);
    const grant = {
      module_code:template.module_code, access_scope:requested.access_scope,
      can_view:template.can_view && requested.can_view,
      can_create:template.can_create && requested.can_create,
      can_edit:template.can_edit && requested.can_edit,
      can_approve:template.can_approve && requested.can_approve,
      can_manage:template.can_manage && requested.can_manage,
    };
    return grant.can_view || grant.can_create || grant.can_edit || grant.can_approve || grant.can_manage ? grant : null;
  }).filter(Boolean) as ReturnType<typeof permissionGrants>;
  return { roleCodes,permissions };
}

async function setAccountPermissions(client: ReturnType<typeof createClient>, accountId: string, grants: ReturnType<typeof permissionGrants>, actorId: string) {
  const scopes = new Set(["OWN","TEAM","PRODUCTION","DISTRIBUTION","ALL"]);
  if (grants.some((grant) => !scopes.has(grant.access_scope))) throw new Error("One or more permission scopes are invalid.");
  if (grants.length) {
    const moduleCodes = [...new Set(grants.map((grant) => grant.module_code))];
    const { data, error } = await client.from("application_modules").select("module_code").eq("active", true).in("module_code", moduleCodes);
    if (error || (data || []).length !== moduleCodes.length) throw new Error("One or more permission modules are invalid.");
  }
  const { error: clearError } = await client.from("account_permission_grants").delete().eq("auth_user_id", accountId);
  if (clearError) throw clearError;
  if (!grants.length) return;
  const { error } = await client.from("account_permission_grants").insert(grants.map((grant) => ({ ...grant, auth_user_id:accountId, granted_by_auth_user_id:actorId })));
  if (error) throw error;
}

async function setAccountRoles(client: ReturnType<typeof createClient>, accountId: string, codes: string[], accountType: string, displayName: string, jobTitleCode: string, loginMethod: string, loginIdentifier: string) {
  const { error: profileError } = await client.from("account_access_profiles").upsert({ auth_user_id: accountId, account_type: accountType, display_name: displayName || null, job_title_code:jobTitleCode || null, login_method:loginMethod, login_identifier:loginIdentifier || null }, { onConflict: "auth_user_id" });
  if (profileError) throw profileError;
  let roles: Array<{ role_id: string; role_code: string }> = [];
  if (codes.length) {
    const { data, error } = await client.from("roles").select("role_id,role_code").eq("active", true).in("role_code", codes);
    if (error || (data || []).length !== codes.length) throw new Error("One or more selected access permissions are invalid.");
    roles = data || [];
  }
  const { error: clearError } = await client.from("account_roles").update({ active: false }).eq("auth_user_id", accountId).eq("active", true);
  if (clearError) throw clearError;
  if (!roles.length) return;
  const { error: insertError } = await client.from("account_roles").upsert(roles.map((role) => ({ auth_user_id: accountId, role_id: role.role_id, active: true })), { onConflict: "auth_user_id,role_id" });
  if (insertError) throw insertError;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return respond({ ok: false, error: "Method not allowed." }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") || "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const authorization = req.headers.get("Authorization") || "";
  if (!supabaseUrl || !anonKey || !serviceKey) return respond({ ok: false, error: "Account service is not configured." }, 500);
  if (!authorization) return respond({ ok: false, error: "Authentication is required." }, 401);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return respond({ ok: false, error: "Invalid request." }, 400); }

  const requester = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false, autoRefreshToken: false } });
  const { data: identity, error: identityError } = await requester.auth.getUser();
  if (identityError || !identity.user) return respond({ ok: false, error: "Authentication is required." }, 401);

  const { data: callerAccess, error: callerAccessError } = await requester.rpc("get_current_account_access");
  if (callerAccessError || !callerAccess?.account_enabled || callerAccess?.account_type !== "USER") return respond({ ok:false,error:"This account is not enabled for account management." },403);

  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const action = value(body, "action");
  let capabilities;
  try { capabilities = await accountCapabilities(admin,identity.user.id); }
  catch (error) { return respond({ ok:false,error:message(error) },403); }
  const permitted = action === "create" ? capabilities.canCreate : action === "update" ? capabilities.canEdit : capabilities.canManage;
  if (!permitted) return respond({ ok:false,error:"This account does not have permission for this account action." },403);
  const accountId = value(body, "auth_user_id");
  const submittedEmail = value(body, "email").toLowerCase();
  // The account list shows emails masked (pa***@g***.com). A masked or empty value
  // on update means "keep the current email".
  const email = submittedEmail.includes("*") ? "" : submittedEmail;
  const password = value(body, "password");
  const staffId = value(body, "staff_id");
  const accountType = value(body, "account_type") === "TERMINAL" ? "TERMINAL" : "USER";
  const displayName = value(body, "display_name");
  const deviceCode = value(body, "device_code");
  const deviceName = value(body, "device_name");
  const stationId = value(body, "station_id");
  let selectedRoles = roleCodes(body);
  let selectedPermissions = permissionGrants(body);
  const jobTitleCode = value(body,"job_title_code").toUpperCase();
  const loginMethod = accountType === "TERMINAL" ? "TERMINAL" : value(body,"login_method") === "USERNAME" ? "USERNAME" : "EMAIL";
  const loginIdentifier = value(body,"login_identifier").toLowerCase().replace(/[^a-z0-9._-]+/g,"-").replace(/^-|-$/g,"");
  const canonicalPasswordSetupUrl = "https://eliscaretex-coder.github.io/ElisCaretex/pages/update-password.html";
  const operationalJobTitles = new Set(["GENERAL_OPERATIVE","TEAM_LEADER","LABEL_OPERATIVE","CLEANER","MAINTENANCE","PRODUCTION_SUPERVISOR","PRODUCTION_MANAGER"]);
  const validRedirect = canonicalPasswordSetupUrl;

  try {
    if (action !== "create") {
      if (!accountId) throw new Error("Account identifier is required.");
      await assertAccountScope(admin,accountId,identity.user.id,capabilities.accessScope);
    }
    if (accountType === "TERMINAL" && ["create","update"].includes(action) && (!capabilities.canManage || capabilities.accessScope !== "ALL")) throw new Error("Manage permission with All scope is required for terminal accounts.");
    if (accountType === "USER" && ["create","update"].includes(action)) await assertJobTitleScope(admin,jobTitleCode,capabilities.accessScope);
    if (accountType === "USER" && operationalJobTitles.has(jobTitleCode) && !staffId && ["create","update"].includes(action)) throw new Error("Link this operational account to its Staff Master record.");
    const isSelf = Boolean(accountId) && accountId === identity.user.id;
    let callerRank: number | null = null;
    if (!capabilities.isAdmin) {
      // Job-title hierarchy (Administrator 1, IT Manager 10, General Manager 20,
      // Production/Logistics Manager 30, ...). A non-administrator gives only job titles
      // at their own level or below and acts only on accounts at their own level or below.
      callerRank = await accountRank(admin,identity.user.id);
      if (accountType === "USER" && ["create","update"].includes(action) && !isSelf) {
        if (jobTitleCode === "ADMINISTRATOR") throw new Error("Only an Administrator can give the Administrator job title.");
        const titleRank = await jobTitleRank(admin,jobTitleCode);
        if (callerRank === null || titleRank === null || titleRank < callerRank) throw new Error("You can only give job titles at your own level or below.");
      }
      if (action !== "create" && !isSelf) {
        const targetRoles = await activeRoleCodes(admin,accountId);
        if (targetRoles.includes("ADMIN")) throw new Error("Only an Administrator can change an Administrator account.");
        const { data:targetProfile,error:targetProfileError } = await admin.from("account_access_profiles").select("account_type").eq("auth_user_id",accountId).maybeSingle();
        if (targetProfileError) throw targetProfileError;
        if (targetProfile?.account_type === "TERMINAL") {
          if (!capabilities.canManage || capabilities.accessScope !== "ALL") throw new Error("Manage permission with All scope is required for terminal accounts.");
        } else {
          const targetRank = await accountRank(admin,accountId);
          if (callerRank === null || targetRank === null || targetRank < callerRank) throw new Error("This account is above your level. Ask an Administrator or IT Manager.");
        }
      }
    }
    let preserved: Awaited<ReturnType<typeof existingAccountConfiguration>> | null = null;
    // Nobody changes their own job title or permissions: a non-administrator
    // editing their own account keeps the current configuration.
    if (action === "update" && (!capabilities.canManage || (isSelf && !capabilities.isAdmin))) {
      if (!accountId) throw new Error("Account identifier is required.");
      if (password && !isSelf) throw new Error("Manage permission is required to replace an account password.");
      preserved = await existingAccountConfiguration(admin,accountId);
      if (!preserved.profile) throw new Error("The account access profile was not found.");
      if (preserved.profile.account_type !== accountType || (accountType === "USER" && preserved.profile.job_title_code !== jobTitleCode)) throw new Error("Manage permission is required to change account type or job title.");
      selectedPermissions = preserved.permissions;
      if (accountType === "TERMINAL") selectedRoles = preserved.roles;
    }
    if (accountType === "USER" && ["create","update"].includes(action)) {
      const resolved = await resolveJobAccess(admin, jobTitleCode, capabilities.canManage ? selectedPermissions : []);
      selectedRoles = resolved.roleCodes;
      selectedPermissions = preserved ? preserved.permissions : resolved.permissions;
    }
    // A job title may carry access the creator does not hold (the hierarchy allows it).
    // Then the creator must never know the password: only an email invitation, which
    // the new person completes themselves, is allowed.
    const setsPassword = (action === "create" && loginMethod === "USERNAME") || (action === "update" && Boolean(password) && !isSelf);
    if (!capabilities.isAdmin && accountType === "USER" && ["create","update"].includes(action) && setsPassword) {
      const [callerGrants, callerRoles] = await Promise.all([activeGrants(admin,identity.user.id), activeRoleCodes(admin,identity.user.id)]);
      try {
        assertGrantsCovered(selectedPermissions as Grant[],callerGrants,"This job title");
        assertRolesCovered(selectedRoles,callerRoles,"This job title");
      } catch {
        throw new Error("This job title has access your account does not have. Use an email invitation so only the new person sets the password.");
      }
    }
    if (action === "create") {
      const passwordRequired = accountType === "TERMINAL" || loginMethod === "USERNAME";
      if (!displayName || (passwordRequired && password.length < 12) || (accountType === "USER" && (!jobTitleCode || (loginMethod === "EMAIL" ? (!email || !email.includes("@") || !validRedirect) : !loginIdentifier))) || (accountType === "TERMINAL" && (!deviceCode || !deviceName || !stationId))) throw new Error(passwordRequired ? "Complete the account details and an initial password with at least 12 characters." : "Complete the account details and a valid invitation destination.");
      // Production computers sign in with their Computer name; the database trigger
      // production_station_devices_sync_sign_in keeps this email in step on rename.
      const technicalEmail = accountType === "TERMINAL" ? `${deviceName.toLowerCase().replace(/[^a-z0-9]+/g,"-").replace(/^-+|-+$/g,"")}@terminal.eliscaretex.local` : loginMethod === "USERNAME" ? `${loginIdentifier}@staff.eliscaretex.local` : email;
      const { data, error } = loginMethod === "EMAIL" && accountType === "USER"
        ? await admin.auth.admin.inviteUserByEmail(technicalEmail,{ redirectTo:validRedirect })
        : await admin.auth.admin.createUser({ email:technicalEmail,password,email_confirm:true });
      if (error || !data.user) throw error || new Error("The account could not be created.");
      await assertLinkableStaff(admin, staffId, data.user.id);
      await setStaffLink(admin, data.user.id, staffId);
      await setAccountRoles(admin, data.user.id, selectedRoles, accountType, displayName, jobTitleCode, loginMethod, loginIdentifier);
      await setAccountPermissions(admin, data.user.id, selectedPermissions, identity.user.id);
      if (accountType === "TERMINAL") {
        const { error: deviceError } = await admin.from("production_station_devices").insert({ station_id: stationId, device_code: deviceCode, device_name: deviceName, device_auth_user_id: data.user.id, created_by_auth_user_id: identity.user.id });
        if (deviceError) throw deviceError;
      }
      return respond({ ok:true,auth_user_id:data.user.id,technical_email:accountType === "TERMINAL" ? technicalEmail : null,invitation_sent:loginMethod === "EMAIL" && accountType === "USER" });
    }

    if (!accountId) throw new Error("Account identifier is required.");
    if (accountId === identity.user.id && ["disable", "delete"].includes(action)) throw new Error("You cannot disable or delete your own signed-in account.");
    if (accountId === identity.user.id && action === "update" && capabilities.isAdmin && jobTitleCode !== "ADMINISTRATOR") throw new Error("You cannot remove your own Administrator job title.");

    const { data: terminal, error: terminalError } = await admin
      .from("production_station_devices")
      .select("station_device_id,device_code")
      .eq("device_auth_user_id", accountId)
      .maybeSingle();
    if (terminalError) throw terminalError;

    if (action === "send_setup_link") {
      const { data:userData,error:userError }=await admin.auth.admin.getUserById(accountId);
      if (userError || !userData.user?.email || userData.user.email.endsWith(".eliscaretex.local")) throw new Error("This account does not use a personal email address.");
      if (!validRedirect) throw new Error("The password setup destination is not valid.");
      const { error }=await admin.auth.resetPasswordForEmail(userData.user.email,{ redirectTo:validRedirect });
      if (error) throw error;
      return respond({ ok:true,setup_link_sent:true });
    }

    if (action === "reset_password") {
      if (!terminal) throw new Error("Password reset is available only for registered production computers.");
      if (password.length < 12) throw new Error("The new terminal password must have at least 12 characters.");
      const { error } = await admin.auth.admin.updateUserById(accountId, { password });
      if (error) throw error;
      return respond({ ok: true });
    }

    if (action === "update") {
      if (terminal) {
        if (!deviceName || !stationId || !deviceCode || deviceCode !== terminal.device_code) throw new Error("Complete the terminal name and registered station. The terminal code cannot be changed.");
        const { error: deviceError } = await admin.from("production_station_devices").update({ device_name:deviceName,station_id:stationId }).eq("station_device_id",terminal.station_device_id);
        if (deviceError) throw deviceError;
        await setAccountRoles(admin,accountId,selectedRoles,"TERMINAL",deviceName,"","TERMINAL",deviceCode);
        await setAccountPermissions(admin,accountId,selectedPermissions,identity.user.id);
        return respond({ ok:true });
      }
      const { data:currentUser,error:currentUserError } = await admin.auth.admin.getUserById(accountId);
      if (currentUserError || !currentUser.user) throw currentUserError || new Error("The account was not found.");
      const currentEmail = String(currentUser.user.email || "").toLowerCase();
      const nextEmail = loginMethod === "USERNAME" ? `${loginIdentifier}@staff.eliscaretex.local` : (email || (currentEmail.endsWith(".eliscaretex.local") ? "" : currentEmail));
      if (!jobTitleCode || (loginMethod === "EMAIL" ? (!nextEmail || !nextEmail.includes("@")) : !loginIdentifier)) throw new Error("Complete the job title and sign-in method.");
      if (password && password.length < 12) throw new Error("Replacement passwords must have at least 12 characters.");
      // Changing where an account signs in (email or username) hands the account to
      // whoever controls the new address, so it needs Manage permission.
      if (nextEmail !== currentEmail && !capabilities.canManage) throw new Error("Manage permission is required to change an account's sign-in email or username.");
      const changes: Record<string, string> = {};
      if (nextEmail !== currentEmail) changes.email = nextEmail;
      if (password) changes.password = password;
      if (Object.keys(changes).length) {
        const { error } = await admin.auth.admin.updateUserById(accountId, changes);
        if (error) throw error;
      }
      await assertLinkableStaff(admin, staffId, accountId);
      await setStaffLink(admin, accountId, staffId);
      await setAccountRoles(admin, accountId, selectedRoles, accountType, displayName, jobTitleCode, loginMethod, loginIdentifier);
      await setAccountPermissions(admin, accountId, selectedPermissions, identity.user.id);
      return respond({ ok: true });
    }

    if (action === "disable" || action === "enable") {
      const { error } = await admin.auth.admin.updateUserById(accountId, { ban_duration: action === "disable" ? "876000h" : "none" });
      if (error) throw error;
      return respond({ ok: true });
    }

    if (action === "delete") {
      if (terminal) throw new Error("Terminal accounts cannot be deleted. Disable the account or remove its terminal binding in the production setup.");
      const { error } = await admin.auth.admin.deleteUser(accountId);
      if (error) throw error;
      return respond({ ok: true });
    }

    return respond({ ok: false, error: "Unsupported account operation." }, 400);
  } catch (error) {
    console.error(JSON.stringify({ component: "admin-account-management", action, requester: identity.user.id, error: message(error) }));
    return respond({ ok: false, error: message(error) }, 400);
  }
});
