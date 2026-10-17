// register: claims a (device-generated, random) username with an unblinded registration token.
//
// POST { ucommit, bundle, token, token_sig, revoke_hash } → { ok: true }
//
// The server receives only the username's commitment, never the username itself.
// Checks: token signature (RSA-PSS/SHA-384 under the blind key), token unspent, bundle
// well-formed, bound to `ucommit`, and self-signed with BOTH Ed25519 and ML-DSA-65.
// Spending the token and inserting the directory row happen in one SQL transaction.
import { verifyToken } from "../_shared/blind.ts";
import { parseBundle, verifyBundle } from "../_shared/bundle.ts";
import { rpc } from "../_shared/db.ts";
import {
  b64decode, b64encode, commitment, handler, hex, HttpError, json, readJson, sha256, str, timingSafeEqual, utf8,
} from "../_shared/util.ts";

const TOKEN_PREFIX = utf8("PRIVA-TOKEN-v1");
const TOKEN_LEN = TOKEN_PREFIX.length + 32;

Deno.serve(handler(async (req) => {
  if (req.method !== "POST") throw new HttpError(405, "method");
  const body = await readJson(req);

  const ucommit = commitment(body.ucommit);
  const bundleBytes = b64decode(str(body.bundle, "bad_bundle", 24_000));
  const token = b64decode(str(body.token, "bad_token", 128));
  const tokenSig = b64decode(str(body.token_sig, "bad_token", 1024));
  // SHA-256 of the device's revocation secret: lets that device remove this username after a reinstall.
  const revokeHash = commitment(body.revoke_hash);

  if (token.length !== TOKEN_LEN || !timingSafeEqual(token.subarray(0, TOKEN_PREFIX.length), TOKEN_PREFIX)) {
    throw new HttpError(400, "bad_token");
  }
  if (!(await verifyToken(token, tokenSig))) throw new HttpError(403, "bad_token");

  const bundle = parseBundle(bundleBytes);
  if (bundle.ucommit !== ucommit) throw new HttpError(400, "bad_bundle");
  if (!(await verifyBundle(bundle))) throw new HttpError(400, "bad_bundle_signature");

  const result = await rpc<string>("svc_register", {
    p_commit: ucommit,
    p_bundle_b64: b64encode(bundleBytes),
    p_token_sha256: hex(await sha256(token)),
    p_revoke_hash: revokeHash,
  });
  switch (result) {
    case "ok": return json(200, { ok: true });
    case "taken": throw new HttpError(409, "username_taken");
    case "token_spent": throw new HttpError(409, "token_spent");
    default: throw new HttpError(500, "internal");
  }
}));
