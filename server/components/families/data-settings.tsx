"use client";

// Settings → Data (family-planner's settings/DataSection.tsx without "Clone"): the family as a
// JSON file (the calendar of all years and the finances), and, for editors, importing such a
// file over it.

import { useRef } from "react";
import { Download, Upload } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { useConfirm } from "@/components/ui/confirm-dialog";
import { toast } from "@/components/ui/sonner";
import { usePlanner } from "@/components/calendar/context";
import { todayIso } from "@/components/calendar/planner-store";
import { exportFileName, parseExportFile } from "@/lib/calendar/export-file";
import { useT } from "@/lib/i18n/provider";

export function DataSettings() {
  const { t } = useT();
  const store = usePlanner();
  const { confirm, dialog } = useConfirm();
  const fileRef = useRef<HTMLInputElement>(null);
  const family = store.family;
  if (!family) return null;
  const name = family.name;

  /** Downloads the family (all years and the finances, without its ids and links). */
  async function exportFile() {
    if (store.pending) return toast(t("settings.data.waitSaving"));
    try {
      const data = await store.exportFile();
      const blob = new Blob([JSON.stringify(data, null, 2) + "\n"], { type: "application/json" });
      const a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = exportFileName(name, todayIso());
      a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 60000);
    } catch (err) {
      toast.error(t("settings.data.exportFailed", { msg: (err as Error).message }));
    }
  }

  async function importFile(file: File) {
    if (store.pending) return toast(t("settings.data.waitSaving"));
    const data = parseExportFile(await file.text().catch(() => ""));
    if (!data) return toast.error(t("settings.data.invalid"));
    const ok = await confirm({
      title: t("settings.data.confirmTitle"),
      message: t("settings.data.confirm", { name, file: file.name }),
      confirmLabel: t("settings.data.replace"),
      cancelLabel: t("common.cancel"),
      destructive: true,
    });
    if (!ok) return;
    try {
      await store.importFile(data);
      toast.success(t("settings.data.imported"));
    } catch (err) {
      toast.error(t("settings.data.importFailed", { msg: (err as Error).message }));
    }
  }

  return (
    <div className="space-y-6">
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">{t("settings.data.export")}</CardTitle>
          <CardDescription>{t("settings.data.exportHelp")}</CardDescription>
        </CardHeader>
        <CardContent>
          <Button variant="outline" onClick={exportFile}>
            <Download /> {t("settings.data.export")}
          </Button>
        </CardContent>
      </Card>
      {!store.readOnly && (
        <Card>
          <CardHeader>
            <CardTitle className="text-lg">{t("settings.data.import")}</CardTitle>
            <CardDescription>{t("settings.data.importHelp")}</CardDescription>
          </CardHeader>
          <CardContent>
            <Button variant="outline" onClick={() => fileRef.current?.click()}>
              <Upload /> {t("settings.data.import")}
            </Button>
            <input
              ref={fileRef}
              type="file"
              accept=".json,application/json"
              hidden
              onChange={(e) => {
                const file = e.target.files?.[0];
                e.target.value = ""; // picking the same file again fires "change" again
                if (file) void importFile(file);
              }}
            />
          </CardContent>
        </Card>
      )}
      {dialog}
    </div>
  );
}
