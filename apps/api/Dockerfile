FROM node:22-alpine AS build
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

FROM node:22-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app/apps/api

COPY --from=build /app/apps/api/package*.json ./
COPY --from=build /app/apps/api/node_modules ./node_modules
COPY --from=build /app/apps/api/dist ./dist
COPY --from=build /app/apps/api/docs ./docs
COPY --from=build /app/infra/migrations /app/infra/migrations
COPY apps/api/.env.example ./.env.example

RUN mkdir -p uploads exports \
  && chown -R node:node /app/apps/api /app/infra

USER node
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=5 \
  CMD node -e "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "dist/server.js"]
