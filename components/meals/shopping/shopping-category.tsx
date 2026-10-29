"use client";

import { useState, useMemo, useTransition, useEffect } from "react";
import { ChevronDown } from "lucide-react";
import { useT } from "@/lib/i18n/provider";
import { formatQuantity } from "@/lib/meals/display/format";
import { toast } from "@/components/ui/sonner";
import { submitChecked } from "@/lib/offline/submit";
import type { ShoppingItemDto } from "@/lib/meals/queries/shopping";
import { useMeals } from "../meals-context";

interface ShoppingCategoryProps {
  category: string;
  items: ShoppingItemDto[];
}

export function ShoppingCategory({ category, items }: ShoppingCategoryProps) {
  const { t } = useT();
  const { familyId, canEdit } = useMeals();
  const [isOpen, setIsOpen] = useState(true);
  const [, startTransition] = useTransition();
  // Optimistic overrides keyed by item id.
  const [optimistic, setOptimistic] = useState<Record<string, boolean>>({});

  // Reconcile with server truth: when fresh `items` arrive (e.g. after
  // router.refresh() following an offline drain or uncheck-all), drop any
  // optimistic override that the server has now confirmed. Overrides that
  // still differ from the server value (still in-flight) are kept.
  useEffect(() => {
    setOptimistic((current) => {
      let changed = false;
      const next: Record<string, boolean> = {};
      for (const [id, val] of Object.entries(current)) {
        const serverItem = items.find((i) => i.id === id);
        if (serverItem && serverItem.isChecked === val) {
          changed = true;
          continue;
        }
        next[id] = val;
      }
      return changed ? next : current;
    });
  }, [items]);

  const checkedOf = (item: ShoppingItemDto) => optimistic[item.id] ?? item.isChecked;

  const sortedItems = useMemo(() => {
    return [...items].sort((a, b) => {
      const ac = optimistic[a.id] ?? a.isChecked;
      const bc = optimistic[b.id] ?? b.isChecked;
      if (ac === bc) return 0;
      return ac ? 1 : -1;
    });
  }, [items, optimistic]);

  const checkedCount = items.filter((item) => checkedOf(item)).length;

  function onToggle(item: ShoppingItemDto) {
    const next = !checkedOf(item);
    setOptimistic((o) => ({ ...o, [item.id]: next }));
    startTransition(async () => {
      const { result } = await submitChecked(familyId, item.id, next);
      if (result === "error") {
        setOptimistic((o) => ({ ...o, [item.id]: !next })); // revert
        toast.error(t("meals.common.errorRetry"));
      }
      // "queued" (offline) keeps the optimistic state; it replays on reconnect.
    });
  }

  return (
    <div className="rounded-lg border border-border bg-card shadow-sm">
      <button
        type="button"
        className="flex w-full items-center justify-between px-4 py-3"
        onClick={() => setIsOpen((prev) => !prev)}
        aria-expanded={isOpen}
      >
        <div className="flex items-center gap-2">
          <ChevronDown
            className={`h-4 w-4 text-muted-foreground transition-transform ${isOpen ? "" : "-rotate-90"}`}
          />
          <h3 className="text-sm font-semibold text-foreground">
            {t(`meals.shopping.categories.${category}`)}
          </h3>
        </div>
        <span className="text-xs text-muted-foreground">
          {t("meals.shopping.itemCount", { checked: checkedCount, total: items.length })}
        </span>
      </button>

      {isOpen && (
        <div className="divide-y divide-border border-t border-border">
          {sortedItems.map((item) => {
            const checked = checkedOf(item);
            return (
              <label key={item.id} className={`flex items-center gap-3 px-4 py-2.5 ${canEdit ? "cursor-pointer" : ""}`}>
                <input
                  type="checkbox"
                  checked={checked}
                  onChange={() => onToggle(item)}
                  disabled={!canEdit}
                  className="h-5 w-5 shrink-0 rounded accent-primary"
                  aria-label={item.ingredientName}
                />
                <span
                  className={`flex-1 text-sm ${checked ? "text-muted-foreground line-through" : "text-foreground"}`}
                >
                  {formatQuantity(item.quantity)} {item.unitAbbreviation} {item.ingredientName}
                </span>
              </label>
            );
          })}
        </div>
      )}
    </div>
  );
}
