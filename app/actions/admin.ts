"use server";

import { revalidatePath } from "next/cache";
import { createUser, deleteUser, resetUser, updateUser } from "@/lib/admin/users";
import { resolveLocale } from "@/lib/i18n/server";
import { createFamily, deleteFamily, renameFamily } from "@/lib/families/manage";
import { addMember, removeMember, setRole } from "@/lib/families/members";
import { run } from "@/lib/actions/result";
import { addMemberSchema, adminUserSchema, adminUserUpdateSchema, familyNameSchema, role } from "@/lib/schemas/auth";

const admin = { admin: true };

function refresh() {
  revalidatePath("/", "layout");
}

export const adminCreateUserAction = async (input: unknown) =>
  run(({ db, now }) => {
    const res = createUser(db, adminUserSchema.parse(input), now);
    refresh();
    return res;
  }, admin);

export const adminUpdateUserAction = async (userId: string, input: unknown) =>
  run(({ db, user }) => {
    updateUser(db, user.id, userId, adminUserUpdateSchema.parse(input));
    refresh();
  }, admin);

export const adminDeleteUserAction = async (userId: string) =>
  run(({ db, user }) => {
    deleteUser(db, user.id, userId);
    refresh();
  }, admin);

export const adminResetUserAction = async (userId: string) =>
  run(({ db, now }) => {
    const res = resetUser(db, userId, now);
    refresh();
    return res;
  }, admin);

export const adminCreateFamilyAction = async (input: unknown) =>
  run(async ({ db, now }) => {
    const lang = await resolveLocale(); // the calendar's preset types are named in it
    const family = createFamily(db, { name: familyNameSchema.parse(input).name, lang }, now);
    refresh();
    return { id: family.id };
  }, admin);

export const adminRenameFamilyAction = async (familyId: string, input: unknown) =>
  run(({ db, user, now }) => {
    renameFamily(db, { id: user.id, admin: true }, familyId, familyNameSchema.parse(input).name, now);
    refresh();
  }, admin);

export const adminDeleteFamilyAction = async (familyId: string) =>
  run(({ db, user }) => {
    deleteFamily(db, { id: user.id, admin: true }, familyId);
    refresh();
  }, admin);

export const adminAddMemberAction = async (familyId: string, input: unknown) =>
  run(({ db, user, now }) => {
    addMember(db, { id: user.id, admin: true }, familyId, addMemberSchema.parse(input), now);
    refresh();
  }, admin);

export const adminSetRoleAction = async (familyId: string, userId: string, newRole: unknown) =>
  run(({ db, user }) => {
    setRole(db, { id: user.id, admin: true }, familyId, userId, role.parse(newRole));
    refresh();
  }, admin);

export const adminRemoveMemberAction = async (familyId: string, userId: string) =>
  run(({ db, user }) => {
    removeMember(db, { id: user.id, admin: true }, familyId, userId);
    refresh();
  }, admin);
