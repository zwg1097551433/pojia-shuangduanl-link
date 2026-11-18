# 一键发布.ps1 — 提交代码 → 推送 → 打 Release → 上传便携包 → 复制下载链接
$ErrorActionPreference = 'Continue'
$OWNER = 'zwg1097551433'
$REPO  = 'pojia-shuangduanl-link'
$ROOT  = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $ROOT 'README.md'))) { $ROOT = 'E:\deepseek工作区\破甲后双端互联' }

function Say($m, $c='Gray') { Write-Host $m -ForegroundColor $c }

Say "================================================" Cyan
Say "  一键发布" Cyan
Say "================================================" Cyan
Say ""

# ---------- 1. 检查并提交 ----------
Push-Location $ROOT
$changed = (git status --porcelain) 2>$null
if ($changed) {
  Say ("检测到 " + ($changed | Measure-Object).Count + " 个改动：") Yellow
  $changed | Select-Object -First 10 | ForEach-Object { Say ("  " + $_) DarkGray }
  Say ""
  $msg = Read-Host "输入本次更新说明（直接回车用默认）"
  if ([string]::IsNullOrWhiteSpace($msg)) { $msg = "更新 " + (Get-Date -Format 'yyyy-MM-dd HH:mm') }
  git add -A 2>&1 | Out-Null
  git commit -m $msg 2>&1 | Select-Object -First 2 | ForEach-Object { Say ("  " + $_) }
  $env:GIT_TERMINAL_PROMPT='0'
  $push = git push 2>&1
  $env:GIT_TERMINAL_PROMPT='1'
  if ($LASTEXITCODE -ne 0) { Say "  推送失败：" Red; $push | ForEach-Object { Say ("  " + $_) Red }; Read-Host "回车退出"; exit 1 }
  Say "  代码已推送" Green
} else {
  Say "  没有代码改动，直接发布新版本" DarkGray
}
Pop-Location
Say ""

# ---------- 2. 重新打包便携包 ----------
$pkgSrc = Join-Path $ROOT '连接器便携包'
$zipOut = Join-Path $env:TEMP 'dsh-connector-portable.zip'
if (Test-Path $pkgSrc) {
  Say "重新打包便携包…"
  if (Test-Path $zipOut) { Remove-Item $zipOut -Force }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::CreateFromDirectory($pkgSrc, $zipOut, [System.IO.Compression.CompressionLevel]::Optimal, $true)
  Say ("  " + [int]((Get-Item $zipOut).Length/1KB) + " KB") Green
} else {
  Say "  [跳过] 找不到 连接器便携包 目录" Yellow
}

# ---------- 3. 取 token ----------
$inp = "protocol=https`nhost=github.com`n`n"
$cred = $inp | git credential fill 2>&1
$TOKEN = (($cred -split "`n") | Where-Object { $_ -match '^password=' }) -replace '^password=',''
if (-not $TOKEN) { Say "取不到 GitHub 凭据，请先在有 GitHub 凭据的环境里运行" Red; Read-Host "回车退出"; exit 1 }
$H = @{ Authorization = "token $TOKEN"; 'User-Agent'='dsh'; 'Accept'='application/vnd.github+json' }
Say ""

# ---------- 4. 计算新版本号 ----------
Say "读取现有版本…"
$newTag = 'v1.0.0'
try {
  $rels = Invoke-RestMethod -Uri "https://api.github.com/repos/$OWNER/$REPO/releases" -Headers $H -TimeoutSec 20
  if ($rels -and $rels.Count -gt 0) {
    $latest = ($rels | Sort-Object published_at -Descending)[0].tag_name
    Say ("  当前最新: " + $latest) DarkGray
    if ($latest -match '^v(\d+)\.(\d+)\.(\d+)$') {
      $newTag = "v{0}.{1}.{2}" -f $matches[1], $matches[2], ([int]$matches[3] + 1)
    }
  }
} catch { Say "  读取版本失败，使用默认 v1.0.0" Yellow }
Say ("  新版本号: " + $newTag) Green
$confirm = Read-Host "确认发布 $newTag ？(Y/N)"
if ($confirm -notmatch '^[Yy]') { Say "已取消"; Read-Host "回车退出"; exit 0 }

# ---------- 5. 创建 Release ----------
Say ""
Say "创建 Release $newTag …"
$body = @{
  tag_name = $newTag
  name = "破甲后双端互联 $newTag"
  body = "自动发布 $newTag`n`n下载：dsh-connector-portable.zip`n`n更新说明见提交记录。"
  draft = $false
  prerelease = $false
} | ConvertTo-Json
$rel = $null
try {
  $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$OWNER/$REPO/releases" -Method Post -Headers $H -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 40
  Say ("  OK: " + $rel.html_url) Green
} catch {
  Say ("  创建失败: " + $_.Exception.Message) Red
  Read-Host "回车退出"
  exit 1
}

# ---------- 6. 上传附件 ----------
$dlUrl = ''
if (Test-Path $zipOut) {
  Say "上传便携包…"
  $up = "https://uploads.github.com/repos/$OWNER/$REPO/releases/$($rel.id)/assets?name=dsh-connector-portable.zip"
  $tmp = Join-Path $env:TEMP 'asset.json'
  $curl = 'C:\Windows\System32\curl.exe'
  & $curl -s -X POST -H "Authorization: token $TOKEN" -H "User-Agent: dsh" -H "Content-Type: application/zip" --data-binary "@$zipOut" -o $tmp -w "%{http_code}" $up | Out-Null
  if (Test-Path $tmp) {
    $a = Get-Content $tmp -Raw | ConvertFrom-Json
    if ($a.browser_download_url) {
      $dlUrl = $a.browser_download_url
      Say ("  OK: " + [int]($a.size/1KB) + " KB") Green
    }
  }
}
if (-not $dlUrl) { $dlUrl = "https://github.com/$OWNER/$REPO/releases/latest" }

# ---------- 7. 复制链接 ----------
try { Set-Clipboard -Value $dlUrl } catch {}
Say ""
Say "================================================" Green
Say "  发布完成" Green
Say "================================================" Green
Say ""
Say "  下载直链（已复制到剪贴板）：" White
Say ("  " + $dlUrl) Cyan
Say ""
Say "  Release 页面：" White
Say ("  " + $rel.html_url) Cyan
Say ""
Say "  仓库首页：" White
Say ("  https://github.com/$OWNER/$REPO") Cyan
Say ""
Read-Host "回车退出"