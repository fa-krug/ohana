// Amounts in requests: whole cents, within a sane size.

import { HttpError } from "@/lib/api/http";

const MAX_AMOUNT = 100_000_000_000_000; // cents

/** A whole number of cents, else 400. */
export function cleanAmount(v: unknown, field = "amountCents"): number {
  if (typeof v !== "number" || !Number.isInteger(v) || Math.abs(v) > MAX_AMOUNT) {
    throw new HttpError(400, `${field} must be a whole number of cents`);
  }
  return v;
}
