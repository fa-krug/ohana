"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { BookOpen, CalendarDays, ShoppingCart, Tags } from "lucide-react";
import { cn } from "@/lib/utils";
import { useT } from "@/lib/i18n/provider";
import { useMeals } from "./meals-context";

/** The module's sub-navigation: recipes, plan, shopping list, tags. */
export function MealsTabs() {
  const { t } = useT();
  const { base } = useMeals();
  const pathname = usePathname();
  const tabs = [
    { href: `${base}/recipes`, label: t("meals.nav.recipes"), icon: BookOpen, also: [`${base}/cook`] },
    { href: `${base}/plan`, label: t("meals.nav.plan"), icon: CalendarDays, also: [] },
    { href: `${base}/shopping`, label: t("meals.nav.shopping"), icon: ShoppingCart, also: [] },
    { href: `${base}/tags`, label: t("meals.nav.tags"), icon: Tags, also: [] },
  ];
  return (
    <nav className="mb-6 grid grid-cols-4 border-b sm:flex sm:gap-1">
      {tabs.map(({ href, label, icon: Icon, also }) => {
        const active = [href, ...also].some((h) => pathname === h || pathname.startsWith(`${h}/`));
        return (
          <Link
            key={href}
            href={href}
            aria-current={active ? "page" : undefined}
            className={cn(
              "-mb-px flex min-w-0 flex-col items-center gap-1 border-b-2 px-1 py-2 text-xs font-medium sm:flex-row sm:gap-1.5 sm:px-4 sm:text-sm",
              active ? "border-primary text-foreground" : "border-transparent text-muted-foreground hover:text-foreground",
            )}
          >
            <Icon className="size-4" />
            <span className="max-w-full truncate">{label}</span>
          </Link>
        );
      })}
    </nav>
  );
}
