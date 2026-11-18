@echo off
chcp 936 >nul
title DSH 连接器 - 卸载
echo ================================================
echo   卸载 DSH 连接器
echo.
echo   会清理：程序 / 插件 / 环境变量 / 自启 / 快捷方式
echo   不会动：会话、工作区、DeepSeek 本体
echo ================================================
echo.
pause
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\uninstall.ps1"
