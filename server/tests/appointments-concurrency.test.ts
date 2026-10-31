import { describe, expect, it } from "vitest";
import { mapPool } from "@/lib/appointments/concurrency";

const tick = () => new Promise((r) => setTimeout(r, 5));

describe("mapPool", () => {
  it("maps items preserving input order", async () => {
    const out = await mapPool([1, 2, 3, 4], 2, async (n) => {
      await tick();
      return n * 10;
    });
    expect(out).toEqual([10, 20, 30, 40]);
  });

  it("never exceeds the concurrency limit", async () => {
    let inFlight = 0;
    let peak = 0;
    await mapPool([1, 2, 3, 4, 5, 6, 7, 8], 3, async (n) => {
      inFlight += 1;
      peak = Math.max(peak, inFlight);
      await tick();
      inFlight -= 1;
      return n;
    });
    expect(peak).toBe(3);
  });

  it("runs work concurrently up to the limit", async () => {
    let inFlight = 0;
    let peak = 0;
    await mapPool([1, 2, 3, 4], 4, async () => {
      inFlight += 1;
      peak = Math.max(peak, inFlight);
      await tick();
      inFlight -= 1;
    });
    expect(peak).toBe(4);
  });

  it("passes the item index to the worker", async () => {
    const seen: number[] = [];
    await mapPool(["a", "b", "c"], 1, async (_item, i) => {
      seen.push(i);
    });
    expect(seen).toEqual([0, 1, 2]);
  });
});
