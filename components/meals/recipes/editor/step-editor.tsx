"use client";

import { useId } from "react";
import { useFormContext, useFieldArray } from "react-hook-form";
import {
  DndContext, closestCenter, PointerSensor, KeyboardSensor, useSensor, useSensors,
  type DragEndEvent,
} from "@dnd-kit/core";
import { SortableContext, sortableKeyboardCoordinates, verticalListSortingStrategy } from "@dnd-kit/sortable";
import { useT } from "@/lib/i18n/provider";
import { Button } from "@/components/ui/button";
import { SortableStep } from "./sortable-step";
import { ProgramStepForm } from "./program-step-form";
import { StepIngredientAllocator } from "./step-ingredient-allocator";
import type { RecipeFormValues, FormStepValues } from "@/lib/meals/schemas/recipe";
import type { IngredientLite, UnitLite } from "@/lib/meals/queries/recipes";
import type { Locale } from "@/lib/i18n/config";

const EMPTY_STEP: FormStepValues = {
  instruction: "", programType: "", temperature: null, durationSeconds: null,
  speed: null, turbo: false, direction: "", weightGrams: null, ingredients: [],
};

export function StepEditor({
  method, ingredients, units, locale,
}: { method: "manual" | "machine"; ingredients: IngredientLite[]; units: UnitLite[]; locale: Locale }) {
  const { t } = useT();
  // A stable id keeps dnd-kit's aria-describedby the same on server and client (hydration).
  const dndId = useId();
  const name = method === "manual" ? "manualSteps" : "machineSteps";
  const { control, register } = useFormContext<RecipeFormValues>();
  const { fields, append, remove, move } = useFieldArray({ control, name });
  const sensors = useSensors(
    useSensor(PointerSensor),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  );

  function onDragEnd(e: DragEndEvent) {
    const { active, over } = e;
    if (over && active.id !== over.id) {
      const from = fields.findIndex((f) => f.id === active.id);
      const to = fields.findIndex((f) => f.id === over.id);
      if (from !== -1 && to !== -1) move(from, to); // useFieldArray.move handles the reorder
    }
  }

  return (
    <section className="space-y-3">
      <h2 className="text-sm font-medium">
        {t(method === "manual" ? "meals.steps.manualTitle" : "meals.steps.machineTitle")}
      </h2>
      <DndContext id={dndId} sensors={sensors} collisionDetection={closestCenter} onDragEnd={onDragEnd}>
        <SortableContext items={fields.map((f) => f.id)} strategy={verticalListSortingStrategy}>
          <div className="space-y-2">
            {fields.map((field, idx) => (
              <SortableStep key={field.id} id={field.id} highlight={method === "machine"}>
                <div className="space-y-2">
                  {method === "machine" && <ProgramStepForm name={name} index={idx} />}
                  <textarea
                    {...register(`${name}.${idx}.instruction`)}
                    className="w-full rounded-md border bg-background p-2 text-sm"
                    rows={2}
                    placeholder={t("meals.steps.instructionPlaceholder")}
                  />
                  <StepIngredientAllocator name={name} index={idx} ingredients={ingredients} units={units} locale={locale} />
                  <Button type="button" variant="ghost" onClick={() => remove(idx)}>{t("meals.common.remove")}</Button>
                </div>
              </SortableStep>
            ))}
          </div>
        </SortableContext>
      </DndContext>
      <Button type="button" variant="outline" onClick={() => append({ ...EMPTY_STEP, ingredients: [] })}>
        {t("meals.steps.add")}
      </Button>
    </section>
  );
}
