// Counters, the only thing the relay logs about its traffic (never tokens or payloads).
// index.ts prints them once an hour and starts over.

export type SendStatus = "ok" | "gone" | "invalid" | "limited" | "error";
export type Counter = "register" | "rejected" | SendStatus;

export class Stats {
  private counts = new Map<Counter, number>();

  count(name: Counter, n = 1): void {
    this.counts.set(name, (this.counts.get(name) ?? 0) + n);
  }

  /** "register=3 ok=12 …" since the last flush, or "" when nothing happened. */
  flush(): string {
    const line = [...this.counts].map(([name, n]) => `${name}=${n}`).join(" ");
    this.counts.clear();
    return line;
  }
}
