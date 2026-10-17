// directory: owner-authenticated lease renewal, retirement ("uninstalled"), key rotation and removal.
//
// POST { op: "renew" | "retire" | "update", ucommit, ts, bundle?, sig } → { ok: true }
// POST { op: "revoke", ucommit, secret }  → deletes the username (reinstall / sign back in)
//
// sig = Ed25519 ‖ ML-DSA-65 by the CURRENT directory keys over
//   "PRIVA-DIR-OP-v2\0" ‖ op(1) ‖ ucommit(32) ‖ ts(u64 BE, ms) ‖ SHA-512(new bundle | empty)
// The device decides when to renew or retire; the server only checks the signature and stores.
import { parseBundle, verifyBundle, verifyHybrid } from "../_shared/bundle.ts";
import { rpc } from "../_shared/db.ts";
import {
  b64decode, b64encode, commitment, concat, handler, hex, HttpError, json, readJson, sha256, sha512, str, utf8,
} from "../_shared/util.ts";

const MAX_SKEW_MS = 5 * 60 * 1000;
const OPS: Record<string, number> = { renew: 1, retire: 2, update: 3 };

function unhex(h: string): Uint8Array {
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.substr(i * 2, 2), 16);
  return out;
}

Deno.serve(handler(async (req) => {
  if (req.method !== "POST") throw new HttpError(405, "method");
  const body = await readJson(req);

  if (body.op === "revoke") {
    // Possession of the revocation secret (kept in the owner's Keychain) removes the username.
    const ucommit = commitment(body.ucommit);
    const secret = b64decode(str(body.secret, "bad_secret", 128));
    if (secret.length !== 32) throw new HttpError(400, "bad_secret");
    const ok = await rpc<boolean>("svc_revoke", { p_commit: ucommit, p_secret_sha256: hex(await sha256(secret)) });
    if (!ok) throw new HttpError(404, "not_found");
    return json(200, { ok: true });
  }

  const op = OPS[String(body.op)] ?? 0;
  if (op === 0) throw new HttpError(400, "bad_op");
  const ucommit = commitment(body.ucommit);
  const ts = body.ts;
  if (typeof ts !== "number" || !Number.isSafeInteger(ts) || Math.abs(Date.now() - ts) > MAX_SKEW_MS) {
    throw new HttpError(400, "bad_ts");
  }
  const sig = b64decode(str(body.sig, "bad_sig", 8192));

  const currentB64 = await rpc<string | null>("svc_get_bundle", { p_commit: ucommit });
  if (!currentB64) throw new HttpError(404, "not_found");
  const current = parseBundle(b64decode(currentB64));

  const newBundleBytes = op === 3 ? b64decode(str(body.bundle, "bad_bundle", 24_000)) : new Uint8Array();
  const tsBytes = new Uint8Array(8);
  new DataView(tsBytes.buffer).setBigUint64(0, BigInt(ts));
  const message = concat(utf8("PRIVA-DIR-OP-v2\0"), new Uint8Array([op]), unhex(ucommit), tsBytes, await sha512(newBundleBytes));
  if (!(await verifyHybrid(current.ed25519, current.mldsa65, message, sig))) throw new HttpError(403, "bad_sig");

  if (op === 1) {
    await rpc<boolean>("svc_renew", { p_commit: ucommit });
  } else if (op === 2) {
    await rpc<boolean>("svc_retire", { p_commit: ucommit });
  } else {
    const next = parseBundle(newBundleBytes);
    if (next.ucommit !== ucommit) throw new HttpError(400, "bad_bundle");
    if (!(await verifyBundle(next))) throw new HttpError(400, "bad_bundle_signature");
    await rpc<boolean>("svc_update_bundle", { p_commit: ucommit, p_bundle_b64: b64encode(newBundleBytes) });
  }
  return json(200, { ok: true });
}));
