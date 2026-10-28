"use client";

import { toast } from "@/components/ui/sonner";

/** Copies text and confirms with a toast; falls back to a prompt to copy from. */
export async function copyText(text: string, done: string): Promise<void> {
  try {
    await navigator.clipboard.writeText(text);
    toast.success(done);
  } catch {
    window.prompt("", text);
  }
}
