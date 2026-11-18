@echo off
chcp 936 >nul
title DSH 连接器 - 安装
echo ================================================
echo   DSH 连接器 - 自动安装
echo ================================================
echo.
echo   将会做这些事：
echo     1. 自动探测 DeepSeek 安装位置
echo     2. 自动探测本机局域网 IP
echo     3. 安装连接器程序到 %%USERPROFILE%%\.dsh\connector
echo     4. 给 DeepSeek 打一个小补丁（可回滚）
echo     5. 设置 3 个环境变量
echo     6. 安装 DSH 插件
echo     7. 配置开机自启 + 桌面快捷方式
echo.
echo   不会动：你的会话、工作区、其它插件
echo ================================================
echo.
pause
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1"
