// StoreKit 2 hands the app a compact JWS whose header carries the whole signing chain in `x5c`
// (leaf, intermediate, Apple root), so entitlement can be checked in the Worker with WebCrypto —
// no App Store Server API call, no shared secret. Only what that check needs is parsed out of the
// certificates; the X.509 walker itself lives in x509.ts, shared with App Attest.

import { base64, importKey, parseCertificate, text, verifyChain } from "./x509.ts";

export { parseCertificate };
export type { Certificate } from "./x509.ts";

export type Entitlement = { kind: "subscriber" | "beta"; expiresMs: number; meterKey?: string };

export interface AppleVerifyOptions {
  bundleId: string;
  productId: string;
  rootCertsDer: Uint8Array[];
  now?: number;
}

const BETA_TTL_MS = 24 * 60 * 60 * 1000;

// `jws` is the transaction JWS, or `<transaction>,<renewalInfo>` when the subscription has lapsed
// into a billing grace period: the renewal info is what carries the grace end, and joining the two
// keeps it inside the App Attest client data the app signs over.
export async function verifyEntitlement(jws: string, opts: AppleVerifyOptions): Promise<Entitlement | null> {
  const now = opts.now ?? Date.now();
  try {
    const [transactionJws, renewalJws] = jws.split(",");
    const payload = await verifiedPayload(transactionJws, opts, now);
    if (!payload) return null;
    const entitlement = entitlementOf(payload, opts, now);
    if (entitlement || !renewalJws) return entitlement;
    const renewal = await verifiedPayload(renewalJws, opts, now);
    return renewal ? graceOf(payload, renewal, opts, now) : null;
  } catch {
    return null;
  }
}

async function verifiedPayload(jws: string, opts: AppleVerifyOptions, now: number): Promise<Record<string, unknown> | null> {
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
  return JSON.parse(text(base64url(parts[1])));
}

function entitlementOf(payload: Record<string, unknown>, opts: AppleVerifyOptions, now: number): Entitlement | null {
  if (payload?.bundleId !== opts.bundleId) return null;
  if (typeof payload.productId === "string") {
    const live =
      subscribed(payload, opts) &&
      typeof payload.expiresDate === "number" &&
      payload.expiresDate > now &&
      typeof payload.originalTransactionId === "string";
    return live
      ? { kind: "subscriber", expiresMs: payload.expiresDate as number, meterKey: payload.originalTransactionId as string }
      : null;
  }
  // An AppTransaction with a Sandbox or Xcode receipt is a TestFlight or dev build: beta access,
  // re-checked daily because nothing in the payload expires.
  if (payload.receiptType === "Sandbox" || payload.receiptType === "Xcode") {
    return { kind: "beta", expiresMs: now + BETA_TTL_MS };
  }
  return null;
}

function subscribed(payload: Record<string, unknown>, opts: AppleVerifyOptions): boolean {
  return payload.productId === opts.productId && payload.type === "Auto-Renewable Subscription" && payload.revocationDate == null;
}

// A lapsed transaction still counts while Apple retries billing (App Store Connect's grace period),
// which only the renewal info for that same original transaction can say.
function graceOf(transaction: Record<string, unknown>, renewal: Record<string, unknown>, opts: AppleVerifyOptions, now: number): Entitlement | null {
  const inGrace =
    transaction.bundleId === opts.bundleId &&
    subscribed(transaction, opts) &&
    typeof transaction.originalTransactionId === "string" &&
    renewal.originalTransactionId === transaction.originalTransactionId &&
    typeof renewal.gracePeriodExpiresDate === "number" &&
    renewal.gracePeriodExpiresDate > now;
  return inGrace
    ? { kind: "subscriber", expiresMs: renewal.gracePeriodExpiresDate as number, meterKey: transaction.originalTransactionId as string }
    : null;
}

function base64url(value: string): Uint8Array {
  return base64(value.replace(/-/g, "+").replace(/_/g, "/"));
}
