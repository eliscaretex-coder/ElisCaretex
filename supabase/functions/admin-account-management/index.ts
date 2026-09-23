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

async function setAccountRoles(client: ReturnType<typeof createClient>, accountId: string, codes: string[], accountType: string, displayName: string) {
  const { error: profileError } = await client.from("account_access_profiles").upsert({ auth_user_id: accountId, account_type: accountType, display_name: displayName || null }, { onConflict: "auth_user_id" });
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

  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  if (!await isAdministrator(admin, identity.user.id)) return respond({ ok: false, error: "Only administrators can manage application accounts." }, 403);

  const action = value(body, "action");
  const accountId = value(body, "auth_user_id");
  const email = value(body, "email").toLowerCase();
  const password = value(body, "password");
  const staffId = value(body, "staff_id");
  const accountType = value(body, "account_type") === "TERMINAL" ? "TERMINAL" : "USER";
  const displayName = value(body, "display_name");
  const deviceCode = value(body, "device_code");
  const deviceName = value(body, "device_name");
  const stationId = value(body, "station_id");
  const selectedRoles = roleCodes(body);

  try {
    if (action === "create") {
      if (!displayName || password.length < 12 || (accountType === "USER" && (!email || !email.includes("@"))) || (accountType === "TERMINAL" && (!deviceCode || !deviceName || !stationId))) throw new Error("Complete the account details and an initial password with at least 12 characters.");
      const technicalEmail = accountType === "TERMINAL" ? `${deviceCode.toLowerCase().replace(/[^a-z0-9]+/g,"-").replace(/^-|-$/g,"")}@terminal.eliscaretex.local` : email;
      const { data, error } = await admin.auth.admin.createUser({ email: technicalEmail, password, email_confirm: true });
      if (error || !data.user) throw error || new Error("The account could not be created.");
      await assertLinkableStaff(admin, staffId, data.user.id);
      await setStaffLink(admin, data.user.id, staffId);
      await setAccountRoles(admin, data.user.id, selectedRoles, accountType, displayName);
      if (accountType === "TERMINAL") {
        const { error: deviceError } = await admin.from("production_station_devices").insert({ station_id: stationId, device_code: deviceCode, device_name: deviceName, device_auth_user_id: data.user.id, created_by_auth_user_id: identity.user.id });
        if (deviceError) throw deviceError;
      }
      return respond({ ok: true, auth_user_id: data.user.id, technical_email: accountType === "TERMINAL" ? technicalEmail : null });
    }

    if (!accountId) throw new Error("Account identifier is required.");
    if (accountId === identity.user.id && ["disable", "delete"].includes(action)) throw new Error("You cannot disable or delete your own signed-in account.");
    if (accountId === identity.user.id && action === "update" && !selectedRoles.includes("ADMIN")) throw new Error("You cannot remove your own Administrator permission.");

    const { data: terminal, error: terminalError } = await admin
      .from("production_station_devices")
      .select("station_device_id")
      .eq("device_auth_user_id", accountId)
      .maybeSingle();
    if (terminalError) throw terminalError;

    if (action === "reset_password") {
      if (!terminal) throw new Error("Password reset is available only for registered production computers.");
      if (password.length < 12) throw new Error("The new terminal password must have at least 12 characters.");
      const { error } = await admin.auth.admin.updateUserById(accountId, { password });
      if (error) throw error;
      return respond({ ok: true });
    }

    if (action === "update") {
      if (terminal) throw new Error("Production computer configuration is protected. Use the terminal password reset action to change its sign-in password.");
      if (!email || !email.includes("@")) throw new Error("A valid email is required.");
      if (password && password.length < 12) throw new Error("Replacement passwords must have at least 12 characters.");
      const changes: Record<string, string> = { email };
      if (password) changes.password = password;
      const { error } = await admin.auth.admin.updateUserById(accountId, changes);
      if (error) throw error;
      await assertLinkableStaff(admin, staffId, accountId);
      await setStaffLink(admin, accountId, staffId);
      await setAccountRoles(admin, accountId, selectedRoles, accountType, displayName);
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
