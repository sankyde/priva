// Priva rendezvous: see wrangler.jsonc.
//
//   GET  /connect?topic=<t>   WebSocket: receive every signal sent to <t> as a binary frame
//                             [event length (1)] [event (utf-8)] [payload]. Send "ping" to keep it alive
//                             (answered with "pong" without waking anything).
//                             Headers: Authorization: Pass <base64>   X-Priva-Listen: <key>.<ts>.<sig>
//   POST /send                {"messages":[{"topic","event","d": base64}]} → 202; delivered to whoever is
//                             listening right now, otherwise dropped (signals are retried by the sender).
//                             Header: Authorization: Pass <base64>
//   POST /turn                → {"iceServers":[{urls,username,credential}],"ttl"} | 204 when no TURN key is set.
//                             Short-lived Cloudflare TURN credentials for phones behind strict NATs.
//                             Header: Authorization: Pass <base64>
//
// Who may use it: only someone holding a relay pass for today, blind-signed by Priva's server after an App Store
// purchase check, so a pass proves "a Priva buyer" without saying which one.
// Who may listen: a topic belongs to the first key that listens on it (Ed25519, derived on the owner's iPhone from
// a secret only the owner has, different for every topic). Nobody else can listen, even knowing the topic.
// Topics are opaque: derived on the phones from secrets the relay never sees.
import { DurableObject } from "cloudflare:workers";

interface RateLimit { limit(options: { key: string }): Promise<{ success: boolean }> }

export interface Env {
  TOPIC: DurableObjectNamespace<Topic>;
  /** The relay-pass public key, base64 SPKI (secret `RELAY_PASS_SPKI`, set by scripts/setup_cloudflare.sh). */
  RELAY_PASS_SPKI?: string;
  SEND_LIMIT?: RateLimit;
  CONNECT_LIMIT?: RateLimit;
  PASS_LIMIT?: RateLimit;
  TURN_LIMIT?: RateLimit;
  /** Cloudflare Realtime TURN key (secrets: `wrangler secret put CF_TURN_KEY_ID` / `CF_TURN_KEY_API_TOKEN`). */
  CF_TURN_KEY_ID?: string;
  CF_TURN_KEY_API_TOKEN?: string;
}

const TOPIC_RE = /^[a-z]{1,8}-[a-z0-9]{8,64}$/;
const MAX_MESSAGES = 64;               // per batch (a presence note goes to ≤ 60 friends)
const MAX_PAYLOAD = 96 * 1024;         // decoded bytes; sealed signals are padded to ≤ 64 KiB
const MAX_BODY = 2 * 1024 * 1024;
const MAX_LISTENERS = 16;              // per topic (one owner, a few reconnecting sockets)
const LISTEN_SKEW_S = 300;
const TURN_TTL_S = 3600;               // a leaked credential relays for an hour at most

const PASS_PREFIX = new TextEncoder().encode("PRIVA-PASS-v1");
const PASS_TOKEN = PASS_PREFIX.length + 4 + 32;    // prefix ‖ day (u32 BE, days since 1970 UTC) ‖ random
const PASS_SIG = 256;                              // RSA-2048, RSASSA-PSS SHA-384 (RFC 9474 blind signature)

function decode(b64: string): Uint8Array | null {
  try {
    const bin = atob(b64.replace(/-/g, "+").replace(/_/g, "/"));
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

function equal(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}

async function hexDigest(data: Uint8Array): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", data));
  return Array.from(h.subarray(0, 16), (b) => b.toString(16).padStart(2, "0")).join("");
}

// The active relay-pass key and, after a comma, the standby (kept offline until a switch): passes signed by either are
// good, so the issuer can change keys without phones or the relay being updated first.
let passKeys: Promise<CryptoKey[]> | null = null;

/** The pass in `Authorization: Pass …` if it is genuine and for today (±1 day for clocks and time zones). */
async function validPass(request: Request, env: Env): Promise<Uint8Array | null> {
  const auth = request.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Pass ")) return null;
  const raw = decode(auth.slice(5).trim());
  if (!raw || raw.length !== PASS_TOKEN + PASS_SIG) return null;
  const token = raw.subarray(0, PASS_TOKEN), sig = raw.subarray(PASS_TOKEN);
  if (!equal(token.subarray(0, PASS_PREFIX.length), PASS_PREFIX)) return null;
  const day = new DataView(token.buffer, token.byteOffset + PASS_PREFIX.length, 4).getUint32(0);
  const today = Math.floor(Date.now() / 86_400_000);
  if (Math.abs(day - today) > 1) return null;
  if (!env.RELAY_PASS_SPKI) return null;          // not configured (scripts/setup_cloudflare.sh): admit nobody
  passKeys ??= Promise.all(env.RELAY_PASS_SPKI.split(",").map((s) => s.trim()).filter((s) => s.length > 0)
    .map((s) => crypto.subtle.importKey("spki", decode(s)!, { name: "RSA-PSS", hash: "SHA-384" }, false, ["verify"])));
  for (const key of await passKeys) {
    if (await crypto.subtle.verify({ name: "RSA-PSS", saltLength: 48 }, key, sig, token)) return token;
  }
  return null;
}

async function allowed(limiter: RateLimit | undefined, key: string): Promise<boolean> {
  return limiter ? (await limiter.limit({ key })).success : true;
}

function text(status: number, body: string): Response {
  return new Response(body, { status, headers: { "Cache-Control": "no-store" } });
}

/** Expiring TURN credentials from the Cloudflare Realtime key; only `turn:`/`turns:` entries with credentials. */
async function turnCredentials(env: Env): Promise<Response> {
  if (!env.CF_TURN_KEY_ID || !env.CF_TURN_KEY_API_TOKEN) return new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });
  const r = await fetch(`https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(env.CF_TURN_KEY_ID)}/credentials/generate-ice-servers`, {
    method: "POST",
    headers: { "Authorization": `Bearer ${env.CF_TURN_KEY_API_TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify({ ttl: TURN_TTL_S }),
  });
  if (!r.ok) return text(502, "relay unavailable");
  const body = await r.json() as { iceServers?: { urls?: string[] | string; username?: string; credential?: string }[] };
  const servers = (body.iceServers ?? [])
    .map((s) => ({ urls: (Array.isArray(s.urls) ? s.urls : [s.urls ?? ""]).filter((u) => /^turns?:/.test(u)),
                   username: s.username, credential: s.credential }))
    .filter((s) => s.urls.length > 0 && s.username && s.credential);
  if (servers.length === 0) return text(502, "relay unavailable");
  return new Response(JSON.stringify({ iceServers: servers, ttl: TURN_TTL_S }),
                      { status: 200, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
}

/** One per topic: holds the sockets listening on it and the key that owns it. Never stores a message. */
export class Topic extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
    // No storage here: a send to a made-up topic must not leave anything behind (audit SEC-06). The owner table is
    // made when someone proves they may listen.
  }

  /** WebSocket upgrade, already pass-checked by the Worker. Proves the listener owns the topic. */
  async fetch(request: Request): Promise<Response> {
    const topic = new URL(request.url).searchParams.get("topic") ?? "";
    const [k, ts, s] = (request.headers.get("X-Priva-Listen") ?? "").split(".");
    const key = decode(k ?? ""), sig = decode(s ?? ""), time = Number(ts);
    if (!key || key.length !== 32 || !sig || sig.length !== 64 || !Number.isInteger(time)) return text(401, "listen proof");
    if (Math.abs(Date.now() / 1000 - time) > LISTEN_SKEW_S) return text(401, "listen proof expired");
    const verifyKey = await crypto.subtle.importKey("raw", key, { name: "Ed25519" }, false, ["verify"]);
    const signed = new TextEncoder().encode(`priva-listen-v1|${topic}|${time}`);
    if (!(await crypto.subtle.verify({ name: "Ed25519" }, verifyKey, sig, signed))) return text(401, "listen proof");

    this.ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS owner (k BLOB NOT NULL)");
    const owner = this.ctx.storage.sql.exec<{ k: ArrayBuffer }>("SELECT k FROM owner LIMIT 1").toArray()[0];
    if (!owner) {
      this.ctx.storage.sql.exec("INSERT INTO owner (k) VALUES (?)", key);      // first listener owns it
    } else if (!equal(new Uint8Array(owner.k), key)) {
      return text(403, "not your topic");
    }

    const listening = this.ctx.getWebSockets();
    if (listening.length >= MAX_LISTENERS) listening[0].close(1013, "replaced");
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server);
    return new Response(null, { status: 101, webSocket: client });
  }

  /** Hands one signal to everyone listening; returns how many sockets got it. */
  deliver(event: string, data: Uint8Array): number {
    const name = new TextEncoder().encode(event);
    const frame = new Uint8Array(1 + name.length + data.length);
    frame[0] = name.length;
    frame.set(name, 1);
    frame.set(data, 1 + name.length);
    let delivered = 0;
    for (const ws of this.ctx.getWebSockets()) {
      try { ws.send(frame); delivered++; } catch { /* closing */ }
    }
    return delivered;
  }

  // Listeners only ever send "ping", which the auto-response answers.
  webSocketMessage(): void {}
  webSocketClose(ws: WebSocket, code: number, reason: string): void {
    try { ws.close(code, reason); } catch { /* already closed */ }
  }
  webSocketError(): void {}
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";

    if (url.pathname === "/connect") {
      if (request.headers.get("Upgrade") !== "websocket") return text(426, "expected websocket");
      const topic = url.searchParams.get("topic") ?? "";
      if (!TOPIC_RE.test(topic)) return text(400, "bad topic");
      if (!(await allowed(env.CONNECT_LIMIT, ip))) return text(429, "slow down");
      const pass = await validPass(request, env);
      if (!pass) return text(401, "pass required");
      if (!(await allowed(env.PASS_LIMIT, await hexDigest(pass)))) return text(429, "slow down");
      return env.TOPIC.getByName(topic).fetch(request);
    }

    if (url.pathname === "/send" && request.method === "POST") {
      if (!(await allowed(env.SEND_LIMIT, ip))) return text(429, "slow down");
      const pass = await validPass(request, env);
      if (!pass) return text(401, "pass required");
      if (!(await allowed(env.PASS_LIMIT, await hexDigest(pass)))) return text(429, "slow down");
      const declared = request.headers.get("content-length");
      if (declared === null) return text(411, "length required");        // no chunked bodies (audit SEC-24)
      if (Number(declared) > MAX_BODY) return text(413, "too large");
      let body: { messages?: unknown };
      try { body = await request.json(); } catch { return text(400, "bad json"); }
      const messages = body?.messages;
      if (!Array.isArray(messages) || messages.length === 0 || messages.length > MAX_MESSAGES) return text(400, "bad batch");
      const batch: { topic: string; event: string; data: Uint8Array }[] = [];
      for (const m of messages as { topic?: unknown; event?: unknown; d?: unknown }[]) {
        if (typeof m?.topic !== "string" || !TOPIC_RE.test(m.topic)) return text(400, "bad topic");
        if (typeof m.event !== "string" || m.event.length < 1 || m.event.length > 16) return text(400, "bad event");
        const data = typeof m.d === "string" ? decode(m.d) : null;
        if (!data || data.length > MAX_PAYLOAD) return text(400, "bad payload");
        batch.push({ topic: m.topic, event: m.event, data });
      }
      // A batch costs one Durable Object call per message: big batches spend more of the pass's budget (one unit per
      // 16 messages; the first was taken above), so one pass can't fan out 64 calls per request (audit SEC-06).
      const id = await hexDigest(pass);
      for (let unit = 1; unit < Math.ceil(batch.length / 16); unit++) {
        if (!(await allowed(env.PASS_LIMIT, id))) return text(429, "slow down");
      }
      await Promise.all(batch.map((s) => env.TOPIC.getByName(s.topic).deliver(s.event, s.data).catch(() => 0)));
      return new Response(null, { status: 202, headers: { "Cache-Control": "no-store" } });
    }

    if (url.pathname === "/turn" && request.method === "POST") {
      // Behind a pass, like everything else here: TURN relays any traffic and is metered to the owner past the
      // free 1,000 GB, so it must not be open to anyone holding the app's public keys (audit SEC-05).
      const pass = await validPass(request, env);
      if (!pass) return text(401, "pass required");
      const id = await hexDigest(pass);
      if (!(await allowed(env.PASS_LIMIT, id)) || !(await allowed(env.TURN_LIMIT, id))) return text(429, "slow down");
      return turnCredentials(env);
    }

    return text(404, "not found");
  },
} satisfies ExportedHandler<Env>;
