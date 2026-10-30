# Dockerfile: one image for both processes. `docker-entrypoint.sh web` (default) applies
# migrations and serves Next.js; `docker-entrypoint.sh worker` runs the background worker.
FROM node:22-bookworm-slim AS deps
WORKDIR /app
# Build tools for native modules (better-sqlite3, argon2). sharp needs none: npm installs
# its prebuilt binary for the build platform (@img/sharp-linux-x64 / -arm64, glibc).
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json* ./
RUN npm install --no-audit --no-fund

FROM node:22-bookworm-slim AS build
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

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
# Next standalone server + assets.
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
COPY --from=build /app/public ./public
# Migration + worker toolchain: full deps (incl. tsx + the drizzle migrator) OVERRIDE the
# pruned standalone node_modules, plus the TS sources the scripts and the worker import.
COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/lib ./lib
COPY --from=build /app/scripts ./scripts
COPY --from=build /app/worker ./worker
COPY --from=build /app/drizzle ./drizzle
COPY --from=build /app/tsconfig.json ./tsconfig.json
COPY --from=build /app/package.json ./package.json
COPY docker-entrypoint.sh ./docker-entrypoint.sh
RUN chmod +x ./docker-entrypoint.sh && mkdir -p /app/data/media
ENV DATABASE_FILE=/app/data/ohana.db
# Recipe images, inside the data volume.
ENV MEDIA_ROOT=/app/data/media
ENV PORT=8000
# Next.js standalone server.js binds to $HOSTNAME; Docker auto-sets HOSTNAME to the
# container ID, so force 0.0.0.0 or loopback (healthcheck) can't reach it.
ENV HOSTNAME=0.0.0.0
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD node -e "fetch('http://localhost:8000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
ENV BACKUP_DIR=/app/data/backups
ENTRYPOINT ["./docker-entrypoint.sh"]
CMD ["web"]
