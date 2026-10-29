// The worker's assistant loop: every tick (a second) one cheap query finds the chats that wait
// for a turn — a running chat nobody holds (the web process just saved a message, or the worker
// that held it died) or an idle chat with messages waiting — claims each with a new token and
// runs it WITHOUT awaiting (at most `maxConcurrent` at once). For the turns it runs, the tick
// also notices a stop or a deleted chat right away (a turn renews its hold every 5 s anyway).

import { randomToken } from "@/lib/api/http";
import { DrizzleCalendarStore } from "@/lib/calendar/store";
import { type RunnerEnv, Runner, leaseUntil } from "./chats";
import { type AiEnv, prepareTurn } from "./routes";
import { DrizzleAssistantStore } from "./store";

export class ChatRunner {
  private readonly running = new Map<string, Runner>();
  /** The token each running turn holds its chat with. */
  private readonly tokens = new Map<string, string>();
  private stopped = false;
  private readonly done = new Map<string, Promise<void>>();
  private readonly env: RunnerEnv;
  private readonly store: DrizzleAssistantStore;

  constructor(
    env: AiEnv,
    private readonly maxConcurrent: number = Math.max(1, Number(process.env.ASSISTANT_MAX_CONCURRENT) || 4),
    private readonly log: (msg: string) => void = (m) => console.log(`[assistant] ${m}`),
  ) {
    const store = env.store instanceof DrizzleAssistantStore ? env.store : new DrizzleAssistantStore(env.db);
    this.store = store;
    const calendar = new DrizzleCalendarStore(env.db);
    this.env = {
      ...env,
      store,
      prepare: (chat, family, context, signal) => prepareTurn(env, chat, family, context, signal),
      family: (id) => calendar.getFamily(id),
    };
  }

  get active(): number {
    return this.running.size;
  }

  /** Stops or drops the turns whose chats asked for it, then claims and starts chats that wait
   *  for a turn; returns how many were started. Never throws. */
  tick(now = new Date()): number {
    let started = 0;
    if (this.stopped) return 0;
    try {
      const flags = this.store.chatFlags([...this.running.keys()]);
      for (const [id, runner] of this.running) {
        const f = flags.get(id);
        if (!f) runner.abort.abort("lost");
        else if (f.stop) runner.abort.abort("stop");
      }
      if (this.running.size >= this.maxConcurrent) return 0;
      for (const chat of this.store.pendingChats(now)) {
        if (this.running.size >= this.maxConcurrent) break;
        if (this.running.has(chat.id)) continue;
        if (this.start(chat.id, chat.status, chat.held)) started += 1;
      }
    } catch (err) {
      console.error("[assistant] tick failed:", err);
    }
    return started;
  }

  private start(id: string, status: "idle" | "running", held: boolean): boolean {
    const token = randomToken(32);
    if (!this.store.claimChatNow(id, token, leaseUntil(this.env), status === "idle" ? "start" : "resume")) return false;
    if (held) this.log(`taking over the turn of chat ${id}`);
    const runner = new Runner(this.env, id, token);
    this.running.set(id, runner);
    this.tokens.set(id, token);
    const p = runner
      .drive(held)
      .catch((err) => console.error(`[assistant] chat ${id} failed:`, err))
      .finally(() => {
        this.running.delete(id);
        this.done.delete(id);
        this.tokens.delete(id);
        // Messages may wait already: the next turn starts without waiting for the tick.
        this.tick();
      });
    this.done.set(id, p);
    return true;
  }

  /** Waits for the running turns until all ended or `ms` passed. */
  async idle(ms = Infinity): Promise<void> {
    const until = Date.now() + ms;
    while (this.done.size && Date.now() < until) {
      await Promise.race([Promise.allSettled([...this.done.values()]), new Promise((r) => setTimeout(r, Math.min(50, until - Date.now())))]);
    }
  }

  /** Stops: the turns end where they are, and their chats are let go, so the next worker takes
   *  them over right away (as a worker that died, once its hold ran out). */
  async stop(ms: number): Promise<void> {
    this.stopped = true;
    const held = new Map(this.tokens);
    for (const runner of this.running.values()) runner.abort.abort("lost");
    await this.idle(ms);
    const past = new Date(0).toISOString();
    for (const [id, token] of held) {
      // Only while this worker still holds it (a turn that ended let go of it already).
      await this.store.updateChat(id, { run_until: past }, token).catch(() => null);
    }
  }
}
