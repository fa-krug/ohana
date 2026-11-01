import { existsSync, mkdtempSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import Database from "better-sqlite3";
import { drizzle } from "drizzle-orm/better-sqlite3";
import { migrate } from "drizzle-orm/better-sqlite3/migrator";
import { describe, expect, it } from "vitest";
import { backupDatabase, backupName, hasBackupFor } from "@/lib/maintenance/backup";
import { cleanup } from "@/lib/maintenance/cleanup";
import { migrationsApplied } from "@/lib/maintenance/migrations";
import { createToken } from "@/lib/auth/tokens";
import { createInvite, INVITE_TTL_MS } from "@/lib/families/invites";
import { createTestDb } from "@/lib/test/db";
import { NOW, makeFamily, makeUser } from "@/lib/test/factories";

describe("backups", () => {
  it("write a readable copy per day and keep the newest ones", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ohana-backup-"));
    const live = new Database(join(dir, "live.db"));
    live.exec("create table t (x); insert into t values (42);");
    writeFileSync(join(dir, "ohana-2026-01-01.db"), "");
    writeFileSync(join(dir, "ohana-2026-01-02.db"), "");
    writeFileSync(join(dir, "notes.txt"), "keep me");

    expect(hasBackupFor(dir, NOW)).toBe(false);
    const { file, removed } = await backupDatabase(live, dir, NOW, 2);
    expect(file).toBe(join(dir, backupName(NOW)));
    expect(hasBackupFor(dir, NOW)).toBe(true);
    expect(removed).toEqual(["ohana-2026-01-01.db"]);
    expect(readdirSync(dir).sort()).toEqual(["live.db", "notes.txt", "ohana-2026-01-02.db", "ohana-2026-11-01.db"]);
    const copy = new Database(file, { readonly: true });
    expect(copy.prepare("select x from t").get()).toEqual({ x: 42 });
    copy.close();
    live.close();
    expect(existsSync(join(dir, "ohana-2026-01-01.db"))).toBe(false);
  });
});

describe("cleanup", () => {
  it("removes expired tokens and invites", () => {
    const db = createTestDb();
    const u = makeUser(db);
    const f = makeFamily(db, u.id);
    createToken(db, { userId: u.id, kind: "setup" }, NOW);
    createToken(db, { userId: u.id, kind: "api" }, NOW);
    createInvite(db, { id: u.id }, f.id, "viewer", NOW);
    const later = new Date(NOW.getTime() + INVITE_TTL_MS + 60_000);
    expect(cleanup(db, later)).toEqual({ tokens: 1, invites: 1, rateLimits: 0, dismissals: 0 });
  });
});

describe("migrationsApplied", () => {
  it("is false on an empty database and true after migrating", () => {
    const empty = new Database(":memory:");
    expect(migrationsApplied(empty, "./drizzle")).toBe(false);
    migrate(drizzle(empty), { migrationsFolder: "./drizzle" });
    expect(migrationsApplied(empty, "./drizzle")).toBe(true);
  });
});
