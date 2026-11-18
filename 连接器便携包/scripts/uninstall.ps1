# uninstall.ps1 — 卸载 DSH 连接器（清理程序/插件/环境变量/自启/快捷方式）
$ErrorActionPreference = 'Continue'
$HOME_DIR = Join-Path $env:USERPROFILE '.dsh'
$CONN = Join-Path $HOME_DIR 'connector'
$PLUGIN = Join-Path $HOME_DIR 'connector-plugin'
$PROF = Join-Path $HOME_DIR 'profiles\desktop'
$PJ = Join-Path $PROF 'package.json'

Write-Host "=== 卸载 DSH 连接器 ===" -ForegroundColor Cyan

# 1) 从 profile 移除插件（无 BOM + 自检）
if (Test-Path $PJ) {
  $bak = "$PJ.bak-uninstall-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
  Copy-Item $PJ $bak -Force
  try {
    $raw = [IO.File]::ReadAllText($PJ, (New-Object System.Text.UTF8Encoding $false))
    $j = $raw | ConvertFrom-Json
    $j.dsh.profile.bundles = @($j.dsh.profile.bundles | Where-Object { $_ -ne 'dsh-connector' })
    if ($j.dependencies.PSObject.Properties.Name -contains 'dsh-connector') {
      $j.dependencies.PSObject.Properties.Remove('dsh-connector')
    }
    [IO.File]::WriteAllText($PJ, ($j | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding $false))
    Write-Host "  已从 profile 移除插件" -ForegroundColor Green
  } catch {
    Copy-Item $bak $PJ -Force
    Write-Host "  移除失败，已回滚" -ForegroundColor Red
  }
}

# 2) 删目录
foreach ($d in @($CONN, $PLUGIN)) {
  if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue; Write-Host ("  已删除 " + $d) -ForegroundColor Green }
}
$link = Join-Path $PROF 'node_modules\dsh-connector'
if (Test-Path $link) {
  try { $i = Get-Item $link -Force; if ($i.LinkType) { $i.Delete() } else { Remove-Item $link -Recurse -Force } ; Write-Host "  已删除 node_modules 链接" -ForegroundColor Green } catch {}
}

# 3) 环境变量
foreach ($v in 'DSH_DESKTOP_PORT','DSH_DESKTOP_TRUSTED','DSH_DESKTOP_LAN') {
  [Environment]::SetEnvironmentVariable($v, $null, 'User')
  Write-Host ("  已清除环境变量 " + $v) -ForegroundColor Green
}

# 4) 自启 + 快捷方式
$startup = [Environment]::GetFolderPath('Startup')
foreach ($n in '启动DSH连接器服务.vbs','启动DSH端口转发.vbs') {
  $p = Join-Path $startup $n
  if (Test-Path $p) { Remove-Item $p -Force; Write-Host ("  已删除自启 " + $n) -ForegroundColor Green }
}
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'DSH连接器.lnk'
if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "  已删除桌面快捷方式" -ForegroundColor Green }

# 5) 还原 desktop-host 补丁（如果有安装时备份）
$EXE = ''
foreach ($p in (Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue)) { try { if ($p.Path) { $EXE = $p.Path; break } } catch {} }
if ($EXE) {
  $hostFile = Join-Path (Split-Path $EXE -Parent) 'resources\app\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\index.js'
  $bakHost = Get-ChildItem (Split-Path $hostFile -Parent) -Filter 'index.js.bak-installer-*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($bakHost) {
    Copy-Item $bakHost.FullName $hostFile -Force
    Write-Host ("  已还原 desktop-host 原始文件（来自 " + $bakHost.Name + "）") -ForegroundColor Green
  }
}

Write-Host ""
Write-Host "卸载完成。请重启 DeepSeek 使其生效。" -ForegroundColor Cyan
Read-Host "回车退出"