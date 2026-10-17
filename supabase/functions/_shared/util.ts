// Shared helpers for Priva Edge Functions. No function in this project logs request data.

export const MAX_BODY_BYTES = 64 * 1024;

export class HttpError extends Error {
  constructor(public status: number, public code: string) {
    super(code);
  }
}

export function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

export async function readJson(req: Request): Promise<Record<string, unknown>> {
  // No length, no read: a chunked body would otherwise be read whole before its size is known (audit SEC-24).
  const declared = req.headers.get("content-length");
  if (declared === null) throw new HttpError(411, "length_required");
  const len = Number(declared);
  if (!Number.isFinite(len) || len > MAX_BODY_BYTES) throw new HttpError(413, "too_large");
  const buf = new Uint8Array(await req.arrayBuffer());
  if (buf.length > MAX_BODY_BYTES) throw new HttpError(413, "too_large");
  try {
    const v = JSON.parse(new TextDecoder().decode(buf));
    if (typeof v !== "object" || v === null || Array.isArray(v)) throw new Error();
    return v as Record<string, unknown>;
  } catch {
    throw new HttpError(400, "bad_json");
  }
}

export function handler(fn: (req: Request) => Promise<Response>) {
  return async (req: Request): Promise<Response> => {
    try {
      return await fn(req);
    } catch (e) {
      if (e instanceof HttpError) return json(e.status, { error: e.code });
      // Deliberately generic: never echo internals or inputs.
      return json(500, { error: "internal" });
    }
  };
}

export function str(v: unknown, code: string, max = 100_000): string {
  if (typeof v !== "string" || v.length === 0 || v.length > max) throw new HttpError(400, code);
  return v;
}

export function b64decode(s: string, code = "bad_base64"): Uint8Array {
  try {
    const bin = atob(s);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    throw new HttpError(400, code);
  }
}

export function b64encode(u: Uint8Array): string {
  let s = "";
  for (let i = 0; i < u.length; i += 0x8000) s += String.fromCharCode(...u.subarray(i, i + 0x8000));
  return btoa(s);
}

export function b64urlDecode(s: string): Uint8Array {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  return b64decode(s);
}

export function hex(u: Uint8Array): string {
  return Array.from(u, (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256(data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bs(data)));
}

export async function sha512(data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-512", bs(data)));
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

export const utf8 = (s: string) => new TextEncoder().encode(s);

export function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}

/** Username commitments are opaque 32-byte scrypt outputs computed on the device (hex). */
export function commitment(v: unknown): string {
  const c = str(v, "bad_commit", 64).toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(c)) throw new HttpError(400, "bad_commit");
  return c;
}

/** Copies into a plain ArrayBuffer-backed view, as WebCrypto's BufferSource requires. */
export const bs = (u: Uint8Array): Uint8Array<ArrayBuffer> => new Uint8Array(u);
