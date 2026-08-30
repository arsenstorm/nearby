#!/usr/bin/env node
// Integration test against a live `wrangler dev` instance: exercises the /pair/<room>
// Durable Object rendezvous protocol end to end (see src/pair.ts and src/index.ts).
import assert from "node:assert/strict";
import { generateKeyPairSync, sign as edSign, createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { makeChain } from "./chain.mjs";

const PORT = 8790;
const BASE = `http://127.0.0.1:${PORT}`;
const WS_BASE = `ws://127.0.0.1:${PORT}`;
const WEB_DIR = fileURLToPath(new URL("..", import.meta.url));
const DOMAIN = "nearby-pair-v1";
const BUNDLE_ID = "com.arsenstorm.nearby";

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

// ---- wrangler dev lifecycle ----

let proc;
process.on("exit", () => {
  try {
    proc?.kill();
  } catch {}
});

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
function connect(keys, myID, peerID, room, { signWith = keys } = {}) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${WS_BASE}/pair/${room}`);
    const onClose = (ev) => reject(Object.assign(new Error("closed before ok"), { code: ev.code, reason: ev.reason }));
    ws.addEventListener("close", onClose);
    ws.addEventListener("error", () => {});
    ws.addEventListener("message", function onMessage(ev) {
      const msg = JSON.parse(ev.data);
      if (msg.t === "challenge") {
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

async function main() {
  // The room trusts APPLE_TEST_ROOT on top of the pinned Apple root, so the throwaway chain
  // below verifies in the Worker. That var is never set in production (see wrangler.jsonc).
  const chain = makeChain();
  const testRoot = chain.rootDer.toString("base64");
  const args = ["wrangler", "dev", "--port", String(PORT), "--local", "--var", `APPLE_TEST_ROOT:${testRoot}`];
  proc = spawn("npx", args, {
    cwd: WEB_DIR,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let out = "";
  proc.stdout.on("data", (d) => (out += d));
  proc.stderr.on("data", (d) => (out += d));
  proc.on("error", (err) => {
    console.error("failed to spawn wrangler:", err);
  });

  try {
    await waitReady(`${BASE}/`);
  } catch (err) {
    console.error(out);
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

  // g. Relay frames are answered to the sender and never forwarded to the peer.
  wsA = await connect(A, idA, idB, roomAB);
  {
    const jws = chain.jws({ bundleId: BUNDLE_ID, receiptType: "Sandbox" });
    wsA.send(JSON.stringify({ t: "relay", entitlement: jws }));
    assert.deepEqual(JSON.parse(await nextMessage(wsA)), { t: "relay", ok: true, entitlement: "beta" });
    wsA.send(JSON.stringify({ t: "relay", entitlement: "garbage" }));
    assert.deepEqual(JSON.parse(await nextMessage(wsA)), { t: "relay", ok: false, reason: "not entitled" });
    // Whatever B sees next must be this frame, so neither relay frame reached it.
    const after = JSON.stringify({ t: "hello", after: "relay" });
    wsA.send(after);
    assert.equal(await nextMessage(wsB), after);
  }
  console.log("g. relay answered locally, not forwarded: pass");

  console.log("all cases passed");
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("FAIL:", err);
    process.exit(1);
  });
