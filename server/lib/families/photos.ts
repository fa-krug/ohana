// The members' photos: one per account in a family (family_members.photo) and per person
// without an account (family_people.photo), a 512×512 WebP under MEDIA_ROOT at
// members/<familyId>/<userId or personId>_<ms>.webp (a new name per upload, so it can be cached
// for good). Served by /api/images/… to the family's members (lib/meals/images/serve.ts).

import { existsSync, rmSync } from "node:fs";
import { and, eq } from "drizzle-orm";
import sharp from "sharp";
import type { Db } from "@/lib/db";
import { familyMembers, familyPeople } from "@/lib/db/schema";
import { AuthError } from "@/lib/auth/errors";
import { deleteImageFile, resolveMediaPath, writeMediaFile } from "@/lib/meals/images/storage";
import { type Actor, requireRole } from "./roles";

export const PHOTO_SIZE = 512;

/** The upload as a square WebP (turned as its EXIF says, cropped to what matters); 400 for
 *  bytes that aren't an image. */
export async function processPhoto(input: Buffer): Promise<Buffer> {
  try {
    return await sharp(input)
      .rotate()
      .resize(PHOTO_SIZE, PHOTO_SIZE, { fit: "cover", position: sharp.strategy.attention })
      .webp({ quality: 85 })
      .toBuffer();
  } catch {
    throw new AuthError(400, "Invalid image");
  }
}

/** Writes the photo under a name not taken yet; its path relative to the media root. */
function writePhoto(familyId: string, ownerId: string, webp: Buffer, now: Date): string {
  let ms = now.getTime();
  const name = () => `members/${familyId}/${ownerId}_${ms}.webp`;
  while (existsSync(resolveMediaPath(name())!)) ms++;
  return writeMediaFile(name(), webp);
}

/** Deletes a photo's file; never throws (a file that's gone is fine). */
export function deletePhotoFile(rel: string | null | undefined): void {
  if (!rel) return;
  try {
    deleteImageFile(rel);
  } catch (e) {
    console.warn(`Could not delete photo ${rel}:`, e);
  }
}

/** Deletes every member's and person's photo of a family (once the family is deleted). */
export function deleteFamilyPhotos(familyId: string): void {
  const dir = resolveMediaPath(`members/${familyId}`);
  if (!dir || dir === resolveMediaPath(".")) return;
  try {
    rmSync(dir, { recursive: true, force: true });
  } catch (e) {
    console.warn(`Could not delete the photos of family ${familyId}:`, e);
  }
}

const memberWhere = (familyId: string, userId: string) =>
  and(eq(familyMembers.familyId, familyId), eq(familyMembers.userId, userId));

function memberPhoto(db: Db, familyId: string, userId: string): string | null {
  const row = db.select({ photo: familyMembers.photo }).from(familyMembers).where(memberWhere(familyId, userId)).get();
  if (!row) throw new AuthError(404, "Member not found.");
  return row.photo;
}

function assertMemberPhotoAccess(db: Db, actor: Actor, familyId: string, userId: string): void {
  requireRole(db, actor, familyId, userId === actor.id ? "viewer" : "editor");
  memberPhoto(db, familyId, userId);
}

/** A member's photo in this family (replacing the one before); members set their own, editors
 *  anyone's. */
export async function setMemberPhoto(
  db: Db,
  actor: Actor,
  familyId: string,
  userId: string,
  input: Buffer,
  now: Date,
): Promise<void> {
  assertMemberPhotoAccess(db, actor, familyId, userId);
  const webp = await processPhoto(input);
  const rel = writePhoto(familyId, userId, webp, now);
  let old: string | null;
  try {
    old = memberPhoto(db, familyId, userId); // still a member after the wait?
  } catch (e) {
    deletePhotoFile(rel);
    throw e;
  }
  db.update(familyMembers).set({ photo: rel }).where(memberWhere(familyId, userId)).run();
  deletePhotoFile(old);
}

/** Removes a member's photo; members their own, editors anyone's. */
export function removeMemberPhoto(db: Db, actor: Actor, familyId: string, userId: string): void {
  assertMemberPhotoAccess(db, actor, familyId, userId);
  const old = memberPhoto(db, familyId, userId);
  db.update(familyMembers).set({ photo: null }).where(memberWhere(familyId, userId)).run();
  deletePhotoFile(old);
}

const personWhere = (familyId: string, personId: string) =>
  and(eq(familyPeople.id, personId), eq(familyPeople.familyId, familyId));

function personPhoto(db: Db, familyId: string, personId: string): string | null {
  const row = db.select({ photo: familyPeople.photo }).from(familyPeople).where(personWhere(familyId, personId)).get();
  if (!row) throw new AuthError(404, "Member not found.");
  return row.photo;
}

/** The photo of someone without an account (replacing the one before); editors only. */
export async function setPersonPhoto(
  db: Db,
  actor: Actor,
  familyId: string,
  personId: string,
  input: Buffer,
  now: Date,
): Promise<void> {
  requireRole(db, actor, familyId, "editor");
  personPhoto(db, familyId, personId);
  const webp = await processPhoto(input);
  const rel = writePhoto(familyId, personId, webp, now);
  let old: string | null;
  try {
    old = personPhoto(db, familyId, personId);
  } catch (e) {
    deletePhotoFile(rel);
    throw e;
  }
  db.update(familyPeople).set({ photo: rel }).where(personWhere(familyId, personId)).run();
  deletePhotoFile(old);
}

/** Removes the photo of someone without an account; editors only. */
export function removePersonPhoto(db: Db, actor: Actor, familyId: string, personId: string): void {
  requireRole(db, actor, familyId, "editor");
  const old = personPhoto(db, familyId, personId);
  db.update(familyPeople).set({ photo: null }).where(personWhere(familyId, personId)).run();
  deletePhotoFile(old);
}
