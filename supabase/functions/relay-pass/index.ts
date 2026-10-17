// relay-pass: daily passes for the rendezvous relay (Cloudflare), so only people who bought Priva can use it.
//
// GET  → { public_key, key_id, bits }                                  (the app pins key_id; so does the relay)
// POST { jws | dev_nonce, blinded: [b64, …] } → { blind_sigs: [b64, …], key_id }
//
// Each pass is "PRIVA-PASS-v1" ‖ day ‖ 32 random bytes, blind-signed: the server signs without seeing it, so a
// pass the relay later sees can't be linked to the purchase (or to the username). A purchase may take a limited
// number of passes a month; the count is kept per month only, and only for the current and previous month.
import { relayPassSigner } from "../_shared/blind.ts";
import { rpc } from "../_shared/db.ts";
import { purchaseFrom } from "../_shared/purchase.ts";
import { b64decode, b64encode, handler, HttpError, json, readJson } from "../_shared/util.ts";

const MAX_BATCH = 40;

Deno.serve(handler(async (req) => {
  if (req.method === "GET") return json(200, await relayPassSigner.publicKeyInfo());
  if (req.method !== "POST") throw new HttpError(405, "method");

  const body = await readJson(req);
  if (!Array.isArray(body.blinded) || body.blinded.length < 1 || body.blinded.length > MAX_BATCH) {
    throw new HttpError(400, "bad_batch");
  }
  const blinded = body.blinded.map((b) => {
    if (typeof b !== "string" || b.length > 1024) throw new HttpError(400, "bad_blinded");
    return b64decode(b);
  });
  // Every value is checked before the purchase is charged for any of them.
  for (const b of blinded) await relayPassSigner.check(b);
  const purchase = await purchaseFrom(body);

  const status = await rpc<string>("svc_authorize_relay", {
    p_ref: purchase.ref,
    p_env: purchase.environment,
    p_count: blinded.length,
  });
  if (status === "limit") throw new HttpError(429, "pass_limit");
  if (status !== "ok") throw new HttpError(500, "internal");

  const sigs: string[] = [];
  for (const b of blinded) sigs.push(b64encode(await relayPassSigner.blindSign(b)));
  const { key_id } = await relayPassSigner.publicKeyInfo();
  return json(200, { blind_sigs: sigs, key_id });
}));
