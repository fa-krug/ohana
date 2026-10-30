"use client";

import { useTransition } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { Edit, UtensilsCrossed, ArrowRightLeft, Trash2 } from "lucide-react";
import { useT } from "@/lib/i18n/provider";
import { Button } from "@/components/ui/button";
import { toast } from "@/components/ui/sonner";
import { useConfirm } from "@/components/ui/confirm-dialog";
import { moveRecipeAction } from "@/app/actions/meals";
import { ExportRecipeDialog } from "./export-recipe-dialog";
import type { RecipeExportModel } from "@/lib/meals/recipes/export";
import { useMeals } from "../meals-context";

interface Props {
  recipeId: string;
  listType: string;
  model: RecipeExportModel;
  locale: string;
}

export function RecipeDetailActions({ recipeId, listType, model, locale }: Props) {
  const { t } = useT();
  const { familyId, base, canEdit } = useMeals();
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const { confirm, dialog } = useConfirm();

  function onMove() {
    startTransition(async () => {
      const res = await moveRecipeAction(familyId, recipeId);
      if (res.ok) router.refresh();
      else toast.error(t("meals.common.errorRetry"));
    });
  }

  async function onDelete() {
    const ok = await confirm({
      title: t("meals.recipes.confirmDeleteTitle"),
      message: t("meals.recipes.confirmDelete"),
      destructive: true,
      confirmLabel: t("meals.common.delete"),
      cancelLabel: t("meals.common.cancel"),
    });
    if (!ok) return;
    router.push(`${base}/recipes?deleted=${recipeId}`);
  }

  return (
    <div className="flex flex-wrap gap-2 border-t pt-4">
      {canEdit && (
        <Button variant="default" asChild>
          <Link href={`${base}/recipes/${recipeId}/edit`}>
            <Edit size={16} />
            {t("meals.common.edit")}
          </Link>
        </Button>
      )}
      <Button variant="outline" asChild className="border-primary text-primary hover:bg-primary/10">
        <Link href={`${base}/cook/${recipeId}`}>
          <UtensilsCrossed size={16} />
          {t("meals.cooking.start")}
        </Link>
      </Button>
      <ExportRecipeDialog model={model} locale={locale} />
      {canEdit && (
        <>
          <Button
            variant="outline"
            disabled={pending}
            onClick={onMove}
            className="border-primary text-primary hover:bg-primary/10"
          >
            <ArrowRightLeft size={16} />
            {listType === "KNOWN" ? t("meals.recipes.moveToTry") : t("meals.recipes.moveToKnown")}
          </Button>
          <Button
            variant="outline"
            disabled={pending}
            onClick={onDelete}
            className="border-destructive/30 text-destructive hover:bg-destructive/10"
          >
            <Trash2 size={16} />
            {t("meals.common.delete")}
          </Button>
        </>
      )}
      {dialog}
    </div>
  );
}
