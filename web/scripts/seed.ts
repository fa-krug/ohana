// Loads the shared meal seed data (units + ingredients) into DATABASE_FILE. Idempotent;
// docker-entrypoint.sh runs it after the migrations on every `web` boot.
import { db } from "../lib/db/client";
import { seed } from "../lib/meals/seed";

const n = seed(db);
console.log(`seed data present: ${n.units} units, ${n.ingredients} ingredients`);
