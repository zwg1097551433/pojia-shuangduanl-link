@echo off
chcp 65001 >nul
set "PS=powershell.exe"
where pwsh >nul 2>nul && set "PS=pwsh.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-phone-web.ps1"
echo.
pause
