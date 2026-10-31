# Dockerfile: one image for both processes. `docker-entrypoint.sh server` (default) applies
# migrations and serves the API and sign-in pages; `docker-entrypoint.sh worker` runs the
# background worker. Built for linux/amd64 and linux/arm64 (e.g. a Raspberry Pi).
FROM node:22-bookworm-slim AS deps
WORKDIR /app
# Build tools for native modules (better-sqlite3, argon2). sharp needs none: npm installs
# its prebuilt binary for the build platform (@img/sharp-linux-x64 / -arm64, glibc).
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

FROM deps AS build
COPY . .
# The sign-in pages' script (client/auth.ts → public/assets/auth.js), then drop dev tools.
RUN npm run build && npm prune --omit=dev --no-audit --no-fund

FROM node:22-bookworm-slim AS runtime
WORKDIR /app
# Refuse to ship a runtime older than the CVE-2026-111497 fix (Brotli decoder
# out-of-bounds write; fixed in Node 22.23.4). The tag floats, but a Docker host
# that already holds an older copy of `node:22-bookworm-slim` builds from that
# copy without pulling. Checked by Node version because the fix was backported:
# `process.versions.brotli` still reads 1.1.0 on 22.23.4.
RUN node -e 'const v = process.versions.node.split(".").map(Number); \
  const min = [22, 23, 4]; \
  const cmp = v.map((n, i) => n - min[i]).find((d) => d !== 0) ?? 0; \
  if (cmp < 0) { console.error(`Node ${process.version} predates the CVE-2026-111497 fix (>= 22.23.4); pull a fresh node:22-bookworm-slim`); process.exit(1); }'
ENV NODE_ENV=production
# The server runs its TypeScript with tsx (like the worker): sources, migrations, static files
# and the production dependencies.
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/http ./http
COPY --from=build /app/lib ./lib
COPY --from=build /app/worker ./worker
COPY --from=build /app/scripts ./scripts
COPY --from=build /app/drizzle ./drizzle
COPY --from=build /app/public ./public
COPY --from=build /app/tsconfig.json /app/package.json ./
COPY docker-entrypoint.sh ./docker-entrypoint.sh
RUN chmod +x ./docker-entrypoint.sh && mkdir -p /app/data/media
# The release, shown by GET /api/v1/server (CI passes the git tag; else package.json's).
ARG OHANA_VERSION=
ENV OHANA_VERSION=${OHANA_VERSION}
ENV DATABASE_FILE=/app/data/ohana.db
# Recipe images and backups, inside the data volume.
ENV MEDIA_ROOT=/app/data/media
ENV BACKUP_DIR=/app/data/backups
ENV PORT=8000
EXPOSE 8000
VOLUME ["/app/data"]
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD node -e "fetch('http://localhost:8000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
ENTRYPOINT ["./docker-entrypoint.sh"]
CMD ["server"]
