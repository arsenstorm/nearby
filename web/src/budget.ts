// PRD R16: a kill switch, not a meter. An hourly cron pulls month-to-date TURN egress from
// Cloudflare's GraphQL analytics; once it crosses BUDGET_GB the Worker stops minting credentials
// for everyone, so a runaway month costs a capped amount instead of an unbounded one.

import { month } from "./allowance.ts";

export interface BudgetEnv {
  RELAY: KVNamespace;
  CF_ACCOUNT_ID: string;
  CF_ANALYTICS_TOKEN: string;
  BUDGET_GB: string;
  // Test-only: forces the paused answer without a KV write. Never set in production.
  BUDGET_PAUSED_OVERRIDE?: string;
}

const GRAPHQL = "https://api.cloudflare.com/client/v4/graphql";

// UNCONFIRMED: `callsTurnUsageAdaptiveGroups` / `egressBytes` is our best reading of the Realtime
// TURN dataset. Confirm the node and field names against the account's own schema before deploy —
// https://developers.cloudflare.com/analytics/graphql-api/ (introspect, or use the GraphQL
// explorer). A wrong name returns an `errors` array, which lands in the catch below and leaves the
// kill switch untouched, so a bad guess fails open, not closed.
const QUERY = `query Turn($account: String!, $start: Time!) {
  viewer {
    accounts(filter: { accountTag: $account }) {
      callsTurnUsageAdaptiveGroups(limit: 10000, filter: { datetime_geq: $start }) {
        sum { egressBytes }
      }
    }
  }
}`;

export async function refreshBudget(env: BudgetEnv, now = Date.now()): Promise<number> {
  try {
    const start = `${month(now)}-01T00:00:00Z`;
    const response = await fetch(GRAPHQL, {
      method: "POST",
      headers: { Authorization: `Bearer ${env.CF_ANALYTICS_TOKEN}`, "Content-Type": "application/json" },
      body: JSON.stringify({ query: QUERY, variables: { account: env.CF_ACCOUNT_ID, start } }),
      signal: AbortSignal.timeout(10_000),
    });
    const bytes = egressBytes(await response.json());
    await env.RELAY.put(`budget:month:${month(now)}`, String(bytes));
    const limit = Number(env.BUDGET_GB) * 1e9;
    if (bytes > limit) await env.RELAY.put("budget:paused", "1");
    else await env.RELAY.delete("budget:paused");
    return bytes;
  } catch (error) {
    // Leave the previous verdict in place: a broken analytics call must not silently un-pause.
    console.error("budget refresh failed", error);
    return -1;
  }
}

type Groups = { sum?: { egressBytes?: number } }[];

function egressBytes(body: unknown): number {
  const payload = body as { errors?: unknown[]; data?: { viewer?: { accounts?: { callsTurnUsageAdaptiveGroups?: Groups }[] } } };
  if (payload?.errors?.length) throw new Error(JSON.stringify(payload.errors));
  const groups = payload?.data?.viewer?.accounts?.[0]?.callsTurnUsageAdaptiveGroups;
  if (!Array.isArray(groups)) throw new Error("no turn usage in response");
  return groups.reduce((total, group) => total + (group?.sum?.egressBytes ?? 0), 0);
}

export async function relayPaused(env: BudgetEnv): Promise<boolean> {
  if (env.BUDGET_PAUSED_OVERRIDE) return true;
  return (await env.RELAY.get("budget:paused")) === "1";
}

export async function budgetStatus(env: BudgetEnv, now = Date.now()): Promise<{ paused: boolean; monthBytes: number }> {
  const monthBytes = Number((await env.RELAY.get(`budget:month:${month(now)}`)) ?? 0) || 0;
  return { paused: await relayPaused(env), monthBytes };
}
