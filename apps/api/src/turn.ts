// Mints short-lived Cloudflare Realtime TURN credentials for a pair room, so two peers that can't
// punch through NAT can still relay media without either side holding a long-lived secret.

export type TurnCredentials = { host: string; port: number; username: string; credential: string; ttl: number };

const ICE_URL = /^turn:([^:?]+):(\d+)\?transport=udp$/;

export async function mintTurnCredentials(
  env: { TURN_KEY_ID: string; TURN_API_TOKEN: string; TURN_API_BASE?: string },
  ttlSeconds: number,
): Promise<TurnCredentials | null> {
  const base = env.TURN_API_BASE ?? "https://rtc.live.cloudflare.com/v1";
  let response: Response;
  try {
    response = await fetch(`${base}/turn/keys/${env.TURN_KEY_ID}/credentials/generate-ice-servers`, {
      method: "POST",
      headers: { Authorization: `Bearer ${env.TURN_API_TOKEN}`, "Content-Type": "application/json" },
      body: JSON.stringify({ ttl: ttlSeconds }),
      signal: AbortSignal.timeout(5000),
    });
  } catch {
    return null;
  }
  if (!response.ok) return null;
  let body: unknown;
  try {
    body = await response.json();
  } catch {
    return null;
  }
  // Documented shape is a list (STUN entry, then the TURN entry with credentials); a bare object is
  // tolerated in case the API ever collapses it.
  type IceServer = { urls?: unknown; username?: unknown; credential?: unknown };
  const servers = (body as { iceServers?: IceServer | IceServer[] })?.iceServers;
  const ice = (Array.isArray(servers) ? servers : [servers]).find((s) => typeof s?.username === "string");
  const username = ice?.username;
  const credential = ice?.credential;
  if (typeof username !== "string" || typeof credential !== "string") return null;
  const urls = Array.isArray(ice?.urls) ? ice.urls : [];
  const match = urls.map((url) => (typeof url === "string" ? ICE_URL.exec(url) : null)).find((m): m is RegExpExecArray => m !== null);
  const [host, port] = match ? [match[1], Number(match[2])] : ["turn.cloudflare.com", 3478];
  return { host, port, username, credential, ttl: ttlSeconds };
}
