FROM node:20-alpine AS base
WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev

COPY src ./src
COPY docs ./docs
COPY .env.example ./.env.example

EXPOSE 3000
CMD ["node", "src/server.js"]

