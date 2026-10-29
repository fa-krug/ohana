"use client";

import { Trash2 } from "lucide-react";
import { useT } from "@/lib/i18n/provider";
import { Button } from "@/components/ui/button";

export function RecipeCardDelete({
  onDelete,
  title,
}: {
  onDelete: () => void;
  title: string;
}) {
  const { t } = useT();

  return (
    <Button
      variant="ghost"
      size="icon"
      className="ml-3 shrink-0 text-destructive hover:bg-destructive/10"
      aria-label={`${t("meals.common.delete")} ${title}`}
      onClick={onDelete}
    >
      <Trash2 size={18} />
    </Button>
  );
}
