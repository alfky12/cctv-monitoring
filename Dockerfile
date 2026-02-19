FROM node:20-bookworm-slim

WORKDIR /app

# Runtime tools needed by CCTV pipeline (ffmpeg for transcode/recording)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ffmpeg \
        dumb-init \
        ca-certificates \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

COPY package*.json ./
RUN npm ci --omit=dev

COPY . .

RUN mkdir -p /app/recordings \
    && chmod +x /app/*.sh || true

ENV NODE_ENV=production
EXPOSE 3003

ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "index.js"]
