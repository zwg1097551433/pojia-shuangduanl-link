@echo off
chcp 65001 >nul
set "PS=powershell.exe"
where pwsh >nul 2>nul && set "PS=pwsh.exe"
echo [1/2] local web on LAN...
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-phone-web.ps1"
echo.
echo [2/2] public tunnel (phone on 4G / any network)...
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-remote-tunnel.ps1"
echo.
pause
