// Priva public key bundle (v2): must match Priva/Core/Crypto/Identity.swift byte for byte.
//
//   "PRVB" | ver=2 | ucommit(32) | ed25519(32) | mldsa65(1952) | xwing(1216) | mlkem1024(1568) | day(u32 BE)
//   ── signed prefix ends ──
//   | sig_ed25519(64) | sig_mldsa65(3309)
//
// `ucommit` is the device-computed scrypt commitment to the username: the server never sees names.
// Signature message = "PRIVA-BUNDLE-v2\0" ‖ signed prefix. Both signatures must verify.
import { ml_dsa65 } from "npm:@noble/post-quantum@0.7.1/ml-dsa.js";
import { bs, concat, hex, HttpError, utf8 } from "./util.ts";

export const ED_PK = 32, MLDSA_PK = 1952, XWING_PK = 1216, MLKEM_PK = 1568;
export const ED_SIG = 64, MLDSA_SIG = 3309, HYBRID_SIG = ED_SIG + MLDSA_SIG;

export const BUNDLE_SIZE = 4 + 1 + 32 + 32 + 1952 + 1216 + 1568 + 4 + 64 + 3309;

export interface Bundle {
  ucommit: string;
  ed25519: Uint8Array;
  mldsa65: Uint8Array;
  xwing: Uint8Array;
  mlkem1024: Uint8Array;
  day: number;
  signed: Uint8Array;
  signature: Uint8Array;
}

const bad = () => new HttpError(400, "bad_bundle");

export function parseBundle(b: Uint8Array): Bundle {
  if (b.length !== BUNDLE_SIZE || b[0] !== 0x50 || b[1] !== 0x52 || b[2] !== 0x56 || b[3] !== 0x42 || b[4] !== 2) throw bad();
  let o = 5;
  const take = (n: number) => { const s = b.subarray(o, o + n); o += n; return s; };
  const ucommit = hex(take(32));
  const ed25519 = take(ED_PK), mldsa65 = take(MLDSA_PK), xwing = take(XWING_PK), mlkem1024 = take(MLKEM_PK);
  const dayBytes = take(4);
  const day = new DataView(dayBytes.buffer, dayBytes.byteOffset, 4).getUint32(0);
  const signed = b.subarray(0, o);
  const signature = take(HYBRID_SIG);
  return { ucommit, ed25519, mldsa65, xwing, mlkem1024, day, signed, signature };
}

/** AND-composed hybrid signature: Ed25519 ‖ ML-DSA-65, both over the same message. */
export async function verifyHybrid(
  edPk: Uint8Array, mldsaPk: Uint8Array, message: Uint8Array, sig: Uint8Array,
): Promise<boolean> {
  if (sig.length !== HYBRID_SIG) return false;
  let edOk = false;
  try {
    const key = await crypto.subtle.importKey("raw", bs(edPk), { name: "Ed25519" }, false, ["verify"]);
    edOk = await crypto.subtle.verify({ name: "Ed25519" }, key, bs(sig.subarray(0, ED_SIG)), bs(message));
  } catch {
    edOk = false;
  }
  let pqOk = false;
  try {
    pqOk = ml_dsa65.verify(sig.subarray(ED_SIG), message, mldsaPk);
  } catch {
    pqOk = false;
  }
  return edOk && pqOk;
}

export async function verifyBundle(b: Bundle): Promise<boolean> {
  const msg = concat(utf8("PRIVA-BUNDLE-v2\0"), b.signed);
  return await verifyHybrid(b.ed25519, b.mldsa65, msg, b.signature);
}
