// A chat (or one answer of it) as Markdown for the clipboard: what the chat shows, plus every
// tool call with its arguments and its result.

import type { Item } from "./chat-store";
import { type Lang, toolDetail, toolLabel } from "./tools";

const STATUS = { running: "…", ok: "✓", error: "✗" };

/** JSON pretty-printed; anything else (e.g. a result cut short) as it is. */
function pretty(text: string) {
  try {
    return JSON.stringify(JSON.parse(text), null, 2);
  } catch {
    return text;
  }
}

/** A fenced code block that can't be closed early by backticks in its text. */
function fence(text: string, lang = "") {
  const ticks = "`".repeat(Math.max(3, ...(text.match(/`+/g) ?? []).map((m) => m.length + 1)));
  return `${ticks}${lang}\n${text}\n${ticks}`;
}

/** The items as Markdown; `result` finds a tool call's result by its id. */
export function transcript(l: Lang, items: Item[], result: (id: string) => string | undefined): string {
  const t = l.t;
  return items.map((item, i) => {
    switch (item.kind) {
      case "user": {
        const files = (item.attachments ?? []).map((a) => `📎 ${a.name}`);
        const text = [`**${t("assistant.copy.you")}:** ${item.text}`, ...files].join("\n");
        return i ? `---\n\n${text}` : text;
      }
      case "assistant":
        return item.text;
      case "tool": {
        const label = [toolLabel(l, item), toolDetail(l, item)].filter(Boolean).join(" · ");
        const out = result(item.id);
        const answer = out !== undefined ? fence(pretty(out), "json") : item.summary ?? "";
        return [
          `**🔧 ${label}** ${STATUS[item.status]}`,
          fence(`${item.name} ${JSON.stringify(item.args ?? {}, null, 2)}`),
          answer,
        ].filter(Boolean).join("\n");
      }
      case "change":
        return `✅ ${item.summary}${item.undone ? ` (${t("assistant.undone")})` : ""}`;
      case "question": {
        const picked = item.answer?.selected ?? [];
        const lines = item.options.map((o) => `- [${picked.includes(o) ? "x" : " "}] ${o}`);
        const answer = item.answer?.text
          ? `**${t("assistant.copy.you")}:** ${item.answer.text}`
          : item.skipped
          ? `(${t("assistant.question.skipped")})`
          : "";
        return [`**❓ ${item.question}**`, ...lines, answer].filter(Boolean).join("\n");
      }
      case "compacted":
        return `*${t("assistant.compacted")}*`;
      case "error":
        return `⚠️ ${item.text}`;
    }
  }).join("\n\n");
}
