import { asc, eq } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { familyMembers, users } from "@/lib/db/schema";
import { getDictionary } from "@/lib/i18n/dictionary";
import { pickLocale } from "@/lib/i18n/locale";
import type { Locale } from "@/lib/i18n/config";
import { translate, type TVars } from "@/lib/i18n/translate";

export type TFn = (key: string, vars?: TVars) => string;

/** The language a family's notifications are written in: that of its longest-standing
 *  editor (families have no language of their own yet). */
export function familyLocale(db: Db, familyId: string): Locale {
  const rows = db
    .select({ lang: users.preferredLanguage, role: familyMembers.role })
    .from(familyMembers)
    .innerJoin(users, eq(users.id, familyMembers.userId))
    .where(eq(familyMembers.familyId, familyId))
    .orderBy(asc(familyMembers.joinedAt))
    .all();
  const editor = rows.find((r) => r.role === "editor") ?? rows[0];
  return pickLocale([editor?.lang]);
}

export function translator(locale: Locale): TFn {
  const dict = getDictionary(locale);
  return (key, vars) => translate(dict, key, vars);
}
