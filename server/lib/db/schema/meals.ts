// Meals (ported from cookless): recipes, meal plans (the shopping lists live in Reminders). `ingredients` and
// `units` are shared seed data (scripts/seed.ts); everything else belongs to a family.
import {
  index,
  integer,
  sqliteTable,
  text,
  uniqueIndex,
  type AnySQLiteColumn,
} from "drizzle-orm/sqlite-core";
import { families } from "../schema";

export const ingredients = sqliteTable("ingredients", {
  id: integer("id").primaryKey({ autoIncrement: true }),
  nameDe: text("name_de").notNull(),
  nameEn: text("name_en").notNull(),
  category: text("category").notNull().default("OTHER"),
});

export const units = sqliteTable("units", {
  id: integer("id").primaryKey({ autoIncrement: true }),
  nameDe: text("name_de").notNull(),
  nameEn: text("name_en").notNull(),
  abbreviation: text("abbreviation").notNull(),
  baseUnitId: integer("base_unit_id").references((): AnySQLiteColumn => units.id, { onDelete: "set null" }),
  conversionFactor: text("conversion_factor").notNull().default("1"), // decimal as text
});

/** Recipe tags (cookless's `tags`), per family, in the categories DIETARY, PROTEIN,
 *  CUISINE and MEAL_TYPE. */
export const mealTags = sqliteTable(
  "meal_tags",
  {
    id: text("id").primaryKey(),
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    category: text("category").notNull(),
    nameEn: text("name_en").notNull(),
    nameDe: text("name_de").notNull(),
    isDefault: integer("is_default", { mode: "boolean" }).notNull().default(false),
  },
  (t) => ({
    uniqTag: uniqueIndex("meal_tags_family_category_name_idx").on(t.familyId, t.category, t.nameEn),
  }),
);

export const recipes = sqliteTable(
  "recipes",
  {
    id: text("id").primaryKey(),
    familyId: text("family_id")
      .notNull()
      .references(() => families.id, { onDelete: "cascade" }),
    title: text("title").notNull(),
    description: text("description").notNull().default(""),
    listType: text("list_type").notNull(), // KNOWN | TO_TRY
    defaultServings: integer("default_servings").notNull().default(2),
    prepTimeMinutes: integer("prep_time_minutes"),
    cookTimeMinutes: integer("cook_time_minutes"),
    leftoverDays: integer("leftover_days"),
    image: text("image").notNull().default(""), // path relative to MEDIA_ROOT
    createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
    updatedAt: integer("updated_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({
    recipesFamilyIdIdx: index("recipes_family_id_idx").on(t.familyId),
  }),
);

export const recipeIngredients = sqliteTable(
  "recipe_ingredients",
  {
    id: integer("id").primaryKey({ autoIncrement: true }),
    recipeId: text("recipe_id")
      .notNull()
      .references(() => recipes.id, { onDelete: "cascade" }),
    ingredientId: integer("ingredient_id")
      .notNull()
      .references(() => ingredients.id, { onDelete: "cascade" }),
    quantity: text("quantity").notNull(), // decimal as text
    unitId: integer("unit_id")
      .notNull()
      .references(() => units.id, { onDelete: "cascade" }),
    order: integer("order").notNull().default(0),
  },
  (t) => ({
    recipeIngredientsRecipeIdIdx: index("recipe_ingredients_recipe_id_idx").on(t.recipeId),
  }),
);

export const cookingSteps = sqliteTable(
  "cooking_steps",
  {
    id: integer("id").primaryKey({ autoIncrement: true }),
    recipeId: text("recipe_id")
      .notNull()
      .references(() => recipes.id, { onDelete: "cascade" }),
    method: text("method").notNull(), // MANUAL | MACHINE
    stepNumber: integer("step_number").notNull(),
    instruction: text("instruction").notNull().default(""),
    programType: text("program_type").notNull().default(""),
    temperature: integer("temperature"),
    durationSeconds: integer("duration_seconds"),
    speed: integer("speed"),
    turbo: integer("turbo", { mode: "boolean" }).notNull().default(false),
    direction: text("direction").notNull().default(""),
    weightGrams: integer("weight_grams"),
  },
  (t) => ({
    cookingStepsRecipeIdIdx: index("cooking_steps_recipe_id_idx").on(t.recipeId),
  }),
);

export const stepIngredients = sqliteTable(
  "step_ingredients",
  {
    id: integer("id").primaryKey({ autoIncrement: true }),
    stepId: integer("step_id")
      .notNull()
      .references(() => cookingSteps.id, { onDelete: "cascade" }),
    recipeIngredientId: integer("recipe_ingredient_id")
      .notNull()
      .references(() => recipeIngredients.id, { onDelete: "cascade" }),
    quantity: text("quantity").notNull(),
  },
  (t) => ({
    stepIngredientsStepIdIdx: index("step_ingredients_step_id_idx").on(t.stepId),
  }),
);

export const recipeTags = sqliteTable(
  "recipe_tags",
  {
    id: integer("id").primaryKey({ autoIncrement: true }),
    recipeId: text("recipe_id")
      .notNull()
      .references(() => recipes.id, { onDelete: "cascade" }),
    tagId: text("tag_id")
      .notNull()
      .references(() => mealTags.id, { onDelete: "cascade" }),
  },
  (t) => ({ uniqRecipeTag: uniqueIndex("recipe_tags_recipe_tag_idx").on(t.recipeId, t.tagId) }),
);

/** One meal plan configuration per family. */
export const mealPlans = sqliteTable("meal_plans", {
  id: text("id").primaryKey(),
  familyId: text("family_id")
    .notNull()
    .unique()
    .references(() => families.id, { onDelete: "cascade" }),
  iterationWeeks: integer("iteration_weeks").notNull().default(1),
  shoppingDay1: integer("shopping_day_1").notNull().default(5),
  shoppingDay2: integer("shopping_day_2"),
  servings: integer("servings").notNull().default(2),
  knownRatio: text("known_ratio").notNull().default("0.7"), // decimal as text
  defaultLeftoverDays: integer("default_leftover_days").notNull().default(1),
  createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
});

export const planIterations = sqliteTable(
  "plan_iterations",
  {
    id: text("id").primaryKey(),
    mealPlanId: text("meal_plan_id")
      .notNull()
      .references(() => mealPlans.id, { onDelete: "cascade" }),
    startDate: text("start_date").notNull(),
    endDate: text("end_date").notNull(),
    status: text("status").notNull().default("ACTIVE"), // ACTIVE | ARCHIVED
    createdAt: integer("created_at", { mode: "timestamp" }).notNull(),
  },
  (t) => ({
    planIterationsMealPlanIdIdx: index("plan_iterations_meal_plan_id_idx").on(t.mealPlanId),
  }),
);

export const mealPlanEntries = sqliteTable(
  "meal_plan_entries",
  {
    id: text("id").primaryKey(),
    iterationId: text("iteration_id")
      .notNull()
      .references(() => planIterations.id, { onDelete: "cascade" }),
    date: text("date").notNull(),
    mealType: text("meal_type").notNull(),
    recipeId: text("recipe_id")
      .notNull()
      .references(() => recipes.id, { onDelete: "cascade" }),
    servings: integer("servings").notNull(),
    isLeftover: integer("is_leftover", { mode: "boolean" }).notNull().default(false),
    sourceEntryId: text("source_entry_id").references((): AnySQLiteColumn => mealPlanEntries.id, {
      onDelete: "set null",
    }),
    isLocked: integer("is_locked", { mode: "boolean" }).notNull().default(false),
  },
  (t) => ({
    mealPlanEntriesIterationIdIdx: index("meal_plan_entries_iteration_id_idx").on(t.iterationId),
  }),
);

export const mealPlanExcludedTags = sqliteTable(
  "meal_plan_excluded_tags",
  {
    id: integer("id").primaryKey({ autoIncrement: true }),
    mealPlanId: text("meal_plan_id")
      .notNull()
      .references(() => mealPlans.id, { onDelete: "cascade" }),
    tagId: text("tag_id")
      .notNull()
      .references(() => mealTags.id, { onDelete: "cascade" }),
  },
  (t) => ({ uniqExcluded: uniqueIndex("meal_plan_excluded_tags_plan_tag_idx").on(t.mealPlanId, t.tagId) }),
);
