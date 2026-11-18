# 复制下载链接.ps1 — 取最新 Release 的下载直链，复制到剪贴板并可打开页面
$ErrorActionPreference = 'Continue'
$OWNER = 'zwg1097551433'
$REPO  = 'pojia-shuangduanl-link'

$inp = "protocol=https`nhost=github.com`n`n"
$cred = $inp | git credential fill 2>&1
$TOKEN = (($cred -split "`n") | Where-Object { $_ -match '^password=' }) -replace '^password=',''
$H = @{ Authorization = "token $TOKEN"; 'User-Agent'='dsh'; 'Accept'='application/vnd.github+json' }

$dl = ''; $page = ''
try {
  $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$OWNER/$REPO/releases/latest" -Headers $H -TimeoutSec 20
  $page = $rel.html_url
  $asset = $rel.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
  if ($asset) { $dl = $asset.browser_download_url }
} catch {}

if (-not $dl) {
  $dl = "https://github.com/$OWNER/$REPO/releases/latest"
  Write-Host "未取到附件直链，使用 Release 页面地址" -ForegroundColor Yellow
}

Set-Clipboard -Value $dl
Write-Host ""
Write-Host "下载链接（已复制到剪贴板）：" -ForegroundColor Green
Write-Host $dl -ForegroundColor Cyan
if ($page) {
  Write-Host ""
  Write-Host "Release 页面：" -ForegroundColor Gray
  Write-Host $page -ForegroundColor DarkGray
}
Write-Host ""
$open = Read-Host "是否打开下载页？(Y/N)"
if ($open -match '^[Yy]') { Start-Process $dl }
Start-Sleep -Seconds 1