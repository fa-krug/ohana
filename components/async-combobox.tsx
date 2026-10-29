"use client";

import { useEffect, useRef, useState } from "react";
import { Input } from "@/components/ui/input";
import { useT } from "@/lib/i18n/provider";

/** A text box that queries `${endpoint}?q=…` (debounced) and offers the results to pick. */
export function AsyncCombobox<T>({
  endpoint,
  getLabel,
  getMeta,
  onSelect,
  initialLabel = "",
  placeholder,
  id,
  disabled,
}: {
  endpoint: string;
  getLabel: (item: T) => string;
  getMeta?: (item: T) => string;
  onSelect: (item: T) => void;
  initialLabel?: string;
  placeholder?: string;
  id?: string;
  disabled?: boolean;
}) {
  const { t } = useT();
  const [query, setQuery] = useState(initialLabel);
  const [items, setItems] = useState<T[]>([]);
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [chosen, setChosen] = useState(initialLabel);
  const boxRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    // Don't re-search the label we just picked.
    if (!query.trim() || query === chosen) {
      setItems([]);
      return;
    }
    const timer = setTimeout(async () => {
      setLoading(true);
      try {
        const res = await fetch(`${endpoint}?q=${encodeURIComponent(query)}`);
        setItems(res.ok ? ((await res.json()) as T[]) : []);
        setOpen(true);
      } catch {
        setItems([]);
      } finally {
        setLoading(false);
      }
    }, 300);
    return () => clearTimeout(timer);
  }, [query, chosen, endpoint]);

  useEffect(() => {
    const onClick = (e: MouseEvent) => {
      if (boxRef.current && !boxRef.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", onClick);
    return () => document.removeEventListener("mousedown", onClick);
  }, []);

  return (
    <div ref={boxRef} className="relative">
      <Input
        id={id}
        value={query}
        placeholder={placeholder}
        disabled={disabled}
        onChange={(e) => {
          setQuery(e.target.value);
          setOpen(true);
        }}
        onFocus={() => items.length > 0 && setOpen(true)}
        onKeyDown={(e) => e.key === "Escape" && setOpen(false)}
        autoComplete="off"
        role="combobox"
        aria-expanded={open}
      />
      {open && (items.length > 0 || loading) && (
        <ul className="absolute z-50 mt-1 max-h-60 w-full overflow-auto rounded-md border bg-popover text-popover-foreground shadow-md" role="listbox">
          {loading && <li className="px-3 py-2 text-sm text-muted-foreground">{t("common.searching")}</li>}
          {items.map((item, i) => {
            const label = getLabel(item);
            return (
              <li key={i} role="option" aria-selected={false}>
                <button
                  type="button"
                  className="w-full px-3 py-2 text-left text-sm hover:bg-accent hover:text-accent-foreground"
                  onClick={() => {
                    onSelect(item);
                    setQuery(label);
                    setChosen(label);
                    setOpen(false);
                  }}
                >
                  <span className="flex items-center justify-between gap-2">
                    <span className="truncate">{label}</span>
                    {getMeta && <span className="shrink-0 text-xs text-muted-foreground">{getMeta(item)}</span>}
                  </span>
                </button>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
