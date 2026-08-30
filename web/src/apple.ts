// StoreKit 2 hands the app a compact JWS whose header carries the whole signing chain in `x5c`
// (leaf, intermediate, Apple root), so entitlement can be checked in the Worker with WebCrypto —
// no App Store Server API call, no shared secret. Only what that check needs is parsed out of the
// certificates: the chain is anchored by pinning the root's DER bytes, not by name matching.

export type Entitlement = { kind: "subscriber" | "beta"; expiresMs: number };

export interface AppleVerifyOptions {
  bundleId: string;
  productId: string;
  rootCertsDer: Uint8Array[];
  now?: number;
}

export type Certificate = {
  der: Uint8Array;
  tbs: Uint8Array;
  spki: Uint8Array;
  curve: "P-256" | "P-384";
  hash: "SHA-256" | "SHA-384";
  signature: Uint8Array;
  notBefore: number;
  notAfter: number;
};

const BETA_TTL_MS = 24 * 60 * 60 * 1000;
const CURVES: Record<string, Certificate["curve"]> = {
  "1.2.840.10045.3.1.7": "P-256",
  "1.3.132.0.34": "P-384",
};
const HASHES: Record<string, Certificate["hash"]> = {
  "1.2.840.10045.4.3.2": "SHA-256", // ecdsa-with-SHA256
  "1.2.840.10045.4.3.3": "SHA-384", // ecdsa-with-SHA384
};

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

async function verifyChain(chain: Certificate[], roots: Uint8Array[], now: number): Promise<boolean> {
  const root = chain[chain.length - 1];
  if (!roots.some((trusted) => equal(trusted, root.der))) return false;
  if (chain.some((cert) => now < cert.notBefore || now > cert.notAfter)) return false;
  for (let i = 0; i < chain.length - 1; i++) {
    const issuer = chain[i + 1];
    const key = await importKey(issuer);
    const signature = derToRaw(chain[i].signature, issuer.curve === "P-384" ? 48 : 32);
    const algorithm = { name: "ECDSA", hash: chain[i].hash };
    if (!(await crypto.subtle.verify(algorithm, key, signature, chain[i].tbs))) return false;
  }
  return true;
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

function importKey(cert: Certificate): Promise<CryptoKey> {
  return crypto.subtle.importKey("spki", cert.spki, { name: "ECDSA", namedCurve: cert.curve }, false, ["verify"]);
}

// ---- minimal ASN.1 / X.509 ----

type Node = { tag: number; head: number; start: number; end: number };

function read(der: Uint8Array, offset: number): Node {
  const tag = der[offset];
  const first = der[offset + 1];
  let start = offset + 2;
  let length = first;
  if (first & 0x80) {
    // Long form: the low 7 bits count the length bytes that follow. 0x80 alone is indefinite
    // length, which DER forbids, and lands here as a zero count.
    const count = first & 0x7f;
    if (count < 1 || count > 4) throw new Error("bad length");
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + der[start + i];
    start += count;
  }
  const end = start + length;
  if (!(tag >= 0) || !(end <= der.length)) throw new Error("truncated");
  return { tag, head: offset, start, end };
}

function children(der: Uint8Array, node: Node): Node[] {
  const out: Node[] = [];
  for (let offset = node.start; offset < node.end; ) {
    const child = read(der, offset);
    out.push(child);
    offset = child.end;
  }
  return out;
}

export function parseCertificate(der: Uint8Array): Certificate {
  const [tbs, algorithm, signature] = children(der, read(der, 0));
  const fields = children(der, tbs);
  // TBSCertificate opens with an optional [0] EXPLICIT version, so every later field shifts on v3.
  const base = fields[0].tag === 0xa0 ? 1 : 0;
  const [notBefore, notAfter] = children(der, fields[base + 3]).map((node) => time(der, node));
  const spki = fields[base + 5];
  const curve = CURVES[oid(der, children(der, children(der, spki)[0])[1])];
  const hash = HASHES[oid(der, children(der, algorithm)[0])];
  if (!curve || !hash) throw new Error("unsupported algorithm");
  return {
    der,
    tbs: der.subarray(tbs.head, tbs.end),
    spki: der.subarray(spki.head, spki.end),
    curve,
    hash,
    // BIT STRING content is prefixed with a count of unused trailing bits, always 0 here.
    signature: der.subarray(signature.start + 1, signature.end),
    notBefore,
    notAfter,
  };
}

function oid(der: Uint8Array, node: Node): string {
  const bytes = der.subarray(node.start, node.end);
  const parts = [Math.floor(bytes[0] / 40), bytes[0] % 40];
  let value = 0;
  for (const byte of bytes.subarray(1)) {
    value = value * 128 + (byte & 0x7f);
    if (!(byte & 0x80)) {
      parts.push(value);
      value = 0;
    }
  }
  return parts.join(".");
}

function time(der: Uint8Array, node: Node): number {
  const value = text(der.subarray(node.start, node.end));
  // UTCTime (0x17) is YYMMDDHHMMSSZ; RFC 5280 pivots the two-digit year at 50.
  const full = node.tag === 0x17 ? (Number(value.slice(0, 2)) < 50 ? "20" : "19") + value : value;
  const parsed = /^(\d{4})(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)Z$/.exec(full);
  if (!parsed) throw new Error("bad time");
  const [, y, mo, d, h, mi, s] = parsed.map(Number);
  return Date.UTC(y, mo - 1, d, h, mi, s);
}

function derToRaw(signature: Uint8Array, size: number): Uint8Array {
  const [r, s] = children(signature, read(signature, 0));
  const out = new Uint8Array(size * 2);
  out.set(unsigned(signature, r, size), 0);
  out.set(unsigned(signature, s, size), size);
  return out;
}

function unsigned(der: Uint8Array, node: Node, size: number): Uint8Array {
  // DER INTEGERs are signed, so a 0x00 pad byte appears whenever the top bit would read negative.
  let bytes = der.subarray(node.start, node.end);
  while (bytes.length > size && bytes[0] === 0) bytes = bytes.subarray(1);
  if (bytes.length > size) throw new Error("oversize integer");
  const out = new Uint8Array(size);
  out.set(bytes, size - bytes.length);
  return out;
}

// ---- encoding ----

function base64(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
}

function base64url(value: string): Uint8Array {
  return base64(value.replace(/-/g, "+").replace(/_/g, "/"));
}

function text(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}

function equal(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((byte, i) => byte === b[i]);
}
