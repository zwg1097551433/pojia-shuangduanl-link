@echo off
cd /d "%~dp0"
echo === DSH Dual-Link : REFRESH LINK (Lan) ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Deploy.ps1" -RefreshLink -Mode Lan
echo.
pause
