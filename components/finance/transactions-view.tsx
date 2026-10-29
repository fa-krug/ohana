"use client";

// The transactions of the period: search and filters, inline category change, transfers and
// split bookings (combine the ticked rows, find transfers, auto-combine). Ported from
// family-planner's TransactionsView.tsx, with its auto-categorize button (sorts uncategorized
// transactions like similar ones, the rest with the family's AI).

import { useEffect, useMemo, useState } from "react";
import {
  ArrowLeftRight,
  Download,
  Link,
  ListTree,
  Loader2,
  Pencil,
  Search,
  Sparkles,
  Split,
  Trash2,
  Ungroup,
  Unlink,
  WandSparkles,
  X,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { formatMoney } from "@/lib/finance/money";
import { useT } from "@/lib/i18n/provider";
import { cn } from "@/lib/utils";
import type { Account, Category, Transaction } from "./api";
import { CategoryOptions } from "./category-options";
import { useOptionalChat } from "@/components/assistant/context";
import { useFinance } from "./context";
import type { Filter } from "./finance-store";
import { TransferDialog } from "./transfer-dialog";

/** The category's color, icon and name; its path (with the parents) on hover. */
export function CategoryLabel({ category }: { category?: Category }) {
  const finance = useFinance();
  const { t } = useT();
  if (!category) return <span className="text-muted-foreground">{t("finance.uncategorized")}</span>;
  return (
    <span className="inline-flex min-w-0 items-center gap-1.5" title={finance.categoryTree.path(category.id)}>
      <span className="size-2.5 shrink-0 rounded-full" style={{ backgroundColor: category.color }} />
      <span className="truncate">
        {category.icon ? `${category.icon} ` : ""}
        {category.name}
      </span>
    </span>
  );
}

/** A small pill with the account's color, icon and name. */
export function AccountChip({ account }: { account: Account }) {
  return (
    <span className="inline-flex max-w-40 shrink-0 items-center gap-1 rounded-full border px-1.5 py-px">
      <span className="size-2 shrink-0 rounded-full" style={{ backgroundColor: account.color }} />
      <span className="truncate">
        {account.icon ? `${account.icon} ` : ""}
        {account.name}
      </span>
    </span>
  );
}

/** The filtered transactions of the period, newest first; categories can be set inline. In
 *  edit mode rows can be ticked and combined into a transfer or a split booking. */
/** Sorts the period's uncategorized transactions like similar ones, and with the AI if it is
 *  set up. */
function AutoCategorizeButton() {
  const finance = useFinance();
  const chat = useOptionalChat();
  const { t } = useT();

  useEffect(() => {
    void chat?.loadSettings();
  }, [chat]);

  if (!finance.overview?.categories.length) return null;
  const progress = finance.categorizing;
  const ai = !!chat?.settings?.configured;
  return (
    <Button
      variant="outline"
      disabled={!!progress}
      title={progress ? undefined : t(ai ? "finance.categorize.help" : "finance.categorize.helpSimilar")}
      aria-label={progress?.total ? t("finance.categorize.progress", progress) : t("finance.categorize.button")}
      onClick={() => void finance.autoCategorize()}
    >
      {progress ? <Loader2 className="animate-spin" /> : <Sparkles />}{" "}
      <span className="tabular-nums max-sm:sr-only">
        {progress?.total ? `${progress.done}/${progress.total}` : t("finance.categorize.button")}
      </span>
    </Button>
  );
}

export function TransactionsView({ onEdit }: { onEdit?: (t: Transaction) => void }) {
  const finance = useFinance();
  const { t, locale } = useT();
  const [q, setQ] = useState(finance.filter.q);
  const [finding, setFinding] = useState(false);
  const [combining, setCombining] = useState(false);
  const list = finance.list;
  const accounts = finance.accounts;

  // Search as you type, a moment after the last key.
  useEffect(() => {
    if (q === finance.filter.q) return;
    const timer = setTimeout(() => finance.setFilter({ q }), 250);
    return () => clearTimeout(timer);
  }, [q, finance]);

  // The legs of each transfer that are on this page, to tell where the money went.
  const legs = useMemo(() => {
    const byGroup = new Map<string, Transaction[]>();
    for (const tx of list?.transactions ?? []) {
      if (tx.transferId) byGroup.set(tx.transferId, [...(byGroup.get(tx.transferId) ?? []), tx]);
    }
    return byGroup;
  }, [list]);

  // To name the booking a part belongs to.
  const byId = useMemo(() => new Map(list?.transactions.map((tx) => [tx.id, tx] as const)), [list]);

  const accountName = (tx: Transaction) => finance.accountById(tx.accountId)?.name ?? t("finance.noAccount");
  const dateFormat = new Intl.DateTimeFormat(locale, { day: "2-digit", month: "short", year: "numeric" });

  /** "Transfer · A → B"; just the leg's own side when its partner isn't loaded. */
  function transferText(tx: Transaction) {
    const group = legs.get(tx.transferId!) ?? [tx];
    const from = group.find((l) => l.amountCents < 0);
    const to = group.find((l) => l.amountCents > 0);
    const route =
      from && to
        ? `${accountName(from)} → ${accountName(to)}`
        : tx.amountCents < 0
          ? `${accountName(tx)} →`
          : `→ ${accountName(tx)}`;
    return `${t("finance.transfer")} · ${route}`;
  }

  /** "Part of <booking>" (just "of a split booking" when it isn't loaded), or on the booking
   *  "Split into N parts", with what it still counts itself unless that is 0. */
  function splitText(tx: Transaction) {
    if (tx.splitOf) {
      const booking = byId.get(tx.splitOf);
      const name = booking && (booking.payee || booking.description);
      return name ? t("finance.partOf", { name }) : t("finance.partOfSplit");
    }
    const { parts, remainderCents } = tx.split!;
    const text = t("finance.splitInto", { count: parts });
    if (!remainderCents) return text;
    const amount = formatMoney(remainderCents, finance.currency, locale, { sign: remainderCents > 0 });
    return `${text} · ${t("finance.splitRemainder", { amount })}`;
  }

  const remove = (tx: Transaction) => finance.change([{ action: "delete", id: tx.id }], t("finance.deleted"));

  async function autoCombine() {
    setCombining(true);
    await finance.autoCombineTransfers();
    setCombining(false);
  }

  const selected = list?.transactions.filter((tx) => finance.selected.has(tx.id)) ?? [];

  return (
    <div className="rounded-xl border bg-card">
      <div className="flex flex-wrap items-center gap-2 border-b p-3">
        <div className="relative min-w-40 flex-1">
          <Search className="absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            className="pl-8"
            placeholder={t("finance.search")}
            aria-label={t("finance.search")}
            value={q}
            onChange={(e) => setQ(e.target.value)}
          />
        </div>
        {accounts.length > 0 && (
          <Select
            value={finance.filter.account || "all"}
            onValueChange={(v) => finance.setFilter({ account: v === "all" ? "" : v })}
          >
            <SelectTrigger className="h-10 w-[calc(50%-0.25rem)] sm:w-40" aria-label={t("finance.account")}>
              <SelectValue />
            </SelectTrigger>
            <SelectContent position="popper" className="max-h-80">
              <SelectItem value="all">{t("finance.allAccounts")}</SelectItem>
              <SelectItem value="none">{t("finance.noAccount")}</SelectItem>
              {accounts.map((a) => (
                <SelectItem key={a.id} value={a.id}>
                  {a.icon} {a.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        )}
        <Select
          value={finance.filter.category || "all"}
          onValueChange={(v) => finance.setFilter({ category: v === "all" ? "" : v })}
        >
          <SelectTrigger className="h-10 w-[calc(50%-0.25rem)] sm:w-44" aria-label={t("finance.category")}>
            <SelectValue />
          </SelectTrigger>
          <SelectContent position="popper" className="max-h-80">
            <SelectItem value="all">{t("finance.allCategories")}</SelectItem>
            <SelectItem value="none">{t("finance.uncategorized")}</SelectItem>
            <CategoryOptions />
          </SelectContent>
        </Select>
        <Select
          value={finance.filter.kind || "all"}
          onValueChange={(v) => finance.setFilter({ kind: v === "all" ? "" : (v as Filter["kind"]) })}
        >
          <SelectTrigger className="h-10 w-[calc(50%-0.25rem)] sm:w-36" aria-label={t("finance.kind")}>
            <SelectValue />
          </SelectTrigger>
          <SelectContent position="popper" className="max-h-80">
            <SelectItem value="all">{t("finance.allKinds")}</SelectItem>
            <SelectItem value="income">{t("finance.income")}</SelectItem>
            <SelectItem value="expense">{t("finance.expenses")}</SelectItem>
            <SelectItem value="transfer">{t("finance.transfers")}</SelectItem>
          </SelectContent>
        </Select>
        {onEdit && (
          <>
            <AutoCategorizeButton />
            <Button variant="outline" title={t("finance.findTransfers")} onClick={() => setFinding(true)}>
              <ArrowLeftRight /> <span className="max-sm:sr-only">{t("finance.findTransfers")}</span>
            </Button>
            <Button variant="outline" title={t("finance.autoCombineHelp")} disabled={combining} onClick={autoCombine}>
              <WandSparkles /> <span className="max-sm:sr-only">{t("finance.autoCombine")}</span>
            </Button>
          </>
        )}
      </div>
      {finance.error && <p className="p-4 text-sm text-gap">{finance.error}</p>}
      {list && list.transactions.length === 0 && (
        <p className="p-8 text-center text-sm text-muted-foreground">
          {t(finance.readOnly ? "finance.emptyReadonly" : "finance.empty")}
        </p>
      )}
      {!list && !finance.error && <div className="m-3 h-40 animate-pulse rounded-lg bg-muted" />}
      <ul className={cn("@container divide-y", finance.loadingList && "opacity-60")} aria-busy={finance.loadingList}>
        {list?.transactions.map((tx) => {
          const account = finance.accountById(tx.accountId);
          return (
            <li
              key={tx.id}
              className={cn(
                "grid grid-cols-[auto_1fr_auto] items-center gap-x-3 gap-y-1 px-3 py-2.5",
                onEdit ? "@2xl:grid-cols-[8rem_1fr_12rem_8rem_8.5rem]" : "@2xl:grid-cols-[6.5rem_1fr_12rem_8rem_1.25rem]",
                finance.selected.has(tx.id) && "bg-accent/50",
              )}
              // a stripe in the category's color down the row's left edge
              style={{ boxShadow: `inset 3px 0 0 ${finance.categoryById(tx.categoryId)?.color ?? "transparent"}` }}
            >
              <div className="flex items-center gap-2.5">
                {onEdit && (
                  <Checkbox
                    aria-label={t("finance.select")}
                    checked={finance.selected.has(tx.id)}
                    onCheckedChange={(v) => finance.toggleSelected(tx.id, !!v)}
                  />
                )}
                <time className="text-xs text-muted-foreground tabular-nums @2xl:text-sm" dateTime={tx.date}>
                  {dateFormat.format(new Date(tx.date + "T00:00:00"))}
                </time>
              </div>
              <div className="col-start-1 col-end-3 row-start-2 min-w-0 @2xl:col-auto @2xl:row-auto">
                <div className="truncate font-medium">{tx.payee || tx.description || "—"}</div>
                {tx.transferId ? (
                  <div className="flex min-w-0 items-center gap-1 text-xs text-muted-foreground">
                    <Link className="size-3 shrink-0" aria-hidden />
                    <span className="truncate">{transferText(tx)}</span>
                  </div>
                ) : tx.splitOf || tx.split ? (
                  <div className="flex min-w-0 items-center gap-1 text-xs text-muted-foreground">
                    <ListTree className="size-3 shrink-0" aria-hidden />
                    <span className="truncate">{splitText(tx)}</span>
                  </div>
                ) : (
                  (account || (tx.payee && tx.description)) && (
                    <div className="flex min-w-0 items-center gap-1.5 text-xs text-muted-foreground">
                      {account && <AccountChip account={account} />}
                      {tx.payee && tx.description && <span className="truncate">{tx.description}</span>}
                    </div>
                  )
                )}
              </div>
              <div className="col-start-1 col-end-3 row-start-3 min-w-0 text-sm @2xl:col-auto @2xl:row-auto">
                {onEdit ? (
                  <Select
                    value={tx.categoryId ?? "none"}
                    onValueChange={(v) =>
                      finance.change(
                        [{ action: "update", id: tx.id, categoryId: v === "none" ? null : v }],
                        t("finance.saved"),
                      )
                    }
                  >
                    <SelectTrigger
                      size="sm"
                      className="h-8 w-full border-transparent shadow-none hover:border-input"
                      aria-label={t("finance.category")}
                    >
                      <CategoryLabel category={finance.categoryById(tx.categoryId)} />
                    </SelectTrigger>
                    <SelectContent position="popper" className="max-h-80">
                      <SelectItem value="none">{t("finance.uncategorized")}</SelectItem>
                      <CategoryOptions fits={(c) => c.kind === "both" || (c.kind === "income") === tx.amountCents > 0} />
                    </SelectContent>
                  </Select>
                ) : (
                  <CategoryLabel category={finance.categoryById(tx.categoryId)} />
                )}
              </div>
              <div
                className={cn(
                  "col-start-3 row-start-1 text-right font-semibold whitespace-nowrap tabular-nums @2xl:col-auto @2xl:row-auto",
                  // a transfer leg doesn't count on its own, a split booking only through its
                  // parts (and what they leave over)
                  tx.transferId || tx.split
                    ? "text-muted-foreground"
                    : tx.amountCents > 0
                      ? "text-ok"
                      : tx.amountCents < 0 && "text-gap",
                )}
                title={
                  tx.transferId
                    ? t("finance.transferAmountHint")
                    : tx.split
                      ? t("finance.splitAmountHint")
                      : undefined
                }
              >
                {formatMoney(tx.amountCents, finance.currency, locale, { sign: tx.amountCents > 0 })}
              </div>
              <div className="col-start-3 row-span-2 row-start-2 flex justify-end gap-0.5 @2xl:col-auto @2xl:row-auto">
                {tx.imported && (
                  <span className="self-center" title={t("finance.importedRow")}>
                    <Download className="size-3.5 text-muted-foreground" aria-label={t("finance.importedRow")} />
                  </span>
                )}
                {onEdit && (
                  <>
                    {tx.transferId && (
                      <Button
                        variant="ghost"
                        size="icon"
                        className="size-8"
                        title={t("finance.unlink")}
                        aria-label={t("finance.unlink")}
                        onClick={() => finance.unlink(tx.id)}
                      >
                        <Unlink />
                      </Button>
                    )}
                    {(tx.splitOf || tx.split) && (
                      <Button
                        variant="ghost"
                        size="icon"
                        className="size-8"
                        title={t(tx.splitOf ? "finance.unsplitPart" : "finance.unsplit")}
                        aria-label={t(tx.splitOf ? "finance.unsplitPart" : "finance.unsplit")}
                        onClick={() => finance.unsplit(tx.id)}
                      >
                        <Ungroup />
                      </Button>
                    )}
                    <Button
                      variant="ghost"
                      size="icon"
                      className="size-8"
                      title={t("finance.edit")}
                      aria-label={t("finance.edit")}
                      onClick={() => onEdit(tx)}
                    >
                      <Pencil />
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon"
                      className="size-8"
                      title={t("finance.delete")}
                      aria-label={t("finance.delete")}
                      onClick={() => remove(tx)}
                    >
                      <Trash2 />
                    </Button>
                  </>
                )}
              </div>
            </li>
          );
        })}
      </ul>
      {list && list.total > list.transactions.length && (
        <div className="border-t p-3 text-center">
          <Button variant="outline" size="sm" onClick={() => finance.showMore()}>
            {t("finance.showMore", { n: list.total - list.transactions.length })}
          </Button>
        </div>
      )}
      {onEdit && selected.length >= 2 && <SelectionBar selected={selected} />}
      {finding && <TransferDialog onClose={() => setFinding(false)} />}
    </div>
  );
}

/** What the ticked rows add up to, and the buttons that combine them into a transfer or a
 *  split booking. */
function SelectionBar({ selected }: { selected: Transaction[] }) {
  const finance = useFinance();
  const { t, locale } = useT();
  const [busy, setBusy] = useState(false);
  const net = selected.reduce((sum, tx) => sum + tx.amountCents, 0);
  const money = (cents: number, sign = false) => formatMoney(cents, finance.currency, locale, { sign });
  // Parts and split bookings can't be transfer legs; a split takes only plain transactions.
  const linkable = selected.every((tx) => !tx.splitOf && !tx.split);
  const splittable = selected.length >= 2 && linkable && selected.every((tx) => !tx.transferId);
  // The largest one is the booking (the first of equal ones), the others its parts.
  const booking = selected.reduce((a, b) => (Math.abs(b.amountCents) > Math.abs(a.amountCents) ? b : a));

  async function combine() {
    setBusy(true);
    await finance.link(selected.map((tx) => tx.id));
    setBusy(false);
  }

  async function combineSplit() {
    setBusy(true);
    await finance.split(
      booking.id,
      selected.filter((tx) => tx !== booking).map((tx) => tx.id),
    );
    setBusy(false);
  }

  return (
    <div className="sticky bottom-[calc(env(safe-area-inset-bottom)+0.75rem)] z-10 m-3 flex flex-wrap items-center gap-x-3 gap-y-2 rounded-lg border bg-popover p-3 text-sm shadow-lg">
      <div className="min-w-0 flex-1 basis-56">
        <div className="font-medium tabular-nums">{t("finance.selected", { n: selected.length, net: money(net, true) })}</div>
        <div className="text-xs text-muted-foreground">
          {net === 0
            ? t("finance.combineZero")
            : t(net > 0 ? "finance.combineIncome" : "finance.combineExpense", { amount: money(Math.abs(net)) })}
        </div>
      </div>
      <div className="flex flex-wrap gap-2">
        <Button variant="ghost" size="sm" onClick={() => finance.clearSelection()}>
          <X /> {t("finance.clearSelection")}
        </Button>
        {/* the hints sit on a wrapper: a disabled button shows no tooltip */}
        <span
          title={
            splittable
              ? t("finance.combineSplitHelp", {
                  name: booking.payee || booking.description || "—",
                  amount: money(booking.amountCents, booking.amountCents > 0),
                })
              : t("finance.combineSplitBlocked")
          }
        >
          <Button size="sm" variant="outline" disabled={busy || !splittable} onClick={combineSplit}>
            <Split /> {t("finance.combineSplit")}
          </Button>
        </span>
        <span title={linkable ? undefined : t("finance.combineTransferBlocked")}>
          <Button size="sm" disabled={busy || !linkable} onClick={combine}>
            <Link /> {t("finance.combine")}
          </Button>
        </span>
      </div>
    </div>
  );
}
