"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { useParams, usePathname } from "next/navigation";
import {
  ChevronsUpDown,
  Check,
  Menu,
  PanelLeftClose,
  PanelLeftOpen,
  Plus,
  Settings,
  ShieldCheck,
  Sparkles,
  LogOut,
  UserRound,
} from "lucide-react";
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

const SIDEBAR_KEY = "ohana.sidebarCollapsed";

function readSidebarCollapsed(): boolean {
  try {
    return localStorage.getItem(SIDEBAR_KEY) === "1";
  } catch {
    return false;
  }
}

function writeSidebarCollapsed(collapsed: boolean): void {
  try {
    localStorage.setItem(SIDEBAR_KEY, collapsed ? "1" : "0");
  } catch {
    // Private mode or blocked storage: the sidebar just isn't remembered.
  }
}

/** Runs while the page is parsed, before the first paint: marks the desktop sidebar
 *  (its parent) collapsed, so a collapsed sidebar doesn't flash open. Everything that
 *  looks different in the rail is CSS on that attribute (`group-data-[collapsed]/sidebar`). */
const SIDEBAR_SCRIPT = `try{if(localStorage.getItem(${JSON.stringify(SIDEBAR_KEY)})==="1")document.currentScript.parentElement.setAttribute("data-collapsed","")}catch(e){}`;

let sidebarHydrated = false;

/** SIDEBAR_SCRIPT, only in the server's HTML: React never runs a script it creates on the
 *  client (and warns about it), so later mounts (another family) leave it out. */
function SidebarScript() {
  const [render] = useState(() => !sidebarHydrated);
  useEffect(() => {
    sidebarHydrated = true;
  }, []);
  return render ? <script dangerouslySetInnerHTML={{ __html: SIDEBAR_SCRIPT }} /> : null;
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
  // Desktop sidebar as an icon rail. Hydration starts expanded (SIDEBAR_SCRIPT already
  // collapsed the HTML); later mounts (another family) read the setting right away.
  const [collapsed, setCollapsed] = useState(() => sidebarHydrated && readSidebarCollapsed());

  useEffect(() => setAssistantOpen(readAssistantOpen()), []);
  useEffect(() => setCollapsed(readSidebarCollapsed()), []);
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

  const toggleSidebar = useCallback(() => {
    setCollapsed((was) => {
      writeSidebarCollapsed(!was);
      return !was;
    });
  }, []);

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (!(e.ctrlKey || e.metaKey) || e.altKey || e.shiftKey) return;
      const key = e.key.toLowerCase();
      if (key === "j") {
        e.preventDefault();
        toggleAssistant();
      } else if (key === "b" && window.matchMedia("(min-width: 768px)").matches) {
        e.preventDefault();
        toggleSidebar();
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [toggleAssistant, toggleSidebar]);

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
      {/* Left sidebar: desktop, collapsible to an icon rail. `data-collapsed` is set by
          SIDEBAR_SCRIPT before hydration, hence suppressHydrationWarning. */}
      <aside
        data-collapsed={collapsed ? "" : undefined}
        suppressHydrationWarning
        className="group/sidebar sticky top-0 hidden h-dvh w-64 shrink-0 flex-col border-r bg-sidebar text-sidebar-foreground transition-[width] duration-200 ease-out data-[collapsed]:w-14 motion-reduce:transition-none md:flex"
      >
        <SidebarScript />
        <SidebarContent
          user={user}
          families={families}
          family={family}
          pathname={pathname}
          collapsed={collapsed}
          onToggle={toggleSidebar}
        />
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

/** The sidebar's content. On desktop it gets `onToggle` and can be collapsed to an icon
 *  rail: the rail's look is CSS on the aside's `data-collapsed` (so it is right before
 *  hydration), `collapsed` only adds titles, labels and menu sides. */
function SidebarContent({
  user,
  families,
  family,
  pathname,
  collapsed = false,
  onToggle,
}: {
  user: ShellUser;
  families: ShellFamily[];
  family: ShellFamily | null;
  pathname: string;
  collapsed?: boolean;
  onToggle?: () => void;
}) {
  const { t } = useT();
  const base = family ? `/f/${family.id}` : null;

  const link = (href: string, label: string, Icon: React.ComponentType<{ className?: string }>, extra?: React.ReactNode) => {
    const active = href === base ? pathname === href : pathname === href || pathname.startsWith(`${href}/`);
    return (
      <Link
        key={href}
        href={href}
        title={collapsed ? label : undefined}
        aria-label={collapsed ? label : undefined}
        aria-current={active ? "page" : undefined}
        className={cn(
          "flex items-center gap-2.5 rounded-md px-3 py-2 text-sm font-medium transition-colors group-data-[collapsed]/sidebar:justify-center group-data-[collapsed]/sidebar:px-0",
          active ? "bg-primary text-primary-foreground" : "hover:bg-sidebar-accent hover:text-sidebar-accent-foreground",
        )}
      >
        <Icon className="size-4 shrink-0" />
        <span className="min-w-0 flex-1 truncate group-data-[collapsed]/sidebar:hidden">{label}</span>
        {extra && <span className="group-data-[collapsed]/sidebar:hidden">{extra}</span>}
      </Link>
    );
  };

  const toggleLabel = collapsed ? t("nav.expandSidebar") : t("nav.collapseSidebar");

  return (
    <div className="flex h-full flex-col gap-1 overflow-x-hidden overflow-y-auto p-3 group-data-[collapsed]/sidebar:px-2">
      <div className="flex items-center gap-1 group-data-[collapsed]/sidebar:flex-col">
        <FamilySwitcher families={families} family={family} collapsed={collapsed} />
        {onToggle && (
          <Button
            variant="ghost"
            size="icon"
            title={toggleLabel}
            aria-label={toggleLabel}
            aria-expanded={!collapsed}
            onClick={onToggle}
            className="size-8 shrink-0 text-muted-foreground hover:bg-sidebar-accent"
          >
            <PanelLeftClose className="size-4 group-data-[collapsed]/sidebar:hidden" />
            <PanelLeftOpen className="hidden size-4 group-data-[collapsed]/sidebar:block" />
          </Button>
        )}
      </div>

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
        <AccountMenu user={user} collapsed={collapsed} />
      </div>
    </div>
  );
}

function FamilySwitcher({
  families,
  family,
  collapsed,
}: {
  families: ShellFamily[];
  family: ShellFamily | null;
  collapsed: boolean;
}) {
  const { t } = useT();
  const name = family?.name ?? "Ohana";
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button
          type="button"
          title={collapsed ? name : undefined}
          aria-label={collapsed ? `${t("nav.families")}: ${name}` : undefined}
          className="flex w-full min-w-0 items-center gap-2 rounded-md px-2 py-2 text-left hover:bg-sidebar-accent group-data-[collapsed]/sidebar:w-auto group-data-[collapsed]/sidebar:p-1"
        >
          <span className="flex size-8 shrink-0 items-center justify-center rounded-md bg-primary text-sm font-bold text-primary-foreground">
            {(family?.name ?? "O").slice(0, 1).toUpperCase()}
          </span>
          <span className="min-w-0 flex-1 group-data-[collapsed]/sidebar:hidden">
            <span className="block truncate text-sm font-semibold">{name}</span>
            {family && <span className="block truncate text-xs text-muted-foreground">{t(`roles.${family.role}`)}</span>}
          </span>
          <ChevronsUpDown className="size-4 shrink-0 text-muted-foreground group-data-[collapsed]/sidebar:hidden" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent
        align="start"
        side={collapsed ? "right" : "bottom"}
        sideOffset={collapsed ? 12 : 4}
        className="w-60"
      >
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

function AccountMenu({ user, collapsed }: { user: ShellUser; collapsed: boolean }) {
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
        <button
          type="button"
          title={collapsed ? user.name || user.email : undefined}
          aria-label={collapsed ? `${t("nav.account")}: ${user.name || user.email}` : undefined}
          className="flex w-full items-center gap-2.5 rounded-md px-3 py-2 text-left text-sm hover:bg-sidebar-accent group-data-[collapsed]/sidebar:justify-center group-data-[collapsed]/sidebar:px-0"
        >
          <UserRound className="size-4 shrink-0" />
          <span className="min-w-0 flex-1 group-data-[collapsed]/sidebar:hidden">
            <span className="block truncate font-medium">{user.name || user.email}</span>
            {user.name && <span className="block truncate text-xs text-muted-foreground">{user.email}</span>}
          </span>
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent
        align={collapsed ? "end" : "start"}
        side={collapsed ? "right" : "top"}
        sideOffset={collapsed ? 12 : 4}
        className="w-56"
      >
        <DropdownMenuItem asChild>
          <Link href="/account" className="flex items-center gap-2">
            <UserRound className="size-4" /> {t("nav.account")}
          </Link>
        </DropdownMenuItem>
        <DropdownMenuSeparator />
        <DropdownMenuItem onSelect={onSignOut} className="flex items-center gap-2">
          <LogOut className="size-4" /> {t("nav.signOut")}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
