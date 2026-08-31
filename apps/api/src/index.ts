import { budgetStatus, refreshBudget } from "./budget.ts";
import { PairRoom, type Env as PairEnv } from "./pair.ts";

export { PairRoom };

export interface Env extends PairEnv {
  PAIR: DurableObjectNamespace<PairRoom>;
  PAIR_RL: RateLimit;
  ASSETS: Fetcher;
}

const PAIR_PATH = /^\/pair\/([0-9a-f]{64})$/;

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    // Unauthenticated on purpose: it leaks a boolean and a byte count, and the app needs to know
    // whether relay is worth asking for before it goes looking for a peer.
    if (path === "/relay/status") return Response.json(await budgetStatus(env));
    const match = PAIR_PATH.exec(path);
    if (!match) return env.ASSETS.fetch(request);
    if (request.headers.get("Upgrade") !== "websocket") return new Response("websocket only", { status: 426 });
    const { success } = await env.PAIR_RL.limit({ key: request.headers.get("CF-Connecting-IP") ?? "" });
    if (!success) return new Response("slow down", { status: 429 });
    return env.PAIR.get(env.PAIR.idFromName(match[1])).fetch(request);
  },

  // Hourly (see "triggers" in wrangler.jsonc): refresh month-to-date TURN egress and flip the
  // kill switch. PRD R16.
  async scheduled(_controller, env, ctx) {
    ctx.waitUntil(refreshBudget(env));
  },
} satisfies ExportedHandler<Env>;
