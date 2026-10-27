import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.10";

// Legacy Sync: Finish Area sender endpoint for the Apps Script.
// Every request is signed with HMAC-SHA256 over "<timestamp>.<raw body>" using the
// LEGACY_SYNC_HMAC_SECRET secret. The function only calls the integration.legacy_sync_*
// functions; all mapping rules, switches and limits live in Postgres.
// Deploy with JWT verification OFF (the Apps Script has no Supabase session).

const MAX_BODY_BYTES = 512 * 1024;
const MAX_CLOCK_SKEW_SECONDS = 300;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const KIND = /^[a-z][a-z_]{0,39}$/;
// SQLSTATEs raised on purpose by the legacy sync functions: business answers, not server faults.
const EXPECTED_SQLSTATES = new Set(["22023", "23505", "23514", "40001", "42501", "55000", "P0002"]);

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { code?: string; message?: string } | null }>;

function send(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
}

function hex(bytes: ArrayBuffer) {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function sameText(a: string, b: string) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function sign(secret: string, timestamp: string, body: string) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${timestamp}.${body}`)));
}

function isObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function recordList(body: Record<string, unknown>, max: number) {
  const records = body.records;
  if (!Array.isArray(records) || records.length < 1 || records.length > max || !records.every(isObject)) return null;
  return records;
}

function oneRecord(body: Record<string, unknown>) {
  if (typeof body.runId !== "string" || !UUID.test(body.runId) || !isObject(body.record)) return null;
  return { p_sync_run_id: body.runId, p_record: body.record };
}

// Maps one operation to one database call. Returns null when the request is malformed.
export function plan(body: Record<string, unknown>): { fn: string; args: Record<string, unknown> } | null {
  switch (body.operation) {
    case "finish_dry_run": {
      const records = recordList(body, 60);
      return records && { fn: "legacy_sync_finish_dry_run", args: { p_records: records } };
    }
    case "rewash_dry_run": {
      const records = recordList(body, 40);
      return records && { fn: "legacy_sync_rewash_dry_run", args: { p_records: records } };
    }
    case "start_run": {
      const mode = String(body.mode || "").toUpperCase();
      const from = body.dateFrom ?? null, to = body.dateTo ?? null;
      const requestedBy = typeof body.requestedBy === "string" ? body.requestedBy.trim() : "";
      if (!["COMMIT", "DRY_RUN"].includes(mode)) return null;
      if ((from !== null && (typeof from !== "string" || !DAY.test(from))) || (to !== null && (typeof to !== "string" || !DAY.test(to)))) return null;
      if (!requestedBy || requestedBy.length > 200) return null;
      return { fn: "legacy_sync_start_run", args: { p_source_system: "FINISH_AREA", p_mode: mode, p_date_from: from, p_date_to: to, p_requested_by: requestedBy } };
    }
    case "import_finish": {
      const args = oneRecord(body);
      return args && { fn: "legacy_sync_import_finish_entry", args };
    }
    case "import_rewash": {
      const args = oneRecord(body);
      return args && { fn: "legacy_sync_import_rewash_cell", args };
    }
    case "dry_run": {
      // Generic parts of the sync (wash, and later ones): the database dispatcher picks the function.
      const records = recordList(body, 60);
      if (typeof body.kind !== "string" || !KIND.test(body.kind)) return null;
      return records && { fn: "legacy_sync_dispatch_dry_run", args: { p_kind: body.kind, p_records: records } };
    }
    case "import": {
      const args = oneRecord(body);
      if (typeof body.kind !== "string" || !KIND.test(body.kind)) return null;
      return args && { fn: "legacy_sync_dispatch_import", args: { p_kind: body.kind, ...args } };
    }
    case "poll":
      // Asks the schedule whether to run now (nightly or "Sync now"); claims at most one run.
      return { fn: "legacy_sync_claim_run", args: {} };
    case "control": {
      // Apps Script admin page: STATUS, or ON / OFF for the schedule and every import switch.
      const action = String(body.action || "").toUpperCase();
      const changedBy = typeof body.changedBy === "string" ? body.changedBy.trim() : "";
      if (!["STATUS", "ON", "OFF"].includes(action)) return null;
      if (action !== "STATUS" && (!changedBy || changedBy.length > 200)) return null;
      return { fn: "legacy_sync_control", args: { p_action: action, p_changed_by: changedBy || null } };
    }
    case "finish_run": {
      const status = String(body.status || "").toUpperCase();
      if (typeof body.runId !== "string" || !UUID.test(body.runId) || !["COMPLETED", "FAILED", "CANCELLED"].includes(status)) return null;
      return { fn: "legacy_sync_finish_run", args: { p_sync_run_id: body.runId, p_status: status, p_summary: isObject(body.summary) ? body.summary : {} } };
    }
    default:
      return null;
  }
}

export async function handle(request: Request, secret: string, rpc: Rpc, now = Date.now()) {
  if (request.method !== "POST") return send(405, { ok: false, error: "Method not allowed" });
  if (!secret || secret.length < 32) return send(500, { ok: false, error: "Signing secret is not configured" });

  const raw = await request.text();
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) return send(413, { ok: false, error: "Request too large" });

  const timestamp = request.headers.get("x-legacy-sync-timestamp") || "";
  const signature = (request.headers.get("x-legacy-sync-signature") || "").toLowerCase();
  if (!/^\d{10}$/.test(timestamp) || Math.abs(now / 1000 - Number(timestamp)) > MAX_CLOCK_SKEW_SECONDS) return send(401, { ok: false, error: "Unauthorized" });
  if (!/^[0-9a-f]{64}$/.test(signature) || !sameText(signature, await sign(secret, timestamp, raw))) return send(401, { ok: false, error: "Unauthorized" });

  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    return send(400, { ok: false, error: "Invalid JSON" });
  }
  const call = isObject(body) ? plan(body) : null;
  if (!call) return send(400, { ok: false, error: "Invalid request" });

  const { data, error } = await rpc(call.fn, call.args);
  if (error) {
    if (error.code && EXPECTED_SQLSTATES.has(error.code)) {
      return send(200, { ok: false, code: error.code, error: String(error.message || "").replace(/[\r\n]+/g, " ").slice(0, 300) });
    }
    console.error(`legacy-sync-finish ${call.fn} failed`, error.code, error.message);
    return send(500, { ok: false, error: "Database call failed" });
  }
  return send(200, { ok: true, operation: (body as Record<string, unknown>).operation, result: data ?? null });
}

if (import.meta.main) {
  const url = Deno.env.get("SUPABASE_URL") || "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const db = createClient(url, serviceKey, { db: { schema: "integration" }, auth: { persistSession: false, autoRefreshToken: false } });
  const rpc: Rpc = async (fn, args) => {
    const { data, error } = await db.rpc(fn, args);
    return { data, error };
  };
  Deno.serve((request) => handle(request, Deno.env.get("LEGACY_SYNC_HMAC_SECRET") || "", rpc));
}
