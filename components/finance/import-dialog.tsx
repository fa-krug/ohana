"use client";

// Imports a bank statement (family-planner's ImportDialog.tsx): pick the file, check how its
// columns map (with a preview), then see what is new and what was imported before, and import
// the new rows into an account. Mappings are remembered per bank (by the file's header), with
// the account and whether transfers and split bookings are combined. (Sorting the new rows
// into categories with the AI comes with the assistant.)

import { useMemo, useState } from "react";
import { FileUp } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { type CsvMapping, DATE_FORMATS, decode, type Encoding, guessMapping, mapRows, tableOf } from "@/lib/finance/csv";
import { formatMoney } from "@/lib/finance/money";
import { useT } from "@/lib/i18n/provider";
import type { ImportRow } from "./api";
import { useFinance } from "./context";
import { useOptionalChat } from "@/components/assistant/context";

const NONE = "-1";
const DELIMITERS: [string, string][] = [
  [";", ";"],
  [",", ","],
  ["\t", "Tab"],
  ["|", "|"],
];

type Step =
  | { name: "file" }
  | { name: "map"; bytes: Uint8Array; fileName: string }
  | {
      name: "review";
      bytes: Uint8Array;
      fileName: string;
      duplicates: number[];
      transfers: number;
      splits: number;
    };

export function ImportDialog({ onClose }: { onClose: () => void }) {
  const finance = useFinance();
  const { t } = useT();
  const [step, setStep] = useState<Step>({ name: "file" });
  const [mapping, setMapping] = useState<CsvMapping | null>(null);
  const [remember, setRemember] = useState(true);
  const [account, setAccount] = useState("none");
  const [auto, setAuto] = useState(true);
  const [categorize, setCategorize] = useState(true);
  const chat = useOptionalChat();
  const aiReady = !!chat?.settings?.configured;
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const bytes = step.name === "file" ? null : step.bytes;
  const encoding = mapping?.encoding;
  const text = useMemo(() => {
    if (!bytes || !encoding) return "";
    try {
      return decode(bytes, encoding).text;
    } catch {
      return "";
    }
  }, [bytes, encoding]);
  const table = useMemo(() => (mapping ? tableOf(text, mapping) : null), [text, mapping]);
  const parsed = useMemo(() => (table && mapping ? mapRows(table.rows, mapping) : null), [table, mapping]);

  async function pick(file: File) {
    setError("");
    const data = new Uint8Array(await file.arrayBuffer());
    const { text, encoding } = decode(data);
    const guess = guessMapping(text, encoding);
    // The same bank as before: use its saved mapping.
    const saved = finance.mappings.find((m) => m.signature && m.signature === guess.signature);
    setMapping(saved ?? guess);
    // Its account as last time, else the one the list shows.
    const known = (id?: string) => (id && finance.accountById(id) ? id : undefined);
    setAccount(known(saved?.accountId) ?? known(finance.filter.account) ?? "none");
    setAuto(saved?.autoTransfers ?? true);
    setStep({ name: "map", bytes: data, fileName: file.name });
  }

  const rowsToSend = (): ImportRow[] =>
    parsed!.ok.map(({ date, amountCents, payee, description }) => ({ date, amountCents, payee, description }));

  const accountId = (id = account) => (id === "none" ? undefined : id);

  /** A dry run: which rows are there already, and how many transfers and split bookings would
   *  be combined. */
  async function check(next: { account?: string; auto?: boolean } = {}) {
    if (step.name === "file" || !parsed?.ok.length) return;
    setBusy(true);
    setError("");
    try {
      const res = await finance.checkImport(rowsToSend(), accountId(next.account ?? account), next.auto ?? auto);
      setStep({
        ...step,
        name: "review",
        duplicates: res.duplicates,
        transfers: res.transfers ?? 0,
        splits: res.splits ?? 0,
      });
    } catch (err) {
      setError((err as Error).message);
    }
    setBusy(false);
  }

  async function run() {
    setBusy(true);
    try {
      const res = await finance.importRows(rowsToSend(), accountId(), auto);
      // Runs on after the dialog closed; its toast reports.
      if (categorize && finance.overview?.categories.length) void finance.categorizeIds(res.ids);
      if (remember && mapping?.signature) {
        await finance.saveMapping({ ...mapping, accountId: accountId(), autoTransfers: auto });
      }
      onClose();
    } catch (err) {
      setError(t("finance.import.failed", { msg: (err as Error).message }));
      setBusy(false);
    }
  }

  const set = (patch: Partial<CsvMapping>) => setMapping((m) => (m ? { ...m, ...patch } : m));
  const duplicates = step.name === "review" ? new Set(step.duplicates) : null;

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="max-h-[100dvh] overflow-y-auto sm:max-w-3xl">
        <DialogHeader>
          <DialogTitle>{t("finance.import.title")}</DialogTitle>
          <DialogDescription className="break-all">
            {step.name === "file" ? t("finance.import.help") : step.fileName}
          </DialogDescription>
        </DialogHeader>

        {step.name === "file" && (
          <label className="flex cursor-pointer flex-col items-center gap-2 rounded-xl border-2 border-dashed p-10 text-center text-sm text-muted-foreground hover:bg-accent">
            <FileUp className="size-8" />
            {t("finance.import.pick")}
            <input
              type="file"
              accept=".csv,.txt,text/csv"
              className="sr-only"
              onChange={(e) => {
                const file = e.target.files?.[0];
                if (file) void pick(file);
              }}
            />
          </label>
        )}

        {step.name === "map" && mapping && table && parsed && (
          <MappingForm mapping={mapping} header={table.header} width={table.rows[0]?.length ?? 0} set={set} />
        )}

        {step.name !== "file" && parsed && (
          <Preview
            rows={step.name === "map" ? parsed.ok.slice(0, 6) : parsed.ok.slice(0, 50)}
            duplicates={duplicates}
            currency={finance.currency}
          />
        )}

        {step.name === "map" && parsed && (
          <p className="text-sm text-muted-foreground">
            {t("finance.import.counts", { count: parsed.ok.length })}
            {parsed.errors.length > 0 && t("finance.import.countErrors", { n: parsed.errors.length })}
          </p>
        )}

        {step.name === "review" && parsed && (
          <div className="space-y-2 rounded-lg border bg-muted/50 p-4 text-sm">
            <p className="font-medium">{t("finance.import.new", { count: parsed.ok.length - step.duplicates.length })}</p>
            {step.duplicates.length > 0 && (
              <p className="text-muted-foreground">{t("finance.import.dupes", { n: step.duplicates.length })}</p>
            )}
            {parsed.errors.length > 0 && (
              <p className="text-muted-foreground">{t("finance.import.skipped", { count: parsed.errors.length })}</p>
            )}
            {step.transfers > 0 && (
              <p className="text-muted-foreground">{t("finance.import.transfers", { count: step.transfers })}</p>
            )}
            {step.splits > 0 && <p className="text-muted-foreground">{t("finance.import.splits", { count: step.splits })}</p>}
            {finance.accounts.length > 0 && (
              <>
                <label className="grid gap-1.5 pt-1 font-medium sm:max-w-xs">
                  {t("finance.account")}
                  <Select
                    value={account}
                    disabled={busy}
                    onValueChange={(v) => {
                      setAccount(v);
                      void check({ account: v }); // duplicates are per account
                    }}
                  >
                    <SelectTrigger className="h-10 w-full bg-card">
                      <SelectValue />
                    </SelectTrigger>
                    <SelectContent position="popper" className="max-h-80">
                      <SelectItem value="none">{t("finance.noAccount")}</SelectItem>
                      {finance.accounts.map((a) => (
                        <SelectItem key={a.id} value={a.id}>
                          {a.icon} {a.name}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </label>
                <label className="flex items-center gap-2 pt-1">
                  <Checkbox
                    checked={auto}
                    disabled={busy}
                    onCheckedChange={(v) => {
                      setAuto(!!v);
                      void check({ auto: !!v });
                    }}
                  />
                  {t("finance.import.autoTransfers")}
                </label>
              </>
            )}
            {mapping?.signature && (
              <label className="flex items-center gap-2 pt-1">
                <Checkbox checked={remember} onCheckedChange={(v) => setRemember(!!v)} />
                {t("finance.import.remember")}
              </label>
            )}
            {!!finance.overview?.categories.length && (
              <label className="flex items-center gap-2 pt-1">
                <Checkbox checked={categorize} onCheckedChange={(v) => setCategorize(!!v)} />
                {t(aiReady ? "finance.categorize.onImport" : "finance.categorize.onImportSimilar")}
              </label>
            )}
          </div>
        )}

        {error && <p className="text-sm text-gap">{error}</p>}

        <DialogFooter className="gap-2">
          <Button variant="outline" onClick={onClose}>
            {t("common.cancel")}
          </Button>
          {step.name === "map" && (
            <Button disabled={busy || !parsed?.ok.length} onClick={() => void check()}>
              {t("finance.import.next")}
            </Button>
          )}
          {step.name === "review" && (
            <>
              <Button variant="outline" onClick={() => setStep({ ...step, name: "map" })}>
                {t("finance.import.back")}
              </Button>
              <Button disabled={busy || parsed!.ok.length === step.duplicates.length} onClick={() => void run()}>
                {t("finance.import.run", { n: parsed!.ok.length - step.duplicates.length })}
              </Button>
            </>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function MappingForm({
  mapping,
  header,
  width,
  set,
}: {
  mapping: CsvMapping;
  header: string[];
  width: number;
  set: (patch: Partial<CsvMapping>) => void;
}) {
  const { t } = useT();
  const columns = Array.from(
    { length: Math.max(width, header.length) },
    (_, i) => header[i] || t("finance.import.column", { n: i + 1 }),
  );
  const split = mapping.amount === null;
  const column = (label: string, value: number | null, onChange: (v: number | null) => void, optional = false) => (
    <label className="grid min-w-0 gap-1 text-xs font-medium">
      {label}
      <Select value={String(value ?? NONE)} onValueChange={(v) => onChange(v === NONE ? null : Number(v))}>
        <SelectTrigger size="sm" className="w-full min-w-0">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {optional && <SelectItem value={NONE}>—</SelectItem>}
          {columns.map((c, i) => (
            <SelectItem key={i} value={String(i)}>
              {c}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </label>
  );

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <label className="grid min-w-0 gap-1 text-xs font-medium">
          {t("finance.import.encoding")}
          <Select value={mapping.encoding} onValueChange={(v) => set({ encoding: v as Encoding })}>
            <SelectTrigger size="sm" className="w-full min-w-0">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="utf-8">UTF-8</SelectItem>
              <SelectItem value="windows-1252">Windows-1252 / ISO-8859-1</SelectItem>
            </SelectContent>
          </Select>
        </label>
        <label className="grid min-w-0 gap-1 text-xs font-medium">
          {t("finance.import.delimiter")}
          <Select value={mapping.delimiter} onValueChange={(v) => set({ delimiter: v })}>
            <SelectTrigger size="sm" className="w-full min-w-0">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {DELIMITERS.map(([d, label]) => (
                <SelectItem key={label} value={d}>
                  {label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </label>
        <label className="grid min-w-0 gap-1 text-xs font-medium">
          {t("finance.import.skipRows")}
          <Input
            type="number"
            min={0}
            max={50}
            className="h-8"
            value={mapping.skipRows}
            onChange={(e) => set({ skipRows: Math.max(0, Math.min(50, Number(e.target.value) || 0)) })}
          />
        </label>
        <label className="flex items-end gap-2 pb-1.5 text-xs font-medium">
          <Switch checked={mapping.hasHeader} onCheckedChange={(v) => set({ hasHeader: v })} />
          {t("finance.import.hasHeader")}
        </label>
      </div>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        {column(t("finance.date"), mapping.date, (v) => set({ date: v ?? 0 }))}
        <label className="grid min-w-0 gap-1 text-xs font-medium">
          {t("finance.import.dateFormat")}
          <Select value={mapping.dateFormat} onValueChange={(v) => set({ dateFormat: v as CsvMapping["dateFormat"] })}>
            <SelectTrigger size="sm" className="w-full min-w-0">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {DATE_FORMATS.map((f) => (
                <SelectItem key={f} value={f}>
                  {f}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </label>
        <label className="grid min-w-0 gap-1 text-xs font-medium">
          {t("finance.import.amounts")}
          <Select
            value={split ? "split" : "single"}
            onValueChange={(v) =>
              set(
                v === "split"
                  ? { amount: null, debit: mapping.debit ?? 0, credit: mapping.credit ?? 0 }
                  : { amount: mapping.amount ?? mapping.debit ?? 0, debit: null, credit: null },
              )
            }
          >
            <SelectTrigger size="sm" className="w-full min-w-0">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="single">{t("finance.import.amountSingle")}</SelectItem>
              <SelectItem value="split">{t("finance.import.amountSplit")}</SelectItem>
            </SelectContent>
          </Select>
        </label>
        <label className="grid min-w-0 gap-1 text-xs font-medium">
          {t("finance.import.decimal")}
          <Select value={mapping.decimal} onValueChange={(v) => set({ decimal: v as "," | "." })}>
            <SelectTrigger size="sm" className="w-full min-w-0">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value=",">1.234,56</SelectItem>
              <SelectItem value=".">1,234.56</SelectItem>
            </SelectContent>
          </Select>
        </label>
        {split ? (
          <>
            {column(t("finance.import.debit"), mapping.debit, (v) => set({ debit: v }))}
            {column(t("finance.import.credit"), mapping.credit, (v) => set({ credit: v }))}
          </>
        ) : (
          column(t("finance.amount"), mapping.amount, (v) => set({ amount: v ?? 0 }))
        )}
        {column(t("finance.payee"), mapping.payee, (v) => set({ payee: v }), true)}
        {column(
          t("finance.description"),
          mapping.description[0] ?? null,
          (v) => set({ description: v === null ? [] : [v] }),
          true,
        )}
      </div>
    </div>
  );
}

/** The rows as read; on review, the ones imported before are struck through. */
function Preview({
  rows,
  duplicates,
  currency,
}: {
  rows: (ImportRow & { line: number })[];
  duplicates: Set<number> | null;
  currency: string;
}) {
  const { t, locale } = useT();
  if (!rows.length) return null;
  return (
    <div className="max-h-72 overflow-auto rounded-lg border">
      <table className="w-full text-xs sm:text-sm">
        <thead className="sticky top-0 bg-muted text-left text-xs text-muted-foreground">
          <tr>
            <th className="px-3 py-2 font-medium">{t("finance.date")}</th>
            <th className="px-3 py-2 font-medium">{t("finance.payee")}</th>
            <th className="px-3 py-2 font-medium max-sm:hidden">{t("finance.description")}</th>
            <th className="px-3 py-2 text-right font-medium">{t("finance.amount")}</th>
          </tr>
        </thead>
        <tbody className="divide-y">
          {rows.map((r, i) => {
            const dupe = duplicates?.has(i);
            return (
              <tr key={i} className={dupe ? "text-muted-foreground line-through" : undefined} title={dupe ? t("finance.import.dupes", { n: 1 }) : undefined}>
                <td className="py-1.5 pr-1 pl-3 whitespace-nowrap tabular-nums sm:px-3">{r.date}</td>
                <td className="max-w-28 truncate px-3 py-1.5 sm:max-w-40">{r.payee || r.description}</td>
                <td className="max-w-64 truncate px-3 py-1.5 text-muted-foreground max-sm:hidden">{r.description}</td>
                <td className="px-3 py-1.5 text-right whitespace-nowrap tabular-nums">
                  {formatMoney(r.amountCents, currency, locale, { sign: r.amountCents > 0 })}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
