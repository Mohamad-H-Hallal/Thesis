FROM node:22-alpine@sha256:16e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2 AS build
WORKDIR /app/apps/api

COPY apps/api/package*.json ./
RUN npm ci

COPY apps/api/tsconfig*.json ./
COPY apps/api/src ./src
COPY apps/api/docs ./docs
COPY infra/migrations /app/infra/migrations

RUN npm run build \
  && npm prune --omit=dev \
  && npm cache clean --force

FROM node:22-alpine@sha256:16e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2 AS runtime
ARG APP_RELEASE_VERSION=development
ARG APP_RELEASE_COMMIT=unknown
LABEL org.opencontainers.image.source="https://github.com/Mohamad-H-Hallal/Thesis" \
      org.opencontainers.image.version="${APP_RELEASE_VERSION}" \
      org.opencontainers.image.revision="${APP_RELEASE_COMMIT}"
ENV NODE_ENV=production
WORKDIR /app/apps/api

COPY --from=build /app/apps/api/package*.json ./
COPY --from=build /app/apps/api/node_modules ./node_modules
COPY --from=build /app/apps/api/dist ./dist
COPY --from=build /app/apps/api/docs ./docs
COPY --from=build /app/infra/migrations /app/infra/migrations
COPY apps/api/.env.example ./.env.example
COPY apps/api/docker/entrypoint.sh /usr/local/bin/api-entrypoint.sh

RUN rm -rf \
      /usr/local/lib/node_modules/npm \
      /usr/local/lib/node_modules/corepack \
      /usr/local/bin/npm \
      /usr/local/bin/npx \
      /usr/local/bin/corepack \
  && mkdir -p uploads exports \
  && chmod +x /usr/local/bin/api-entrypoint.sh \
  && chown -R node:node /app/apps/api /app/infra

USER node
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 \
  CMD node -e "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["api-entrypoint.sh"]
CMD ["node", "dist/server.js"]
