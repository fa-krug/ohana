// Push in tests: a fake relay that keeps what it was given, devices registered for accounts
// (device `n`'s key is 32 bytes of `n`, its relay token "r1.<n>"), and what a device got, opened.

import type { Db } from "@/lib/db";
import { createToken } from "@/lib/auth/tokens";
import { DEFAULT_PUSH_RELAY_URL } from "@/lib/push/config";
import { registerDevice } from "@/lib/push/devices";
import { openPayload } from "@/lib/push/payload";
import type { RelayClient, RelayMessage } from "@/lib/push/relay";
import { NOW } from "./factories";

export const deviceKey = (n: number) => Buffer.alloc(32, n);

export interface FakePush {
  client: RelayClient;
  messages: RelayMessage[];
  /** Registers device `n` for the account. */
  device(userId: string, n: number): void;
  /** What device `n` got, opened. */
  received(n: number): ReturnType<typeof openPayload>[];
}

export function fakePush(db: Db): FakePush {
  const messages: RelayMessage[] = [];
  return {
    messages,
    client: {
      async send(_url, batch) {
        messages.push(...batch);
        return batch.map(() => ({ status: "ok" as const }));
      },
    },
    device(userId, n) {
      const { row } = createToken(db, { userId, kind: "api", name: `Device ${n}` }, NOW);
      const device = { relay: DEFAULT_PUSH_RELAY_URL, relayToken: `r1.${n}`, key: deviceKey(n).toString("base64"), platform: "ios" };
      registerDevice(db, { id: userId }, row.id, device, NOW);
    },
    received: (n) => messages.filter((m) => m.relayToken === `r1.${n}`).map((m) => openPayload(deviceKey(n), m.payload)),
  };
}
