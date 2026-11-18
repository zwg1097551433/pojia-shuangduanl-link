@echo off
cd /d "%~dp0"
echo.
echo === DSH Dual-Link : DEPLOY (Public) ===
echo An elevated PowerShell window will open.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Deploy.ps1" -Mode Public
echo.
pause
