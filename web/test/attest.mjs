#!/usr/bin/env node
// Unit tests for src/attest.ts: App Attest attestation and assertion verification, against a
// throwaway chain shaped like Apple's (test/chain.mjs), plus one parse of the real Apple root.
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { verifyAssertion, verifyAttestation } from "../src/attest.ts";
import { parseCertificate } from "../src/x509.ts";
import { AAGUID, makeAppAttest, rpIdHash } from "./chain.mjs";

const TEAM = "ABCDE12345";
const BUNDLE = "com.arsenstorm.nearby";

const attest = makeAppAttest({ teamId: TEAM, bundleId: BUNDLE });
const opts = { teamId: TEAM, bundleId: BUNDLE, rootsDer: [attest.rootDer] };
const challenge = randomBytes(32);

// a. Valid attestation, production aaguid.
const production = attest.credential(challenge);
{
  const result = await verifyAttestation(production.attestation, challenge, production.keyId, opts);
  assert.equal(result?.environment, "production");
  assert.equal(result.publicKeySpki[0], 0x30);
}
console.log("a. valid attestation (production): pass");

// b. Same, with the development aaguid a Xcode/TestFlight build sends.
{
  const dev = attest.credential(challenge, { aaguid: AAGUID.development });
  const result = await verifyAttestation(dev.attestation, challenge, dev.keyId, opts);
  assert.equal(result?.environment, "development");
}
console.log("b. valid attestation (development): pass");

// c. authData bound to a different app: rpIdHash mismatch.
{
  const other = attest.credential(challenge, { rpId: rpIdHash("ZZZZZ99999", BUNDLE) });
  assert.equal(await verifyAttestation(other.attestation, challenge, other.keyId, opts), null);
}
console.log("c. wrong rpIdHash: pass");

// d. Certificate nonce built over a different challenge — a replayed attestation.
{
  const stale = attest.credential(challenge, { nonceChallenge: randomBytes(32) });
  assert.equal(await verifyAttestation(stale.attestation, challenge, stale.keyId, opts), null);
}
console.log("d. nonce mismatch: pass");

// e. Client claims a keyId that isn't the hash of the certified key.
assert.equal(await verifyAttestation(production.attestation, challenge, randomBytes(32), opts), null);
console.log("e. keyId mismatch: pass");

// f. credentialId inside authData doesn't match the certified key either.
{
  const forged = attest.credential(challenge, { credentialId: randomBytes(32) });
  assert.equal(await verifyAttestation(forged.attestation, challenge, forged.keyId, opts), null);
}
console.log("f. credentialId mismatch: pass");

// g. Chain that doesn't reach our pinned anchor.
{
  const stranger = makeAppAttest({ teamId: TEAM, bundleId: BUNDLE }).credential(challenge);
  assert.equal(await verifyAttestation(stranger.attestation, challenge, stranger.keyId, opts), null);
}
console.log("g. untrusted root: pass");

// h. Valid assertion, and the counter it reports is what the server should store.
const spki = (await verifyAttestation(production.attestation, challenge, production.keyId, opts)).publicKeySpki;
const clientData = Buffer.from("relay-request-bytes", "utf8");
const assertOpts = { ...opts, spki, counter: 0 };
assert.equal(await verifyAssertion(production.assertion(clientData, 1), clientData, assertOpts), 1);
console.log("h. valid assertion: pass");

// i. The same assertion replayed once its counter has been stored.
assert.equal(await verifyAssertion(production.assertion(clientData, 1), clientData, { ...assertOpts, counter: 1 }), null);
console.log("i. replayed counter: pass");

// j. Signature over something other than the nonce.
assert.equal(await verifyAssertion(production.assertion(clientData, 2, { corrupt: true }), clientData, assertOpts), null);
console.log("j. bad signature: pass");

// k. Assertion checked against clientData the client didn't sign.
assert.equal(await verifyAssertion(production.assertion(clientData, 2), Buffer.from("other"), assertOpts), null);
console.log("k. clientData mismatch: pass");

// l. Garbage in, null out — never a throw.
assert.equal(await verifyAttestation(randomBytes(64), challenge, production.keyId, opts), null);
assert.equal(await verifyAssertion(randomBytes(64), clientData, assertOpts), null);
console.log("l. malformed CBOR: pass");

// m. The real Apple App Attest root parses with the same walker.
{
  const root = readFileSync(fileURLToPath(new URL("../certs/AppleAppAttestationRootCA.cer", import.meta.url)));
  const cert = parseCertificate(root);
  assert.equal(cert.curve, "P-384");
  assert.equal(cert.hash, "SHA-384");
  assert.equal(new Date(cert.notBefore).toISOString(), "2020-03-18T18:32:53.000Z");
  assert.equal(new Date(cert.notAfter).toISOString(), "2045-03-15T00:00:00.000Z");
  await crypto.subtle.importKey("spki", cert.spki, { name: "ECDSA", namedCurve: "P-384" }, false, ["verify"]);
}
console.log("m. real Apple App Attest root parses: pass");

console.log("all attest cases passed");
