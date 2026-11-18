@echo off
chcp 936 >nul
set "DSH_EXE=F:\deepseek\DeepSeek Harness.exe"
if not exist "%DSH_EXE%" set "DSH_EXE=F:\deepseek\DeepSeek Harness.exe"
set ELECTRON_RUN_AS_NODE=1
echo 正在读取最近会话...
echo.
"%DSH_EXE%" "%~dp0session-digest.mjs" 3 8
echo.
pause
