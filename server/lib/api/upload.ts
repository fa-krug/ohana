import { AuthError } from "@/lib/auth/errors";
import { ALLOWED_UPLOAD_TYPES, MAX_UPLOAD_BYTES } from "@/lib/meals/images/config";

/** An uploaded photo (a recipe's, a member's): the body itself (Content-Type image/jpeg, png or
 *  webp) or a form's "image" file, at most MAX_UPLOAD_BYTES. */
export async function uploadedImage(req: Request): Promise<Buffer> {
  const type = (req.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  let fileType: string;
  let bytes: Buffer;
  if (type === "multipart/form-data") {
    const file = (await req.formData().catch(() => null))?.get("image");
    if (!(file instanceof File)) throw new AuthError(400, "No file provided");
    fileType = file.type;
    if (file.size > MAX_UPLOAD_BYTES) throw new AuthError(400, "File too large (max 5MB)");
    bytes = Buffer.from(await file.arrayBuffer());
  } else {
    fileType = type;
    if (!ALLOWED_UPLOAD_TYPES.has(fileType)) throw new AuthError(400, "Invalid file type");
    const length = Number(req.headers.get("content-length") ?? 0);
    if (length > MAX_UPLOAD_BYTES) throw new AuthError(400, "File too large (max 5MB)");
    bytes = Buffer.from(await req.arrayBuffer());
  }
  if (!ALLOWED_UPLOAD_TYPES.has(fileType)) throw new AuthError(400, "Invalid file type");
  if (bytes.length === 0) throw new AuthError(400, "No file provided");
  if (bytes.length > MAX_UPLOAD_BYTES) throw new AuthError(400, "File too large (max 5MB)");
  return bytes;
}
