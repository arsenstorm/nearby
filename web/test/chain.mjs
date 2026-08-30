// A throwaway certificate chain shaped like Apple's (P-384 root, P-256 intermediate, P-256 leaf)
// plus a JWS signer, shared by test/apple.mjs and test/pair.mjs. node:crypto can sign but cannot
// mint X.509, so the certificates come from the openssl binary. makeAppAttest() does the same for
// App Attest: an anchor chain plus hand-rolled attestation/assertion CBOR (test/attest.mjs).
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createHash, createPrivateKey, createPublicKey, sign } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";

// stderr is piped, not inherited, so openssl's progress chatter stays out of the test output.
const openssl = (...args) => execFileSync("openssl", args, { stdio: ["ignore", "pipe", "pipe"] });

// A scratch CA directory: key generation plus self-signed and issued certificates.
function authority(prefix) {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  const at = (name) => join(dir, name);
  let serial = 1;

  const key = (name, curve) =>
    openssl("genpkey", "-algorithm", "EC", "-pkeyopt", `ec_paramgen_curve:${curve}`, "-out", at(`${name}.key`));

  const selfSigned = (name, curve, hash) => {
    key(name, curve);
    openssl("req", "-new", "-x509", "-key", at(`${name}.key`), `-${hash}`, "-days", "3650",
      "-subj", `/CN=${name}`, "-out", at(`${name}.pem`));
  };

  const issued = (name, curve, ca, hash, extensions) => {
    // App Attest needs the credential key before the certificate exists (the nonce extension
    // depends on it), so a caller may have generated it already.
    if (!existsSync(at(`${name}.key`))) key(name, curve);
    openssl("req", "-new", "-key", at(`${name}.key`), "-subj", `/CN=${name}`, "-out", at(`${name}.csr`));
    const extra = [];
    if (extensions) {
      writeFileSync(at(`${name}.cnf`), `[v3]\n${extensions}\n`);
      extra.push("-extfile", at(`${name}.cnf`), "-extensions", "v3");
    }
    openssl("x509", "-req", "-in", at(`${name}.csr`), "-CA", at(`${ca}.pem`), "-CAkey", at(`${ca}.key`),
      "-set_serial", String(serial++), "-days", "3650", `-${hash}`, ...extra, "-out", at(`${name}.pem`));
  };

  const der = (name) => openssl("x509", "-in", at(`${name}.pem`), "-outform", "DER");

  return { at, key, selfSigned, issued, der };
}

export function makeChain() {
  const ca = authority("nearby-chain-");
  ca.selfSigned("root", "P-384", "sha384");
  ca.issued("intermediate", "P-256", "root", "sha384");
  ca.issued("leaf", "P-256", "intermediate", "sha256");
  ca.selfSigned("rogue", "P-256", "sha256");
  ca.issued("rogueleaf", "P-256", "rogue", "sha256");

  const rootDer = ca.der("root");
  const chain = [ca.der("leaf"), ca.der("intermediate"), rootDer];
  const broken = [ca.der("rogueleaf"), ca.der("intermediate"), rootDer];

  const jws = (payload, { certs = chain, signer = "leaf" } = {}) => {
    const header = { alg: "ES256", x5c: certs.map((cert) => cert.toString("base64")) };
    const input = `${b64url(header)}.${b64url(payload)}`;
    const privateKey = createPrivateKey(readFileSync(ca.at(`${signer}.key`)));
    // JOSE wants raw r‖s, not the DER encoding node:crypto defaults to.
    const sig = sign("sha256", Buffer.from(input), { key: privateKey, dsaEncoding: "ieee-p1363" });
    return `${input}.${sig.toString("base64url")}`;
  };

  return {
    rootDer,
    jws,
    brokenChainJws: (payload) => jws(payload, { certs: broken, signer: "rogueleaf" }),
  };
}

export function b64url(value) {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
}

// ---- App Attest ----

const NONCE_OID = "1.2.840.113635.100.8.2";
export const AAGUID = {
  production: Buffer.concat([Buffer.from("appattest", "ascii"), Buffer.alloc(7)]),
  development: Buffer.from("appattestdevelop", "ascii"),
};

const sha256 = (...parts) => createHash("sha256").update(Buffer.concat(parts)).digest();

export function rpIdHash(teamId, bundleId) {
  return sha256(Buffer.from(`${teamId}.${bundleId}`, "utf8"));
}

// Mirrors what a device produces: a P-256 credential key whose certificate carries the Apple nonce
// extension, the attestation object that registers it, and assertions signed with it afterwards.
// Every knob exists so a test can break exactly one step. `alsoRoot` is a second, untrusted anchor.
export function makeAppAttest({ teamId, bundleId }) {
  const ca = authority("nearby-attest-");
  ca.selfSigned("root", "P-384", "sha384");
  ca.issued("ca", "P-256", "root", "sha384");
  let credentials = 0;

  function credential(challenge, options = {}) {
    const { aaguid = AAGUID.production, rpId = rpIdHash(teamId, bundleId), nonceChallenge = challenge } = options;
    const name = `cred${credentials++}`;
    const point = pointOf(ca, name);
    const keyId = options.credentialId ?? sha256(point);
    const authData = Buffer.concat([
      header(rpId, 0x40, 0),
      aaguid,
      uint16(keyId.length),
      keyId,
      coseKey(point),
    ]);
    const nonce = sha256(authData, sha256(nonceChallenge));
    ca.issued(name, "P-256", "ca", "sha256", `${NONCE_OID}=DER:${extensionDer(nonce).toString("hex")}`);
    const attestation = cbor({
      fmt: "apple-appattest",
      attStmt: { x5c: [ca.der(name), ca.der("ca")], receipt: Buffer.from("receipt", "utf8") },
      authData,
    });
    return { keyId: sha256(point), attestation, assertion: (clientData, counter, opts) => assert(ca, name, rpId, clientData, counter, opts) };
  }

  return { rootDer: ca.der("root"), credential };
}

function assert(ca, name, rpId, clientData, counter, { corrupt = false } = {}) {
  const authenticatorData = header(rpId, 0x00, counter);
  const nonce = sha256(authenticatorData, sha256(clientData));
  const key = createPrivateKey(readFileSync(ca.at(`${name}.key`)));
  const signature = sign("sha256", corrupt ? sha256(nonce) : nonce, key); // DER, as App Attest sends it
  return cbor({ signature, authenticatorData });
}

// The credential key's uncompressed X9.62 point, which App Attest hashes into the keyId. The key
// has to exist before its certificate, because the certificate's nonce extension covers it.
function pointOf(ca, name) {
  ca.key(name, "P-256");
  const jwk = createPublicKey(readFileSync(ca.at(`${name}.key`))).export({ format: "jwk" });
  return Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, "base64url"), Buffer.from(jwk.y, "base64url")]);
}

function header(rpId, flags, counter) {
  const out = Buffer.alloc(37);
  rpId.copy(out, 0);
  out[32] = flags;
  out.writeUInt32BE(counter, 33);
  return out;
}

function uint16(value) {
  const out = Buffer.alloc(2);
  out.writeUInt16BE(value);
  return out;
}

// COSE_Key for an EC2 P-256 public key: {1: 2, 3: -7, -1: 1, -2: x, -3: y}.
function coseKey(point) {
  return cbor(new Map([[1, 2], [3, -7], [-1, 1], [-2, point.subarray(1, 33)], [-3, point.subarray(33)]]));
}

// OCTET STRING { SEQUENCE { [1] { OCTET STRING nonce } } } — the outer OCTET STRING is extnValue,
// which openssl's `DER:` form wraps for us, so only the inner bytes go in.
function extensionDer(nonce) {
  return Buffer.concat([Buffer.from([0x30, nonce.length + 4, 0xa1, nonce.length + 2, 0x04, nonce.length]), nonce]);
}

// ---- tiny CBOR encoder (enough for what App Attest sends) ----

export function cbor(value) {
  if (Buffer.isBuffer(value) || value instanceof Uint8Array) return Buffer.concat([head(2, value.length), Buffer.from(value)]);
  if (typeof value === "string") return Buffer.concat([head(3, Buffer.byteLength(value)), Buffer.from(value, "utf8")]);
  if (typeof value === "number") return value < 0 ? head(1, -1 - value) : head(0, value);
  if (Array.isArray(value)) return Buffer.concat([head(4, value.length), ...value.map(cbor)]);
  const entries = value instanceof Map ? [...value] : Object.entries(value);
  return Buffer.concat([head(5, entries.length), ...entries.flatMap(([k, v]) => [cbor(k), cbor(v)])]);
}

function head(major, n) {
  const tag = major << 5;
  if (n < 24) return Buffer.from([tag | n]);
  if (n < 0x100) return Buffer.from([tag | 24, n]);
  if (n < 0x10000) return Buffer.from([tag | 25, n >> 8, n & 0xff]);
  const out = Buffer.alloc(5);
  out[0] = tag | 26;
  out.writeUInt32BE(n, 1);
  return out;
}
