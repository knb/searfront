FROM node:22-bookworm-slim AS base
WORKDIR /app

FROM base AS deps
COPY package*.json ./
RUN npm ci

FROM deps AS build
COPY tsconfig.json eslint.config.js ./
COPY src ./src
RUN npm run build

FROM base AS production
ENV NODE_ENV=production
RUN groupadd --system app && useradd --system --gid app --home /app app
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build /app/dist ./dist
RUN mkdir -p /app/debug && chown -R app:app /app
USER app
EXPOSE 3000
CMD ["node", "dist/server.js"]
