import { DurableObject } from "cloudflare:workers";
import { chargeAllowance } from "./allowance.ts";
import { verifyEntitlement } from "./apple.ts";
import { verifyAssertion, verifyAttestation } from "./attest.ts";
import { relayPaused, type BudgetEnv } from "./budget.ts";
import { mintTurnCredentials } from "./turn.ts";
import { concat } from "./x509.ts";

// One room per pair of nodes, named sha256(lo.bytes ‖ hi.bytes) of the two 8-byte NodeIDs, so a room is
// addressable only by someone who already knows both IDs. Two authenticated slots; frames are forwarded
// opaquely between them, except `{"t":"relay"}` which the room answers itself.
const MAX_MESSAGE = 2048;
// A relay frame carries a StoreKit JWS with its whole x5c chain inline plus, on a node's first
// request, an App Attest attestation object — together a good 12 KiB of base64.
const MAX_RELAY = 24_576;
const AUTH_DEADLINE_MS = 5_000;
const PENDING_TTL_MS = 60_000;
const SWEEP_MS = 5_000;
const DOMAIN = "nearby-pair-v1";
// PRD R9: 10-minute TURN credentials, renewed by the app over this same socket.
const RELAY_TTL_S = 600;

type Slot = { since: number; nonce: string; nodeID?: string; peerID?: string };
type Pending = { at: number; message: string };
type Auth = { t: "auth"; nodeID: string; peerID: string; signingKey: string; sig: string };
type Relay = { entitlement: string; keyId: string; attestation: string; assertion: string };
// What we remember per node between relay requests: the App Attest key and its replay counter.
type Attested = { spki: string; counter: number };

export interface Env extends BudgetEnv {
  APPLE_BUNDLE_ID: string;
  APPLE_PRODUCT_ID: string;
  APPLE_ROOT_CA_G3: string;
  // Extra trust anchor for the integration test only. Never set this in production.
  APPLE_TEST_ROOT?: string;
  APP_ATTEST_TEAM_ID: string;
  APP_ATTEST_BUNDLE_ID: string;
  APP_ATTEST_ROOT: string;
  // Extra App Attest trust anchor for the integration test only. Never set this in production.
  APP_ATTEST_TEST_ROOT?: string;
  ALLOWANCE_MINUTES: string;
  // Test-deploy overrides only (`wrangler deploy --var`): mint for any authenticated slot, and a
  // shorter credential lifetime so renewal comes round sooner.
  RELAY_UNGATED?: string;
  RELAY_TTL_S?: string;
  TURN_KEY_ID: string;
  TURN_API_TOKEN: string;
  // Only overridden by tests, against a fake local server.
  TURN_API_BASE?: string;
}

export class PairRoom extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") return new Response("websocket only", { status: 426 });
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server);
    const nonce = hex(crypto.getRandomValues(new Uint8Array(32)));
    server.serializeAttachment({ since: Date.now(), nonce } satisfies Slot);
    server.send(JSON.stringify({ t: "challenge", nonce }));
    await this.ctx.storage.setAlarm(Date.now() + SWEEP_MS);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") return ws.close(1003, "text frames only");
    if (message.length > MAX_RELAY) return ws.close(1009, "too big");
    const slot = ws.deserializeAttachment() as Slot;
    if (!slot.nodeID || !slot.peerID) {
      if (message.length > MAX_MESSAGE) return ws.close(1009, "too big");
      return this.authenticate(ws, slot, message);
    }
    const relay = parseRelay(message);
    if (relay !== null) return this.handleRelay(ws, slot, relay);
    if (message.length > MAX_MESSAGE) return ws.close(1009, "too big");
    return this.forward(slot.nodeID, slot.peerID, message);
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    for (const ws of this.ctx.getWebSockets()) {
      const slot = ws.deserializeAttachment() as Slot;
      if (!slot.nodeID && now - slot.since > AUTH_DEADLINE_MS) ws.close(1008, "auth timeout");
    }
    const pending = await this.ctx.storage.list<Pending>({ prefix: "pending:" });
    for (const [key, value] of pending) if (now - value.at > PENDING_TTL_MS) await this.ctx.storage.delete(key);
    const busy = this.ctx.getWebSockets().length > 0 || pending.size > 0;
    if (busy) await this.ctx.storage.setAlarm(now + SWEEP_MS);
  }

  private async authenticate(ws: WebSocket, slot: Slot, message: string): Promise<void> {
    const auth = parseAuth(message);
    if (!auth || !(await this.verify(auth, slot.nonce))) return ws.close(1008, "bad auth");
    if (this.occupiedByOthers(auth.nodeID)) return ws.close(1013, "full");
    for (const other of this.ctx.getWebSockets()) {
      if (other !== ws && (other.deserializeAttachment() as Slot).nodeID === auth.nodeID) other.close(1000, "replaced");
    }
    ws.serializeAttachment({ ...slot, nodeID: auth.nodeID, peerID: auth.peerID } satisfies Slot);
    ws.send(JSON.stringify({ t: "ok" }));
    const key = `pending:${auth.nodeID}`;
    const pending = await this.ctx.storage.get<Pending>(key);
    if (!pending) return;
    ws.send(pending.message);
    await this.ctx.storage.delete(key);
  }

  private async verify(auth: Auth, nonce: string): Promise<boolean> {
    const signingKey = base64(auth.signingKey);
    if (signingKey.length !== 32 || auth.nodeID === auth.peerID) return false;
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", signingKey));
    if (hex(digest.subarray(0, 8)) !== auth.nodeID) return false;
    // Fixed-width hex sorts the same as the numeric NodeID order the app uses for lo/hi.
    const [lo, hi] = [auth.nodeID, auth.peerID].sort();
    const room = new Uint8Array(await crypto.subtle.digest("SHA-256", concat(unhex(lo), unhex(hi))));
    if (hex(room) !== this.ctx.id.name) return false;
    const key = await crypto.subtle.importKey("raw", signingKey, { name: "Ed25519" }, false, ["verify"]);
    const signed = concat(new TextEncoder().encode(DOMAIN), unhex(nonce), new TextEncoder().encode(this.ctx.id.name!));
    return crypto.subtle.verify("Ed25519", key, base64(auth.sig), signed);
  }

  private occupiedByOthers(nodeID: string): boolean {
    const ids = new Set<string>();
    for (const ws of this.ctx.getWebSockets()) {
      const id = (ws.deserializeAttachment() as Slot).nodeID;
      if (id && id !== nodeID) ids.add(id);
    }
    return ids.size >= 2;
  }

  // A relay request is always answered, never fatal: a peer that is out of allowance or fails
  // attestation keeps its socket and carries on trying to connect directly.
  private async handleRelay(ws: WebSocket, slot: Slot, relay: Relay): Promise<void> {
    const reply = await this.grantRelay(slot, relay);
    // Refusals are the only relay outcome worth a log line: `wrangler tail` is how they get diagnosed.
    if (!reply.ok) console.log(`relay refused ${slot.nodeID}: ${reply.reason}`);
    ws.send(JSON.stringify({ t: "relay", ...reply }));
  }

  private async grantRelay(slot: Slot, relay: Relay): Promise<Record<string, unknown>> {
    if (await relayPaused(this.env)) return { ok: false, reason: "relay paused" };
    const ttl = Number(this.env.RELAY_TTL_S) || RELAY_TTL_S;
    // Simulators can neither attest nor hold an entitlement, so a relay test between two of them
    // needs a manual deploy with `--var RELAY_UNGATED:1`; never set it in wrangler.jsonc.
    if (this.env.RELAY_UNGATED === "1") {
      const turn = await mintTurnCredentials(this.env, ttl);
      return turn ? { ok: true, entitlement: "ungated", turn } : { ok: false, reason: "relay unavailable" };
    }
    if (!(await this.attested(slot, relay))) return { ok: false, reason: "attestation required" };
    const roots = anchors(this.env.APPLE_ROOT_CA_G3, this.env.APPLE_TEST_ROOT);
    const entitlement = await verifyEntitlement(relay.entitlement, {
      bundleId: this.env.APPLE_BUNDLE_ID,
      productId: this.env.APPLE_PRODUCT_ID,
      rootCertsDer: roots,
    });
    if (!entitlement) return { ok: false, reason: "not entitled" };
    const limit = Number(this.env.ALLOWANCE_MINUTES);
    if (!(await chargeAllowance(this.env.RELAY, slot.nodeID!, ttl / 60, limit))) {
      return { ok: false, reason: "allowance exhausted" };
    }
    const turn = await mintTurnCredentials(this.env, ttl);
    return turn ? { ok: true, entitlement: entitlement.kind, turn } : { ok: false, reason: "relay unavailable" };
  }

  // App Attest (PRD R17). A node registers once with an attestation, then proves possession of the
  // same key on every request with an assertion over `clientData` (see clientData() below).
  private async attested(slot: Slot, relay: Relay): Promise<boolean> {
    const opts = {
      teamId: this.env.APP_ATTEST_TEAM_ID,
      bundleId: this.env.APP_ATTEST_BUNDLE_ID,
      rootsDer: anchors(this.env.APP_ATTEST_ROOT, this.env.APP_ATTEST_TEST_ROOT),
    };
    const key = `attest:${slot.nodeID}`;
    let stored = await this.env.RELAY.get<Attested>(key, "json");
    // A fresh attestation replaces the stored key: a client that lost or reset its key must be able to re-enrol.
    if (!stored || relay.attestation) {
      if (!relay.attestation) return refuse("no attestation and no registered key");
      const keyId = base64(relay.keyId);
      const fresh = await verifyAttestation(base64(relay.attestation), unhex(slot.nonce), keyId, opts);
      if (!fresh) return refuse(`attestation rejected (${relay.attestation.length} chars, keyId ${relay.keyId.length} chars)`);
      stored = { spki: b64(fresh.publicKeySpki), counter: 0 };
    }
    const data = clientData(relay.entitlement, slot.nonce);
    const counter = await verifyAssertion(base64(relay.assertion), data, { ...opts, spki: base64(stored.spki), counter: stored.counter });
    if (counter === null) return refuse(`assertion rejected (stored counter ${stored.counter})`);
    await this.env.RELAY.put(key, JSON.stringify({ spki: stored.spki, counter } satisfies Attested));
    return true;
  }

  private async forward(from: string, to: string, message: string): Promise<void> {
    for (const ws of this.ctx.getWebSockets()) {
      const slot = ws.deserializeAttachment() as Slot;
      if (slot.nodeID === to) return ws.send(message);
    }
    // Peer not here yet: hold the latest frame so a connect race still resolves.
    await this.ctx.storage.put(`pending:${to}`, { at: Date.now(), message } satisfies Pending);
  }
}

function parseAuth(message: string): Auth | null {
  let value: unknown;
  try {
    value = JSON.parse(message);
  } catch {
    return null;
  }
  const auth = value as Partial<Auth>;
  const id = /^[0-9a-f]{16}$/;
  const ok =
    auth?.t === "auth" &&
    typeof auth.nodeID === "string" && id.test(auth.nodeID) &&
    typeof auth.peerID === "string" && id.test(auth.peerID) &&
    typeof auth.signingKey === "string" &&
    typeof auth.sig === "string";
  return ok ? (auth as Auth) : null;
}

// Returns a relay frame's fields (missing ones become empty strings, which fail their own check
// further down), or null for anything else, which stays opaque and gets forwarded.
function parseRelay(message: string): Relay | null {
  let value: unknown;
  try {
    value = JSON.parse(message);
  } catch {
    return null;
  }
  const frame = value as Record<string, unknown>;
  if (frame?.t !== "relay") return null;
  const field = (name: keyof Relay) => (typeof frame[name] === "string" ? (frame[name] as string) : "");
  return { entitlement: field("entitlement"), keyId: field("keyId"), attestation: field("attestation"), assertion: field("assertion") };
}

// The bytes the App Attest assertion signs over. Binding the entitlement JWS stops a stolen
// assertion from being paired with someone else's subscription, and the room nonce — fresh per
// socket — stops it from being replayed into a new connection. The iOS client must build exactly
// these bytes as its clientData.
function clientData(jws: string, roomNonce: string): Uint8Array {
  return concat(new TextEncoder().encode(jws), unhex(roomNonce));
}

function anchors(...roots: (string | undefined)[]): Uint8Array[] {
  return roots.filter((root): root is string => !!root).map(base64);
}

function b64(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes));
}

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function unhex(text: string): Uint8Array {
  return Uint8Array.from(text.match(/../g) ?? [], (pair) => parseInt(pair, 16));
}

function base64(text: string): Uint8Array {
  try {
    return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
  } catch {
    return new Uint8Array();
  }
}

function refuse(why: string): false {
  console.log(`attest: ${why}`);
  return false;
}
