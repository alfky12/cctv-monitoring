@echo off
setlocal enabledelayedexpansion

:: Log file mapping
set LOG_FILE=%~dp0smart_transcode.log
echo [%DATE% %TIME%] --- Processing: %MTX_PATH% --- >> "%LOG_FILE%"

:: Only process streams ending in _input
echo %MTX_PATH% | findstr "_input" >nul
if errorlevel 1 (
    exit /b 0
)

:: Read config values
set CONFIG_FILE=%~dp0config.json
set RTSP_PORT=8555
set VIDEO_BITRATE=800k
set MAX_VIDEO_BITRATE=900k
set VIDEO_FPS=12
set AUDIO_ENABLED=true
set AUDIO_BITRATE=64k
set RESOLUTION=1280:720

:: Try to read RTSP port from config
for /f "tokens=2 delims=:" %%a in ('findstr "rtsp_port" "%CONFIG_FILE%" 2^>nul') do (
    set "val=%%a"
    set "val=!val: =!"
    set "val=!val:,=!"
    set "val=!val:"=!"
    if not "!val!"=="" set RTSP_PORT=!val!
)

:: Internal URLs
set SOURCE_RTSP=rtsp://127.0.0.1:%RTSP_PORT%/%MTX_PATH%
set TARGET_NAME=%MTX_PATH:_input=%
set TARGET_RTSP=rtsp://127.0.0.1:%RTSP_PORT%/%TARGET_NAME%

:: Wait for MediaMTX to stabilize the source
timeout /t 2 /nobreak >nul

:: Detect Codec
echo [%DATE% %TIME%] Probing codec for %MTX_PATH%... >> "%LOG_FILE%"
ffprobe -v error -rtsp_transport tcp -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 -timeout 3000000 "%SOURCE_RTSP%" > "%TEMP%\codec_probe.txt" 2>nul
set /p VIDEO_CODEC=<"%TEMP%\codec_probe.txt"
del "%TEMP%\codec_probe.txt" 2>nul

echo [%DATE% %TIME%] Detected Codec: '%VIDEO_CODEC%' >> "%LOG_FILE%"

:: Smart codec selection: copy H.264, transcode others
if /i "%VIDEO_CODEC%"=="h264" (
    echo [%DATE% %TIME%] H.264 detected, using COPY mode ^(no transcoding^) >> "%LOG_FILE%"
    ffmpeg -hide_banner -loglevel error -rtsp_transport tcp -i "%SOURCE_RTSP%" -c:v copy -c:a copy -f rtsp -rtsp_transport tcp "%TARGET_RTSP%" >> "%LOG_FILE%" 2>&1
) else (
    echo [%DATE% %TIME%] Non-H.264 detected ^(%VIDEO_CODEC%^), transcoding to H.264 >> "%LOG_FILE%"
    ffmpeg -hide_banner -loglevel error -rtsp_transport tcp -i "%SOURCE_RTSP%" -c:v libx264 -preset ultrafast -tune zerolatency -profile:v main -level 4.0 -pix_fmt yuv420p -b:v %VIDEO_BITRATE% -maxrate %MAX_VIDEO_BITRATE% -bufsize 1600k -r %VIDEO_FPS% -g 24 -c:a aac -ac 1 -ar 44100 -b:a %AUDIO_BITRATE% -f rtsp -rtsp_transport tcp "%TARGET_RTSP%" >> "%LOG_FILE%" 2>&1
)
