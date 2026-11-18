# restart.ps1 — 重启 DeepSeek（IP 变化或服务异常时用）
$ErrorActionPreference = 'Continue'
Write-Host "=== 重启 DeepSeek ===" -ForegroundColor Cyan

$EXE = ''
foreach ($p in (Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue)) {
  try { if ($p.Path -and (Test-Path $p.Path)) { $EXE = $p.Path; break } } catch {}
}
if (-not $EXE) {
  foreach ($c in @('F:\deepseek\DeepSeek Harness.exe', (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'))) {
    if (Test-Path $c) { $EXE = $c; break }
  }
}
if (-not $EXE) { Write-Host "找不到 DeepSeek" -ForegroundColor Red; Read-Host "回车退出"; exit 1 }

Write-Host "结束现有进程…"
Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue | ForEach-Object { try { Stop-Process -Id $_.Id -Force } catch {} }
Start-Sleep -Seconds 2

Write-Host "启动…" 
# 关键：清除 ELECTRON_RUN_AS_NODE，否则 App 会以 Node 模式启动、没有窗口
$env:ELECTRON_RUN_AS_NODE = $null
Remove-Item Env:\ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
Start-Process -FilePath $EXE

Write-Host "已启动。等窗口出现后，左侧栏点「连接器」即可。" -ForegroundColor Green
Start-Sleep -Seconds 2
Read-Host "回车退出"