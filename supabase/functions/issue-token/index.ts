// issue-token: verifies a purchase and blind-signs ONE registration token.
//
// GET  → { public_key, key_id, bits }                      (the app pins key_id)
// POST { jws | dev_nonce, blinded } → { blind_sig, key_id }
//
// The server never sees the token itself, only `blinded`, so the resulting
// username registration cannot be linked back to this purchase.
import { blindSign, checkBlinded, publicKeyInfo } from "../_shared/blind.ts";
import { rpc } from "../_shared/db.ts";
import { purchaseFrom } from "../_shared/purchase.ts";
import { b64decode, b64encode, handler, hex, HttpError, json, readJson, sha256, str } from "../_shared/util.ts";

Deno.serve(handler(async (req) => {
  if (req.method === "GET") return json(200, await publicKeyInfo());
  if (req.method !== "POST") throw new HttpError(405, "method");

  const body = await readJson(req);
  const blinded = b64decode(str(body.blinded, "bad_blinded", 1024));
  await checkBlinded(blinded);          // before the purchase is charged: a malformed request costs no username
  const purchase = await purchaseFrom(body);

  const status = await rpc<string>("svc_authorize_issue", {
    p_ref: purchase.ref,
    p_env: purchase.environment,
    p_blinded_sha256: hex(await sha256(blinded)),
  });
  if (status === "limit") throw new HttpError(409, "token_limit");
  if (status === "rate_limited") throw new HttpError(429, "rate_limited");
  if (status !== "new" && status !== "reissue") throw new HttpError(500, "internal");

  const sig = await blindSign(blinded);
  const { key_id } = await publicKeyInfo();
  return json(200, { blind_sig: b64encode(sig), key_id });
}));
