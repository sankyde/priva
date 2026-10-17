// RFC 9474 RSABSSA-SHA384-PSS-Deterministic, server side.
// The private operation uses CRT with base blinding + exponent blinding (timing side
// channels) and verifies its own output before returning it (fault attacks).
//
// Two independent keys: registration tokens ("blind_sk_v1", 4096-bit) and relay passes ("relay_sk_v1",
// 2048-bit: many are signed at once, and a pass is only good for one day).
import { b64decode, b64encode, bs, hex, HttpError, sha256 } from "./util.ts";
import { config, existingSecret, secret } from "./db.ts";

function toBig(u: Uint8Array): bigint {
  if (u.length === 0) return 0n;
  return BigInt("0x" + hex(u));
}

function toBytes(x: bigint, len: number): Uint8Array {
  const h = x.toString(16).padStart(len * 2, "0");
  if (h.length > len * 2) throw new HttpError(500, "encode");
  const out = new Uint8Array(len);
  for (let i = 0; i < len; i++) out[i] = parseInt(h.substr(i * 2, 2), 16);
  return out;
}

function b64uToBig(s: string): bigint {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  return toBig(b64decode(s));
}

function modpow(base: bigint, exp: bigint, m: bigint): bigint {
  let r = 1n;
  let b = base % m;
  let e = exp;
  while (e > 0n) {
    if (e & 1n) r = (r * b) % m;
    b = (b * b) % m;
    e >>= 1n;
  }
  return r;
}

function modinv(a: bigint, m: bigint): bigint {
  let [oldR, r] = [((a % m) + m) % m, m];
  let [oldS, s] = [1n, 0n];
  while (r !== 0n) {
    const q = oldR / r;
    [oldR, r] = [r, oldR - q * r];
    [oldS, s] = [s, oldS - q * s];
  }
  if (oldR !== 1n) throw new HttpError(500, "inverse");
  return ((oldS % m) + m) % m;
}

function randomBig(bytes: number): bigint {
  return toBig(crypto.getRandomValues(new Uint8Array(bytes)));
}

interface KeyMaterial {
  n: bigint; e: bigint; p: bigint; q: bigint; dp: bigint; dq: bigint; qi: bigint;
  spki: Uint8Array; verifyKey: CryptoKey; keyId: string; bytes: number;
}

/** A blind-signing key kept in `priva.server_secrets` under `name`, created on first use. */
export class BlindSigner {
  private cached: Promise<KeyMaterial> | null = null;
  /// `name`: the first key, made on first use. `activeConfig`: the app_config entry naming the key in use, so the
  /// operator can switch to the standby (generated offline, its id already pinned in the app: scripts/standby_keys.sh)
  /// without an app update. A switched-to key must already be in server_secrets: it's never made up on the spot.
  constructor(private readonly name: string, private readonly bits: number, private readonly activeConfig: string) {}

  private keys(): Promise<KeyMaterial> {
    if (!this.cached) this.cached = this.load().catch((e) => { this.cached = null; throw e; });
    return this.cached;
  }

  private async load(): Promise<KeyMaterial> {
    const bits = this.bits;
    const active = await config<string>(this.activeConfig, this.name);
    if (active !== this.name) return this.material(await existingSecret(active));
    const pkcs8b64 = await secret(this.name, async () => {
      const kp = await crypto.subtle.generateKey(
        { name: "RSA-PSS", modulusLength: bits, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-384" },
        true,
        ["sign", "verify"],
      ) as CryptoKeyPair;
      return new Uint8Array(await crypto.subtle.exportKey("pkcs8", kp.privateKey));
    });
    return this.material(pkcs8b64);
  }

  private async material(pkcs8b64: string): Promise<KeyMaterial> {
    const bits = this.bits;
    const priv = await crypto.subtle.importKey(
      "pkcs8", bs(b64decode(pkcs8b64)), { name: "RSA-PSS", hash: "SHA-384" }, true, ["sign"],
    );
    const jwk = await crypto.subtle.exportKey("jwk", priv);
    const pubJwk = { kty: "RSA", n: jwk.n, e: jwk.e, alg: "PS384", ext: true };
    const verifyKey = await crypto.subtle.importKey("jwk", pubJwk, { name: "RSA-PSS", hash: "SHA-384" }, true, ["verify"]);
    const spki = new Uint8Array(await crypto.subtle.exportKey("spki", verifyKey));
    return {
      n: b64uToBig(jwk.n!), e: b64uToBig(jwk.e!), p: b64uToBig(jwk.p!), q: b64uToBig(jwk.q!),
      dp: b64uToBig(jwk.dp!), dq: b64uToBig(jwk.dq!), qi: b64uToBig(jwk.qi!),
      spki, verifyKey, keyId: hex(await sha256(spki)), bytes: bits / 8,
    };
  }

  async publicKeyInfo(): Promise<{ public_key: string; key_id: string; bits: number }> {
    const k = await this.keys();
    return { public_key: b64encode(k.spki), key_id: k.keyId, bits: this.bits };
  }

  /** The checks blindSign makes on its input, without signing: run before a request is counted against a purchase,
   *  so a malformed request never uses up a username or a month's passes. */
  async check(blinded: Uint8Array): Promise<void> {
    const k = await this.keys();
    if (blinded.length !== k.bytes) throw new HttpError(400, "bad_blinded");
    const m = toBig(blinded);
    if (m <= 1n || m >= k.n) throw new HttpError(400, "bad_blinded");
  }

  /** RFC 9474 §4.3 BlindSign. */
  async blindSign(blinded: Uint8Array): Promise<Uint8Array> {
    const k = await this.keys();
    if (blinded.length !== k.bytes) throw new HttpError(400, "bad_blinded");
    const m = toBig(blinded);
    if (m <= 1n || m >= k.n) throw new HttpError(400, "bad_blinded");

    // Base blinding: operate on m·rᵉ so operand values are independent of the input.
    const r = (randomBig(k.bytes + 16) % (k.n - 2n)) + 2n;
    const mb = (m * modpow(r, k.e, k.n)) % k.n;
    // Exponent blinding: d_p + t·(p−1) gives an equivalent exponent with random bits.
    const dp = k.dp + randomBig(8) * (k.p - 1n);
    const dq = k.dq + randomBig(8) * (k.q - 1n);
    const m1 = modpow(mb % k.p, dp, k.p);
    const m2 = modpow(mb % k.q, dq, k.q);
    const h = (k.qi * (((m1 - m2) % k.p) + k.p)) % k.p;
    const sb = (m2 + h * k.q) % k.n;
    const s = (sb * modinv(r, k.n)) % k.n;

    if (modpow(s, k.e, k.n) !== m) throw new HttpError(500, "sign_check");
    return toBytes(s, k.bytes);
  }

  /** Standard RSASSA-PSS (SHA-384, 48-byte salt) verification of a finalized signature. */
  async verify(token: Uint8Array, sig: Uint8Array): Promise<boolean> {
    const k = await this.keys();
    if (sig.length !== k.bytes) return false;
    return await crypto.subtle.verify({ name: "RSA-PSS", saltLength: 48 }, k.verifyKey, bs(sig), bs(token));
  }
}

export const registrationSigner = new BlindSigner("blind_sk_v1", 4096, "token_key_name");
export const relayPassSigner = new BlindSigner("relay_sk_v1", 2048, "pass_key_name");

// Registration tokens (issue-token / register).
export const publicKeyInfo = () => registrationSigner.publicKeyInfo();
export const blindSign = (blinded: Uint8Array) => registrationSigner.blindSign(blinded);
export const checkBlinded = (blinded: Uint8Array) => registrationSigner.check(blinded);
export const verifyToken = (token: Uint8Array, sig: Uint8Array) => registrationSigner.verify(token, sig);
