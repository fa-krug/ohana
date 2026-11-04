// Input checks of the knowledge base: a file's path relative to the folder, its hash, size,
// modification time and Finder tags, as the app sends them in a manifest or an upload.

import { HttpError } from "@/lib/api/http";

export const MAX_PATH_LENGTH = 1024;
export const MAX_TAGS = 50;
export const MAX_TAG_LENGTH = 100;

const HASH_RE = /^[0-9a-f]{64}$/;

/** A path relative to the folder: NFC, "/" separated, no leading or trailing "/", no empty,
 *  "." or ".." part and no hidden part (".…": the app skips hidden files), at most 1024
 *  characters. Null when it isn't one. */
export function normalizePath(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const path = v.normalize("NFC");
  if (!path || path.length > MAX_PATH_LENGTH || /[\u0000-\u001f\\]/.test(path)) return null;
  const parts = path.split("/");
  if (parts.some((p) => p === "" || p.startsWith("."))) return null;
  return path;
}

export function cleanPath(v: unknown, field = "path"): string {
  const path = normalizePath(v);
  if (path === null) throw new HttpError(400, `${field} must be a path inside the folder`);
  return path;
}

/** The last part of a path: the file's name. */
export function nameOf(path: string): string {
  return path.slice(path.lastIndexOf("/") + 1);
}

/** A subfolder to filter by ("Versicherungen/Auto"; slashes around it are ignored); null for
 *  none (empty or "/"). */
export function cleanFolderFilter(v: string | null): string | null {
  if (v === null) return null;
  const trimmed = v.replace(/^\/+|\/+$/g, "");
  if (!trimmed) return null;
  return cleanPath(trimmed, "folder");
}

/** A SHA-256 in hex (lowercased). */
export function cleanHash(v: unknown, field = "hash"): string {
  const hash = typeof v === "string" ? v.toLowerCase() : "";
  if (!HASH_RE.test(hash)) throw new HttpError(400, `${field} must be a SHA-256 in hex`);
  return hash;
}

/** A whole number ≥ 0 (a size in bytes, a time in ms). */
export function cleanCount(v: unknown, field: string): number {
  if (typeof v !== "number" || !Number.isSafeInteger(v) || v < 0) {
    throw new HttpError(400, `${field} must be a whole number ≥ 0`);
  }
  return v;
}

/** Finder tags: trimmed, NFC, without empty ones and duplicates (missing: none). */
export function cleanTags(v: unknown, field = "tags"): string[] {
  if (v === undefined || v === null) return [];
  if (!Array.isArray(v) || v.some((t) => typeof t !== "string")) {
    throw new HttpError(400, `${field} must be a list of strings`);
  }
  const tags = [...new Set((v as string[]).map((t) => t.normalize("NFC").trim()).filter(Boolean))];
  if (tags.length > MAX_TAGS) throw new HttpError(400, `${field}: at most ${MAX_TAGS} tags`);
  if (tags.some((t) => t.length > MAX_TAG_LENGTH)) throw new HttpError(400, `${field}: a tag is too long (max. ${MAX_TAG_LENGTH})`);
  return tags;
}

/** The fields every file carries (a manifest's entry, an upload). */
export interface FileInfo {
  path: string;
  size: number;
  mtime: number;
  hash: string;
  tags: string[];
}

/** A manifest's entry: `hash` null for a file the device sees but couldn't hash (an iCloud file
 *  it couldn't download). */
export type ManifestFile = Omit<FileInfo, "hash"> & { hash: string | null };

export function cleanFileInfo(raw: unknown, what?: string): FileInfo;
export function cleanFileInfo(raw: unknown, what: string, opts: { nullHash: true }): ManifestFile;
export function cleanFileInfo(raw: unknown, what = "file", opts: { nullHash?: boolean } = {}): ManifestFile {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new HttpError(400, `${what} must be an object`);
  const f = raw as Record<string, unknown>;
  return {
    path: cleanPath(f.path),
    size: cleanCount(f.size, "size"),
    mtime: cleanCount(f.mtime, "mtime"),
    hash: opts.nullHash && f.hash === null ? null : cleanHash(f.hash),
    tags: cleanTags(f.tags),
  };
}

/** Reads a JSON object body of at most `maxBytes` (413 above it). */
export async function readLimitedBody(req: Request, maxBytes: number): Promise<Record<string, unknown>> {
  const tooLarge = () => new HttpError(413, `The request is too large (max. ${Math.round(maxBytes / 1_000_000)} MB)`);
  if (Number(req.headers.get("content-length") ?? 0) > maxBytes) throw tooLarge();
  const bytes = await req.arrayBuffer();
  if (bytes.byteLength > maxBytes) throw tooLarge();
  const text = new TextDecoder().decode(bytes);
  if (!text.trim()) return {};
  try {
    const body = JSON.parse(text);
    if (body && typeof body === "object" && !Array.isArray(body)) return body;
  } catch {
    // fall through
  }
  throw new HttpError(400, "Body must be a JSON object");
}
