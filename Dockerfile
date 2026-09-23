FROM node:20-bookworm-slim
ENV NODE_ENV=production \
    TZ=Asia/Jayapura
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg curl ca-certificates sqlite3 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY . .
RUN mkdir -p /app/recordings /app/data
EXPOSE 3003
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS http://127.0.0.1:3003/ || exit 1
CMD ["node", "index.js"]
