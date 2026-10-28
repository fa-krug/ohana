// Prints a one-time setup link for an account, e.g. for an administrator who is locked out:
//   npm run setup-link -- <email>
// (in the container: docker compose exec web ./node_modules/.bin/tsx scripts/setup-link.ts <email>)
import { eq } from "drizzle-orm";
import { db } from "../lib/db/client";
import { users } from "../lib/db/schema";
import { resetUser } from "../lib/admin/users";

const email = process.argv[2]?.trim().toLowerCase();
if (!email) {
  console.error("Usage: tsx scripts/setup-link.ts <email>");
  process.exit(1);
}
const user = db.select().from(users).where(eq(users.email, email)).get();
if (!user) {
  console.error(`No account with the email ${email}.`);
  process.exit(1);
}
const { setupUrl, expiresAt } = resetUser(db, user.id, new Date());
console.log(`Setup link for ${email} (valid until ${expiresAt.toISOString()}):\n${setupUrl}`);
