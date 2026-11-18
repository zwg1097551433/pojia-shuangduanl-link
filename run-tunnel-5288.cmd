@echo off
"E:\deepseek工作区\phone-armor\bin\cloudflared.exe" tunnel --url http://192.168.1.2:5288 --no-autoupdate --logfile "E:\deepseek工作区\phone-armor\tunnel.log" --loglevel info
