"use client";

import { useMemo, useState } from "react";
import { Copy, Share2 } from "lucide-react";
import { useT } from "@/lib/i18n/provider";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { toast } from "@/components/ui/sonner";
import {
  generateMarkdown,
  generatePdf,
  shareOrDownload,
  type RecipeExportModel,
} from "@/lib/meals/recipes/export";

interface Props {
  model: RecipeExportModel;
  locale: string;
}

export function ExportRecipeDialog({ model, locale }: Props) {
  const { t } = useT();
  const [open, setOpen] = useState(false);
  const [format, setFormat] = useState<"markdown" | "pdf">("markdown");
  const [portions, setPortions] = useState(model.defaultServings);
  const [includeImage, setIncludeImage] = useState(true);
  const [includeDescription, setIncludeDescription] = useState(true);
  const [includeIngredients, setIncludeIngredients] = useState(true);
  const [includeSteps, setIncludeSteps] = useState(true);
  const [busy, setBusy] = useState(false);

  const sections = useMemo(
    () => ({ includeDescription, includeIngredients, includeSteps }),
    [includeDescription, includeIngredients, includeSteps],
  );

  const markdownPreview = useMemo(
    () => generateMarkdown(model, portions || model.defaultServings || 1, sections, locale),
    [model, portions, sections, locale],
  );

  async function copy() {
    try {
      await navigator.clipboard.writeText(markdownPreview);
      toast.success(t("meals.export.copied"));
    } catch {
      toast.error(t("meals.export.failed"));
    }
  }

  async function onShare() {
    setBusy(true);
    try {
      const effectivePortions = portions || model.defaultServings || 1;
      const content =
        format === "markdown"
          ? generateMarkdown(model, effectivePortions, sections, locale)
          : await generatePdf(model, effectivePortions, { ...sections, includeImage }, locale);
      const result = await shareOrDownload(model.title, content, format);
      toast.success(t(result === "shared" ? "meals.export.shared" : "meals.export.downloaded"));
      setOpen(false);
    } catch {
      toast.error(t("meals.export.failed"));
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <Button
        variant="outline"
        onClick={() => setOpen(true)}
        className="border-primary text-primary hover:bg-primary/10"
      >
        <Share2 size={16} />
        {t("meals.export.button")}
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle>{t("meals.export.title")}</DialogTitle>
          </DialogHeader>

          <div className="space-y-4">
            <div className="space-y-2">
              <Label>{t("meals.export.format")}</Label>
              <ToggleGroup
                type="single"
                value={format}
                onValueChange={(value) => value && setFormat(value as "markdown" | "pdf")}
                className="justify-start"
              >
                <ToggleGroupItem value="markdown">{t("meals.export.formatMarkdown")}</ToggleGroupItem>
                <ToggleGroupItem value="pdf">{t("meals.export.formatPdf")}</ToggleGroupItem>
              </ToggleGroup>
            </div>

            <div className="space-y-2">
              <Label htmlFor="export-portions">{t("meals.export.portions")}</Label>
              <Input
                id="export-portions"
                type="number"
                min={1}
                value={portions}
                onChange={(e) => setPortions(Math.max(1, parseInt(e.target.value, 10) || 1))}
                className="w-24"
              />
            </div>

            <div className="space-y-2">
              <Label>{t("meals.export.includeSection")}</Label>
              <div className="flex flex-col gap-2">
                {model.imageUrl && (
                  <label className="flex items-center gap-2 text-sm">
                    <input
                      type="checkbox"
                      checked={includeImage}
                      onChange={(e) => setIncludeImage(e.target.checked)}
                    />
                    {t("meals.export.includeImage")}
                  </label>
                )}
                <label className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={includeDescription}
                    onChange={(e) => setIncludeDescription(e.target.checked)}
                  />
                  {t("meals.export.includeDescription")}
                </label>
                <label className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={includeIngredients}
                    onChange={(e) => setIncludeIngredients(e.target.checked)}
                  />
                  {t("meals.export.includeIngredients")}
                </label>
                <label className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    checked={includeSteps}
                    onChange={(e) => setIncludeSteps(e.target.checked)}
                  />
                  {t("meals.export.includeSteps")}
                </label>
              </div>
            </div>

            <div className="flex gap-2">
              <Button variant="outline" onClick={copy} className="flex-1">
                <Copy size={16} /> {t("meals.export.copy")}
              </Button>
              <Button onClick={onShare} disabled={busy} className="flex-1">
                <Share2 size={16} /> {t("meals.export.share")}
              </Button>
            </div>
          </div>
        </DialogContent>
      </Dialog>
    </>
  );
}
