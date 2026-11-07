// Task 12 (folded into frontend-integration plan): proxy between the browser and api.cmd_* commands.
// Route: POST /functions/v1/api/<dotted.command> -> rpc cmd_<command with dots -> underscores>.
// Forwards the caller's own JWT (never the service role) so app.ctx()/RLS apply as the real user.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const MR_STATUS: Record<string, number> = {
  MR001: 409,
  MR002: 422,
  MR003: 403,
  MR004: 404,
  MR005: 400,
};

function cors(body: BodyInit | null, status: number, extraHeaders: Record<string, string> = {}) {
  return new Response(body, {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, content-type, idempotency-key",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      ...extraHeaders,
    },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return cors(null, 204);
  }
  if (req.method !== "POST") {
    return cors(JSON.stringify({ error: { code: "MR000", rule: "method_not_allowed", object: null, todo: "use POST" } }), 405);
  }

  const url = new URL(req.url);
  // Path is /functions/v1/api/<dotted.command>
  const parts = url.pathname.split("/").filter(Boolean);
  const idx = parts.indexOf("api");
  const dotted = idx >= 0 ? parts.slice(idx + 1).join("/") : "";
  if (!dotted) {
    return cors(JSON.stringify({ error: { code: "MR000", rule: "missing_command", object: null, todo: "POST /functions/v1/api/<command>" } }), 400);
  }
  const fnName = "cmd_" + dotted.replace(/\./g, "_");

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return cors(JSON.stringify({ error: { code: "MR003", rule: "missing_auth", object: null, todo: "sign in" } }), 401);
  }
  const idemKey = req.headers.get("Idempotency-Key");
  if (!idemKey) {
    return cors(JSON.stringify({ error: { code: "MR005", rule: "missing_idempotency_key", object: null, todo: "send Idempotency-Key header" } }), 400);
  }

  let args: unknown = {};
  try {
    const text = await req.text();
    args = text ? JSON.parse(text) : {};
  } catch {
    return cors(JSON.stringify({ error: { code: "MR005", rule: "invalid_json_body", object: null, todo: "send valid JSON" } }), 400);
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    db: { schema: "api" },
  });

  const { data, error } = await supabase.rpc(fnName, { p_idem: idemKey, p_args: args });

  if (error) {
    let parsed: { code?: string; rule?: string; object?: unknown; todo?: string } | null = null;
    try {
      parsed = JSON.parse(error.message);
    } catch {
      // not a structured refusal
    }
    const code = (error as { code?: string }).code;
    if (parsed && code && MR_STATUS[code]) {
      return cors(JSON.stringify({ error: { code, ...parsed } }), MR_STATUS[code]);
    }
    return cors(JSON.stringify({ error: { code: code ?? "MR999", rule: "unmapped_error", object: null, todo: error.message } }), 500);
  }

  return cors(JSON.stringify({ ok: true, ...(data as Record<string, unknown>) }), 200);
});
