@echo off
title TikScribe
cd /d "%~dp0"
echo.
echo  === TikScribe: transkrip dan rangkuman TikTok, AI jalan di GPU Anda ===
echo.
rem Pertama kali: unduh model AI (+-2,9 GB) ke folder "models". Berikutnya langsung lewat.
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\download-models.ps1"
if errorlevel 1 (
  echo.
  echo  Unduhan model belum selesai. Periksa internet lalu jalankan file ini lagi, unduhan akan dilanjutkan.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "tools\server.ps1"
pause
