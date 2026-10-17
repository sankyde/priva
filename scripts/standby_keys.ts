// Makes the standby signing keys (docs/OPERATIONS.md § Switching signing keys), exactly as the server makes its own
// (supabase/functions/_shared/blind.ts): a registration-token key (RSA-PSS 4096) and a relay-pass key (RSA-PSS 2048).
// Their private halves go to stdout as JSON, for scripts/standby_keys.sh to encrypt; the public values the app and
// relay pin go to stderr. Run through scripts/standby_keys.sh, not directly.
import { b64encode, hex, sha256 } from "../supabase/functions/_shared/util.ts";

async function make(bits: number) {
  const kp = await crypto.subtle.generateKey(
    { name: "RSA-PSS", modulusLength: bits, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-384" },
    true,
    ["sign", "verify"],
  ) as CryptoKeyPair;
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", kp.privateKey));
  // The key id the server reports: the SPKI of the key rebuilt from its JWK, as BlindSigner does.
  const priv = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "RSA-PSS", hash: "SHA-384" }, true, ["sign"]);
  const jwk = await crypto.subtle.exportKey("jwk", priv);
  const pub = await crypto.subtle.importKey("jwk", { kty: "RSA", n: jwk.n, e: jwk.e, alg: "PS384", ext: true },
    { name: "RSA-PSS", hash: "SHA-384" }, true, ["verify"]);
  const spki = new Uint8Array(await crypto.subtle.exportKey("spki", pub));
  return { pkcs8: b64encode(pkcs8), spki: b64encode(spki), keyId: hex(await sha256(spki)) };
}

const token = await make(4096);
const pass = await make(2048);
console.error(`TOKEN_KEY_ID ${token.keyId}`);
console.error(`PASS_KEY_ID ${pass.keyId}`);
console.error(`PASS_SPKI ${pass.spki}`);
console.log(JSON.stringify({
  made: new Date().toISOString(),
  blind_sk_v2: token.pkcs8, blind_key_id: token.keyId,
  relay_sk_v2: pass.pkcs8, relay_key_id: pass.keyId, relay_spki: pass.spki,
}));
