// cookless web/lib/ai/stream-client.test.ts (the route is the family's now; errors carry the message)
import { afterEach, describe, expect, it, vi } from "vitest";
import { streamGenerateRecipes } from "@/lib/meals/ai/stream-client";

afterEach(() => vi.restoreAllMocks());

function streamFrom(chunks: string[]): Response {
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      const enc = new TextEncoder();
      for (const c of chunks) controller.enqueue(enc.encode(c));
      controller.close();
    },
  });
  return { ok: true, status: 200, body } as unknown as Response;
}

describe("streamGenerateRecipes", () => {
  it("parses NDJSON across chunk boundaries", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        streamFrom([
          '{"type":"recipe","index":0,"data":{"tit',
          'le":"A"}}\n{"type":"image","index":0,"data":{"image_base64":"xx"}}\n',
          '{"type":"done"}\n',
        ]),
      ),
    );
    const events: unknown[] = [];
    await streamGenerateRecipes("fam-1", { count: 1, tagIds: [], freeText: "", generateImages: true }, (e) => events.push(e));
    expect(events).toEqual([
      { type: "recipe", index: 0, data: { title: "A" } },
      { type: "image", index: 0, data: { image_base64: "xx" } },
      { type: "done" },
    ]);
  });

  it("throws on a non-ok response", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => ({ ok: false, status: 500 }) as unknown as Response));
    await expect(
      streamGenerateRecipes("fam-1", { count: 1, tagIds: [], freeText: "", generateImages: false }, () => {}),
    ).rejects.toThrow();
  });

  it("posts to the family's route and passes the server's message on", async () => {
    const fetchMock = vi.fn(async (_url: string) => Response.json({ message: "The AI isn't set up yet" }, { status: 400 }));
    vi.stubGlobal("fetch", fetchMock);
    await expect(
      streamGenerateRecipes("fam-1", { count: 2, tagIds: [], freeText: "", generateImages: false }, () => {}),
    ).rejects.toThrow("The AI isn't set up yet");
    expect(fetchMock.mock.calls[0][0]).toBe("/api/v1/families/fam-1/recipes/generate");
  });
});
