// The bank interfaces an account can sync with. Another bank is another BankProvider (types.ts)
// added here; the routes, the runner and the app's DTO only know the provider's id.

import { comdirect } from "./comdirect";
import type { BankProvider } from "./types";

export const PROVIDERS: Record<string, BankProvider> = {
  [comdirect.id]: comdirect,
};

export function providerOf(id: string): BankProvider | undefined {
  return Object.hasOwn(PROVIDERS, id) ? PROVIDERS[id] : undefined;
}
