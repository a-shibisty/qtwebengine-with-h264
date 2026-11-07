@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-qt.ps1" %*
echo.
pause
