import { z } from "zod";
import { ROLES } from "@/lib/families/roles";

const email = z.string().trim().toLowerCase().email();
// Sign-in name: an email or a plain name (accounts imported from the old apps may use one).
const identifier = z.string().trim().toLowerCase().min(1);
const password = z.string().min(1);
const name = z.string().trim().max(100).default("");

export const loginPasswordSchema = z.object({ email: identifier, password });

export const registerPasswordSchema = z.object({
  email,
  name,
  password,
  inviteCode: z.string().min(1),
});

export const registerFirstUserSchema = z.object({ email, name, password });

export const setPasswordSchema = z.object({
  currentPassword: z.string().optional(),
  newPassword: z.string().min(1),
});

export const removePasswordSchema = z.object({ currentPassword: z.string().min(1) });

export const passkeyLoginBeginSchema = z.object({ email: identifier.optional() });

export const passkeyRegisterBeginSchema = z.object({
  email,
  name,
  inviteCode: z.string().optional(),
});

export const passkeyCompleteSchema = z.object({
  credential: z.string().min(1),
  deviceName: z.string().max(200).default(""),
});

export const emailChangeSchema = z.object({ newEmail: email });

export const role = z.enum(ROLES);
export const familyNameSchema = z.object({ name: z.string().trim().min(1).max(100) });
export const addMemberSchema = z.object({ email: identifier, role });
const personName = z.string().trim().min(1).max(80);
// "" from an empty date field: no birthday.
export const birthdaySchema = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/)
  .or(z.literal("").transform(() => null))
  .nullable()
  .default(null);
export const addPersonSchema = z.object({ name: personName, birthday: birthdaySchema, invite: role.nullable().default(null) });
export const personSchema = z.object({ name: personName, birthday: birthdaySchema });
export const profileSchema = z.object({
  name: z.string().trim().max(100).optional(),
  preferredLanguage: z.enum(["en", "de"]).optional(),
});
export const apiTokenSchema = z.object({ name: z.string().trim().min(1).max(100) });
export const adminUserSchema = z.object({ email: identifier, name, isAdmin: z.boolean().default(false) });
export const adminUserUpdateSchema = z.object({
  email: identifier.optional(),
  name: z.string().trim().max(100).optional(),
  isAdmin: z.boolean().optional(),
});
