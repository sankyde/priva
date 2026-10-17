// Proof of purchase for every function that hands out anonymous credentials (registration tokens, relay passes):
// an App Store AppTransaction JWS, or, for development builds only while `allow_dev_purchases` is on, a random
// per-install nonce signed with the operator's development key (the function secret PRIVA_DEV_PURCHASE_KEY, kept in
// the operator's .env and Debug builds, never in the source): the published code alone can't mint purchases.
// Only a keyed hash of the purchase is ever kept, never the transaction id.
import { verifyAppTransaction } from "./apple.ts";
import { config, secret } from "./db.ts";
import { b64decode, bs, concat, hex, HttpError, str, timingSafeEqual, utf8 } from "./util.ts";

export interface Purchase {
  ref: string;
  environment: "Production" | "Sandbox" | "Dev";
}

export async function purchaseFrom(body: Record<string, unknown>): Promise<Purchase> {
  let environment: Purchase["environment"];
  let id: string;
  if (typeof body.jws === "string") {
    const tx = await verifyAppTransaction(body.jws, await config<string>("bundle_id", "com.sanketdesai.priva"));
    environment = tx.environment;
    id = tx.appTransactionId;
  } else if (typeof body.dev_nonce === "string") {
    // Development builds (simulator / Xcode installs have no App Store receipt). Off in production.
    if ((await config<boolean>("allow_dev_purchases", false)) !== true) throw new HttpError(403, "purchase_unverified");
    const nonce = b64decode(str(body.dev_nonce, "bad_nonce", 64));
    if (nonce.length !== 32) throw new HttpError(400, "bad_nonce");
    if (!(await devProofValid(nonce, body.dev_proof))) throw new HttpError(403, "purchase_unverified");
    environment = "Dev";
    id = hex(nonce);
  } else {
    throw new HttpError(400, "missing_proof");
  }
  const pepper = b64decode(await secret("purchase_pepper_v1", async () => crypto.getRandomValues(new Uint8Array(32))));
  const key = await crypto.subtle.importKey("raw", bs(pepper), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, utf8(`priva-purchase-v1|${environment}|${id}`));
  return { ref: hex(new Uint8Array(mac)), environment };
}

/** HMAC-SHA256(PRIVA_DEV_PURCHASE_KEY, "priva-dev-purchase-v1|" ‖ nonce): only the operator's builds can make it. */
export async function devProofValid(nonce: Uint8Array, proof: unknown, key = Deno.env.get("PRIVA_DEV_PURCHASE_KEY")): Promise<boolean> {
  if (!key || typeof proof !== "string" || proof.length > 64) return false;
  let given: Uint8Array;
  try { given = b64decode(proof); } catch { return false; }
  const k = await crypto.subtle.importKey("raw", bs(utf8(key)), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const want = new Uint8Array(await crypto.subtle.sign("HMAC", k, bs(concat(utf8("priva-dev-purchase-v1|"), nonce))));
  return given.length === want.length && timingSafeEqual(given, want);
}
