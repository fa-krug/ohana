import { z } from "zod";
declare const console: any;
const INVALID_CROP = "Invalid crop.";
const fraction = z.number({ error: INVALID_CROP }).finite(INVALID_CROP);
const cropSchema = z
  .tuple([z.string(), fraction, fraction, fraction])
  .rest(fraction)
  .refine((a) => a.length === 4 || a.length % 2 === 0, { message: INVALID_CROP });
const cases: unknown[] = ["a", 1, null, undefined, ["x"], ["x", "0", 0, 0.5, 1], ["x", 0, 0, 0.5, 1, 2], ["x", 0, 0, 0.5, 1, 2, 3], ["x", 0, 0, 0.5, 1, Infinity], ["x", 0, 0, 0.5, 1, NaN]];
for (const c of cases) {
  const r = cropSchema.safeParse(c);
  console.log(JSON.stringify(c), r.success ? "OK " + JSON.stringify(r.data) : r.error.issues.map((i: any) => i.code + ":" + i.message + ":" + JSON.stringify(i.path)).join(" | "));
}
const s = z.string({ error: (iss) => (iss.input === undefined ? "url is required" : "url must be a string") }).trim().url().max(2000);
for (const c of [undefined, 5, null, "nope", "https://x.example/a"]) {
  const r = s.safeParse(c);
  console.log("S", JSON.stringify(c), r.success ? "OK" : r.error.issues[0].message);
}
