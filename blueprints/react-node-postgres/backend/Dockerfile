# syntax=docker/dockerfile:1
FROM node:22-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY . .
RUN npx prisma generate
RUN npx tsc || true

FROM node:22-alpine
WORKDIR /app
COPY package*.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev
COPY --from=builder /app/node_modules/.prisma ./node_modules/.prisma
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/src ./src

# Use tsx to run TypeScript directly as fallback
RUN npm install -g tsx

EXPOSE 3001

# Run migrations then start
CMD ["sh", "-c", "npx prisma db push --accept-data-loss && npx tsx prisma/seed.ts 2>/dev/null; npx tsx src/index.ts"]
