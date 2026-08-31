// App Attest (PRD R17): proves a relay request comes from a genuine build of our app on a genuine
// device, so a scraped StoreKit JWS replayed from a script buys nobody TURN minutes. Follows
// https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server
// with WebCrypto only — the certificate walker is shared with the StoreKit check (x509.ts).

import {
  certificateExtension,
  children,
  concat,
  derToRaw,
  equal,
  importSpki,
  parseCertificate,
  publicKeyPoint,
  read,
  sha256,
  text,
  verifyChain,
  type Certificate,
} from "./x509.ts";

// Apple's per-credential nonce extension; its value is SEQUENCE { [1] { OCTET STRING nonce } }.
const NONCE_OID = "1.2.840.113635.100.8.2";
const AAGUIDS: Record<string, Environment> = {
  "appattest\0\0\0\0\0\0\0": "production",
  appattestdevelop: "development",
};

export type Environment = "production" | "development";

export interface AttestOptions {
  teamId: string;
  bundleId: string;
  rootsDer: Uint8Array[];
  now?: number;
}

// ---- attestation: first contact, registers the device key ----

export async function verifyAttestation(
  cbor: Uint8Array,
  challenge: Uint8Array,
  keyId: Uint8Array,
  opts: AttestOptions,
): Promise<{ publicKeySpki: Uint8Array; environment: Environment } | null> {
  try {
    const object = decodeCbor(cbor) as Record<string, unknown>;
    const attStmt = object.attStmt as Record<string, unknown> | undefined;
    const authData = object.authData;
    const x5c = attStmt?.x5c;
    if (object.fmt !== "apple-appattest" || !(authData instanceof Uint8Array) || !Array.isArray(x5c)) return null;
    if (x5c.length < 2 || !x5c.every((cert) => cert instanceof Uint8Array)) return null;
    const chain = (x5c as Uint8Array[]).map(parseCertificate);
    if (!(await anchored(chain, opts))) return null; // step 1
    if (!(await nonceMatches(chain[0], authData, challenge))) return null; // steps 2-3
    // Step 4: the client's claimed keyId must be the hash of the credential certificate's key.
    if (!equal(await sha256(publicKeyPoint(chain[0])), keyId)) return null;
    if (!(await rpIdMatches(authData, opts))) return null; // step 5
    const environment = attestedCredential(authData, keyId);
    return environment && { publicKeySpki: chain[0].spki, environment };
  } catch {
    return null;
  }
}

// The credential certificate is signed by an Apple intermediate that x5c carries, but the root is
// not in x5c — it is our pinned trust anchor, so append each candidate and try.
async function anchored(chain: Certificate[], opts: AttestOptions): Promise<boolean> {
  const now = opts.now ?? Date.now();
  for (const der of opts.rootsDer) {
    if (await verifyChain([...chain, parseCertificate(der)], [der], now)) return true;
  }
  return false;
}

// Steps 2-3: nonce = SHA256(authData ‖ SHA256(challenge)), and the credential certificate's
// 1.2.840.113635.100.8.2 extension must carry exactly that.
async function nonceMatches(cert: Certificate, authData: Uint8Array, challenge: Uint8Array): Promise<boolean> {
  const nonce = await sha256(concat(authData, await sha256(challenge)));
  const value = certificateExtension(cert, NONCE_OID);
  if (!value) return false;
  const tagged = children(value, read(value, 0))[0];
  const octets = children(value, tagged)[0];
  return equal(value.subarray(octets.start, octets.end), nonce);
}

// ---- assertion: every later relay request ----

export interface AssertionOptions extends AttestOptions {
  spki: Uint8Array;
  counter: number;
}

// Returns the assertion's counter (to be stored) or null. The counter is strictly increasing per
// key, so a captured assertion cannot be replayed.
export async function verifyAssertion(
  cbor: Uint8Array,
  clientData: Uint8Array,
  opts: AssertionOptions,
): Promise<number | null> {
  try {
    const object = decodeCbor(cbor) as Record<string, unknown>;
    const authData = object.authenticatorData;
    const signature = object.signature;
    if (!(authData instanceof Uint8Array) || !(signature instanceof Uint8Array)) return null;
    if (!(await rpIdMatches(authData, opts))) return null;
    const counter = counterOf(authData);
    if (counter <= opts.counter) return null;
    const nonce = await sha256(concat(authData, await sha256(clientData)));
    const key = await importSpki(opts.spki, "P-256");
    const raw = derToRaw(signature, 32);
    const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, raw, nonce);
    return ok ? counter : null;
  } catch {
    return null;
  }
}

// ---- authenticator data ----

// Layout: rpIdHash(32) ‖ flags(1) ‖ counter(4), then for an attestation the attested credential
// data: aaguid(16) ‖ credentialIdLength(2) ‖ credentialId ‖ COSE public key (which we ignore —
// the certificate already gave us the key).
async function rpIdMatches(authData: Uint8Array, opts: AttestOptions): Promise<boolean> {
  if (authData.length < 37) return false;
  const rpIdHash = await sha256(new TextEncoder().encode(`${opts.teamId}.${opts.bundleId}`));
  return equal(authData.subarray(0, 32), rpIdHash);
}

// Only an attestation carries attested credential data; an assertion's authData stops at 37 bytes.
function attestedCredential(authData: Uint8Array, keyId: Uint8Array): Environment | null {
  if (counterOf(authData) !== 0) return null; // a freshly attested key has never signed
  if (authData.length < 87) return null;
  const environment = AAGUIDS[text(authData.subarray(37, 53))];
  const view = new DataView(authData.buffer, authData.byteOffset, authData.byteLength);
  if (!environment || view.getUint16(53) !== 32) return null;
  return equal(authData.subarray(55, 87), keyId) ? environment : null;
}

function counterOf(authData: Uint8Array): number {
  return new DataView(authData.buffer, authData.byteOffset, authData.byteLength).getUint32(33);
}

// ---- CBOR ----
// Apple's attestation and assertion objects use only maps, arrays, byte strings, text strings and
// unsigned integers, so that is all this decodes. Anything else throws and the caller bails.

type Cbor = number | string | Uint8Array | Cbor[] | { [key: string]: Cbor };

export function decodeCbor(data: Uint8Array): Cbor {
  const at = { i: 0 };
  const value = decode(data, at);
  if (at.i !== data.length) throw new Error("trailing cbor");
  return value;
}

function decode(data: Uint8Array, at: { i: number }): Cbor {
  const initial = data[at.i++];
  if (initial === undefined) throw new Error("truncated cbor");
  const count = argument(data, at, initial & 0x1f);
  switch (initial >> 5) {
    case 0:
      return count;
    case 2:
      return bytes(data, at, count);
    case 3:
      return text(bytes(data, at, count));
    case 4:
      return Array.from({ length: count }, () => decode(data, at));
    case 5: {
      const out: { [key: string]: Cbor } = {};
      for (let i = 0; i < count; i++) out[String(decode(data, at))] = decode(data, at);
      return out;
    }
    default:
      throw new Error(`unsupported cbor major type ${initial >> 5}`);
  }
}

function argument(data: Uint8Array, at: { i: number }, info: number): number {
  if (info < 24) return info;
  const width = { 24: 1, 25: 2, 26: 4 }[info];
  if (!width || at.i + width > data.length) throw new Error("unsupported cbor length");
  let value = 0;
  for (let i = 0; i < width; i++) value = value * 256 + data[at.i++];
  return value;
}

function bytes(data: Uint8Array, at: { i: number }, count: number): Uint8Array {
  if (at.i + count > data.length) throw new Error("truncated cbor");
  const out = data.subarray(at.i, at.i + count);
  at.i += count;
  return out;
}
