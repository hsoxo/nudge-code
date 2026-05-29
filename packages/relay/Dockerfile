# syntax=docker/dockerfile:1

FROM node:24-alpine AS deps
WORKDIR /app

COPY package.json package-lock.json ./
COPY packages/protocol-ts/package.json packages/protocol-ts/package.json
COPY packages/relay/package.json packages/relay/package.json
RUN npm ci

FROM deps AS build
COPY packages/protocol-ts/tsconfig.json packages/protocol-ts/tsconfig.json
COPY packages/protocol-ts/src packages/protocol-ts/src
COPY packages/relay/tsconfig.json packages/relay/tsconfig.json
COPY packages/relay/src packages/relay/src
RUN npm run build --workspaces --if-present
RUN npm prune --omit=dev

FROM node:24-alpine AS runtime
ENV NODE_ENV=production \
    NUDGE_RELAY_HOSTED_MODE=1 \
    NUDGE_RELAY_PORT=8787
WORKDIR /app

RUN addgroup -S nudge \
    && adduser -S -G nudge nudge \
    && mkdir -p /var/lib/nudge /var/log/nudge \
    && chown -R nudge:nudge /app /var/lib/nudge /var/log/nudge

COPY --from=build --chown=nudge:nudge /app/package.json /app/package-lock.json ./
COPY --from=build --chown=nudge:nudge /app/node_modules ./node_modules
COPY --from=build --chown=nudge:nudge /app/packages/protocol-ts/package.json ./packages/protocol-ts/package.json
COPY --from=build --chown=nudge:nudge /app/packages/protocol-ts/dist ./packages/protocol-ts/dist
COPY --from=build --chown=nudge:nudge /app/packages/relay/package.json ./packages/relay/package.json
COPY --from=build --chown=nudge:nudge /app/packages/relay/dist ./packages/relay/dist

USER nudge
EXPOSE 8787
CMD ["node", "packages/relay/dist/index.js"]
