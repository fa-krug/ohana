import { z } from "zod";
declare const console: any;

const a = z.number({ error: "not a number" });
const b = z.tuple([z.string()]).rest(z.number({ error: "not a number" }));
const c = z.string({ error: (iss) => (iss.input === undefined ? "required" : "not a string") });
const d = z.string().optional().nullable();
const e = z.enum(["a", "b"], { error: "bad" });
const f = z.coerce.number({ error: "not a number" }).int().min(1).max(100);
const g = z.number().int().min(1).max(100).optional().nullable();
const h = z.string().optional().nullable().transform((v) => v ?? null);
const i = z.number({ error: (iss) => (iss.code === "invalid_type" ? "not a number" : "bad") });
const j = z.tuple([z.string(), z.number({ error: "not a number" })]).rest(z.number({ error: "not a number" }));
const k = z.object({ x: z.string() }).strict();

