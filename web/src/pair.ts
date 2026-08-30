import { DurableObject } from "cloudflare:workers";
import { verifyEntitlement } from "./apple";

// One room per pair of nodes, named sha256(lo.bytes ‖ hi.bytes) of the two 8-byte NodeIDs, so a room is
// addressable only by someone who already knows both IDs. Two authenticated slots; frames are forwarded
// opaquely between them, except `{"t":"relay"}` which the room answers itself.
const MAX_MESSAGE = 2048;
// A relay frame carries a StoreKit JWS with its whole x5c chain inline, several KiB of base64.
const MAX_RELAY = 16_384;
const AUTH_DEADLINE_MS = 5_000;
const PENDING_TTL_MS = 60_000;
const SWEEP_MS = 5_000;
const DOMAIN = "nearby-pair-v1";

type Slot = { since: number; nonce: string; nodeID?: string; peerID?: string };
type Pending = { at: number; message: string };
type Auth = { t: "auth"; nodeID: string; peerID: string; signingKey: string; sig: string };

export interface Env {
  APPLE_BUNDLE_ID: string;
  APPLE_PRODUCT_ID: string;
  APPLE_ROOT_CA_G3: string;
  // Extra trust anchor for the integration test only. Never set this in production.
  APPLE_TEST_ROOT?: string;
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
    const jws = parseRelay(message);
    if (jws !== null) return this.handleRelay(ws, jws);
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

  private async handleRelay(ws: WebSocket, jws: string): Promise<void> {
    const roots = [this.env.APPLE_ROOT_CA_G3, this.env.APPLE_TEST_ROOT].filter((root): root is string => !!root).map(base64);
    const entitlement = await verifyEntitlement(jws, {
      bundleId: this.env.APPLE_BUNDLE_ID,
      productId: this.env.APPLE_PRODUCT_ID,
      rootCertsDer: roots,
    });
    const reply = entitlement
      ? { t: "relay", ok: true, entitlement: entitlement.kind }
      : { t: "relay", ok: false, reason: "not entitled" };
    ws.send(JSON.stringify(reply));
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

// Returns the carried JWS for a relay frame (empty when malformed), or null for anything else,
// which stays opaque and gets forwarded.
function parseRelay(message: string): string | null {
  let value: unknown;
  try {
    value = JSON.parse(message);
  } catch {
    return null;
  }
  const frame = value as { t?: unknown; entitlement?: unknown };
  if (frame?.t !== "relay") return null;
  return typeof frame.entitlement === "string" ? frame.entitlement : "";
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

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}
