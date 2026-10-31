"use client";

// The assistant as a page of its own: the chats on the left, the open chat on the right
// (ChatView's wide layout), filling the main area below the phones' top bar.

import { ChatView } from "./chat-panel";

export function ChatPage() {
  return (
    <div className="-mx-4 -my-6 h-[calc(100dvh-3.5rem-1px)] sm:-mx-6 md:h-dvh">
      <ChatView page />
    </div>
  );
}
