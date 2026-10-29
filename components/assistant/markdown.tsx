import { type ReactNode } from "react";

// A small Markdown renderer for the assistant's answers: paragraphs, headings, lists, tables,
// code, bold, italics, links. It builds React elements (never HTML), so model output can't
// inject markup; links only open http(s) URLs.

const INLINE =
  /(`[^`]+`|\*\*[^*]+\*\*|__[^_]+__|\*[^*\s][^*]*\*|_[^_\s][^_]*_|\[[^\]]+\]\([^)\s]+\)|https?:\/\/[^\s<>()]+[^\s<>().,;:!?'"])/g;

function safeHref(url: string): string | undefined {
  return /^https?:\/\//i.test(url) ? url : undefined;
}

function inline(text: string, key = ""): ReactNode[] {
  const out: ReactNode[] = [];
  let last = 0;
  let i = 0;
  for (const m of text.matchAll(INLINE)) {
    const s = m[0];
    if (m.index! > last) out.push(text.slice(last, m.index));
    const k = `${key}-${i++}`;
    if (s.startsWith("`")) {
      out.push(
        <code key={k} className="rounded bg-muted px-1 py-0.5 text-[0.85em]">
          {s.slice(1, -1)}
        </code>,
      );
    } else if (s.startsWith("**") || s.startsWith("__")) {
      out.push(<strong key={k}>{inline(s.slice(2, -2), k)}</strong>);
    } else if (s.startsWith("*") || s.startsWith("_")) {
      out.push(<em key={k}>{inline(s.slice(1, -1), k)}</em>);
    } else if (s.startsWith("[")) {
      const [, label, url] = /^\[([^\]]+)\]\(([^)\s]+)\)$/.exec(s)!;
      const href = safeHref(url);
      out.push(
        href
          ? (
            <a
              key={k}
              href={href}
              target="_blank"
              rel="noopener noreferrer"
              className="text-primary underline underline-offset-2"
            >
              {label}
            </a>
          )
          : label,
      );
    } else {
      out.push(
        <a
          key={k}
          href={s}
          target="_blank"
          rel="noopener noreferrer"
          className="break-all text-primary underline underline-offset-2"
        >
          {s.replace(/^https?:\/\//, "")}
        </a>,
      );
    }
    last = m.index! + s.length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

// A table's delimiter row, e.g. `| --- | :--: | ---: |` (the outer pipes are optional).
const TABLE_RULE = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;

type Align = "left" | "center" | "right" | undefined;

/** A table row's cells; `\|` is a literal pipe. */
function cells(line: string): string[] {
  const row = line.trim().replace(/^\|/, "").replace(/(?<!\\)\|$/, "");
  return row.split(/(?<!\\)\|/).map((c) => c.trim().replace(/\\\|/g, "|"));
}

/** Whether a table starts at line `i`: a header row, then a delimiter row as wide as it. */
function isTableStart(lines: string[], i: number): boolean {
  return lines[i].includes("|") && i + 1 < lines.length &&
    TABLE_RULE.test(lines[i + 1]) &&
    cells(lines[i + 1]).length === cells(lines[i]).length;
}

function align(rule: string): Align {
  const left = rule.startsWith(":");
  const right = rule.endsWith(":");
  return left && right ? "center" : right ? "right" : left ? "left" : undefined;
}

export function Markdown({ text }: { text: string }) {
  const lines = text.replace(/\r/g, "").split("\n");
  const blocks: ReactNode[] = [];
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const k = `b${i}`;
    if (!line.trim()) {
      i++;
      continue;
    }
    if (line.startsWith("```")) {
      const code: string[] = [];
      for (i++; i < lines.length && !lines[i].startsWith("```"); i++) {
        code.push(lines[i]);
      }
      i++;
      blocks.push(
        <pre
          key={k}
          className="overflow-x-auto rounded-md bg-muted p-2 text-xs"
        ><code>{code.join("\n")}</code></pre>,
      );
      continue;
    }
    const heading = /^(#{1,4})\s+(.*)$/.exec(line);
    if (heading) {
      blocks.push(
        <p key={k} className="font-semibold">{inline(heading[2], k)}</p>,
      );
      i++;
      continue;
    }
    if (/^\s*([-*•]|\d+[.)])\s+/.test(line)) {
      const ordered = /^\s*\d+[.)]/.test(line);
      const items: ReactNode[] = [];
      for (; i < lines.length && /^\s*([-*•]|\d+[.)])\s+/.test(lines[i]); i++) {
        items.push(
          <li key={i}>
            {inline(
              lines[i].replace(/^\s*([-*•]|\d+[.)])\s+/, ""),
              `${k}-${i}`,
            )}
          </li>,
        );
      }
      blocks.push(
        ordered
          ? <ol key={k} className="list-decimal space-y-0.5 pl-5">{items}</ol>
          : <ul key={k} className="list-disc space-y-0.5 pl-5">{items}</ul>,
      );
      continue;
    }
    if (isTableStart(lines, i)) {
      const head = cells(line);
      const aligns = cells(lines[i + 1]).map(align);
      const rows: string[][] = [];
      for (i += 2; i < lines.length && lines[i].includes("|"); i++) {
        rows.push(cells(lines[i]));
      }
      blocks.push(
        <div key={k} className="overflow-x-auto">
          <table className="w-full border-collapse text-xs [overflow-wrap:normal]">
            <thead>
              <tr className="border-b">
                {head.map((h, c) => (
                  <th
                    key={c}
                    className="px-2 py-1 font-semibold"
                    style={{ textAlign: aligns[c] ?? "left" }}
                  >
                    {inline(h, `${k}-h${c}`)}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((row, r) => (
                <tr key={r} className="border-b last:border-0">
                  {head.map((_, c) => (
                    <td
                      key={c}
                      className="px-2 py-1"
                      style={{ textAlign: aligns[c] }}
                    >
                      {inline(row[c] ?? "", `${k}-${r}-${c}`)}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>,
      );
      continue;
    }
    const para: string[] = [];
    for (
      ;
      i < lines.length && lines[i].trim() &&
      !/^(```|#{1,4}\s|\s*([-*•]|\d+[.)])\s)/.test(lines[i]) &&
      !isTableStart(lines, i);
      i++
    ) {
      para.push(lines[i]);
    }
    blocks.push(
      <p key={k}>
        {para.flatMap((
          p,
          j,
        ) => (j ? [<br key={`br${j}`} />, ...inline(p, `${k}-${j}`)] : inline(p, `${k}-${j}`)))}
      </p>,
    );
  }
  return (
    <div className="space-y-2 leading-relaxed [overflow-wrap:anywhere]">
      {blocks}
    </div>
  );
}
