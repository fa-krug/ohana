import Link from "next/link";
import { ChevronRight } from "lucide-react";

/** A trail of links above a page's content; the last item is the current page. */
export function Breadcrumbs({ items }: { items: { label: string; href?: string }[] }) {
  return (
    <nav aria-label="Breadcrumb" className="mb-3 min-w-0">
      <ol className="flex min-w-0 flex-wrap items-center gap-1 text-sm text-muted-foreground">
        {items.map((item, i) => (
          <li key={i} className="flex min-w-0 items-center gap-1">
            {i > 0 && <ChevronRight className="size-3.5 shrink-0" />}
            {item.href ? (
              <Link href={item.href} className="truncate hover:text-foreground hover:underline">
                {item.label}
              </Link>
            ) : (
              <span className="truncate text-foreground">{item.label}</span>
            )}
          </li>
        ))}
      </ol>
    </nav>
  );
}
