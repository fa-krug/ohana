// The import's report as text (what scripts/import-legacy.ts prints).
import { SOURCE_LABEL, SOURCE_NAMES, type ImportReport } from "./types";

export function formatReport(r: ImportReport): string {
  const out: string[] = [];
  out.push(r.dryRun ? "DRY RUN: nothing was written (the import ran and was rolled back)." : "Import done.");

  out.push("", "Rows per table:");
  const counts = Object.entries(r.counts).sort(([a], [b]) => a.localeCompare(b));
  if (counts.length === 0) out.push("  (none)");
  const width = Math.max(0, ...counts.map(([t]) => t.length));
  for (const [t, n] of counts) out.push(`  ${t.padEnd(width)}  ${n}`);

  out.push("", `Accounts (${r.users.length}):`);
  for (const u of r.users) {
    const from = u.from.map((s) => SOURCE_LABEL[s]).join(" + ");
    const pw = u.existing
      ? "existed in Ohana already (kept as it was)"
      : u.passwordFrom
        ? `password from ${SOURCE_LABEL[u.passwordFrom]}`
        : "NO PASSWORD";
    out.push(`  ${u.email}  [${from}]  ${pw}${u.isAdmin ? "  admin" : ""}`);
  }
  const setup = r.users.filter((u) => u.needsSetupLink);
  if (setup.length > 0) {
    out.push("", "Accounts that need a setup link (they have no usable password):");
    for (const u of setup) out.push(`  npm run setup-link -- ${u.email}`);
  }

  out.push("", `Families (${r.families.length}):`);
  for (const f of r.families) {
    const from = SOURCE_NAMES.filter((s) => f.from[s]).map((s) => `${SOURCE_LABEL[s]} ${f.from[s]}`).join(", ");
    out.push(`  "${f.name}"  id ${f.id}  ← ${from}`);
    out.push(`    members: ${f.members.length ? f.members.map((m) => `${m.email} (${m.role})`).join(", ") : "none"}`);
  }

  if (r.skipped.length > 0) {
    out.push("", "Skipped:");
    const groups = new Map<string, string[]>();
    for (const s of r.skipped) {
      const key = `${SOURCE_LABEL[s.source]} ${s.table}: ${s.reason}`;
      groups.set(key, [...(groups.get(key) ?? []), s.key]);
    }
    for (const [key, keys] of groups) {
      const sample = keys.slice(0, 5).join(", ") + (keys.length > 5 ? `, … (${keys.length - 5} more)` : "");
      out.push(`  ${key} — ${keys.length === 1 ? keys[0] : `${keys.length}: ${sample}`}`);
    }
  }

  out.push("", `Recipe photos: ${r.media.copied} ${r.dryRun ? "to copy" : "copied"}, ${r.media.missing.length} missing`);
  for (const m of r.media.missing.slice(0, 20)) out.push(`  missing: ${m}`);
  if (r.media.missing.length > 20) out.push(`  … ${r.media.missing.length - 20} more`);

  if (r.notes.length > 0) {
    out.push("", "Notes:");
    for (const n of r.notes) out.push(`  - ${n}`);
  }
  return out.join("\n");
}
