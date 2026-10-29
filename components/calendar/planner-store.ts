// One open family calendar: the types, entries and notes of one year, with the queue that saves
// local edits, polling for other people's changes, undo / redo and the day selection. No DOM:
// the grid (grid.ts) and React components subscribe to it. Ported from family-planner's
// app/src/features/vacation/store.ts (without its offline cache; Ohana's API signs in with the
// session cookie).

import {
  addDays,
  applyDays,
  applyNotes,
  changedNotesOnly,
  changedOnly,
  clearDays,
  daysInMonth,
  type Entries,
  type EntryOp,
  type EntryType,
  fillWith,
  gapDays,
  iso,
  isWeekend,
  nextColor,
  type Note,
  type NoteOp,
  type Notes,
  parseClipboardText,
  pasteTargets,
  type Pattern,
  patternOf,
  range,
  type Role,
  toClipboardText,
  toggleType,
  toNoteOps,
  toOps,
} from "@/lib/calendar/core";
import type { TVars } from "@/lib/i18n/translate";
import { api, ApiError, type Birthday, type CalEvent, type Family, type FamilyState } from "./api";
import { setSkipWeekends, viewPrefs } from "./view-prefs";

const POLL_MS = 15000;
const MAX_DAYS_PER_REQUEST = 4000; // server limit

export type SyncKey = "" | "saved" | "saving" | "loading" | "updating" | "retrying" | "offline";

/** What changed: "data" (entries, notes, types, family), "selection", or "ui" (anything else). */
export type Change = "data" | "selection" | "ui";

export interface I18n {
  locale: string;
  t: (key: string, vars?: TVars) => string;
  tList: (key: string) => string[];
}

type NoteChange = Map<string, Note | null>;
type Step =
  | { kind: "entries"; before: Entries; after: Entries }
  | { kind: "notes"; before: NoteChange; after: NoteChange };
type Batch = { kind: "entries"; ops: EntryOp[] } | { kind: "notes"; ops: NoteOp[] };

/** Today in the device's time zone. */
export function todayIso(): string {
  const d = new Date();
  return iso(d.getFullYear(), d.getMonth(), d.getDate());
}

export class PlannerStore {
  readonly familyId: string;
  family: Family | null = null;
  types: EntryType[] = []; // the types of `year`; every year has its own
  typeYears: number[] | null = null; // years that have types (null until loaded)
  entries: Entries = new Map();
  notes: Notes = new Map();
  /** Timed events (booked appointments) by day; read-only here. */
  events = new Map<string, CalEvent[]>();
  /** The members' birthdays by day; read-only here. */
  birthdays = new Map<string, Birthday[]>();
  year: number;
  readOnly: boolean;
  notFound = false;
  selection = new Set<string>();
  anchor: string | null = null;
  focus: string | null = null;
  clipboard: { pattern: Pattern; text: string; year: number } | null = null;
  undoStack: Step[] = [];
  redoStack: Step[] = [];
  rangeMode = false;
  multi = false; // touch: taps add days to the selection or remove them
  sync: { key: SyncKey; error: boolean } = { key: "", error: false };
  /** Set by the grid while a pointer drag runs, so polling waits. */
  dragging = false;
  /** Bumps on every emitted change; React reads it through useSyncExternalStore. */
  rev = 0;
  i18n: I18n;

  private version = 0; // bumps on every local change; stale poll responses are dropped
  private queue: Batch[] = [];
  private flushing = false;
  private retryDelay = 2000;
  private wake: (() => void) | null = null; // ends the retry backoff early
  private lastResponse: string | null = null; // JSON of the last applied response...
  private appliedVersion = -1; // ...and version right after applying it
  private reloadAfterSave = false; // a load was dropped because of local changes
  private listeners = new Set<(change: Change) => void>();
  private stopPolling: (() => void) | null = null;
  private closed = false;

  private toast: (msg: string) => void;

  constructor(familyId: string, year: number, opts: { readOnly: boolean; i18n: I18n; toast: (msg: string) => void }) {
    this.familyId = familyId;
    this.year = year;
    this.readOnly = opts.readOnly;
    this.i18n = opts.i18n;
    this.toast = opts.toast;
  }

  private t(key: string, vars?: TVars) {
    return this.i18n.t(key, vars);
  }

  /** A language switch: the grid rebuilds its month and weekday names. */
  setI18n(i18n: I18n) {
    const changed = i18n.locale !== this.i18n.locale;
    this.i18n = i18n;
    if (changed) this.emit("ui");
  }

  // ------------------------------------------------------------- subscriptions

  subscribe = (fn: (change: Change) => void) => {
    this.listeners.add(fn);
    return () => {
      this.listeners.delete(fn);
    };
  };

  getRev = () => this.rev;

  private emit(change: Change) {
    this.rev++;
    for (const fn of this.listeners) fn(change);
  }

  get pending(): boolean {
    return this.queue.length > 0 || this.flushing;
  }

  get skipWeekends(): boolean {
    return viewPrefs().skipWeekends;
  }

  private setSync(key: SyncKey, error = false) {
    this.sync = { key, error };
    this.emit("ui");
  }

  typeById(id: string) {
    return this.types.find((t) => t.id === id);
  }

  // ------------------------------------------------------------- loading + saving

  private applyResponse(data: FamilyState, json = JSON.stringify(data)) {
    this.family = data.family;
    this.readOnly = data.family.readOnly;
    this.types = data.types;
    this.typeYears = data.typeYears ?? null;
    this.entries = new Map(Object.entries(data.entries));
    this.notes = new Map(Object.entries(data.notes ?? {}));
    this.events = new Map(Object.entries(data.events ?? {}));
    this.birthdays = new Map(Object.entries(data.birthdays ?? {}));
    this.lastResponse = json;
    this.appliedVersion = this.version;
  }

  /** Loads, and starts polling. */
  async open() {
    this.closed = false;
    this.setSync("loading");
    if (!(await this.load()) || this.closed) return;
    this.startPolling();
  }

  close() {
    this.closed = true;
    this.stopPolling?.();
    this.stopPolling = null;
  }

  /** Fetches and shows the family; resolves to false if it doesn't exist. */
  async load({ quiet = false }: { quiet?: boolean } = {}) {
    const { version, year } = this;
    try {
      const data = await api.getFamily(this.familyId, year);
      // Ignore if the user changed something meanwhile or switched years.
      if (version !== this.version || year !== this.year || this.queue.length) {
        this.reloadAfterSave = true; // catch up once the queued changes are saved
        return true;
      }
      this.reloadAfterSave = false;
      const json = JSON.stringify(data);
      // Skip identical responses unless something changed locally since the last one.
      const changed = json !== this.lastResponse || this.appliedVersion !== this.version;
      if (changed) {
        this.applyResponse(data, json);
        this.emit("data");
      }
      if (!quiet || this.sync.error) this.setSync("saved");
    } catch (err) {
      const e = err as ApiError;
      if (e.status === 404) {
        this.notFound = true;
        this.emit("data");
        return false;
      }
      if (!quiet) this.toast(this.t("calendar.toast.loadFailed", { msg: e.message }));
      this.setSync("offline", true);
    }
    return true;
  }

  private isIdle() {
    return (
      document.visibilityState === "visible" &&
      !this.dragging &&
      !this.queue.length &&
      !document.querySelector('[role="dialog"], [role="alertdialog"]')
    );
  }

  private startPolling() {
    if (this.stopPolling) return;
    const poll = () => this.isIdle() && this.load({ quiet: true });
    const online = () => {
      if (this.wake) this.wake();
      else poll();
    };
    const timer = setInterval(poll, POLL_MS);
    document.addEventListener("visibilitychange", poll);
    window.addEventListener("online", online);
    this.stopPolling = () => {
      clearInterval(timer);
      document.removeEventListener("visibilitychange", poll);
      window.removeEventListener("online", online);
    };
  }

  private enqueue(batch: Batch) {
    if (!batch.ops.length) return;
    this.queue.push(batch);
    void this.flush();
  }

  private async flush() {
    if (this.flushing) return;
    this.flushing = true;
    while (this.queue.length) {
      this.setSync("saving");
      // Send queued batches as one request; ops are applied in order, so this is equivalent.
      // Entries and notes go to different endpoints, so a request holds only one kind.
      const kind = this.queue[0].kind;
      const ops: (EntryOp | NoteOp)[] = [];
      let n = 0;
      let days = 0;
      for (; n < this.queue.length && this.queue[n].kind === kind; n++) {
        const size = (this.queue[n].ops as (EntryOp | NoteOp)[]).reduce((sum, op) => sum + op.dates.length, 0);
        if (n && days + size > MAX_DAYS_PER_REQUEST) break;
        days += size;
        ops.push(...this.queue[n].ops);
      }
      try {
        if (kind === "entries") await api.applyOps(this.familyId, ops as EntryOp[]);
        else await api.applyNoteOps(this.familyId, ops as NoteOp[]);
        this.queue.splice(0, n);
        this.retryDelay = 2000;
      } catch (err) {
        const e = err as ApiError;
        // 429 (rate limit) is temporary: keep the changes and retry with the backoff below.
        if (e.status && e.status < 500 && e.status !== 429) {
          // The server rejected it (e.g. a type was deleted elsewhere): drop and resync.
          this.queue.splice(0, n);
          this.toast(this.t("calendar.toast.saveFailed", { msg: e.message }));
          await this.load();
          continue;
        }
        this.setSync("retrying", true);
        await new Promise<void>((r) => {
          this.wake = r;
          setTimeout(r, this.retryDelay);
        });
        this.wake = null;
        this.retryDelay = Math.min(this.retryDelay * 2, 30000);
      }
    }
    this.flushing = false;
    this.setSync("saved");
    if (this.reloadAfterSave) void this.load({ quiet: true });
  }

  // ------------------------------------------------------------- editing

  /** Applies day changes locally, records undo and sends them to the server. */
  commit(next: Entries, { record = true } = {}) {
    if (this.readOnly) return;
    const changes = changedOnly(this.entries, next);
    if (!changes.size) return;
    const before: Entries = new Map([...changes.keys()].map((d) => [d, [...(this.entries.get(d) ?? [])]]));
    const ops = toOps(this.entries, changes);
    applyDays(this.entries, changes);
    this.version++;
    if (record) this.recordStep({ kind: "entries", before, after: changes });
    this.enqueue({ kind: "entries", ops });
    this.emit("data");
  }

  /** Same as commit() for day notes (next: Map<date, note | null>). */
  commitNotes(next: Map<string, Note | null>, { record = true } = {}) {
    if (this.readOnly) return;
    const changes = changedNotesOnly(this.notes, next);
    if (!changes.size) return;
    const before: NoteChange = new Map([...changes.keys()].map((d) => [d, this.notes.get(d) ?? null]));
    const ops = toNoteOps(changes);
    applyNotes(this.notes, changes);
    this.version++;
    if (record) this.recordStep({ kind: "notes", before, after: changes });
    this.enqueue({ kind: "notes", ops });
    this.emit("data");
  }

  private recordStep(step: Step) {
    this.undoStack.push(step);
    if (this.undoStack.length > 200) this.undoStack.shift();
    this.redoStack = [];
  }

  private applyStep(step: Step, which: "before" | "after") {
    if (step.kind === "notes") this.commitNotes(step[which], { record: false });
    else this.commit(step[which], { record: false });
  }

  undo() {
    const step = this.undoStack.pop();
    if (!step) return this.toast(this.t("calendar.toast.nothingUndo"));
    this.applyStep(step, "before");
    this.redoStack.push(step);
    this.emit("ui");
  }

  redo() {
    const step = this.redoStack.pop();
    if (!step) return this.toast(this.t("calendar.toast.nothingRedo"));
    this.applyStep(step, "after");
    this.undoStack.push(step);
    this.emit("ui");
  }

  selectedDays(): string[] {
    return [...this.selection].sort();
  }

  /** Selected days honoring the "skip weekends" option. */
  targetDays(days = this.selectedDays()): string[] {
    const skip = this.skipWeekends && days.length > 1;
    return skip ? days.filter((d) => !isWeekend(d)) : days;
  }

  setSkipWeekends(on: boolean) {
    setSkipWeekends(on);
    this.emit("ui");
  }

  toggleOnSelection(typeId: string) {
    if (this.readOnly) return;
    const days = this.targetDays();
    if (!days.length) return this.toast(this.t("calendar.toast.selectFirst"));
    this.commit(toggleType(this.entries, days, typeId));
  }

  clearSelectedDays() {
    const days = this.selectedDays();
    if (days.length) this.commit(clearDays(days));
  }

  copySelection(): string | null {
    const days = this.selectedDays();
    if (!days.length) return null;
    // Copy the whole span so gaps between selected days are kept.
    const span = range(days[0], days[days.length - 1]);
    const pattern = patternOf(this.entries, span);
    const text = toClipboardText(span, pattern, this.types);
    this.clipboard = { pattern, text, year: this.year };
    this.toast(this.t("calendar.toast.copiedDays", { count: span.length }));
    return text;
  }

  pastePattern(pattern: Pattern) {
    if (this.readOnly) return;
    const days = this.selectedDays();
    if (!days.length) return this.toast(this.t("calendar.toast.selectPaste"));
    if (!pattern.length) return;
    const targets =
      days.length === 1
        ? pasteTargets(days, pattern.length, `${this.year}-12-31`, this.skipWeekends)
        : this.targetDays(days);
    this.commit(fillWith(targets, pattern));
    if (days.length === 1) this.select(targets[0], targets[targets.length - 1]);
  }

  /** Pastes clipboard text: our own copy if it is one, else type names per line. */
  pasteText(text: string) {
    if (this.readOnly) return;
    const own = this.clipboard && (text === this.clipboard.text || !text.trim());
    // Prefer our own copy (keeps type ids even if names are duplicated). Ids belong to the
    // year they were copied in, so in another year the types are matched by name instead.
    if (own && this.clipboard!.year === this.year) {
      return this.pastePattern(this.clipboard!.pattern);
    }
    if (own) text = this.clipboard!.text;
    if (!text.trim()) return;
    const { pattern, unknown } = parseClipboardText(text, this.types);
    if (unknown.length) {
      this.toast(this.t("calendar.toast.unknownTypes", { count: unknown.length, names: unknown.join(", ") }));
    }
    this.pastePattern(pattern);
  }

  // ------------------------------------------------------------- selection

  select(a: string, b = a, { add = false } = {}) {
    if (!add) this.selection.clear();
    for (const d of range(a, b)) {
      if (d.startsWith(String(this.year))) this.selection.add(d);
    }
    this.anchor = a;
    this.focus = b;
    this.emit("selection");
  }

  /** Replaces the selection, e.g. while dragging from a saved base selection. */
  setSelection(days: Set<string>) {
    this.selection = new Set(days);
  }

  /** Adds a single day to the selection, or removes it if it is already selected. */
  toggleDay(date: string) {
    if (!this.selection.has(date)) {
      return this.select(date, date, { add: true });
    }
    this.selection.delete(date);
    this.anchor = this.focus = date;
    this.emit("selection");
  }

  deselect() {
    this.selection.clear();
    this.multi = false;
    this.emit("selection");
  }

  setMulti(on: boolean) {
    this.multi = on;
    this.emit("ui");
  }

  setRangeMode(on: boolean) {
    this.rangeMode = on;
    this.emit("ui");
  }

  /** Arrow keys: by days (or weeks in the month view), or a month with |delta| >= 31. */
  moveFocus(delta: number, extend: boolean): string | null {
    const from = this.focus ?? todayIso();
    let next: string;
    if (Math.abs(delta) < 31) next = addDays(from, delta);
    else {
      // Up/down: same day number in the previous/next month (clamped).
      const [y, m, d] = from.split("-").map(Number);
      const month = m - 1 + Math.sign(delta);
      if (month < 0 || month > 11) return null;
      next = iso(y, month, Math.min(d, daysInMonth(y, month)));
    }
    if (!next.startsWith(String(this.year))) return null;
    if (extend) this.select(this.anchor ?? from, next);
    else this.select(next);
    return next;
  }

  /** Selects the next day that needs cover; returns it, or null if there is none. */
  nextGap(): string | null {
    const gaps = gapDays(this.entries, this.types, this.year);
    if (!gaps.length) {
      this.toast(this.t("calendar.toast.noGaps", { year: this.year }));
      return null;
    }
    const after = gaps.find((d) => d > (this.focus ?? "")) ?? gaps[0];
    this.select(after);
    return after;
  }

  // ------------------------------------------------------------- years

  setYear(y: number) {
    if (y < 1900 || y > 2200 || y === this.year) return;
    this.year = y;
    this.selection.clear();
    this.anchor = this.focus = null;
    // Undo steps hold type ids of the year they were made in.
    this.undoStack = [];
    this.redoStack = [];
    this.version++;
    this.types = [];
    this.typeYears = null;
    this.entries = new Map();
    this.notes = new Map();
    this.setSync("loading");
    this.emit("data");
    void this.load();
  }

  /** The year to copy types from when this year has none: the closest earlier one, else later. */
  copySource(): number | null {
    const years = (this.typeYears ?? []).filter((y) => y !== this.year);
    return years.filter((y) => y < this.year).pop() ?? years[0] ?? null;
  }

  // ------------------------------------------------------------- family + types

  async rotateLink(link: "feed" | "legacy") {
    const data = await api.rotateLink(this.familyId, link, this.year);
    if (this.family) this.family = { ...this.family, ...data.family };
    if (link === "legacy" && this.family) delete this.family.legacyId;
    this.emit("data");
  }

  async updateType(id: string, patch: Partial<EntryType>) {
    // Look the type up again: a refresh may have replaced the objects.
    const current = this.typeById(id);
    if (current) Object.assign(current, patch);
    this.types = [...this.types];
    this.version++;
    this.emit("data");
    try {
      await api.updateType(this.familyId, this.year, id, patch);
    } catch (err) {
      this.toast(this.t("calendar.toast.typeSaveFailed", { msg: (err as Error).message }));
      await this.load();
    }
  }

  async moveType(i: number, dir: -1 | 1) {
    const j = i + dir;
    const types = [...this.types];
    [types[i], types[j]] = [types[j], types[i]];
    types.forEach((t, k) => (t.position = k));
    this.types = types;
    this.version++;
    this.emit("data");
    try {
      await Promise.all([
        api.updateType(this.familyId, this.year, types[i].id, { position: i }),
        api.updateType(this.familyId, this.year, types[j].id, { position: j }),
      ]);
    } catch (err) {
      this.toast(this.t("calendar.toast.reorderFailed", { msg: (err as Error).message }));
    }
  }

  /** Days of the shown year that use a type. */
  daysWith(typeId: string): number {
    return [...this.entries.values()].filter((ids) => ids.includes(typeId)).length;
  }

  async deleteType(id: string) {
    try {
      await api.deleteType(this.familyId, this.year, id);
      this.types = this.types.filter((x) => x.id !== id);
      for (const [d, ids] of this.entries) {
        const rest = ids.filter((x) => x !== id);
        if (rest.length) this.entries.set(d, rest);
        else this.entries.delete(d);
      }
      if (!this.types.length) {
        this.typeYears = (this.typeYears ?? []).filter((y) => y !== this.year);
      }
      this.undoStack = [];
      this.redoStack = [];
      this.version++;
      this.emit("data");
    } catch (err) {
      this.toast(this.t("calendar.toast.deleteFailed", { msg: (err as Error).message }));
    }
  }

  async addType(): Promise<EntryType | null> {
    const n = this.types.length + 1;
    try {
      const type = await api.addType(this.familyId, this.year, {
        name: this.t("calendar.types.newName", { n }),
        color: nextColor(this.types),
        role: "none" as Role,
      });
      this.types = [...this.types, type];
      this.addTypeYear(this.year);
      this.version++;
      this.emit("data");
      return type;
    } catch (err) {
      this.toast(this.t("calendar.toast.addTypeFailed", { msg: (err as Error).message }));
      return null;
    }
  }

  private addTypeYear(year: number) {
    const years = new Set(this.typeYears ?? []);
    this.typeYears = [...years.add(year)].sort((a, b) => a - b);
  }

  async copyTypes(from: number): Promise<boolean> {
    const year = this.year;
    try {
      const types = await api.copyTypes(this.familyId, from, year);
      if (year !== this.year) return true;
      this.types = types;
      this.addTypeYear(year);
      this.version++;
      this.emit("data");
      return true;
    } catch (err) {
      this.toast(this.t("calendar.toast.copyTypesFailed", { msg: (err as Error).message }));
      return false;
    }
  }

  /** Lets the backoff of a failed save end early (e.g. the network came back). */
  retryNow() {
    this.wake?.();
  }
}
