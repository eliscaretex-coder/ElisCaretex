import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function escapeHtml(value: unknown) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function standardBase64FromUtf8(value: string) {
  const bytes = new TextEncoder().encode(value);
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

function base64UrlFromUtf8(value: string) {
  return standardBase64FromUtf8(value).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/g, "");
}

function encodedHeader(value: unknown) {
  return `=?UTF-8?B?${standardBase64FromUtf8(String(value ?? ""))}?=`;
}

function cleanHeaderValue(value: unknown) {
  return String(value ?? "").replace(/[\r\n]+/g, " ").trim();
}

function safeErrorMessage(error: unknown) {
  const message = error instanceof Error ? error.message : String(error ?? "Unknown error");
  return cleanHeaderValue(message).slice(0, 1200);
}

function logFailure(stage: string, message: unknown, extra: Record<string, unknown> = {}) {
  console.error(JSON.stringify({
    component: "production-roster-leave-email",
    stage,
    error: cleanHeaderValue(message).slice(0, 1200),
    ...extra,
  }));
}

async function getGmailAccessToken(clientId: string, clientSecret: string, refreshToken: string) {
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      refresh_token: refreshToken,
      grant_type: "refresh_token",
    }),
  });

  const payload = await response.json().catch(() => ({}));
  if (!response.ok || !payload?.access_token) {
    const providerMessage = cleanHeaderValue(payload?.error_description || payload?.error || `Google OAuth returned HTTP ${response.status}.`);
    throw new Error(`Gmail OAuth token refresh failed: ${providerMessage}`);
  }
  return String(payload.access_token);
}

function buildMimeMessage(args: {
  sender: string;
  recipient: string;
  subject: string;
  text: string;
  html: string;
}) {
  const boundary = `eliscaretex_${crypto.randomUUID().replaceAll("-", "")}`;
  const sender = cleanHeaderValue(args.sender);
  const recipient = cleanHeaderValue(args.recipient);
  const subject = encodedHeader(args.subject);

  return [
    `From: ElisCaretex Roster <${sender}>`,
    `To: ${recipient}`,
    `Subject: ${subject}`,
    "MIME-Version: 1.0",
    `Content-Type: multipart/alternative; boundary=\"${boundary}\"`,
    "",
    `--${boundary}`,
    "Content-Type: text/plain; charset=UTF-8",
    "Content-Transfer-Encoding: 8bit",
    "",
    args.text,
    "",
    `--${boundary}`,
    "Content-Type: text/html; charset=UTF-8",
    "Content-Transfer-Encoding: 8bit",
    "",
    args.html,
    "",
    `--${boundary}--`,
    "",
  ].join("\r\n");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") || "";
  const gmailClientId = Deno.env.get("GOOGLE_GMAIL_CLIENT_ID") || "";
  const gmailClientSecret = Deno.env.get("GOOGLE_GMAIL_CLIENT_SECRET") || "";
  const gmailRefreshToken = Deno.env.get("GOOGLE_GMAIL_REFRESH_TOKEN") || "";
  const gmailSender = cleanHeaderValue(Deno.env.get("GOOGLE_GMAIL_SENDER") || "");
  const authorization = req.headers.get("Authorization") || "";

  if (!supabaseUrl || !supabaseAnonKey) {
    const message = "Supabase function environment is incomplete.";
    logFailure("supabase_environment", message);
    return json({ ok: false, stage: "supabase_environment", error: message }, 500);
  }
  if (!authorization) return json({ ok: false, stage: "authentication", error: "Authentication is required." }, 401);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body." }, 400);
  }

  const leaveRequestId = String(body.leave_request_id || "").trim();
  const reviewBaseUrl = String(body.review_base_url || "").trim();
  if (!leaveRequestId) return json({ error: "leave_request_id is required." }, 400);

  let reviewUrl: URL;
  try {
    reviewUrl = new URL(reviewBaseUrl);
    if (!["https:", "http:"].includes(reviewUrl.protocol)) throw new Error("Invalid protocol");
  } catch {
    return json({ error: "A valid review_base_url is required." }, 400);
  }

  const client = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: prepared, error: prepareError } = await client.rpc("prepare_production_roster_gm_review", {
    p_leave_request_id: leaveRequestId,
  });
  if (prepareError) {
    logFailure("workflow_prepare", prepareError.message);
    return json({ ok: false, stage: "workflow_prepare", error: prepareError.message }, 400);
  }

  const recipient = cleanHeaderValue(prepared?.sent_to || "");
  const token = String(prepared?.review_token || "").trim();
  if (!recipient || !token) {
    const message = "General Manager review preparation returned incomplete data.";
    logFailure("workflow_prepare", message);
    return json({ ok: false, stage: "workflow_prepare", error: message }, 500);
  }

  reviewUrl.searchParams.set("t", token);
  const approveUrl = new URL(reviewUrl.toString()); approveUrl.searchParams.set("decision", "APPROVED");
  const rejectUrl = new URL(reviewUrl.toString()); rejectUrl.searchParams.set("decision", "REJECTED");
  const dateRange = prepared.start_date === prepared.end_date
    ? String(prepared.start_date || "")
    : `${prepared.start_date} to ${prepared.end_date}`;
  const subject = `Holiday request review - ${prepared.display_name || "Staff member"} - ${dateRange}`;
  const reason = String(prepared.reason || "—");
  const duration = Number(prepared.duration_days || 0);

  const html = `
    <div style="font-family:Arial,sans-serif;max-width:640px;color:#0f172a;line-height:1.45">
      <div style="border:1px solid #e2e8f0;border-radius:14px;padding:22px;background:#ffffff">
        <h2 style="margin:0 0 6px;font-size:22px">Holiday request review</h2>
        <p style="margin:0 0 18px;color:#64748b">A General Manager decision is required.</p>
        <table style="border-collapse:collapse;width:100%;margin-bottom:18px">
          <tr><td style="padding:7px 4px;color:#64748b;width:120px">Staff</td><td style="padding:7px 4px;font-weight:700">${escapeHtml(prepared.display_name)}</td></tr>
          <tr><td style="padding:7px 4px;color:#64748b">Dates</td><td style="padding:7px 4px">${escapeHtml(dateRange)}</td></tr>
          <tr><td style="padding:7px 4px;color:#64748b">Duration</td><td style="padding:7px 4px">${duration} calendar days</td></tr>
          <tr><td style="padding:7px 4px;color:#64748b">Reason</td><td style="padding:7px 4px">${escapeHtml(reason)}</td></tr>
        </table>
        <p style="margin:0 0 10px">
          <a href="${escapeHtml(approveUrl.toString())}" style="display:inline-block;background:#15803d;color:#fff;text-decoration:none;padding:12px 18px;border-radius:9px;font-weight:700;margin:0 9px 8px 0">Approve Holiday</a>
          <a href="${escapeHtml(rejectUrl.toString())}" style="display:inline-block;background:#b91c1c;color:#fff;text-decoration:none;padding:12px 18px;border-radius:9px;font-weight:700;margin:0 0 8px">Reject Holiday</a>
        </p>
        <a href="${escapeHtml(reviewUrl.toString())}" style="font-size:13px;color:#0f766e">Open full review page</a>
        <p style="font-size:12px;color:#94a3b8;margin:20px 0 0">The secure review link expires ${escapeHtml(prepared.expires_at || "")}. Email buttons open a confirmation page; GET requests never change the decision. The decision is recorded once and cannot modify an already published Roster directly.</p>
      </div>
    </div>`;

  const text = [
    "Holiday request review",
    "",
    `Staff: ${prepared.display_name || ""}`,
    `Dates: ${dateRange}`,
    `Duration: ${duration} calendar days`,
    `Reason: ${reason}`,
    "",
    `Approve: ${approveUrl.toString()}`,
    `Reject: ${rejectUrl.toString()}`,
    `Full review: ${reviewUrl.toString()}`,
    `Link expires: ${prepared.expires_at || ""}`,
  ].join("\n");

  if (!gmailClientId || !gmailClientSecret || !gmailRefreshToken || !gmailSender) {
    const missing = [
      !gmailClientId ? "GOOGLE_GMAIL_CLIENT_ID" : "",
      !gmailClientSecret ? "GOOGLE_GMAIL_CLIENT_SECRET" : "",
      !gmailRefreshToken ? "GOOGLE_GMAIL_REFRESH_TOKEN" : "",
      !gmailSender ? "GOOGLE_GMAIL_SENDER" : "",
    ].filter(Boolean);
    const message = `Gmail sender is not configured. Missing: ${missing.join(", ")}.`;
    logFailure("gmail_configuration", message, { missing });
    await client.rpc("mark_production_roster_gm_email_result", {
      p_leave_request_id: leaveRequestId,
      p_success: false,
      p_error_message: message,
    });
    return json({ ok: false, stage: "gmail_configuration", error: message, missing }, 503);
  }

  let accessToken = "";
  try {
    accessToken = await getGmailAccessToken(gmailClientId, gmailClientSecret, gmailRefreshToken);
  } catch (error) {
    const message = safeErrorMessage(error);
    logFailure("gmail_oauth_refresh", message);
    await client.rpc("mark_production_roster_gm_email_result", {
      p_leave_request_id: leaveRequestId,
      p_success: false,
      p_error_message: message,
    });
    return json({ ok: false, stage: "gmail_oauth_refresh", error: message }, 500);
  }

  const mime = buildMimeMessage({ sender: gmailSender, recipient, subject, text, html });

  let response: Response;
  try {
    response = await fetch("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ raw: base64UrlFromUtf8(mime) }),
    });
  } catch (error) {
    const message = safeErrorMessage(error);
    logFailure("gmail_network", message);
    await client.rpc("mark_production_roster_gm_email_result", {
      p_leave_request_id: leaveRequestId,
      p_success: false,
      p_error_message: message,
    });
    return json({ ok: false, stage: "gmail_network", error: message }, 502);
  }

  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = cleanHeaderValue(
      payload?.error?.message || payload?.error_description || payload?.error || `Gmail API returned HTTP ${response.status}.`,
    );
    logFailure("gmail_send", message, { google_http_status: response.status });
    await client.rpc("mark_production_roster_gm_email_result", {
      p_leave_request_id: leaveRequestId,
      p_success: false,
      p_error_message: message,
    });
    return json({ ok: false, stage: "gmail_send", error: message, google_http_status: response.status }, 502);
  }

  const { error: markError } = await client.rpc("mark_production_roster_gm_email_result", {
    p_leave_request_id: leaveRequestId,
    p_success: true,
    p_error_message: null,
  });
  if (markError) {
    const message = `Email sent but workflow state could not be finalized: ${markError.message}`;
    logFailure("workflow_finalize", message);
    return json({ ok: false, stage: "workflow_finalize", error: message }, 500);
  }

  return json({
    ok: true,
    leave_request_id: leaveRequestId,
    sent_to: recipient,
    provider: "gmail",
    provider_message_id: payload?.id || null,
    provider_thread_id: payload?.threadId || null,
    message: "Holiday request sent to the General Manager through Gmail.",
  });
});
