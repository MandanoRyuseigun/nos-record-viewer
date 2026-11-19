@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-records.ps1"
if errorlevel 1 (
  echo.
  echo [ERROR] Failed to update records.js. Please send this message to whoever shared the viewer.
  pause
)
start "" "%~dp0viewer.html"
