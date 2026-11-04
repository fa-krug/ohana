// The knowledge base of the family API (/api/v1/families/{id}/knowledge…). Editors only: for a
// viewer every path under /knowledge answers 404 as for a family without the module, so nothing
// tells them it exists.
//
// GET  /knowledge/folder                       {folder: {id, createdAt} | null}
// POST /knowledge/folder                       {folder} (201 when this made it)
// POST /knowledge/manifest                     {folderId, files: [{path, size, mtime, hash, tags}]} → {upload: [path]}
// PUT  /knowledge/documents                    {folderId, path, hash, size, mtime, tags, pages: [text]} → 202 {id, status}
// GET  /knowledge/documents?q=&tag=&folder=&status=&cursor=&limit=   {documents, nextCursor}
// GET  /knowledge/documents/{id}               {document} (with facts and chunks)
// POST /knowledge/documents/{id}/reindex       202 {document}
// POST /knowledge/documents/{id}/exclude       {excluded} → {document}
// GET  /knowledge/tags                         {tags: [{tag, count}]}

import type { Ctx, Loaded } from "@/lib/api/family-api";
import { HttpError, json } from "@/lib/api/http";
import { STATUSES, type DocumentStatus, cleanPages, getDocument, listDocuments, listTags, reindexDocument, setExcluded, uploadDocument } from "./documents";
import { ensureFolder, folderDto, getFolder, requireFolder } from "./folders";
import { cleanFileInfo, cleanFolderFilter, readLimitedBody } from "./input";
import { applyManifest, cleanManifestFiles } from "./manifest";

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
  if (more.length) throw notFound();
  switch (part) {
    case "folder":
      if (id !== undefined) throw notFound();
      if (method === "GET") return folderRoute(ctx, familyId);
      if (method === "POST") return createFolderRoute(ctx, familyId);
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

async function createFolderRoute(ctx: Ctx, familyId: string): Promise<Response> {
  const { folder, created } = ensureFolder(ctx.db, familyId, ctx.requireUser().id, ctx.now);
  return json({ folder: folderDto(folder) }, created ? 201 : 200);
}

async function manifestRoute(ctx: Ctx, familyId: string): Promise<Response> {
  const body = await readLimitedBody(ctx.req, MAX_MANIFEST_BODY);
  const folder = requireFolder(ctx.db, familyId, body.folderId);
  const files = cleanManifestFiles(body.files);
  return json(applyManifest(ctx.db, folder.id, files, ctx.now));
}

async function uploadRoute(ctx: Ctx, familyId: string): Promise<Response> {
  const body = await readLimitedBody(ctx.req, MAX_UPLOAD_BODY);
  const folder = requireFolder(ctx.db, familyId, body.folderId);
  const input = { ...cleanFileInfo(body, "body"), pages: cleanPages(body.pages) };
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
  return json(
    listDocuments(ctx.db, familyId, {
      q: p.get("q"),
      tag: p.get("tag") || null,
      folder: cleanFolderFilter(p.get("folder")),
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
