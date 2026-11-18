@echo off
chcp 936 >nul
title 重启 DeepSeek
echo 正在重启 DeepSeek（IP 变化后用它恢复）...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\restart.ps1"
