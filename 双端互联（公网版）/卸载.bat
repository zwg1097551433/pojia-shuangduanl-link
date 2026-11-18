@echo off
cd /d "%~dp0"
echo === DSH Dual-Link : UNINSTALL (Public) ===
echo Tasks will be removed and services stopped. Desktop DSH is untouched.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Deploy.ps1" -Uninstall -Mode Public
echo.
pause
