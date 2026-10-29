"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { useParams, usePathname } from "next/navigation";
import { ChevronsUpDown, Check, Menu, Plus, Settings, ShieldCheck, Sparkles, LogOut, UserRound } from "lucide-react";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Sheet, SheetContent, SheetTitle } from "@/components/ui/sheet";
import { useT } from "@/lib/i18n/provider";
import { logoutAction } from "@/app/actions/auth";
import { AssistantProvider } from "@/components/assistant/context";
import { ChatView } from "@/components/assistant/chat-panel";
import { MODULES, OVERVIEW_ICON } from "./modules";

export interface ShellFamily {
  id: string;
  name: string;
  role: "editor" | "viewer";
}

export interface ShellUser {
  name: string;
  email: string;
  isAdmin: boolean;
}

const ASSISTANT_KEY = "ohana.assistantOpen";

function readAssistantOpen(): boolean {
  try {
    return localStorage.getItem(ASSISTANT_KEY) === "1";
  } catch {
    return false;
  }
}

function writeAssistantOpen(open: boolean): void {
  try {
    localStorage.setItem(ASSISTANT_KEY, open ? "1" : "0");
  } catch {
    // Private mode or blocked storage: the panel just isn't remembered.
  }
}

/** The app's frame: the left sidebar (families, modules, account) and the right
 *  assistant panel; both are sheets on phones. */
export function AppShell({
  user,
  families,
  defaultFamilyId,
  children,
}: {
  user: ShellUser;
  families: ShellFamily[];
  /** The family shown in the sidebar on pages outside a family (account, admin). */
  defaultFamilyId: string | null;
  children: React.ReactNode;
}) {
  const { t } = useT();
  const params = useParams<{ familyId?: string }>();
  const pathname = usePathname();
  const family = families.find((f) => f.id === (params.familyId ?? defaultFamilyId)) ?? null;
  const [navOpen, setNavOpen] = useState(false);
  const [assistantOpen, setAssistantOpen] = useState(false); // desktop panel
  const [assistantSheet, setAssistantSheet] = useState(false); // phones

  useEffect(() => setAssistantOpen(readAssistantOpen()), []);
  useEffect(() => setNavOpen(false), [pathname]);

  const toggleAssistant = useCallback(() => {
    if (window.matchMedia("(min-width: 1024px)").matches) {
      setAssistantOpen((open) => {
        writeAssistantOpen(!open);
        return !open;
      });
    } else {
      setAssistantSheet((open) => !open);
    }
  }, []);

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "j") {
        e.preventDefault();
        toggleAssistant();
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [toggleAssistant]);

  // The year calendar uses the whole width.
  const wide = /^\/f\/[^/]+\/calendar$/.test(pathname);

  const nav = <SidebarContent user={user} families={families} family={family} pathname={pathname} />;

  const closeAssistant = () => {
    setAssistantSheet(false);
    setAssistantOpen(false);
    writeAssistantOpen(false);
  };
  const assistant = family ? (
    <ChatView onClose={closeAssistant} />
  ) : (
    <AssistantPlaceholder onClose={closeAssistant} />
  );

  const frame = (
    <div className="flex min-h-dvh bg-background">
      {/* Left sidebar: desktop */}
      <aside className="sticky top-0 hidden h-dvh w-64 shrink-0 flex-col border-r bg-sidebar text-sidebar-foreground md:flex">
        {nav}
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        {/* Top bar: phones */}
        <header className="sticky top-0 z-30 flex items-center gap-2 border-b bg-background/95 px-3 py-2 backdrop-blur md:hidden">
          <Button variant="ghost" size="icon" aria-label={t("nav.openMenu")} onClick={() => setNavOpen(true)}>
            <Menu className="size-5" />
          </Button>
          <span className="min-w-0 flex-1 truncate font-semibold">{family?.name ?? "Ohana"}</span>
          <Button variant="ghost" size="icon" aria-label={t("nav.assistant")} onClick={toggleAssistant}>
            <Sparkles className="size-5" />
          </Button>
        </header>
        <main className={cn("mx-auto w-full flex-1 px-4 py-6 sm:px-6", wide ? "max-w-none" : "max-w-5xl")}>{children}</main>
      </div>

      {/* Right sidebar: desktop rail + panel */}
      <aside className="sticky top-0 hidden h-dvh shrink-0 border-l bg-sidebar lg:flex" aria-label={t("assistant.title")}>
        {assistantOpen ? (
          <div className="flex w-96 flex-col">{assistant}</div>
        ) : (
          <button
            type="button"
            title={t("nav.toggleAssistant")}
            aria-label={t("nav.toggleAssistant")}
            onClick={toggleAssistant}
            className="flex w-12 justify-center pt-4 text-muted-foreground hover:text-primary"
          >
            <Sparkles className="size-5" />
          </button>
        )}
      </aside>

      {/* Phones */}
      <Sheet open={navOpen} onOpenChange={setNavOpen}>
        <SheetContent side="left" closeLabel={t("common.close")}>
          <SheetTitle className="sr-only">{t("nav.openMenu")}</SheetTitle>
          {nav}
        </SheetContent>
      </Sheet>
      <Sheet open={assistantSheet} onOpenChange={setAssistantSheet}>
        <SheetContent
          side="right"
          closeLabel={t("common.close")}
          className="w-full max-w-none pt-0 sm:max-w-md [&>button:last-child]:hidden"
          aria-describedby={undefined}
        >
          <SheetTitle className="sr-only">{t("assistant.title")}</SheetTitle>
          {assistant}
        </SheetContent>
      </Sheet>
    </div>
  );

  // One chat store per family (the panel keeps its chat while it is closed and reopened).
  return family ? (
    <AssistantProvider key={family.id} familyId={family.id}>
      {frame}
    </AssistantProvider>
  ) : (
    frame
  );
}

/** Outside a family (no family yet): the assistant needs one. */
function AssistantPlaceholder({ onClose }: { onClose: () => void }) {
  const { t } = useT();
  return (
    <div className="flex h-full flex-col">
      <div className="flex h-14 items-center justify-between border-b px-3">
        <span className="flex items-center gap-2 font-semibold">
          <Sparkles className="size-4 text-primary" /> {t("assistant.title")}
        </span>
        <Button variant="ghost" size="icon" aria-label={t("common.close")} onClick={onClose}>
          <span aria-hidden>×</span>
        </Button>
      </div>
      <div className="flex flex-1 flex-col items-center justify-center gap-3 p-6 text-center">
        <Sparkles className="size-8 text-primary" />
        <p className="text-sm text-muted-foreground">{t("assistant.noFamily")}</p>
      </div>
    </div>
  );
}

function SidebarContent({
  user,
  families,
  family,
  pathname,
}: {
  user: ShellUser;
  families: ShellFamily[];
  family: ShellFamily | null;
  pathname: string;
}) {
  const { t } = useT();
  const base = family ? `/f/${family.id}` : null;

  const link = (href: string, label: string, Icon: React.ComponentType<{ className?: string }>, extra?: React.ReactNode) => {
    const active = href === base ? pathname === href : pathname === href || pathname.startsWith(`${href}/`);
    return (
      <Link
        key={href}
        href={href}
        className={cn(
          "flex items-center gap-2.5 rounded-md px-3 py-2 text-sm font-medium transition-colors",
          active ? "bg-primary text-primary-foreground" : "hover:bg-sidebar-accent hover:text-sidebar-accent-foreground",
        )}
      >
        <Icon className="size-4 shrink-0" />
        <span className="min-w-0 flex-1 truncate">{label}</span>
        {extra}
      </Link>
    );
  };

  return (
    <div className="flex h-full flex-col gap-1 overflow-y-auto p-3">
      <FamilySwitcher families={families} family={family} />

      {base && (
        <nav className="mt-3 flex flex-col gap-0.5">
          {link(base, t("nav.overview"), OVERVIEW_ICON)}
          {MODULES.map((m) =>
            link(
              `${base}/${m.key}`,
              t(`nav.${m.key}`),
              m.icon,
              !m.ready && (
                <span className="rounded bg-muted px-1.5 py-0.5 text-[0.65rem] font-normal text-muted-foreground">
                  {t("common.comingSoon")}
                </span>
              ),
            ),
          )}
        </nav>
      )}

      <div className="mt-auto flex flex-col gap-0.5 pt-3">
        {base && link(`${base}/settings`, t("nav.settings"), Settings)}
        {user.isAdmin && link("/admin", t("nav.administration"), ShieldCheck)}
        <AccountMenu user={user} />
      </div>
    </div>
  );
}

function FamilySwitcher({ families, family }: { families: ShellFamily[]; family: ShellFamily | null }) {
  const { t } = useT();
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button
          type="button"
          className="flex w-full items-center gap-2 rounded-md px-2 py-2 text-left hover:bg-sidebar-accent"
        >
          <span className="flex size-8 shrink-0 items-center justify-center rounded-md bg-primary text-sm font-bold text-primary-foreground">
            {(family?.name ?? "O").slice(0, 1).toUpperCase()}
          </span>
          <span className="min-w-0 flex-1">
            <span className="block truncate text-sm font-semibold">{family?.name ?? "Ohana"}</span>
            {family && <span className="block truncate text-xs text-muted-foreground">{t(`roles.${family.role}`)}</span>}
          </span>
          <ChevronsUpDown className="size-4 shrink-0 text-muted-foreground" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="w-60">
        <DropdownMenuLabel>{t("nav.families")}</DropdownMenuLabel>
        {families.map((f) => (
          <DropdownMenuItem key={f.id} asChild>
            <Link href={`/f/${f.id}`} className="flex items-center gap-2">
              <span className="min-w-0 flex-1 truncate">{f.name}</span>
              {f.id === family?.id && <Check className="size-4" />}
            </Link>
          </DropdownMenuItem>
        ))}
        {families.length > 0 && <DropdownMenuSeparator />}
        <DropdownMenuItem asChild>
          <Link href="/families/new" className="flex items-center gap-2">
            <Plus className="size-4" /> {t("nav.newFamily")}
          </Link>
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

function AccountMenu({ user }: { user: ShellUser }) {
  const { t } = useT();
  async function onSignOut() {
    await logoutAction();
    // The service worker (meals) caches pages and recipe images: drop them with the session.
    navigator.serviceWorker?.controller?.postMessage({ type: "CLEAR_CACHES" });
    window.location.href = "/login";
  }
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button type="button" className="flex w-full items-center gap-2.5 rounded-md px-3 py-2 text-left text-sm hover:bg-sidebar-accent">
          <UserRound className="size-4 shrink-0" />
          <span className="min-w-0 flex-1">
            <span className="block truncate font-medium">{user.name || user.email}</span>
            {user.name && <span className="block truncate text-xs text-muted-foreground">{user.email}</span>}
          </span>
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" side="top" className="w-56">
        <DropdownMenuItem asChild>
          <Link href="/account" className="flex items-center gap-2">
            <UserRound className="size-4" /> {t("nav.account")}
          </Link>
        </DropdownMenuItem>
        {user.isAdmin && (
          <DropdownMenuItem asChild>
            <Link href="/admin" className="flex items-center gap-2">
              <ShieldCheck className="size-4" /> {t("nav.administration")}
            </Link>
          </DropdownMenuItem>
        )}
        <DropdownMenuSeparator />
        <DropdownMenuItem onSelect={onSignOut} className="flex items-center gap-2">
          <LogOut className="size-4" /> {t("nav.signOut")}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
