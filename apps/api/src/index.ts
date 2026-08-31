import { Hono } from "hono";
import { budgetStatus, refreshBudget } from "./budget.ts";
import { PairRoom, type Env as PairEnv } from "./pair.ts";

export { PairRoom };

export interface Env extends PairEnv {
  PAIR: DurableObjectNamespace<PairRoom>;
  PAIR_RL: RateLimit;
  ASSETS: Fetcher;
}

const app = new Hono<{ Bindings: Env }>();

// Unauthenticated on purpose: it leaks a boolean and a byte count, and the app needs to know
// whether relay is worth asking for before it goes looking for a peer.
app.get("/relay/status", async (c) => c.json(await budgetStatus(c.env)));

app.get("/pair/:room{[0-9a-f]{64}}", async (c) => {
  if (c.req.header("Upgrade") !== "websocket") return c.text("websocket only", 426);
  const { success } = await c.env.PAIR_RL.limit({ key: c.req.header("CF-Connecting-IP") ?? "" });
  if (!success) return c.text("slow down", 429);
  return c.env.PAIR.get(c.env.PAIR.idFromName(c.req.param("room"))).fetch(c.req.raw);
});

// Everything else is the apps/web static site.
app.notFound((c) => c.env.ASSETS.fetch(c.req.raw));

export default {
  fetch: app.fetch,

  // Hourly (see "triggers" in wrangler.jsonc): refresh month-to-date TURN egress and flip the
  // kill switch. PRD R16.
  async scheduled(_controller, env, ctx) {
    ctx.waitUntil(refreshBudget(env));
  },
} satisfies ExportedHandler<Env>;
