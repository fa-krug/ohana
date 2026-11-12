// The knowledge base of the family API (/api/v1/families/{id}/knowledge…). Editors only: for a
// viewer every path under /knowledge answers 404 as for a family without the module, so nothing
// tells them it exists.
//
// GET   /knowledge/folder                      {folder: {id, createdAt, lastManifestAt, lastManifestDevice, aiScans} | null}
// POST  /knowledge/folder                      {replace?} → {folder} (201 when this made it; replace: a new one, the old one's documents gone)
// PATCH /knowledge/folder                      {aiScans} → {folder} (404 without one; off: the waiting scans not asked for go)
// GET  /knowledge/status                       {folder | null, counts: {pending, ready, failed, missing, excluded}, chunks, cards, cardCounts, scans, aiScans}
// POST /knowledge/cards                        {all?} → 202 {queued, cardCounts} (cards written again: the older ones and failed, or all; 409 while none are made: without the family's AI or with `aiScans` off)
// POST /knowledge/manifest                     {folderId, device?, files: [{path, size, mtime, hash | null, tags, reader?}]} → {upload: [path]}
// PUT  /knowledge/documents                    {folderId, path, hash, size, mtime, tags, reader?, reread?, scansChecked?, pages: [text]} → 202 {id, status}
// PUT  /knowledge/documents/{id}/pages/{page}/scan?hash=&force=   (image/jpeg) → 202 {page, status} (scans.ts)
// GET  /knowledge/documents?q=&tag=&folder=&person=&status=&cursor=&limit=   {documents, nextCursor}
// GET  /knowledge/documents/{id}               {document} (with the card's facts and the chunks)
// POST /knowledge/documents/{id}/reindex       202 {document}
// POST /knowledge/documents/{id}/exclude       {excluded} → {document}
// POST /knowledge/documents/{id}/card          202 {document} (the card made again; 409 unless ready with text)
// GET  /knowledge/tags                         {tags: [{tag, count}]}

import type { Ctx, Loaded } from "@/lib/api/family-api";
import { HttpError, json } from "@/lib/api/http";
import { cardsEnabled, cardsOn } from "./card";
import {
  STATUSES,
  type DocumentStatus,
  cleanPages,
  countCards,
  countDocuments,
  getDocument,
  listDocuments,
  listTags,
  reindexDocument,
  remakeCard,
  rewriteCards,
  setExcluded,
  uploadDocument,
} from "./documents";
import { ensureFolder, folderDto, getFolder, replaceFolder, requireFolder, setAiScans } from "./folders";
import { cleanFileInfo, cleanFolderFilter, readLimitedBody } from "./input";
import { applyManifest, cleanDevice, cleanManifestFiles } from "./manifest";
import { putPageScan, scansEnabled } from "./scans";

/** Request bodies: a manifest of 20 000 files, an upload's 2 MB of text as JSON. */
const MAX_MANIFEST_BODY = 16_000_000;
const MAX_UPLOAD_BODY = 8_000_000;

/** Routes /families/{id}/knowledge[/…]; null for anything else. */
export function handleKnowledge(ctx: Ctx): Promise<Response> | null {
  if (ctx.rest[0] !== "knowledge") return null;
  return loadEditor(ctx).then((loaded) => route(ctx, loaded));
}

const notFound = () => new HttpError(404, "Not found");
const notAllowed = () => new HttpError(405, "Method not allowed");

/** The family for an editor; a viewer gets the same 404 as an unknown path. */
async function loadEditor(ctx: Ctx): Promise<Loaded> {
  const loaded = await ctx.load("view");
  if (loaded.access !== "edit") throw notFound();
  return loaded;
}

function route(ctx: Ctx, { family }: Loaded): Promise<Response> {
  const [, part, id, action, ...more] = ctx.rest;
  const { method } = ctx;
  const familyId = family.id;
  if (part === "documents" && id !== undefined && action === "pages" && more.length === 2 && more[1] === "scan") {
    if (method === "PUT") return scanRoute(ctx, familyId, id, more[0]);
    throw notAllowed();
  }
  if (more.length) throw notFound();
  switch (part) {
    case "folder":
      if (id !== undefined) throw notFound();
      if (method === "GET") return folderRoute(ctx, familyId);
      if (method === "POST") return createFolderRoute(ctx, familyId);
      if (method === "PATCH") return patchFolderRoute(ctx, familyId);
      throw notAllowed();
    case "status":
      if (id !== undefined) throw notFound();
      if (method === "GET") return statusRoute(ctx, familyId);
      throw notAllowed();
    case "cards":
      if (id !== undefined) throw notFound();
      if (method === "POST") return rewriteCardsRoute(ctx, familyId);
      throw notAllowed();
    case "manifest":
      if (id !== undefined) throw notFound();
      if (method === "POST") return manifestRoute(ctx, familyId);
      throw notAllowed();
    case "tags":
      if (id !== undefined) throw notFound();
      if (method === "GET") return Promise.resolve(json({ tags: listTags(ctx.db, familyId) }));
      throw notAllowed();
    case "documents":
      if (id === undefined) {
        if (method === "GET") return listRoute(ctx, familyId);
        if (method === "PUT") return uploadRoute(ctx, familyId);
        throw notAllowed();
      }
      if (action === undefined) {
        if (method === "GET") return Promise.resolve(json({ document: getDocument(ctx.db, familyId, id) }));
        throw notAllowed();
      }
      if (action === "reindex") {
        if (method === "POST") return Promise.resolve(json({ document: reindexDocument(ctx.db, familyId, id, ctx.now) }, 202));
        throw notAllowed();
      }
      if (action === "card") {
        if (method === "POST") return Promise.resolve(json({ document: remakeCard(ctx.db, familyId, id, ctx.now) }, 202));
        throw notAllowed();
      }
      if (action === "exclude") {
        if (method === "POST") return excludeRoute(ctx, familyId, id);
        throw notAllowed();
      }
      throw notFound();
    default:
      throw notFound();
  }
}

async function folderRoute(ctx: Ctx, familyId: string): Promise<Response> {
  const folder = getFolder(ctx.db, familyId);
  return json({ folder: folder ? folderDto(folder) : null });
}

/** The family's folder, made on first use; with `{replace: true}` a new one in place of the old. */
async function createFolderRoute(ctx: Ctx, familyId: string): Promise<Response> {
  const body = await readLimitedBody(ctx.req, 10_000);
  if (body.replace !== undefined && typeof body.replace !== "boolean") throw new HttpError(400, "replace must be true or false");
  const userId = ctx.requireUser().id;
  if (body.replace) return json({ folder: folderDto(replaceFolder(ctx.db, familyId, userId, ctx.now)) }, 201);
  const { folder, created } = ensureFolder(ctx.db, familyId, userId, ctx.now);
  return json({ folder: folderDto(folder) }, created ? 201 : 200);
}

/** The family's settings of the folder: `aiScans` (the assistant reads the knowledge base: the
 *  documents' summaries and keywords are written, every page of PDFs and images goes to the family's
 *  AI). */
async function patchFolderRoute(ctx: Ctx, familyId: string): Promise<Response> {
  const body = await readLimitedBody(ctx.req, 10_000);
  if (typeof body.aiScans !== "boolean") throw new HttpError(400, "aiScans must be true or false");
  return json({ folder: folderDto(setAiScans(ctx.db, familyId, body.aiScans)) });
}

/** The settings screen's view: the folder (with the last manifest), documents by status, chunks,
 *  the cards by status (`cardCounts`, countCards), whether scans can be read (`scans`: the family's AI set up, the assistant on),
 *  whether the family has its AI read the knowledge base (`aiScans`) and so whether cards are made (`cards`: both). */
async function statusRoute(ctx: Ctx, familyId: string): Promise<Response> {
  const folder = getFolder(ctx.db, familyId);
  const { counts, chunks } = countDocuments(ctx.db, familyId);
  return json({
    folder: folder ? folderDto(folder) : null,
    counts,
    chunks,
    cards: cardsOn(ctx.db, familyId),
    cardCounts: countCards(ctx.db, familyId),
    scans: scansEnabled(ctx.db, familyId),
    aiScans: folder?.aiScans ?? false,
  });
}

/** Settings → Knowledge's *Read All* (with the assistant on): the cards made before keywords and
 *  the failed ones, or with `{all: true}` every card, wait for the worker again (one AI request
 *  each). 409 while no cards are made. */
async function rewriteCardsRoute(ctx: Ctx, familyId: string): Promise<Response> {
  const body = await readLimitedBody(ctx.req, 10_000);
  if (body.all !== undefined && typeof body.all !== "boolean") throw new HttpError(400, "all must be true or false");
  if (!cardsEnabled(ctx.db, familyId)) throw new HttpError(409, "The family's AI isn't set up, so no summaries are written");
  if (!cardsOn(ctx.db, familyId)) throw new HttpError(409, "The assistant doesn't read the knowledge base, so no summaries are written");
  const queued = rewriteCards(ctx.db, familyId, { all: body.all === true }, ctx.now);
  return json({ queued, cardCounts: countCards(ctx.db, familyId) }, 202);
}

async function scanRoute(ctx: Ctx, familyId: string, id: string, page: string): Promise<Response> {
  return json(await putPageScan(ctx.db, familyId, id, page, ctx.url.searchParams, ctx.req, ctx.now), 202);
}

async function manifestRoute(ctx: Ctx, familyId: string): Promise<Response> {
  const body = await readLimitedBody(ctx.req, MAX_MANIFEST_BODY);
  const folder = requireFolder(ctx.db, familyId, body.folderId);
  const device = cleanDevice(body.device);
  const files = cleanManifestFiles(body.files);
  return json(applyManifest(ctx.db, folder, files, ctx.now, device));
}

async function uploadRoute(ctx: Ctx, familyId: string): Promise<Response> {
  const body = await readLimitedBody(ctx.req, MAX_UPLOAD_BODY);
  const folder = requireFolder(ctx.db, familyId, body.folderId);
  if (body.reread !== undefined && typeof body.reread !== "boolean") throw new HttpError(400, "reread must be true or false");
  if (body.scansChecked !== undefined && typeof body.scansChecked !== "boolean") throw new HttpError(400, "scansChecked must be true or false");
  const input = { ...cleanFileInfo(body, "body"), pages: cleanPages(body.pages), reread: body.reread === true, scansChecked: body.scansChecked === true };
  const { id, status } = uploadDocument(ctx.db, familyId, folder.id, input, ctx.now);
  return json({ id, status }, 202);
}

async function listRoute(ctx: Ctx, familyId: string): Promise<Response> {
  const p = ctx.url.searchParams;
  const status = p.get("status") || null;
  if (status !== null && !STATUSES.includes(status as DocumentStatus)) {
    throw new HttpError(400, `status must be one of ${STATUSES.join(", ")}`);
  }
  const rawLimit = p.get("limit");
  const limit = rawLimit ? Number(rawLimit) : undefined;
  if (limit !== undefined && (!Number.isInteger(limit) || limit < 1)) throw new HttpError(400, "limit must be a whole number ≥ 1");
  const person = p.get("person") || null;
  if (person !== null && person.length > 100) throw new HttpError(400, "person is not a member's id");
  return json(
    listDocuments(ctx.db, familyId, {
      q: p.get("q"),
      tag: p.get("tag") || null,
      folder: cleanFolderFilter(p.get("folder")),
      person,
      status: status as DocumentStatus | null,
      cursor: p.get("cursor") || null,
      limit,
    }),
  );
}

async function excludeRoute(ctx: Ctx, familyId: string, id: string): Promise<Response> {
  const body = await readLimitedBody(ctx.req, 10_000);
  if (typeof body.excluded !== "boolean") throw new HttpError(400, "excluded must be true or false");
  return json({ document: setExcluded(ctx.db, familyId, id, body.excluded, ctx.now) });
}
