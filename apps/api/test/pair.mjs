#!/usr/bin/env node
// Integration test against a live `wrangler dev` instance: exercises the /pair/<room>
// Durable Object rendezvous protocol end to end (see src/pair.ts and src/index.ts).
import assert from "node:assert/strict";
import { generateKeyPairSync, sign as edSign, createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { makeAppAttest, makeChain } from "./chain.mjs";

const PORT = 8790;
const PAUSED_PORT = 8791;
const BASE = `http://127.0.0.1:${PORT}`;
const WS_BASE = `ws://127.0.0.1:${PORT}`;
const WEB_DIR = fileURLToPath(new URL("..", import.meta.url));
const DOMAIN = "nearby-pair-v1";
const BUNDLE_ID = "com.arsenstorm.nearby";
const TEAM_ID = "ABCDE12345";
// Two grants' worth, so the third relay in the run runs the node out of allowance (case j).
const ALLOWANCE_MINUTES = 20;

// ---- crypto / protocol helpers ----

function rawPublicKey(keyPair) {
  const jwk = keyPair.publicKey.export({ format: "jwk" });
  return Buffer.from(jwk.x, "base64url");
}

function nodeIdOf(keyPair) {
  const digest = createHash("sha256").update(rawPublicKey(keyPair)).digest();
  return digest.subarray(0, 8).toString("hex");
}

function roomName(idA, idB) {
  const [lo, hi] = [idA, idB].sort();
  const bytes = Buffer.concat([Buffer.from(lo, "hex"), Buffer.from(hi, "hex")]);
  return createHash("sha256").update(bytes).digest("hex");
}

function signChallenge(privateKey, nonceHex, room) {
  const data = Buffer.concat([Buffer.from(DOMAIN, "utf8"), Buffer.from(nonceHex, "hex"), Buffer.from(room, "utf8")]);
  return edSign(null, data, privateKey);
}

// ---- fake TURN key-server ----
// Stands in for Cloudflare's Realtime TURN API (see src/turn.ts) so the test never calls the
// real thing. `failNext` flips case h's single 500 without disturbing every other request.

const turnServer = { requests: 0, failNext: false };

function startTurnServer() {
  return new Promise((resolve) => {
    const server = createServer((req, res) => {
      if (req.method !== "POST" || req.url !== "/turn/keys/test-key/credentials/generate-ice-servers") {
        res.writeHead(404).end();
        return;
      }
      let body = "";
      req.on("data", (d) => (body += d));
      req.on("end", () => {
        turnServer.requests++;
        if (turnServer.failNext) {
          turnServer.failNext = false;
          res.writeHead(500).end();
          return;
        }
        assert.equal(req.headers.authorization, "Bearer test-token");
        assert.equal(body, JSON.stringify({ ttl: 600 }));
        res.writeHead(200, { "Content-Type": "application/json" }).end(
          JSON.stringify({
            // Cloudflare's documented shape: a STUN entry, then the TURN entry carrying credentials.
            iceServers: [
              { urls: ["stun:stun.cloudflare.com:3478"] },
              {
                urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turn:turn.cloudflare.com:3478?transport=tcp"],
                username: "u1",
                credential: "c1",
              },
            ],
          }),
        );
      });
    });
    server.listen(0, "127.0.0.1", () => resolve(server));
  });
}

// ---- wrangler dev lifecycle ----
// Two instances run side by side: the normal one, and a second with BUDGET_PAUSED_OVERRIDE set for
// case k. Separate --persist-to directories keep their KV and Durable Object state apart (and keep
// each run independent of the last).

const procs = [];
let turnServerHandle;
process.on("exit", () => {
  for (const proc of procs) {
    try {
      proc.kill();
    } catch {}
  }
  try {
    turnServerHandle?.close();
  } catch {}
});

function startWorker(port, vars) {
  const args = ["wrangler", "dev", "--port", String(port), "--local",
    // Both instances run at once, so neither may take the default inspector port.
    "--inspector-port", String(port + 1000),
    "--persist-to", mkdtempSync(join(tmpdir(), "nearby-wrangler-")),
    ...Object.entries(vars).flatMap(([name, value]) => ["--var", `${name}:${value}`])];
  const proc = spawn("npx", args, { cwd: WEB_DIR, stdio: ["ignore", "pipe", "pipe"] });
  proc.log = "";
  proc.stdout.on("data", (d) => (proc.log += d));
  proc.stderr.on("data", (d) => (proc.log += d));
  proc.on("error", (err) => console.error("failed to spawn wrangler:", err));
  procs.push(proc);
  return proc;
}

async function waitReady(url, timeoutMs = 60_000, intervalMs = 500) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      await fetch(url);
      return;
    } catch {}
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error(`server at ${url} not ready after ${timeoutMs}ms`);
}

// ---- websocket helpers ----

function nextMessage(ws) {
  return new Promise((resolve, reject) => {
    const onMessage = (ev) => {
      ws.removeEventListener("close", onClose);
      resolve(ev.data);
    };
    const onClose = (ev) => {
      ws.removeEventListener("message", onMessage);
      reject(Object.assign(new Error("closed before message"), { code: ev.code, reason: ev.reason }));
    };
    ws.addEventListener("message", onMessage, { once: true });
    ws.addEventListener("close", onClose, { once: true });
  });
}

function waitClose(ws) {
  return new Promise((resolve) => {
    ws.addEventListener("close", (ev) => resolve({ code: ev.code, reason: ev.reason }), { once: true });
  });
}

// Connects, completes the challenge/auth handshake, and resolves the socket once `{t:"ok"}`
// arrives. `room` is both the URL path segment and the room hashed into the signed challenge —
// that's what the server actually treats as the Durable Object's identity, independent of
// whatever peerID is claimed in the auth frame.
function connect(keys, myID, peerID, room, { signWith = keys, base = WS_BASE } = {}) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${base}/pair/${room}`);
    const onClose = (ev) => reject(Object.assign(new Error("closed before ok"), { code: ev.code, reason: ev.reason }));
    ws.addEventListener("close", onClose);
    ws.addEventListener("error", () => {});
    ws.addEventListener("message", function onMessage(ev) {
      const msg = JSON.parse(ev.data);
      if (msg.t === "challenge") {
        // The App Attest challenge is this socket's nonce, so relay frames need it later.
        ws.roomNonce = msg.nonce;
        const sig = signChallenge(signWith.privateKey, msg.nonce, room);
        const signingKey = Buffer.from(rawPublicKey(keys)).toString("base64");
        ws.send(JSON.stringify({ t: "auth", nodeID: myID, peerID, signingKey, sig: sig.toString("base64") }));
      } else if (msg.t === "ok") {
        ws.removeEventListener("message", onMessage);
        ws.removeEventListener("close", onClose);
        resolve(ws);
      }
    });
  });
}

// Same handshake, but resolves with the close code/reason instead of the socket — for the
// negative-path cases, where the server is expected to reject the auth attempt.
function attemptClose(keys, myID, peerID, room, { signWith = keys, timeoutMs = 10_000 } = {}) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${WS_BASE}/pair/${room}`);
    const timer = setTimeout(() => {
      reject(new Error("timed out waiting for close"));
      ws.close();
    }, timeoutMs);
    ws.addEventListener("close", (ev) => {
      clearTimeout(timer);
      resolve({ code: ev.code, reason: ev.reason });
    });
    ws.addEventListener("error", () => {});
    ws.addEventListener("message", (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.t === "challenge") {
        const sig = signChallenge(signWith.privateKey, msg.nonce, room);
        const signingKey = Buffer.from(rawPublicKey(keys)).toString("base64");
        ws.send(JSON.stringify({ t: "auth", nodeID: myID, peerID, signingKey, sig: sig.toString("base64") }));
      }
    });
  });
}

// ---- test run ----

// The relay request frame the Worker now expects: entitlement JWS, App Attest keyId, the
// attestation on first contact, and an assertion over utf8(jws) ‖ unhex(roomNonce) every time.
function relayFrame(ws, jws, credential, counter, { attestation = false, assertion = true } = {}) {
  const clientData = Buffer.concat([Buffer.from(jws, "utf8"), Buffer.from(ws.roomNonce, "hex")]);
  return JSON.stringify({
    t: "relay",
    entitlement: jws,
    keyId: credential.keyId.toString("base64"),
    ...(attestation ? { attestation: credential.attestation.toString("base64") } : {}),
    ...(assertion ? { assertion: credential.assertion(clientData, counter).toString("base64") } : {}),
  });
}

async function main() {
  // The room trusts APPLE_TEST_ROOT and APP_ATTEST_TEST_ROOT on top of the pinned Apple roots, so
  // the throwaway chains below verify in the Worker. Neither var is ever set in production.
  const chain = makeChain();
  const attest = makeAppAttest({ teamId: TEAM_ID, bundleId: BUNDLE_ID });
  turnServerHandle = await startTurnServer();
  const vars = {
    APPLE_TEST_ROOT: chain.rootDer.toString("base64"),
    APP_ATTEST_TEST_ROOT: attest.rootDer.toString("base64"),
    APP_ATTEST_TEAM_ID: TEAM_ID,
    ALLOWANCE_MINUTES: String(ALLOWANCE_MINUTES),
    TURN_KEY_ID: "test-key",
    TURN_API_TOKEN: "test-token",
    TURN_API_BASE: `http://127.0.0.1:${turnServerHandle.address().port}`,
  };
  startWorker(PORT, vars);
  startWorker(PAUSED_PORT, { ...vars, BUDGET_PAUSED_OVERRIDE: "1" });

  try {
    await Promise.all([waitReady(`${BASE}/`), waitReady(`http://127.0.0.1:${PAUSED_PORT}/`)]);
  } catch (err) {
    console.error(procs.map((p) => p.log).join("\n"));
    throw err;
  }

  const A = generateKeyPairSync("ed25519");
  const B = generateKeyPairSync("ed25519");
  const C = generateKeyPairSync("ed25519");
  const idA = nodeIdOf(A);
  const idB = nodeIdOf(B);
  const idC = nodeIdOf(C);
  const roomAB = roomName(idA, idB);
  const roomAC = roomName(idA, idC);

  // a. Both connect; frames forward verbatim in both directions.
  let wsA = await connect(A, idA, idB, roomAB);
  let wsB = await connect(B, idB, idA, roomAB);
  const helloA = JSON.stringify({ t: "hello", from: "A" });
  wsA.send(helloA);
  assert.equal(await nextMessage(wsB), helloA);
  const helloB = JSON.stringify({ t: "hello", from: "B" });
  wsB.send(helloB);
  assert.equal(await nextMessage(wsA), helloB);
  console.log("a. live forwarding both directions: pass");

  // b. Pending message is delivered as the first frame on reconnect.
  wsA.close();
  wsB.close();
  await Promise.all([waitClose(wsA), waitClose(wsB)]);
  wsA = await connect(A, idA, idB, roomAB);
  const late = JSON.stringify({ t: "hello", late: true });
  wsA.send(late);
  wsB = await connect(B, idB, idA, roomAB);
  assert.equal(await nextMessage(wsB), late);
  console.log("b. pending message delivered on reconnect: pass");

  // c. Bad signature (signed with the wrong node's private key) closes 1008.
  {
    const { code } = await attemptClose(A, idA, idB, roomAB, { signWith: B });
    assert.equal(code, 1008);
  }
  console.log("c. bad signature closes 1008: pass");

  // d. Claimed peerID doesn't match the room hashed into the URL: closes 1008.
  {
    const { code } = await attemptClose(A, idA, idB, roomAC);
    assert.equal(code, 1008);
  }
  console.log("d. wrong room closes 1008: pass");

  // e. Third party impersonating a known peer fails the room-hash check: closes 1008.
  {
    const { code } = await attemptClose(C, idC, idA, roomAB);
    assert.equal(code, 1008);
  }
  console.log("e. third-party impersonation closes 1008: pass");

  // f. Oversize frame from an authenticated peer closes 1009.
  {
    const closed = waitClose(wsA);
    wsA.send("x".repeat(3000));
    const { code } = await closed;
    assert.equal(code, 1009);
  }
  console.log("f. oversize frame closes 1009: pass");

  // g. Relay frames are answered to the sender and never forwarded to the peer. The first one
  // also registers A's App Attest key, so it carries the attestation; later ones assert only.
  wsA = await connect(A, idA, idB, roomAB);
  const credential = attest.credential(Buffer.from(wsA.roomNonce, "hex"));
  const jws = chain.jws({ bundleId: BUNDLE_ID, receiptType: "Sandbox" });
  {
    const before = turnServer.requests;
    wsA.send(relayFrame(wsA, jws, credential, 1, { attestation: true }));
    assert.deepEqual(JSON.parse(await nextMessage(wsA)), {
      t: "relay",
      ok: true,
      entitlement: "beta",
      turn: { host: "turn.cloudflare.com", port: 3478, username: "u1", credential: "c1", ttl: 600 },
    });
    assert.equal(turnServer.requests, before + 1);
    wsA.send(relayFrame(wsA, "garbage", credential, 2));
    assert.deepEqual(JSON.parse(await nextMessage(wsA)), { t: "relay", ok: false, reason: "not entitled" });
    // Whatever B sees next must be this frame, so neither relay frame reached it.
    const after = JSON.stringify({ t: "hello", after: "relay" });
    wsA.send(after);
    assert.equal(await nextMessage(wsB), after);
  }
  console.log("g. relay answered locally, not forwarded: pass");

  // h. TURN key-server failure doesn't crash the room; the caller sees ok:false instead.
  {
    turnServer.failNext = true;
    wsA.send(relayFrame(wsA, jws, credential, 3));
    assert.deepEqual(JSON.parse(await nextMessage(wsA)), { t: "relay", ok: false, reason: "relay unavailable" });
  }
  console.log("h. TURN mint failure replies ok:false: pass");

  // i. No assertion at all: entitlement alone buys nothing (PRD R17).
  {
    wsA.send(relayFrame(wsA, jws, credential, 4, { assertion: false }));
    assert.deepEqual(JSON.parse(await nextMessage(wsA)), { t: "relay", ok: false, reason: "attestation required" });
  }
  console.log("i. missing assertion rejected: pass");

  // j. Allowance (PRD R15): g and h each charged a 10-minute grant, exhausting the 20 above.
  {
    wsA.send(relayFrame(wsA, jws, credential, 5));
    assert.deepEqual(JSON.parse(await nextMessage(wsA)), { t: "relay", ok: false, reason: "allowance exhausted" });
    assert.deepEqual(await (await fetch(`${BASE}/relay/status`)).json(), { paused: false, monthBytes: 0 });
  }
  console.log("j. allowance exhausted after two grants: pass");

  // k. Budget kill switch (PRD R16): the paused instance refuses everyone, before it even looks
  // at attestation or entitlement.
  {
    const pausedBase = `http://127.0.0.1:${PAUSED_PORT}`;
    const wsP = await connect(A, idA, idB, roomAB, { base: `ws://127.0.0.1:${PAUSED_PORT}` });
    wsP.send(relayFrame(wsP, jws, credential, 1, { attestation: true }));
    assert.deepEqual(JSON.parse(await nextMessage(wsP)), { t: "relay", ok: false, reason: "relay paused" });
    assert.deepEqual(await (await fetch(`${pausedBase}/relay/status`)).json(), { paused: true, monthBytes: 0 });
    wsP.close();
  }
  console.log("k. relay paused while over budget: pass");

  console.log("all cases passed");
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("FAIL:", err);
    process.exit(1);
  });
