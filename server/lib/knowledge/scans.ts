// Page scans: a page of a document the app sends as a picture (PUT
// /knowledge/documents/{id}/pages/{page}/scan?hash=…[&force=1]) for the family's AI to transcribe
// (scan-runner.ts), because the device's own OCR read it poorly (a table, a sideways or faint
// scan). The family turns this on (`kb_folders.ai_scans`, PATCH /knowledge/folder): the pages go
// to its AI provider. An editor may ask for one document anyway (`force`, "Read Again with the
// Assistant"); both need the family's AI set up and the assistant on (`scansEnabled`, what the
// status calls `scans`).
//
// The picture is kept as a file (scan-files.ts) only until it's read; the row says how it went
// (waiting | running | done | failed) and goes with the document's text, after 7 days at most.

import { and, count, eq, inArray, ne } from "drizzle-orm";
import type { Db } from "@/lib/db";
import { kbDocuments, kbPageScans } from "@/lib/db/schema";
import { HttpError } from "@/lib/api/http";
import { cardsEnabled } from "./card";
import { getDocumentRow } from "./documents";
import { getFolder } from "./folders";
import { cleanHash } from "./input";
import { deleteScanFiles, writeScanFile } from "./scan-files";

/** The largest picture of a page. */
export const MAX_SCAN_BYTES = 4 * 1024 * 1024;
/** Scans of one document waiting or being read at a time. */
export const MAX_SCANS_PER_DOCUMENT = 20;

export type ScanStatus = "waiting" | "running" | "done" | "failed";

/** Whether the family's page scans can be read at all: the assistant on and the family's AI set
 *  up (as for the cards). */
export function scansEnabled(db: Pick<Db, "select">, familyId: string): boolean {
  return cardsEnabled(db, familyId);
}

/** The page of the path: a whole number ≥ 1 (400 otherwise). */
function cleanPage(raw: string): number {
  const page = /^\d{1,6}$/.test(raw) ? Number(raw) : 0;
  if (page < 1) throw new HttpError(400, "page must be a whole number ≥ 1");
  return page;
}

/** Whether a query flag is set ("1" or "true"). */
function flag(v: string | null): boolean {
  return v === "1" || v === "true";
}

/** The request's body as bytes: a JPEG of at most MAX_SCAN_BYTES (413 above, 415 for another
 *  type, 400 for something that isn't a JPEG). */
async function readJpeg(req: Request): Promise<Buffer> {
  const type = (req.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  if (type !== "image/jpeg") throw new HttpError(415, "The page must be sent as image/jpeg");
  const tooLarge = () => new HttpError(413, `The picture is too large (max. ${MAX_SCAN_BYTES / 1024 / 1024} MB)`);
  if (Number(req.headers.get("content-length") ?? 0) > MAX_SCAN_BYTES) throw tooLarge();
  const bytes = Buffer.from(await req.arrayBuffer());
  if (bytes.length > MAX_SCAN_BYTES) throw tooLarge();
  // A JPEG starts with SOI and a marker.
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff) throw new HttpError(400, "The page is not a JPEG");
  return bytes;
}

/**
 * Stores a page's picture for the family's AI (the scan route). 404: no such document; 400: no
 * such page; 409: the document changed (`hash` isn't its current one), it is excluded or its file
 * missing, the family's AI can't read scans, or (without `force`) the family has them off; 413:
 * MAX_SCANS_PER_DOCUMENT other pages of it still wait, or the picture is too large. A scan of the
 * same page replaces the earlier one (row and file).
 */
export async function putPageScan(
  db: Db,
  familyId: string,
  documentId: string,
  rawPage: string,
  params: URLSearchParams,
  req: Request,
  now: Date,
): Promise<{ page: number; status: ScanStatus }> {
  const page = cleanPage(rawPage);
  const force = flag(params.get("force"));
  const hash = cleanHash(params.get("hash") ?? "");
  const doc = getDocumentRow(db, familyId, documentId);
  if (!doc) throw new HttpError(404, "Document not found");
  if (page > doc.pages) throw new HttpError(400, `The document has ${doc.pages} page(s)`);
  if (doc.hash !== hash) throw new HttpError(409, "The document changed");
  if (doc.status === "excluded") throw new HttpError(409, "The document is excluded");
  if (doc.status === "missing") throw new HttpError(409, "The document's file is missing");
  if (!scansEnabled(db, familyId)) throw new HttpError(409, "The family's AI can't read scans");
  if (!force && !getFolder(db, familyId)?.aiScans) throw new HttpError(409, "Reading scans with the assistant is off");
  const open = () =>
    db
      .select({ n: count() })
      .from(kbPageScans)
      .where(and(eq(kbPageScans.documentId, documentId), ne(kbPageScans.page, page), inArray(kbPageScans.status, ["waiting", "running"])))
      .get()?.n ?? 0;
  const tooMany = () => new HttpError(413, `Too many pages of the document wait to be read (max. ${MAX_SCANS_PER_DOCUMENT})`);
  if (open() >= MAX_SCANS_PER_DOCUMENT) throw tooMany();
  const bytes = await readJpeg(req);

  const path = writeScanFile(familyId, documentId, page, bytes, now);
  let replaced: string | null;
  try {
    replaced = db.transaction(
      (tx) => {
        // Checked again: the document may have changed while the picture came.
        const row = tx
          .select({ hash: kbDocuments.hash, status: kbDocuments.status, pages: kbDocuments.pages })
          .from(kbDocuments)
          .where(and(eq(kbDocuments.familyId, familyId), eq(kbDocuments.id, documentId)))
          .get();
        if (!row) throw new HttpError(404, "Document not found");
        if (row.hash !== hash || page > row.pages || row.status === "excluded" || row.status === "missing") {
          throw new HttpError(409, "The document changed");
        }
        if (open() >= MAX_SCANS_PER_DOCUMENT) throw tooMany();
        const old =
          tx
            .select({ path: kbPageScans.path })
            .from(kbPageScans)
            .where(and(eq(kbPageScans.documentId, documentId), eq(kbPageScans.page, page)))
            .get()?.path ?? null;
        const fresh = {
          hash,
          path,
          forced: force,
          status: "waiting",
          error: null,
          runToken: null,
          runUntil: null,
          attempts: 0,
          retries: 0,
          createdAt: now,
          updatedAt: now,
        };
        tx.insert(kbPageScans)
          .values({ documentId, familyId, page, ...fresh })
          .onConflictDoUpdate({ target: [kbPageScans.documentId, kbPageScans.page], set: fresh })
          .run();
        return old;
      },
      { behavior: "immediate" },
    );
  } catch (err) {
    deleteScanFiles([path]);
    throw err;
  }
  if (replaced && replaced !== path) deleteScanFiles([replaced]);
  return { page, status: "waiting" };
}
