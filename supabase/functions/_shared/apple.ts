// Verifies a StoreKit 2 AppTransaction JWS (paid-app proof of purchase) offline:
//   x5c chain → pinned Apple Root CA - G3 → Apple intermediate (OID …6.2.1) → leaf (OID …6.11.1)
//   → ES256 JWS signature → payload checks.
import "npm:reflect-metadata@0.2.2";
import * as x509 from "npm:@peculiar/x509@2.1.0";
import { b64decode, b64urlDecode, bs, hex, HttpError, sha256, utf8 } from "./util.ts";

x509.cryptoProvider.set(crypto);

export const APPLE_ROOT_G3_SHA256 = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179";
const OID_APPLE_INTERMEDIATE = "1.2.840.113635.100.6.2.1";
const OID_APPLE_RECEIPT_LEAF = "1.2.840.113635.100.6.11.1";

export interface VerifiedAppTransaction {
  appTransactionId: string;
  environment: "Production" | "Sandbox";
}

const reject = () => new HttpError(403, "purchase_unverified");

export async function verifyAppTransaction(
  jws: string,
  expectedBundleId: string,
  rootSha256: string = APPLE_ROOT_G3_SHA256,
): Promise<VerifiedAppTransaction> {
  const parts = jws.split(".");
  if (parts.length !== 3 || jws.length > 32_000) throw reject();

  let header: { alg?: string; x5c?: unknown };
  let payload: Record<string, unknown>;
  try {
    header = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[0])));
    payload = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[1])));
  } catch {
    throw reject();
  }
  if (header.alg !== "ES256" || !Array.isArray(header.x5c) || header.x5c.length !== 3) throw reject();

  const ders = (header.x5c as unknown[]).map((c) => {
    if (typeof c !== "string") throw reject();
    return b64decode(c);
  });
  if (hex(await sha256(ders[2])) !== rootSha256) throw reject();

  const [leaf, intermediate, root] = ders.map((d) => new x509.X509Certificate(bs(d)));
  const signedDate = typeof payload.signedDate === "number" ? new Date(payload.signedDate) : new Date();

  const chainOk =
    (await root.verify({ date: signedDate })) &&
    (await intermediate.verify({ publicKey: root.publicKey, date: signedDate })) &&
    (await leaf.verify({ publicKey: intermediate.publicKey, date: signedDate }));
  if (!chainOk) throw reject();
  if (!intermediate.getExtension(OID_APPLE_INTERMEDIATE)) throw reject();
  if (!leaf.getExtension(OID_APPLE_RECEIPT_LEAF)) throw reject();

  const leafKey = await leaf.publicKey.export({ name: "ECDSA", namedCurve: "P-256" }, ["verify"]);
  const sig = b64urlDecode(parts[2]);
  if (sig.length !== 64) throw reject();
  const sigOk = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" }, leafKey, bs(sig), bs(utf8(`${parts[0]}.${parts[1]}`)),
  );
  if (!sigOk) throw reject();

  if (payload.bundleId !== expectedBundleId) throw reject();
  const env = payload.receiptType ?? payload.environment;
  if (env !== "Production" && env !== "Sandbox") throw reject();
  const id = payload.appTransactionId;
  if (typeof id !== "string" || id.length < 4 || id.length > 128) throw reject();

  return { appTransactionId: id, environment: env };
}
