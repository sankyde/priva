// Minimal PostgREST RPC client for service_role-only SQL functions.
import { b64encode, HttpError } from "./util.ts";

function serviceKey(): string {
  const keys = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (keys) {
    try {
      const k = JSON.parse(keys)["default"];
      if (typeof k === "string" && k.length > 0) return k;
    } catch { /* fall through to legacy key */ }
  }
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!legacy) throw new HttpError(500, "config");
  return legacy;
}

export async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const key = serviceKey();
  const headers: Record<string, string> = { "Content-Type": "application/json", apikey: key };
  // New sb_secret_ keys must not be sent as a Bearer token; legacy JWT keys must.
  if (!key.startsWith("sb_")) headers["Authorization"] = `Bearer ${key}`;
  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers,
    body: JSON.stringify(args),
  });
  if (!res.ok) {
    await res.body?.cancel();
    throw new HttpError(500, "db");
  }
  return (await res.json()) as T;
}

export async function config<T>(key: string, fallback: T): Promise<T> {
  const v = await rpc<T | null>("svc_get_config", { p_key: key });
  return v ?? fallback;
}

/** A secret that must already exist (a signing key the operator switched to): never created here. */
export async function existingSecret(name: string): Promise<string> {
  const existing = await rpc<string | null>("svc_get_secret", { p_name: name });
  if (!existing) throw new HttpError(500, "key_missing");
  return existing;
}

/** Returns the stored secret, creating it from `make()` exactly once (race-safe). */
export async function secret(name: string, make: () => Promise<Uint8Array>): Promise<string> {
  const existing = await rpc<string | null>("svc_get_secret", { p_name: name });
  if (existing) return existing;
  const candidate = b64encode(await make());
  return await rpc<string>("svc_get_or_create_secret", { p_name: name, p_candidate: candidate });
}
