// Just enough ASN.1/X.509 to check a certificate chain with WebCrypto: shared by the StoreKit
// entitlement check (apple.ts) and App Attest (attest.ts). Chains are anchored by pinning the
// root's DER bytes, never by name matching, so nothing here parses subjects or issuers.

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

const CURVES: Record<string, Certificate["curve"]> = {
  "1.2.840.10045.3.1.7": "P-256",
  "1.3.132.0.34": "P-384",
};
const HASHES: Record<string, Certificate["hash"]> = {
  "1.2.840.10045.4.3.2": "SHA-256", // ecdsa-with-SHA256
  "1.2.840.10045.4.3.3": "SHA-384", // ecdsa-with-SHA384
};

export type Node = { tag: number; head: number; start: number; end: number };

export function read(der: Uint8Array, offset: number): Node {
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

export function children(der: Uint8Array, node: Node): Node[] {
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

// The chain runs leaf -> ... -> root; the root must be one of `roots` byte for byte.
export async function verifyChain(chain: Certificate[], roots: Uint8Array[], now: number): Promise<boolean> {
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

export function importKey(cert: Certificate): Promise<CryptoKey> {
  return importSpki(cert.spki, cert.curve);
}

export function importSpki(spki: Uint8Array, curve: Certificate["curve"]): Promise<CryptoKey> {
  return crypto.subtle.importKey("spki", spki, { name: "ECDSA", namedCurve: curve }, false, ["verify"]);
}

// The raw uncompressed X9.62 point (0x04 ‖ X ‖ Y) out of the SPKI BIT STRING; App Attest hashes it.
export function publicKeyPoint(cert: Certificate): Uint8Array {
  const bits = children(cert.spki, read(cert.spki, 0))[1];
  return cert.spki.subarray(bits.start + 1, bits.end);
}

// The contents of an extension's extnValue OCTET STRING, or null when the certificate has no
// such extension. Extensions live in tbsCertificate's optional [3] EXPLICIT wrapper.
export function certificateExtension(cert: Certificate, wanted: string): Uint8Array | null {
  const der = cert.der;
  const fields = children(der, children(der, read(der, 0))[0]);
  const wrapper = fields.find((field) => field.tag === 0xa3);
  if (!wrapper) return null;
  for (const extension of children(der, children(der, wrapper)[0])) {
    const parts = children(der, extension);
    if (oid(der, parts[0]) !== wanted) continue;
    // parts[1] is the optional critical BOOLEAN, so the value is always the last element.
    const value = parts[parts.length - 1];
    return der.subarray(value.start, value.end);
  }
  return null;
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

export function derToRaw(signature: Uint8Array, size: number): Uint8Array {
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

// ---- bytes ----

export function base64(value: string): Uint8Array {
  return Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
}

export function text(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}

export function equal(a: Uint8Array, b: Uint8Array): boolean {
  return a.length === b.length && a.every((byte, i) => byte === b[i]);
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

export function sha256(bytes: Uint8Array): Promise<Uint8Array> {
  return crypto.subtle.digest("SHA-256", bytes).then((digest) => new Uint8Array(digest));
}
