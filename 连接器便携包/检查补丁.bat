@echo off
chcp 936 >nul
title DSH 连接器 - 检查补丁
echo DeepSeek 升级后，需要重新打补丁。这里会检查并补齐。
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\check-patch.ps1"
