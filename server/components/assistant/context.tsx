"use client";

import { createContext, useContext, useEffect, useState, useSyncExternalStore } from "react";
import { useRouter } from "next/navigation";
import { toast } from "@/components/ui/sonner";
import { useT } from "@/lib/i18n/provider";
import { ChatStore, pageOf } from "./chat-store";
import { notifyChanged } from "./events";

const ChatContext = createContext<ChatStore | null>(null);

/** Where the user is when they send a message: the page, and the calendar's year (`?y=`). */
function here() {
  const y = Number(new URLSearchParams(window.location.search).get("y"));
  return {
    page: pageOf(window.location.pathname),
    year: Number.isInteger(y) && y >= 1900 && y <= 2200 ? y : new Date().getFullYear(),
  };
}

/** One ChatStore for the family's chats while the app is open (the right panel; give it a
 *  `key` per family). A change of the assistant reloads the page's data. */
export function AssistantProvider({ familyId, children }: { familyId: string; children: React.ReactNode }) {
  const { t, locale } = useT();
  const router = useRouter();
  const [store] = useState(
    () =>
      new ChatStore(familyId, {
        i18n: { t, locale },
        toast: (message) => toast(message),
        onChange: (kind) => {
          notifyChanged(familyId, kind);
          // Pages rendered on the server (the overview's cards) catch up too.
          router.refresh();
        },
        context: here,
      }),
  );
  // The dictionary functions are new on each render (a language switch).
  useEffect(() => store.setI18n({ t, locale }));
  return <ChatContext.Provider value={store}>{children}</ChatContext.Provider>;
}

/** The store, re-rendering on each of its changes. */
export function useChat(): ChatStore {
  const store = useContext(ChatContext);
  if (!store) throw new Error("useChat must be used within an AssistantProvider");
  useSyncExternalStore(store.subscribe, store.getRev, store.getRev);
  return store;
}

/** The store if there is one (the finance page asks whether the AI is set up). */
export function useOptionalChat(): ChatStore | null {
  const store = useContext(ChatContext);
  useSyncExternalStore(
    store?.subscribe ?? (() => () => {}),
    store?.getRev ?? (() => 0),
    store?.getRev ?? (() => 0),
  );
  return store;
}
