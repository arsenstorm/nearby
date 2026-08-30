// StoreKit 2 hands the app a compact JWS whose header carries the whole signing chain in `x5c`
// (leaf, intermediate, Apple root), so entitlement can be checked in the Worker with WebCrypto —
// no App Store Server API call, no shared secret. Only what that check needs is parsed out of the
// certificates; the X.509 walker itself lives in x509.ts, shared with App Attest.

import { base64, importKey, parseCertificate, text, verifyChain } from "./x509.ts";

export { parseCertificate };
export type { Certificate } from "./x509.ts";

export type Entitlement = { kind: "subscriber" | "beta"; expiresMs: number };

export interface AppleVerifyOptions {
  bundleId: string;
  productId: string;
  rootCertsDer: Uint8Array[];
  now?: number;
}

const BETA_TTL_MS = 24 * 60 * 60 * 1000;

export async function verifyEntitlement(jws: string, opts: AppleVerifyOptions): Promise<Entitlement | null> {
  const now = opts.now ?? Date.now();
  try {
    const parts = jws.split(".");
    if (parts.length !== 3) return null;
    const header = JSON.parse(text(base64url(parts[0]))) as { alg?: unknown; x5c?: unknown };
    if (header.alg !== "ES256" || !Array.isArray(header.x5c) || header.x5c.length < 2) return null;
    const chain = header.x5c.map((cert: string) => parseCertificate(base64(cert)));
    if (!(await verifyChain(chain, opts.rootCertsDer, now))) return null;
    const key = await importKey(chain[0]);
    const signed = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
    // JOSE signatures are already raw r‖s, unlike the DER ones inside the certificates.
    if (!(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, base64url(parts[2]), signed))) return null;
    return entitlementOf(JSON.parse(text(base64url(parts[1]))), opts, now);
  } catch {
    return null;
  }
}

function entitlementOf(payload: Record<string, unknown>, opts: AppleVerifyOptions, now: number): Entitlement | null {
  if (payload?.bundleId !== opts.bundleId) return null;
  if (typeof payload.productId === "string") {
    const live =
      payload.productId === opts.productId &&
      payload.type === "Auto-Renewable Subscription" &&
      typeof payload.expiresDate === "number" &&
      payload.expiresDate > now &&
      payload.revocationDate == null;
    return live ? { kind: "subscriber", expiresMs: payload.expiresDate as number } : null;
  }
  // An AppTransaction with a Sandbox or Xcode receipt is a TestFlight or dev build: beta access,
  // re-checked daily because nothing in the payload expires.
  if (payload.receiptType === "Sandbox" || payload.receiptType === "Xcode") {
    return { kind: "beta", expiresMs: now + BETA_TTL_MS };
  }
  return null;
}

function base64url(value: string): Uint8Array {
  return base64(value.replace(/-/g, "+").replace(/_/g, "/"));
}
