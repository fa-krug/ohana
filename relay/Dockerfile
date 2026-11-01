# Dockerfile: the push relay (relay/). Built for linux/amd64 and linux/arm64 (e.g. a Raspberry Pi).
# No native modules and no build step: the TypeScript runs with tsx, like the server.
FROM node:22-bookworm-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund && npm prune --omit=dev --no-audit --no-fund

FROM node:22-bookworm-slim AS runtime
WORKDIR /app
# Refuse to ship a runtime older than the CVE-2026-111497 fix (Node 22.23.4); see server/Dockerfile.
RUN node -e 'const v = process.versions.node.split(".").map(Number); \
  const min = [22, 23, 4]; \
  const cmp = v.map((n, i) => n - min[i]).find((d) => d !== 0) ?? 0; \
  if (cmp < 0) { console.error(`Node ${process.version} predates the CVE-2026-111497 fix (>= 22.23.4); pull a fresh node:22-bookworm-slim`); process.exit(1); }'
ENV NODE_ENV=production
ENV PORT=8080
COPY --from=deps /app/node_modules ./node_modules
COPY package.json tsconfig.json ./
COPY src ./src
# The relay holds no files: run it as the image's unprivileged user.
USER node
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://localhost:'+(process.env.PORT||8080)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["./node_modules/.bin/tsx", "src/index.ts"]
