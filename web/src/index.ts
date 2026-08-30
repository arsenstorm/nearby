import { PairRoom, type Env as PairEnv } from "./pair";

export { PairRoom };

export interface Env extends PairEnv {
  PAIR: DurableObjectNamespace<PairRoom>;
  PAIR_RL: RateLimit;
  ASSETS: Fetcher;
}

const PAIR_PATH = /^\/pair\/([0-9a-f]{64})$/;

export default {
  async fetch(request, env) {
    const match = PAIR_PATH.exec(new URL(request.url).pathname);
    if (!match) return env.ASSETS.fetch(request);
    if (request.headers.get("Upgrade") !== "websocket") return new Response("websocket only", { status: 426 });
    const { success } = await env.PAIR_RL.limit({ key: request.headers.get("CF-Connecting-IP") ?? "" });
    if (!success) return new Response("slow down", { status: 429 });
    return env.PAIR.get(env.PAIR.idFromName(match[1])).fetch(request);
  },
} satisfies ExportedHandler<Env>;
