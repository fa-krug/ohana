// The mock AI's building blocks: the messages it gets and the answers it gives, in OpenAI's
// format (streamed or not).

export type Part = { type: string; text?: string };
export type Msg = {
  role: string;
  content: string | null | Part[];
  tool_calls?: { id: string; function: { name: string } }[];
  tool_call_id?: string;
};

/** A message's text: the string, or its text parts joined. */
export function textOf(content: Msg["content"]) {
  if (!Array.isArray(content)) return String(content ?? "");
  return content.filter((p) => p.type === "text").map((p) => p.text ?? "").join("\n");
}

export function chunk(delta: Record<string, unknown>, finish: string | null = null) {
  return `data: ${JSON.stringify({ choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
}

export type Call = { name: string; args: unknown };

/** An answer with its text and tool calls (one, or several in one step). */
export function reply(stream: boolean, content: string, call?: Call | Call[]) {
  const calls = (Array.isArray(call) ? call : call ? [call] : []).map((c) => ({
    id: `call_${crypto.randomUUID().slice(0, 8)}`,
    type: "function",
    function: { name: c.name, arguments: JSON.stringify(c.args) },
  }));
  if (!stream) {
    return Response.json({
      choices: [{
        index: 0,
        message: { role: "assistant", content, ...(calls.length ? { tool_calls: calls } : {}) },
        finish_reason: calls.length ? "tool_calls" : "stop",
      }],
    });
  }
  let body = "";
  for (const word of content.match(/\S+\s*/g) ?? []) body += chunk({ content: word });
  for (const [index, toolCall] of calls.entries()) {
    // Arguments arrive in pieces, like real servers send them.
    const args = toolCall.function.arguments;
    body += chunk({
      tool_calls: [{
        index,
        id: toolCall.id,
        type: "function",
        function: { name: toolCall.function.name, arguments: "" },
      }],
    });
    for (let i = 0; i < args.length; i += 12) {
      body += chunk({ tool_calls: [{ index, function: { arguments: args.slice(i, i + 12) } }] });
    }
  }
  body += chunk({}, calls.length ? "tool_calls" : "stop") + "data: [DONE]\n\n";
  return new Response(body, { headers: { "content-type": "text/event-stream" } });
}

/** A 400 like a model that takes no pictures, when the message has none. */
export function refusesWithoutImage(message: Msg): Response | null {
  const parts = Array.isArray(message.content) ? message.content : [];
  if (parts.some((p) => p.type === "image_url")) return null;
  return Response.json({ error: { message: "This model does not support image input" } }, { status: 400 });
}
