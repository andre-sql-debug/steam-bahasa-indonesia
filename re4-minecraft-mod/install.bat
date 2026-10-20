@echo off
rem Double-click to install or update the RE4 Minecraft mod (see install.ps1)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
pause
