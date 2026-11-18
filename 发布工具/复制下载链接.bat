@echo off
chcp 936 >nul
title 复制下载链接
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0复制下载链接.ps1"
