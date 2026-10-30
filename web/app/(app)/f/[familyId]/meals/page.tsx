import Link from "next/link";
import { redirect } from "next/navigation";
import { BookOpen, CalendarDays, UserPlus } from "lucide-react";
import { db } from "@/lib/db";
import { requireFamily } from "@/lib/families/page";
import { countRecipes } from "@/lib/meals/queries/recipes";
import { getI18n } from "@/lib/i18n/server";

export const dynamic = "force-dynamic";

/** The module's entry: the recipes, or — while the family has none yet — a short welcome
 *  (cookless's /welcome) pointing at the first steps. */
export default async function MealsPage({ params }: { params: Promise<{ familyId: string }> }) {
  const { familyId } = await params;
  const { role } = await requireFamily(familyId);
  const base = `/f/${familyId}/meals`;
  if (countRecipes(db, familyId) > 0 || role !== "editor") redirect(`${base}/recipes`);
  const { t } = await getI18n();
  const links = [
    { href: `${base}/recipes/new?list=KNOWN`, icon: BookOpen, title: t("meals.welcome.addRecipe"), desc: t("meals.welcome.addRecipeDescription") },
    { href: `${base}/plan`, icon: CalendarDays, title: t("meals.welcome.createPlan"), desc: t("meals.welcome.createPlanDescription") },
    { href: `/f/${familyId}/settings`, icon: UserPlus, title: t("meals.welcome.inviteMember"), desc: t("meals.welcome.inviteMemberDescription") },
  ];
  return (
    <div className="flex flex-1 items-center justify-center py-6">
      <div className="w-full max-w-md rounded-xl border bg-card p-6 shadow-sm">
        <h1 className="text-center text-2xl font-bold text-foreground">{t("meals.welcome.title")}</h1>
        <p className="mt-2 text-center text-sm text-muted-foreground">{t("meals.welcome.subtitle")}</p>
        <div className="mt-6 space-y-3">
          {links.map(({ href, icon: Icon, title, desc }) => (
            <Link
              key={href}
              href={href}
              className="flex items-center gap-4 rounded-lg border border-border p-4 transition-colors hover:border-primary/40 hover:bg-primary/10"
            >
              <div className="flex size-10 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary">
                <Icon size={20} />
              </div>
              <div>
                <div className="font-medium text-foreground">{title}</div>
                <div className="text-sm text-muted-foreground">{desc}</div>
              </div>
            </Link>
          ))}
        </div>
        <Link
          href={`${base}/recipes`}
          className="mt-6 block w-full rounded-md bg-primary px-4 py-2 text-center font-medium text-primary-foreground hover:bg-primary/90"
        >
          {t("meals.welcome.getStarted")}
        </Link>
      </div>
    </div>
  );
}
