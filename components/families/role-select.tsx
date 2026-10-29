"use client";

import { useT } from "@/lib/i18n/provider";

type Role = "editor" | "viewer";

export function RoleSelect({ value, onChange, id }: { value: Role; onChange: (role: Role) => void; id?: string }) {
  const { t } = useT();
  return (
    <select
      id={id}
      value={value}
      onChange={(e) => onChange(e.target.value as Role)}
      className="h-10 rounded-md border border-input bg-background pl-3 pr-9 text-sm"
      title={t(`roles.${value}Hint`)}
    >
      <option value="editor">{t("roles.editor")}</option>
      <option value="viewer">{t("roles.viewer")}</option>
    </select>
  );
}
