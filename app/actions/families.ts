"use server";

import { revalidatePath } from "next/cache";
import { z } from "zod";
import { createInvite, revokeInvite } from "@/lib/families/invites";
import { resolveLocale } from "@/lib/i18n/server";
import { createFamily, deleteFamily, renameFamily } from "@/lib/families/manage";
import { addMember, removeMember, setMemberBirthday, setRole } from "@/lib/families/members";
import { addPerson, removePerson, updatePerson } from "@/lib/families/people";
import { acceptInvite } from "@/lib/families/invites";
import { run } from "@/lib/actions/result";
import { addMemberSchema, addPersonSchema, birthdaySchema, familyNameSchema, personSchema, role } from "@/lib/schemas/auth";

function refresh() {
  revalidatePath("/", "layout");
}

export const createFamilyAction = async (input: unknown) =>
  run(async ({ db, user, now }) => {
    const lang = await resolveLocale(); // the calendar's preset types are named in it
    const family = createFamily(db, { name: familyNameSchema.parse(input).name, editorId: user.id, lang }, now);
    refresh();
    return { id: family.id };
  });

export const renameFamilyAction = async (familyId: string, input: unknown) =>
  run(({ db, user, now }) => {
    renameFamily(db, { id: user.id }, familyId, familyNameSchema.parse(input).name, now);
    refresh();
  });

export const deleteFamilyAction = async (familyId: string) =>
  run(({ db, user }) => {
    deleteFamily(db, { id: user.id }, familyId);
    refresh();
  });

export const addMemberAction = async (familyId: string, input: unknown) =>
  run(({ db, user, now }) => {
    addMember(db, { id: user.id }, familyId, addMemberSchema.parse(input), now);
    refresh();
  });

export const setRoleAction = async (familyId: string, userId: string, newRole: unknown) =>
  run(({ db, user }) => {
    setRole(db, { id: user.id }, familyId, userId, role.parse(newRole));
    refresh();
  });

export const removeMemberAction = async (familyId: string, userId: string) =>
  run(({ db, user }) => {
    removeMember(db, { id: user.id }, familyId, userId);
    refresh();
  });

/** A member without an account (a child, …), optionally with an invite link for them. */
export const addPersonAction = async (familyId: string, input: unknown) =>
  run(({ db, user, now }) => {
    const res = addPerson(db, { id: user.id }, familyId, addPersonSchema.parse(input), now);
    refresh();
    return { id: res.person.id, invite: res.invite };
  });

export const updatePersonAction = async (familyId: string, personId: string, input: unknown) =>
  run(({ db, user, now }) => {
    updatePerson(db, { id: user.id }, familyId, personId, personSchema.parse(input), now);
    refresh();
  });

export const setMemberBirthdayAction = async (familyId: string, userId: string, birthday: unknown) =>
  run(({ db, user, now }) => {
    setMemberBirthday(db, { id: user.id }, familyId, userId, birthdaySchema.parse(birthday), now);
    refresh();
  });

export const removePersonAction = async (familyId: string, personId: string) =>
  run(({ db, user }) => {
    removePerson(db, { id: user.id }, familyId, personId);
    refresh();
  });

/** An invite link; with `personId` for that member without an account. */
export const createInviteAction = async (familyId: string, inviteRole: unknown, personId?: string) =>
  run(({ db, user, now }) => {
    const invite = createInvite(db, { id: user.id }, familyId, role.parse(inviteRole), now, personId === undefined ? undefined : z.string().parse(personId));
    refresh();
    return invite;
  });

export const revokeInviteAction = async (familyId: string, inviteId: string) =>
  run(({ db, user }) => {
    revokeInvite(db, { id: user.id }, familyId, inviteId);
    refresh();
  });

export const acceptInviteAction = async (code: string) =>
  run(({ db, user, now }) => {
    const res = acceptInvite(db, user.id, code, now);
    refresh();
    return res;
  });
