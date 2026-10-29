"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { cn } from "@/lib/utils";
import { useT } from "@/lib/i18n/provider";

export function AdminTabs() {
  const { t } = useT();
  const pathname = usePathname();
  const tabs = [
    { href: "/admin/users", label: t("admin.users") },
    { href: "/admin/families", label: t("admin.families") },
  ];
  return (
    <nav className="mb-6 flex gap-1 border-b">
      {tabs.map((tab) => (
        <Link
          key={tab.href}
          href={tab.href}
          className={cn(
            "-mb-px border-b-2 px-4 py-2 text-sm font-medium",
            pathname.startsWith(tab.href) ? "border-primary text-foreground" : "border-transparent text-muted-foreground hover:text-foreground",
          )}
        >
          {tab.label}
        </Link>
      ))}
    </nav>
  );
}
