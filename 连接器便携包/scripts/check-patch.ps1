# check-patch.ps1 — DeepSeek 升级后检查并重新应用 desktop-host 补丁
$ErrorActionPreference = 'Continue'
Write-Host "=== 检查 desktop-host 补丁 ===" -ForegroundColor Cyan

$EXE = ''
$procs = Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue
foreach ($p in $procs) { try { if ($p.Path -and (Test-Path $p.Path)) { $EXE = $p.Path; break } } catch {} }
if (-not $EXE) {
  foreach ($c in @('F:\deepseek\DeepSeek Harness.exe', (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'))) {
    if (Test-Path $c) { $EXE = $c; break }
  }
}
if (-not $EXE) { Write-Host "找不到 DeepSeek" -ForegroundColor Red; Read-Host "回车退出"; exit 1 }
Write-Host ("DeepSeek: " + $EXE)

$HOST_FILE = Join-Path (Split-Path $EXE -Parent) 'resources\app\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\index.js'
if (-not (Test-Path $HOST_FILE)) { Write-Host "找不到 desktop-host" -ForegroundColor Red; Read-Host "回车退出"; exit 1 }

$text = [IO.File]::ReadAllText($HOST_FILE, (New-Object System.Text.UTF8Encoding $false))
$c1 = ($text -match 'DSH_DESKTOP_PORT'); $c2 = ($text -match 'DSH_DESKTOP_TRUSTED'); $c3 = ($text -match 'desktop-web-url')
Write-Host ("  端口可配置     : " + $(if ($c1) { "OK" } else { "缺失" })) -ForegroundColor $(if ($c1) { 'Green' } else { 'Red' })
Write-Host ("  trusted-host   : " + $(if ($c2) { "OK" } else { "缺失" })) -ForegroundColor $(if ($c2) { 'Green' } else { 'Red' })
Write-Host ("  URL 落盘       : " + $(if ($c3) { "OK" } else { "缺失" })) -ForegroundColor $(if ($c3) { 'Green' } else { 'Red' })

if ($c1 -and $c2 -and $c3) {
  Write-Host "补丁完整，无需处理。" -ForegroundColor Green
  Read-Host "回车退出"; exit 0
}

Write-Host ""
$ans = Read-Host "补丁缺失，现在重新应用？(Y/N)"
if ($ans -notmatch '^[Yy]') { exit 0 }

# 复用安装脚本里的补丁逻辑
$installer = Join-Path $PSScriptRoot 'install.ps1'
if (Test-Path $installer) {
  Write-Host "调用 install.ps1 重新打补丁（会跳过已存在的部分）…" -ForegroundColor Yellow
  & powershell -NoProfile -ExecutionPolicy Bypass -File $installer
} else {
  Write-Host "缺少 install.ps1，无法自动修复" -ForegroundColor Red
  Read-Host "回车退出"
}