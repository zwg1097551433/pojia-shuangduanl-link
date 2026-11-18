@echo off
rem ============================================================================
rem  DSH Connector - start local service on 127.0.0.1:14930
rem  Portable: %~dp0 for script dir, %USERPROFILE% for log, dsh-exe.txt for the app path.
rem ============================================================================
setlocal
set "ELECTRON_RUN_AS_NODE=1"
set "DIR=%~dp0"
set "EXE="

if exist "%DIR%dsh-exe.txt" set /p EXE=<"%DIR%dsh-exe.txt"
if not defined EXE if exist "F:\deepseek\DeepSeek Harness.exe" set "EXE=F:\deepseek\DeepSeek Harness.exe"
if not defined EXE if exist "%LOCALAPPDATA%\Programs\DeepSeek Harness\DeepSeek Harness.exe" set "EXE=%LOCALAPPDATA%\Programs\DeepSeek Harness\DeepSeek Harness.exe"
if not defined EXE if exist "%LOCALAPPDATA%\DeepSeek Harness\DeepSeek Harness.exe" set "EXE=%LOCALAPPDATA%\DeepSeek Harness\DeepSeek Harness.exe"
if not defined EXE if exist "C:\Program Files\DeepSeek Harness\DeepSeek Harness.exe" set "EXE=C:\Program Files\DeepSeek Harness\DeepSeek Harness.exe"

if not defined EXE (
  echo [connector] DeepSeek Harness.exe not found. Write its full path into "%DIR%dsh-exe.txt" and retry.>> "%USERPROFILE%\.dsh\connector\server.log"
  exit /b 2
)

"%EXE%" "%DIR%server.mjs" > "%USERPROFILE%\.dsh\connector\server.log" 2>&1
