"use client";

import { useRef, useTransition } from "react";
import { useRouter } from "next/navigation";
import { ImagePlus, Loader2, Sparkles, Trash2 } from "lucide-react";
import { useT } from "@/lib/i18n/provider";
import { Button } from "@/components/ui/button";
import { toast } from "@/components/ui/sonner";
import {
  uploadRecipeImageAction,
  removeRecipeImageAction,
  generateRecipeImageAction,
} from "@/app/actions/meals";
import { useMeals } from "../meals-context";

interface Props {
  recipeId: string;
  hasImage: boolean;
  /** An image model is set: "Generate with AI". */
  canGenerate?: boolean;
}

export function RecipeImageActions({ recipeId, hasImage, canGenerate = false }: Props) {
  const { t } = useT();
  const { familyId } = useMeals();
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [generating, startGenerating] = useTransition();
  const fileRef = useRef<HTMLInputElement>(null);

  function onFile(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;
    const fd = new FormData();
    fd.append("image", file);
    startTransition(async () => {
      const res = await uploadRecipeImageAction(familyId, recipeId, fd);
      if (res.ok) router.refresh();
      else toast.error(t("meals.recipeImage.uploadFailed"));
    });
  }

  function onGenerate() {
    startGenerating(async () => {
      const res = await generateRecipeImageAction(familyId, recipeId);
      if (res.ok) router.refresh();
      else toast.error(t("meals.recipeImage.generateFailed", { msg: res.message }));
    });
  }

  function onRemove() {
    startTransition(async () => {
      const res = await removeRecipeImageAction(familyId, recipeId);
      if (res.ok) {
        toast.success(t("meals.recipeImage.removed"));
        router.refresh();
      } else {
        toast.error(t("meals.common.errorRetry"));
      }
    });
  }

  return (
    <div className="flex flex-wrap gap-2">
      <input ref={fileRef} type="file" accept="image/jpeg,image/png,image/webp" hidden onChange={onFile} />
      <Button variant="outline" size="sm" disabled={pending || generating} onClick={() => fileRef.current?.click()}>
        <ImagePlus size={16} />
        {t("meals.recipeImage.upload")}
      </Button>
      {canGenerate && (
        <Button
          variant="outline"
          size="sm"
          disabled={pending || generating}
          onClick={onGenerate}
          className="border-primary/30 text-primary hover:bg-primary/10"
        >
          {generating ? <Loader2 size={16} className="animate-spin" /> : <Sparkles size={16} />}
          {generating ? t("meals.recipeImage.generating") : t("meals.recipeImage.generate")}
        </Button>
      )}
      {hasImage && (
        <Button
          variant="outline"
          size="sm"
          disabled={pending}
          onClick={onRemove}
          className="border-destructive/30 text-destructive hover:bg-destructive/10"
        >
          <Trash2 size={16} />
          {t("meals.recipeImage.remove")}
        </Button>
      )}
    </div>
  );
}
