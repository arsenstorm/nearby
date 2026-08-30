#!/usr/bin/env node
// Unit tests for src/apple.ts: the StoreKit 2 JWS verifier, exercised against a throwaway
// certificate chain (test/chain.mjs) shaped like Apple's, plus one parse of the real Apple root.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { verifyEntitlement, parseCertificate } from "../src/apple.ts";
import { makeChain, b64url } from "./chain.mjs";

const BUNDLE = "com.arsenstorm.nearby";
const PRODUCT = "com.arsenstorm.nearby.plus.monthly";
const DAY_MS = 24 * 60 * 60 * 1000;

const chain = makeChain();
const opts = { bundleId: BUNDLE, productId: PRODUCT, rootCertsDer: [chain.rootDer] };
const now = Date.now();
const verify = (jws, extra = {}) => verifyEntitlement(jws, { ...opts, ...extra });

const subscription = (overrides = {}) => ({
  bundleId: BUNDLE,
  productId: PRODUCT,
  type: "Auto-Renewable Subscription",
  expiresDate: now + 30 * DAY_MS,
  ...overrides,
});

// a. Valid subscription.
{
  const payload = subscription();
  assert.deepEqual(await verify(chain.jws(payload)), { kind: "subscriber", expiresMs: payload.expiresDate });
}
console.log("a. valid subscription: pass");

// b. Expired subscription.
assert.equal(await verify(chain.jws(subscription({ expiresDate: now - DAY_MS }))), null);
console.log("b. expired subscription: pass");

// b2. Lapsed subscription inside a billing grace period, proven by its renewal info.
{
  const lapsed = subscription({ expiresDate: now - DAY_MS, originalTransactionId: "1000000123" });
  const renewal = (overrides = {}) => ({ originalTransactionId: "1000000123", gracePeriodExpiresDate: now + 2 * DAY_MS, ...overrides });
  const pair = (r) => `${chain.jws(lapsed)},${chain.jws(r)}`;
  assert.deepEqual(await verify(pair(renewal())), { kind: "subscriber", expiresMs: now + 2 * DAY_MS });
  assert.equal(await verify(pair(renewal({ gracePeriodExpiresDate: now - 1 }))), null);
  assert.equal(await verify(pair(renewal({ originalTransactionId: "999" }))), null);
  assert.equal(await verify(pair(renewal({ gracePeriodExpiresDate: undefined }))), null);
  // A live subscription ignores the renewal half; a renewal cannot revive a revoked one.
  assert.deepEqual(await verify(`${chain.jws(subscription())},${chain.jws(renewal())}`), { kind: "subscriber", expiresMs: now + 30 * DAY_MS });
  assert.equal(await verify(`${chain.jws(subscription({ expiresDate: now - DAY_MS, originalTransactionId: "1000000123", revocationDate: now - DAY_MS }))},${chain.jws(renewal())}`), null);
}
console.log("b2. billing grace period: pass");

// c. Wrong productId.
assert.equal(await verify(chain.jws(subscription({ productId: `${PRODUCT}.other` }))), null);
console.log("c. wrong productId: pass");

// d. Wrong bundleId.
assert.equal(await verify(chain.jws(subscription({ bundleId: "com.example.other" }))), null);
console.log("d. wrong bundleId: pass");

// e. AppTransaction receipt types.
{
  const appTransaction = (receiptType) => chain.jws({ bundleId: BUNDLE, receiptType });
  const beta = await verify(appTransaction("Sandbox"));
  assert.equal(beta.kind, "beta");
  assert.ok(beta.expiresMs > now && beta.expiresMs <= Date.now() + DAY_MS);
  assert.equal((await verify(appTransaction("Xcode"))).kind, "beta");
  assert.equal(await verify(appTransaction("Production")), null);
}
console.log("e. AppTransaction Sandbox/Xcode beta, Production null: pass");

// f. Leaf signed by an unrelated CA.
assert.equal(await verify(chain.brokenChainJws(subscription())), null);
console.log("f. broken chain: pass");

// g. Root not in the trust list.
{
  const apple = readFileSync(fileURLToPath(new URL("../certs/AppleRootCA-G3.cer", import.meta.url)));
  assert.equal(await verify(chain.jws(subscription()), { rootCertsDer: [apple] }), null);
}
console.log("g. untrusted root: pass");

// h. Payload swapped after signing.
{
  const [header, , signature] = chain.jws(subscription({ expiresDate: now - DAY_MS })).split(".");
  const forged = b64url(subscription());
  assert.equal(await verify(`${header}.${forged}.${signature}`), null);
}
console.log("h. tampered payload: pass");

// i. The real Apple root parses with the same walker.
{
  const apple = readFileSync(fileURLToPath(new URL("../certs/AppleRootCA-G3.cer", import.meta.url)));
  const cert = parseCertificate(apple);
  assert.equal(cert.curve, "P-384");
  assert.equal(cert.hash, "SHA-384");
  assert.equal(new Date(cert.notBefore).toISOString(), "2014-04-30T18:19:06.000Z");
  assert.equal(new Date(cert.notAfter).toISOString(), "2039-04-30T18:19:06.000Z");
  // 0x30 SEQUENCE header, then the ecPublicKey AlgorithmIdentifier and the 97-byte uncompressed point.
  assert.equal(cert.spki[0], 0x30);
  await crypto.subtle.importKey("spki", cert.spki, { name: "ECDSA", namedCurve: "P-384" }, false, ["verify"]);
}
console.log("i. real Apple root parses: pass");

console.log("all apple cases passed");
