"use client";

// Meals → Finance (phase 7): a groceries transaction near a shopping day links to that day's
// shopping list. The page hands the links down (lib/finance/groceries.ts shoppingLinks).

import { createContext, useContext } from "react";
import NextLink from "next/link";
import { ShoppingCart } from "lucide-react";
import { useT } from "@/lib/i18n/provider";
import { listForTransaction, type ShoppingLinks } from "@/lib/finance/groceries-links";

const Ctx = createContext<{ familyId: string; links: ShoppingLinks } | null>(null);

export function ShoppingLinksProvider({
  familyId,
  links,
  children,
}: {
  familyId: string;
  links: ShoppingLinks;
  children: React.ReactNode;
}) {
  return <Ctx.Provider value={{ familyId, links }}>{children}</Ctx.Provider>;
}

/** The cart icon linking a transaction to its shopping list, or nothing. */
export function ShoppingListLink({ tx }: { tx: { date: string; categoryId: string | null } }) {
  const ctx = useContext(Ctx);
  const { t } = useT();
  const list = ctx && listForTransaction(ctx.links, tx);
  if (!ctx || !list) return null;
  return (
    <NextLink
      href={`/f/${ctx.familyId}/meals/shopping/${list.id}`}
      className="self-center rounded p-1 text-muted-foreground hover:bg-accent hover:text-foreground"
      title={t("finance.shoppingList")}
      aria-label={t("finance.shoppingList")}
    >
      <ShoppingCart className="size-3.5" />
    </NextLink>
  );
}
