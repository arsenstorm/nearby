// A throwaway certificate chain shaped like Apple's (P-384 root, P-256 intermediate, P-256 leaf)
// plus a JWS signer, shared by test/apple.mjs and test/pair.mjs. node:crypto can sign but cannot
// mint X.509, so the certificates come from the openssl binary.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { createPrivateKey, sign } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";

// stderr is piped, not inherited, so openssl's progress chatter stays out of the test output.
const openssl = (...args) => execFileSync("openssl", args, { stdio: ["ignore", "pipe", "pipe"] });

export function makeChain() {
  const dir = mkdtempSync(join(tmpdir(), "nearby-chain-"));
  const at = (name) => join(dir, name);
  let serial = 1;

  const key = (name, curve) =>
    openssl("genpkey", "-algorithm", "EC", "-pkeyopt", `ec_paramgen_curve:${curve}`, "-out", at(`${name}.key`));

  const selfSigned = (name, curve, hash) => {
    key(name, curve);
    openssl("req", "-new", "-x509", "-key", at(`${name}.key`), `-${hash}`, "-days", "3650",
      "-subj", `/CN=${name}`, "-out", at(`${name}.pem`));
  };

  const issued = (name, curve, ca, hash) => {
    key(name, curve);
    openssl("req", "-new", "-key", at(`${name}.key`), "-subj", `/CN=${name}`, "-out", at(`${name}.csr`));
    openssl("x509", "-req", "-in", at(`${name}.csr`), "-CA", at(`${ca}.pem`), "-CAkey", at(`${ca}.key`),
      "-set_serial", String(serial++), "-days", "3650", `-${hash}`, "-out", at(`${name}.pem`));
  };

  const der = (name) => openssl("x509", "-in", at(`${name}.pem`), "-outform", "DER");

  selfSigned("root", "P-384", "sha384");
  issued("intermediate", "P-256", "root", "sha384");
  issued("leaf", "P-256", "intermediate", "sha256");
  selfSigned("rogue", "P-256", "sha256");
  issued("rogueleaf", "P-256", "rogue", "sha256");

  const rootDer = der("root");
  const chain = [der("leaf"), der("intermediate"), rootDer];
  const broken = [der("rogueleaf"), der("intermediate"), rootDer];

  const jws = (payload, { certs = chain, signer = "leaf" } = {}) => {
    const header = { alg: "ES256", x5c: certs.map((cert) => cert.toString("base64")) };
    const input = `${b64url(header)}.${b64url(payload)}`;
    const privateKey = createPrivateKey(readFileSync(at(`${signer}.key`)));
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
