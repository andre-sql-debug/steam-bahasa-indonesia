@echo off
rem Double-click to remove the RE4 Minecraft mod (see uninstall.ps1)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1"
echo.
pause
