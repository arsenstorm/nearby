// PRD R15: each node gets a fixed number of relayed minutes per calendar month. Every granted
// TURN credential is one 10-minute block, charged up front — the app renews over the same socket,
// so a long call charges again rather than being metered.

// ponytail: KV is eventually consistent, so a node hammering several rooms at once can overshoot
// by a grant or two before the read catches up. That is a few minutes of TURN, not a business
// risk; if exactness ever matters, move the counter into a Durable Object.
export async function chargeAllowance(
  kv: KVNamespace,
  nodeID: string,
  minutes: number,
  limitMinutes: number,
  now = Date.now(),
): Promise<boolean> {
  const key = `allowance:${nodeID}:${month(now)}`;
  const used = Number((await kv.get(key)) ?? 0) || 0;
  if (used + minutes > limitMinutes) return false;
  // ~40 days outlives the longest month, so past months expire without a sweep.
  await kv.put(key, String(used + minutes), { expirationTtl: 40 * 24 * 60 * 60 });
  return true;
}

export function month(now: number): string {
  return new Date(now).toISOString().slice(0, 7);
}
