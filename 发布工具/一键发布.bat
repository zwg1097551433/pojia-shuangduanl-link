@echo off
chcp 936 >nul
title 一键发布
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0一键发布.ps1"
