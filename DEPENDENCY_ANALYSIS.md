# Dependency Analysis - cctv-monitoring

## 1) Runtime utama (Node.js app)
Berdasarkan `package.json`, aplikasi menggunakan stack Express + EJS + SQLite dan integrasi notifikasi/streaming.

### Core web
- `express`, `body-parser`, `cors`, `method-override`, `express-session`
- `ejs` untuk server-side rendering view dashboard/admin.

### Data & auth
- `sqlite3` untuk database lokal (`cameras.db`)
- `bcrypt` untuk hash password

### CCTV / Integrasi
- `onvif` untuk discovery / kontrol perangkat kamera yang mendukung ONVIF
- `node-telegram-bot-api` untuk notifikasi Telegram
- `web-push` untuk push notification browser
- `sharp` untuk manipulasi image/icon processing (native module)

## 2) External binary dependency
Aplikasi juga membutuhkan binary sistem:
- `ffmpeg` → dipakai transcode, recording, dan pipeline stream.
- `mediamtx` → gateway RTSP/HLS/API untuk stream distribution.

## 3) Konfigurasi penting dependency
Dependency runtime dikendalikan oleh `config.json`:
- Port web app (`server.port`) default: `3003`
- MediaMTX host/API/RTSP/HLS (`mediamtx.*`) default: `127.0.0.1:9123/8555/8856`

Untuk deployment Docker, override dapat dilakukan via ENV:
- `SERVER_PORT`
- `MEDIAMTX_HOST`
- `MEDIAMTX_API_PORT`
- `MEDIAMTX_RTSP_PORT`
- `MEDIAMTX_HLS_PORT`
- `MEDIAMTX_PUBLIC_HLS_URL`

## 4) Dockerization strategy
Agar stabil di server rumahan/NAS (termasuk CasaOS):
- Node app dijalankan pada image `node:20-bookworm-slim` + `ffmpeg`.
- MediaMTX dijalankan sebagai service terpisah (`bluenviron/mediamtx`).
- Data persisten dimount: `config.json`, `cameras.db`, `recordings/`, `mediamtx.yml`.

## 5) File hasil implementasi
- `Dockerfile` → image app production-ready.
- `docker-compose.yml` → stack lokal (build source + mediamtx).
- `docker-compose.casaos.yml` → compose siap import CasaOS dengan metadata `x-casaos`.
