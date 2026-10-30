"use client";

import { createContext, useContext } from "react";

interface MealsCtx {
  familyId: string;
  /** Editors change things; viewers only look. The server enforces it either way. */
  canEdit: boolean;
  /** `/f/<familyId>/meals` */
  base: string;
}

const Ctx = createContext<MealsCtx | null>(null);

export function MealsProvider({
  familyId,
  canEdit,
  children,
}: {
  familyId: string;
  canEdit: boolean;
  children: React.ReactNode;
}) {
  return <Ctx.Provider value={{ familyId, canEdit, base: `/f/${familyId}/meals` }}>{children}</Ctx.Provider>;
}

export function useMeals(): MealsCtx {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error("useMeals must be used within a MealsProvider");
  return ctx;
}
