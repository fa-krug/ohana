// The members' photos: one per account in a family (family_members.photo) and per person
// without an account (family_people.photo). Each upload keeps two WebPs under MEDIA_ROOT, a new
// name per upload or crop (so they can be cached for good):
//   - the original, turned upright as its EXIF says and at most 2048×2048
//     (members/<familyId>/<userId or personId>_<ms>_original.webp, `photo_original`), and
//   - the 512×512 square everyone sees (members/<familyId>/<id>_<ms>.webp, `photo`), cut from
//     the original where `photo_crop` says ({x, y, w, h}: fractions of the upright original, a
//     square in pixels) or, without a crop, where sharp's attention strategy finds what matters.
// A new crop (PATCH) renders a new square from the kept original. Photos from before originals
// were kept have none and can't be adjusted. Served by /api/images/… (both files) to the
// family's members (lib/meals/images/serve.ts).

import { existsSync, rmSync } from "node:fs";
import { and, eq } from "drizzle-orm";
import sharp from "sharp";
import { z } from "zod";
import type { Db } from "@/lib/db";
import { familyMembers, familyPeople } from "@/lib/db/schema";
import { AuthError } from "@/lib/auth/errors";
import { deleteImageFile, readImage, resolveMediaPath, writeMediaFile } from "@/lib/meals/images/storage";
import { type Actor, requireRole } from "./roles";

export const PHOTO_SIZE = 512;
export const PHOTO_ORIGINAL_SIZE = 2048;

/** Where the square is cut from the upright original: fractions of its width (x, w) and height
 *  (y, h), top-left corner and size. */
export interface PhotoCrop {
  x: number;
  y: number;
  w: number;
  h: number;
}

const CROP_SLACK = 1e-6;
const INVALID_CROP = "Invalid crop.";
const fraction = z.number({ invalid_type_error: INVALID_CROP, required_error: INVALID_CROP }).finite(INVALID_CROP);

/** A crop inside the picture (with a little slack for rounding, then clamped to it). */
export const photoCropSchema = z
  .object(
    { x: fraction, y: fraction, w: fraction, h: fraction },
    { invalid_type_error: INVALID_CROP, required_error: INVALID_CROP },
  )
  .refine(
    (c) =>
      c.x >= -CROP_SLACK &&
      c.y >= -CROP_SLACK &&
      c.w > 0 &&
      c.h > 0 &&
      c.x + c.w <= 1 + CROP_SLACK &&
      c.y + c.h <= 1 + CROP_SLACK,
    INVALID_CROP,
  )
  .transform((c): PhotoCrop => {
    const x = Math.min(Math.max(c.x, 0), 1);
    const y = Math.min(Math.max(c.y, 0), 1);
    return { x, y, w: Math.min(c.w, 1 - x), h: Math.min(c.h, 1 - y) };
  });

/** A crop given as the query's x, y, w and h: null without any of them, 400 with only some. */
export function cropFromQuery(params: URLSearchParams): PhotoCrop | null {
  const keys = ["x", "y", "w", "h"] as const;
  const given = keys.filter((k) => params.has(k));
  if (given.length === 0) return null;
  if (given.length < keys.length) throw new AuthError(400, "A crop needs x, y, w and h.");
  const num = (k: string) => {
    const v = params.get(k)!.trim();
    return v === "" ? Number.NaN : Number(v);
  };
  const parsed = photoCropSchema.safeParse({ x: num("x"), y: num("y"), w: num("w"), h: num("h") });
  if (!parsed.success) throw new AuthError(400, INVALID_CROP);
  return parsed.data;
}

/** A stored crop (JSON text) as the API answers it; null for none (or one that can't be read). */
export function parsePhotoCrop(text: string | null | undefined): PhotoCrop | null {
  if (!text) return null;
  try {
    const parsed = photoCropSchema.safeParse(JSON.parse(text));
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}

/** The upload turned upright and made at most 2048×2048 (WebP); 400 for bytes that aren't an
 *  image. */
export async function processOriginal(input: Buffer): Promise<Buffer> {
  try {
    return await sharp(input)
      .rotate()
      .resize(PHOTO_ORIGINAL_SIZE, PHOTO_ORIGINAL_SIZE, { fit: "inside", withoutEnlargement: true })
      .webp({ quality: 90 })
      .toBuffer();
  } catch {
    throw new AuthError(400, "Invalid image");
  }
}

/** The 512×512 square (WebP) of an upright original: where `crop` says (its rounded pixels, at
 *  least one), else what sharp's attention strategy picks. */
export async function renderSquare(original: Buffer, crop: PhotoCrop | null): Promise<Buffer> {
  let image = sharp(original);
  if (crop) {
    const { width = 0, height = 0 } = await image.metadata();
    if (!width || !height) throw new Error("An image without a size");
    const left = Math.min(Math.round(crop.x * width), width - 1);
    const top = Math.min(Math.round(crop.y * height), height - 1);
    image = image.extract({
      left,
      top,
      width: Math.max(1, Math.min(Math.round(crop.w * width), width - left)),
      height: Math.max(1, Math.min(Math.round(crop.h * height), height - top)),
    });
  }
  return image
    .resize(PHOTO_SIZE, PHOTO_SIZE, crop ? { fit: "cover" } : { fit: "cover", position: sharp.strategy.attention })
    .webp({ quality: 85 })
    .toBuffer();
}

/** Writes a photo file under a name not taken yet; its path relative to the media root. */
function writePhoto(familyId: string, ownerId: string, webp: Buffer, now: Date, suffix = ""): string {
  let ms = now.getTime();
  const name = () => `members/${familyId}/${ownerId}_${ms}${suffix}.webp`;
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

/** Deletes the files of a photo (the square and the original). */
export function deletePhotoFiles(row: { photo?: string | null; photoOriginal?: string | null }): void {
  deletePhotoFile(row.photo);
  deletePhotoFile(row.photoOriginal);
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

// ---- One member's or person's photo ----

interface PhotoRow {
  photo: string | null;
  photoOriginal: string | null;
  photoCrop: string | null;
}

/** The photo columns of one member or person: `read` throws 404 once they're gone. */
interface PhotoSlot {
  familyId: string;
  ownerId: string;
  read(): PhotoRow;
  write(row: PhotoRow): void;
}

const photoColumns = (t: typeof familyMembers | typeof familyPeople) => ({
  photo: t.photo,
  photoOriginal: t.photoOriginal,
  photoCrop: t.photoCrop,
});

function memberSlot(db: Db, familyId: string, userId: string): PhotoSlot {
  const where = and(eq(familyMembers.familyId, familyId), eq(familyMembers.userId, userId));
  return {
    familyId,
    ownerId: userId,
    read() {
      const row = db.select(photoColumns(familyMembers)).from(familyMembers).where(where).get();
      if (!row) throw new AuthError(404, "Member not found.");
      return row;
    },
    write(row) {
      db.update(familyMembers).set(row).where(where).run();
    },
  };
}

function personSlot(db: Db, familyId: string, personId: string): PhotoSlot {
  const where = and(eq(familyPeople.id, personId), eq(familyPeople.familyId, familyId));
  return {
    familyId,
    ownerId: personId,
    read() {
      const row = db.select(photoColumns(familyPeople)).from(familyPeople).where(where).get();
      if (!row) throw new AuthError(404, "Member not found.");
      return row;
    },
    write(row) {
      db.update(familyPeople).set(row).where(where).run();
    },
  };
}

/** Stores an upload as the slot's photo (original + square, `crop` or sharp's pick), replacing
 *  and deleting the files before. */
async function upload(slot: PhotoSlot, input: Buffer, crop: PhotoCrop | null, now: Date): Promise<void> {
  const original = await processOriginal(input);
  const square = await renderSquare(original, crop);
  const written = {
    photo: writePhoto(slot.familyId, slot.ownerId, square, now),
    photoOriginal: writePhoto(slot.familyId, slot.ownerId, original, now, "_original"),
  };
  let old: PhotoRow;
  try {
    old = slot.read(); // still there after the wait?
  } catch (e) {
    deletePhotoFiles(written);
    throw e;
  }
  slot.write({ ...written, photoCrop: crop ? JSON.stringify(crop) : null });
  deletePhotoFiles(old);
}

/** Cuts a new square from the slot's original (a new file; the square before is deleted). */
async function recrop(slot: PhotoSlot, crop: PhotoCrop, now: Date): Promise<void> {
  const row = slot.read();
  if (!row.photo) throw new AuthError(404, "No photo.");
  const original = row.photoOriginal ? await readImage(row.photoOriginal) : null;
  if (!row.photoOriginal || !original) throw new AuthError(409, "This photo can't be adjusted.");
  let square: Buffer;
  try {
    square = await renderSquare(original, crop);
  } catch {
    throw new AuthError(409, "This photo can't be adjusted.");
  }
  const rel = writePhoto(slot.familyId, slot.ownerId, square, now);
  let current: PhotoRow;
  try {
    current = slot.read();
    if (current.photoOriginal !== row.photoOriginal) throw new AuthError(409, "The photo was replaced meanwhile.");
  } catch (e) {
    deletePhotoFile(rel);
    throw e;
  }
  slot.write({ photo: rel, photoOriginal: row.photoOriginal, photoCrop: JSON.stringify(crop) });
  if (current.photo !== rel) deletePhotoFile(current.photo);
}

function remove(slot: PhotoSlot): void {
  const old = slot.read();
  slot.write({ photo: null, photoOriginal: null, photoCrop: null });
  deletePhotoFiles(old);
}

/** Members change their own photo, editors anyone's (404 for someone who isn't a member). */
function memberAccess(db: Db, actor: Actor, familyId: string, userId: string): PhotoSlot {
  requireRole(db, actor, familyId, userId === actor.id ? "viewer" : "editor");
  const slot = memberSlot(db, familyId, userId);
  slot.read();
  return slot;
}

/** Only editors change the photo of someone without an account. */
function personAccess(db: Db, actor: Actor, familyId: string, personId: string): PhotoSlot {
  requireRole(db, actor, familyId, "editor");
  const slot = personSlot(db, familyId, personId);
  slot.read();
  return slot;
}

/** A member's photo in this family (replacing the one before), cut where `crop` says or, without
 *  one, where sharp finds what matters; members set their own, editors anyone's. */
export async function setMemberPhoto(
  db: Db,
  actor: Actor,
  familyId: string,
  userId: string,
  input: Buffer,
  now: Date,
  crop: PhotoCrop | null = null,
): Promise<void> {
  await upload(memberAccess(db, actor, familyId, userId), input, crop, now);
}

/** A new crop of a member's photo, from its original (404 without a photo, 409 for one without
 *  an original). */
export async function cropMemberPhoto(
  db: Db,
  actor: Actor,
  familyId: string,
  userId: string,
  crop: PhotoCrop,
  now: Date,
): Promise<void> {
  await recrop(memberAccess(db, actor, familyId, userId), crop, now);
}

/** Removes a member's photo (square and original); members their own, editors anyone's. */
export function removeMemberPhoto(db: Db, actor: Actor, familyId: string, userId: string): void {
  remove(memberAccess(db, actor, familyId, userId));
}

/** The photo of someone without an account (replacing the one before); editors only. */
export async function setPersonPhoto(
  db: Db,
  actor: Actor,
  familyId: string,
  personId: string,
  input: Buffer,
  now: Date,
  crop: PhotoCrop | null = null,
): Promise<void> {
  await upload(personAccess(db, actor, familyId, personId), input, crop, now);
}

/** A new crop of the photo of someone without an account; editors only. */
export async function cropPersonPhoto(
  db: Db,
  actor: Actor,
  familyId: string,
  personId: string,
  crop: PhotoCrop,
  now: Date,
): Promise<void> {
  await recrop(personAccess(db, actor, familyId, personId), crop, now);
}

/** Removes the photo of someone without an account; editors only. */
export function removePersonPhoto(db: Db, actor: Actor, familyId: string, personId: string): void {
  remove(personAccess(db, actor, familyId, personId));
}
