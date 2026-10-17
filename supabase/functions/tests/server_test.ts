// Offline tests for the pure crypto pieces of the Edge Functions.
// Run: deno test -A supabase/functions/tests/server_test.ts
import "npm:reflect-metadata@0.2.2";
import * as x509 from "npm:@peculiar/x509@2.1.0";
import { ml_dsa65 } from "npm:@noble/post-quantum@0.7.1/ml-dsa.js";
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { verifyAppTransaction } from "../_shared/apple.ts";
import { devProofValid } from "../_shared/purchase.ts";
import { parseBundle, verifyBundle, verifyHybrid } from "../_shared/bundle.ts";
import { b64encode, bs, concat, hex, sha256, utf8 } from "../_shared/util.ts";

x509.cryptoProvider.set(crypto);
const ec = { name: "ECDSA", namedCurve: "P-256", hash: "SHA-256" } as const;
const b64url = (u: Uint8Array) => b64encode(u).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function makeChain(opts: { leafOid?: boolean; interOid?: boolean } = {}) {
  const rootKeys = await crypto.subtle.generateKey(ec, true, ["sign", "verify"]) as CryptoKeyPair;
  const interKeys = await crypto.subtle.generateKey(ec, true, ["sign", "verify"]) as CryptoKeyPair;
  const leafKeys = await crypto.subtle.generateKey(ec, true, ["sign", "verify"]) as CryptoKeyPair;
  const nb = new Date(Date.now() - 86400_000), na = new Date(Date.now() + 86400_000 * 365);
  const root = await x509.X509CertificateGenerator.createSelfSigned({
    serialNumber: "01", name: "CN=Test Root", notBefore: nb, notAfter: na, keys: rootKeys, signingAlgorithm: ec,
    extensions: [new x509.BasicConstraintsExtension(true, undefined, true)],
  });
  const inter = await x509.X509CertificateGenerator.create({
    serialNumber: "02", subject: "CN=Test Intermediate", issuer: root.subject, notBefore: nb, notAfter: na,
    signingKey: rootKeys.privateKey, publicKey: interKeys.publicKey, signingAlgorithm: ec,
    extensions: [
      new x509.BasicConstraintsExtension(true, 0, true),
      ...(opts.interOid === false ? [] : [new x509.Extension("1.2.840.113635.100.6.2.1", false, new Uint8Array([5, 0]))]),
    ],
  });
  const leaf = await x509.X509CertificateGenerator.create({
    serialNumber: "03", subject: "CN=Test Leaf", issuer: inter.subject, notBefore: nb, notAfter: na,
    signingKey: interKeys.privateKey, publicKey: leafKeys.publicKey, signingAlgorithm: ec,
    extensions: opts.leafOid === false ? [] : [new x509.Extension("1.2.840.113635.100.6.11.1", false, new Uint8Array([5, 0]))],
  });
  const ders = [leaf, inter, root].map((c) => new Uint8Array(c.rawData));
  return { ders, leafKeys, rootSha: hex(await sha256(ders[2])) };
}

async function makeJws(chain: Awaited<ReturnType<typeof makeChain>>, payload: Record<string, unknown>) {
  const header = { alg: "ES256", x5c: chain.ders.map(b64encode) };
  const signingInput = `${b64url(utf8(JSON.stringify(header)))}.${b64url(utf8(JSON.stringify(payload)))}`;
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, chain.leafKeys.privateKey, bs(utf8(signingInput))));
  return `${signingInput}.${b64url(sig)}`;
}

const goodPayload = { bundleId: "com.priva.app", receiptType: "Production", appTransactionId: "704089281234", signedDate: Date.now() };

Deno.test("AppTransaction: valid chain + signature accepted", async () => {
  const chain = await makeChain();
  const tx = await verifyAppTransaction(await makeJws(chain, goodPayload), "com.priva.app", chain.rootSha);
  assertEquals(tx.appTransactionId, "704089281234");
  assertEquals(tx.environment, "Production");
});

Deno.test("AppTransaction: self-made chain rejected against the real pinned Apple root", async () => {
  const chain = await makeChain();
  await assertRejects(() => verifyAppTransaction(makeJwsSync(chain), "com.priva.app"));
  function makeJwsSync(_c: typeof chain) { return "x.y.z"; }
  await assertRejects(async () => verifyAppTransaction(await makeJws(chain, goodPayload), "com.priva.app"));
});

Deno.test("AppTransaction: tampered payload rejected", async () => {
  const chain = await makeChain();
  const jws = await makeJws(chain, goodPayload);
  const [h, _p, s] = jws.split(".");
  const forged = `${h}.${b64url(utf8(JSON.stringify({ ...goodPayload, appTransactionId: "999999" })))}.${s}`;
  await assertRejects(() => verifyAppTransaction(forged, "com.priva.app", chain.rootSha));
});

Deno.test("AppTransaction: wrong bundle, Xcode env, missing Apple OIDs rejected", async () => {
  const chain = await makeChain();
  await assertRejects(async () => verifyAppTransaction(await makeJws(chain, { ...goodPayload, bundleId: "evil.app" }), "com.priva.app", chain.rootSha));
  await assertRejects(async () => verifyAppTransaction(await makeJws(chain, { ...goodPayload, receiptType: "Xcode" }), "com.priva.app", chain.rootSha));
  const noLeafOid = await makeChain({ leafOid: false });
  await assertRejects(async () => verifyAppTransaction(await makeJws(noLeafOid, goodPayload), "com.priva.app", noLeafOid.rootSha));
  const noInterOid = await makeChain({ interOid: false });
  await assertRejects(async () => verifyAppTransaction(await makeJws(noInterOid, goodPayload), "com.priva.app", noInterOid.rootSha));
});

// ── Bundle (v2: bound to a device-computed username commitment) ────────────────
async function makeBundle(ucommit = crypto.getRandomValues(new Uint8Array(32))) {
  const ed = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const edPk = new Uint8Array(await crypto.subtle.exportKey("raw", ed.publicKey));
  const pq = ml_dsa65.keygen(crypto.getRandomValues(new Uint8Array(32)));
  const day = new Uint8Array(4);
  new DataView(day.buffer).setUint32(0, 20718);
  const signed = concat(utf8("PRVB"), new Uint8Array([2]), ucommit, edPk, pq.publicKey,
    crypto.getRandomValues(new Uint8Array(1216)), crypto.getRandomValues(new Uint8Array(1568)), day);
  const msg = concat(utf8("PRIVA-BUNDLE-v2\0"), signed);
  const sigEd = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, ed.privateKey, bs(msg)));
  const sigPq = ml_dsa65.sign(msg, pq.secretKey);
  return concat(signed, sigEd, sigPq);
}

Deno.test("Bundle v2: well-formed hybrid-signed bundle verifies and exposes its commitment", async () => {
  const c = crypto.getRandomValues(new Uint8Array(32));
  const b = parseBundle(await makeBundle(c));
  assertEquals(b.ucommit, hex(c));
  assert(await verifyBundle(b));
});

Deno.test("Bundle v2: any flipped byte breaks verification", async () => {
  const raw = await makeBundle();
  for (const idx of [10, 100, 3000, 6000, raw.length - 3400, raw.length - 10]) {
    const t = raw.slice();
    t[idx] ^= 0x01;
    let ok = false;
    try { ok = await verifyBundle(parseBundle(t)); } catch { ok = false; }
    assert(!ok, `byte ${idx}`);
  }
});

Deno.test("Hybrid signature: Ed25519 alone or ML-DSA alone is not enough", async () => {
  const b = parseBundle(await makeBundle());
  const msg = concat(utf8("PRIVA-BUNDLE-v2\0"), b.signed);
  const sig = b.signature.slice();
  sig.fill(0, 64);
  assert(!(await verifyHybrid(b.ed25519, b.mldsa65, msg, sig)));
  const sig2 = b.signature.slice();
  sig2.fill(0, 0, 64);
  assert(!(await verifyHybrid(b.ed25519, b.mldsa65, msg, sig2)));
});

Deno.test("Bundle v2: malformed sizes and wrong version rejected", async () => {
  const raw = await makeBundle();
  let threw = 0;
  const v1 = raw.slice(); v1[4] = 1;
  for (const t of [raw.subarray(0, raw.length - 1), concat(raw, new Uint8Array([0])), new Uint8Array(10), v1]) {
    try { parseBundle(t); } catch { threw++; }
  }
  assertEquals(threw, 4);
});

Deno.test("Development purchases: only a nonce signed with the operator's key passes", async () => {
  const key = "a".repeat(64);
  const nonce = crypto.getRandomValues(new Uint8Array(32));
  const k = await crypto.subtle.importKey("raw", bs(utf8(key)), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const proof = new Uint8Array(await crypto.subtle.sign("HMAC", k, bs(concat(utf8("priva-dev-purchase-v1|"), nonce))));
  assert(await devProofValid(nonce, b64encode(proof), key), "the operator's own build");
  assert(!(await devProofValid(nonce, undefined, key)), "no proof: what anyone with the published source can send");
  assert(!(await devProofValid(nonce, b64encode(proof), "b".repeat(64))), "signed with another key");
  const other = crypto.getRandomValues(new Uint8Array(32));
  assert(!(await devProofValid(other, b64encode(proof), key)), "a proof for another nonce");
  assert(!(await devProofValid(nonce, b64encode(proof), undefined)), "the server has no key: nobody gets development purchases");
  assert(!(await devProofValid(nonce, "!!!not base64!!!", key)));
  assert(!(await devProofValid(nonce, b64encode(proof.subarray(0, 16)), key)), "a truncated proof");
});
