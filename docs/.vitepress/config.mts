// The project's website and documentation, https://ohana.fa-krug.de (GitHub Pages, built by
// .github/workflows/pages.yml). The pages are the Markdown files of docs/, so they read the same
// on GitHub. Links that leave docs/ (../server/.env.example, ../apple/README.md, …) point to the
// repository on GitHub on the site.
import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs"
import { createRequire } from "node:module"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { defineConfig } from "vitepress"
import { missingOperatorFields } from "./operator"

const repo = "https://github.com/fa-krug/ohana"
const docsDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const require = createRequire(import.meta.url)

// Files the API reference page (public/api-reference.html) loads, written next to it: the spec
// from docs/ and Redoc's bundle from node_modules, served by the site itself. Redoc's sidebar
// shows its logo from cdn.redoc.ly: replaced by an empty image, so the page makes no request
// to anyone else (see legal/privacy.md).
const blankImage = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="
const extraFiles: Record<string, () => string> = {
  "openapi.yaml": () => readFileSync(path.join(docsDir, "openapi.yaml"), "utf8"),
  "redoc.standalone.js": () => {
    const bundle = readFileSync(require.resolve("redoc/bundles/redoc.standalone.js"), "utf8")
    const logo = "https://cdn.redoc.ly/redoc/logo-mini.svg"
    if (!bundle.includes(logo)) throw new Error(`redoc.standalone.js no longer loads ${logo}: check it for outside requests`)
    return bundle.replaceAll(logo, blankImage)
  },
}

if (process.env.OHANA_SITE_STRICT === "1") {
  const missing = missingOperatorFields()
  if (missing.length) {
    throw new Error(
      `docs/.vitepress/operator.ts: fill in ${missing.join(", ")} before publishing (Imprint, privacy policy)`,
    )
  }
}

/** A relative link in docs/<relativePath> that leaves docs/ or isn't a page → the file on GitHub. */
function githubLink(href: string, relativePath: string): string | null {
  if (!href || /^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith("/") || href.startsWith("#")) return null
  const [target, hash = ""] = href.split("#")
  const resolved = path.posix.normalize(path.posix.join("docs", path.posix.dirname(relativePath), target))
  const insideDocs = resolved.startsWith("docs/")
  if (insideDocs && (target.endsWith(".md") || target.endsWith(".html") || !path.posix.extname(target))) return null
  const full = path.join(docsDir, "..", resolved)
  const kind = existsSync(full) && statSync(full).isDirectory() ? "tree" : "blob"
  return `${repo}/${kind}/main/${resolved}${hash ? `#${hash}` : ""}`
}

export default defineConfig({
  lang: "en",
  title: "Ohana",
  description:
    "One app for the whole family: calendar, finances, meals, doctor appointments and an AI assistant. Open source and self-hosted.",
  cleanUrls: true,
  lastUpdated: true,
  // README.md files and the CLAUDE-style notes aren't pages; node_modules is VitePress's own.
  srcExclude: ["**/README.md", "node_modules/**"],
  head: [
    ["link", { rel: "icon", type: "image/svg+xml", href: "/icon.svg" }],
    ["meta", { name: "theme-color", content: "#0d9488" }],
    ["meta", { property: "og:type", content: "website" }],
    ["meta", { property: "og:title", content: "Ohana: one app for the whole family" }],
    [
      "meta",
      {
        property: "og:description",
        content: "Calendar, finances, meals, doctor appointments and an AI assistant. Open source, self-hosted.",
      },
    ],
    ["meta", { property: "og:url", content: "https://ohana.fa-krug.de/" }],
  ],
  sitemap: { hostname: "https://ohana.fa-krug.de" },
  markdown: {
    config(md) {
      md.core.ruler.push("ohana_repo_links", (state) => {
        const relativePath: string = state.env?.relativePath ?? ""
        for (const block of state.tokens) {
          for (const token of block.children ?? []) {
            if (token.type !== "link_open") continue
            const href = token.attrGet("href")
            const rewritten = href ? githubLink(href, relativePath) : null
            if (rewritten) token.attrSet("href", rewritten)
          }
        }
      })
    },
  },
  vite: {
    plugins: [
      {
        // `npm run dev`: serve the API reference's files like the build does.
        name: "ohana-extra-files",
        configureServer(server) {
          server.middlewares.use((req, res, next) => {
            const name = req.url?.split("?")[0].replace(/^\//, "") ?? ""
            const content = extraFiles[name]
            if (!content) return next()
            res.setHeader("Content-Type", name.endsWith(".js") ? "text/javascript" : "application/yaml")
            res.end(content())
          })
        },
      },
    ],
  },
  buildEnd(site) {
    for (const [name, content] of Object.entries(extraFiles)) {
      writeFileSync(path.join(site.outDir, name), content())
    }
  },
  themeConfig: {
    logo: "/icon.svg",
    nav: [
      { text: "Quick start", link: "/quickstart" },
      { text: "Docs", link: "/introduction", activeMatch: "^/(introduction|quickstart|self-hosting|configuration|app|api|development|security|plan)" },
      { text: "API reference", link: "/api-reference.html", target: "_self" },
      {
        text: "Project",
        items: [
          { text: "Source code", link: repo },
          { text: "Issues", link: `${repo}/issues` },
          { text: "Contributing", link: `${repo}/blob/main/CONTRIBUTING.md` },
          { text: "Container image", link: `${repo}/pkgs/container/ohana` },
        ],
      },
    ],
    sidebar: [
      {
        text: "Getting started",
        items: [
          { text: "What is Ohana?", link: "/introduction" },
          { text: "Quick start", link: "/quickstart" },
        ],
      },
      {
        text: "Running a server",
        items: [
          { text: "Self-hosting guide", link: "/self-hosting" },
          { text: "Configuration reference", link: "/configuration" },
          { text: "Security", link: "/security" },
        ],
      },
      {
        text: "Using Ohana",
        items: [{ text: "The app", link: "/app" }],
      },
      {
        text: "Developers",
        items: [
          { text: "Development", link: "/development" },
          { text: "API", link: "/api" },
          { text: "API reference", link: "/api-reference.html", target: "_self" },
          { text: "Background and decisions", link: "/plan" },
        ],
      },
      {
        text: "Legal",
        items: [
          { text: "Imprint", link: "/legal/imprint" },
          { text: "Privacy policy", link: "/legal/privacy" },
          { text: "Licenses", link: "/legal/license" },
        ],
      },
    ],
    socialLinks: [{ icon: "github", link: repo }],
    search: { provider: "local" },
    editLink: {
      pattern: `${repo}/edit/main/docs/:path`,
      text: "Edit this page on GitHub",
    },
    footer: {
      message:
        'Server AGPL-3.0, app MPL-2.0 · <a href="/legal/imprint">Imprint</a> · <a href="/legal/privacy">Privacy</a> · <a href="/legal/license">Licenses</a>',
      copyright: "Ohana contributors",
    },
  },
})
