# sync-repo.ps1 — 把「线上正在跑的文件」同步进本仓库（含脱敏）并推送
#
# 为什么要这个：仓库里的 连接器便携包/ 是给人下载的副本，真正生效的是
#   %USERPROFILE%\.dsh\connector\*、%USERPROFILE%\.dsh\connector-plugin\*
# 改完代码直接跑这个脚本，别手工拷贝（容易漏文件、也容易把 token 带上去）。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\sync-repo.ps1 -Message "fix: 说明改了什么"
#   powershell -ExecutionPolicy Bypass -File tools\sync-repo.ps1 -NoPush      # 只提交不推
param(
  [string]$Message = 'sync: 同步线上文件',
  [switch]$NoPush,
  [string]$WorkDir = 'E:\deepseek工作区\phone-armor'
)

$ErrorActionPreference = 'Stop'
$Repo    = Split-Path $PSScriptRoot -Parent
$Dsh     = Join-Path $env:USERPROFILE '.dsh'
$ConnSrc = Join-Path $Dsh 'connector'
$PlugSrc = Join-Path $Dsh 'connector-plugin'
$Pkg     = Join-Path $Repo '连接器便携包'
$ConnDst = Join-Path $Pkg 'files\connector'
$PlugDst = Join-Path $Pkg 'files\plugin'
$ScrDst  = Join-Path $Pkg 'scripts'

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

Say '=== 1/4 同步连接器程序 ===' 'Cyan'
foreach ($f in @('server.mjs', 'DSH连接器.hta', 'start-server.cmd', 'app.ico')) {
  $s = Join-Path $ConnSrc $f
  if (Test-Path $s) { Copy-Item $s $ConnDst -Force; Say ("  + " + $f) }
  else { Say ("  ! 缺 " + $f) 'Yellow' }
}
foreach ($f in @('dsh-port-forward.mjs', 'dsh-rewrite-proxy.mjs')) {
  $s = Join-Path $Dsh $f
  if (Test-Path $s) { Copy-Item $s $ConnDst -Force; Say ("  + " + $f) }
  else { Say ("  ! 缺 " + $f) 'Yellow' }
}

Say '=== 2/4 同步插件源码 ===' 'Cyan'
foreach ($f in @('client.js', 'package.json', 'cordis.patch.yml', 'check-json.mjs')) {
  $s = Join-Path $PlugSrc $f
  if (Test-Path $s) { Copy-Item $s $PlugDst -Force; Say ("  + " + $f) }
}
$lib = Join-Path $PlugSrc 'lib\index.js'
if (Test-Path $lib) {
  New-Item -ItemType Directory -Force -Path (Join-Path $PlugDst 'lib') | Out-Null
  Copy-Item $lib (Join-Path $PlugDst 'lib\index.js') -Force
  Say '  + lib\index.js'
}
foreach ($f in @('install-connector-plugin.ps1', 'remove-connector-plugin.ps1')) {
  $s = Join-Path $PlugSrc $f
  if (Test-Path $s) { Copy-Item $s $ScrDst -Force; Say ("  + " + $f) }
}

Say '=== 3/4 同步文档并脱敏 ===' 'Cyan'
if (Test-Path $WorkDir) {
  Get-ChildItem $WorkDir -File -Filter '*.md' | Where-Object { $_.Name -notlike '会话记录-*' } | ForEach-Object {
    Copy-Item $_.FullName $Repo -Force
    Say ("  + " + $_.Name)
  }
}

# 脱敏：真实访问 token / 当前隧道域名 / 本机用户目录，一个都不许进仓库
$token = ''
try {
  $u = Get-Content (Join-Path $Dsh 'desktop-web-url.txt') -Raw -ErrorAction SilentlyContinue
  $m = [regex]::Match($u, 'token=([A-Za-z0-9_\-]+)')
  if ($m.Success) { $token = $m.Groups[1].Value }
} catch {}
$domain = ''
try {
  $p = Get-Content (Join-Path $Dsh 'desktop-public-url.txt') -Raw -ErrorAction SilentlyContinue
  $m = [regex]::Match($p, 'https://([a-z0-9\-]+\.trycloudflare\.com)')
  if ($m.Success) { $domain = $m.Groups[1].Value }
} catch {}

$textExt = @('.md', '.txt', '.ps1', '.sh', '.bat', '.cmd', '.mjs', '.js', '.yml', '.json', '.hta')
$fixed = 0
Get-ChildItem $Repo -Recurse -File | Where-Object { $textExt -contains $_.Extension -and $_.FullName -notmatch '\\\.git\\' } | ForEach-Object {
  $t = [IO.File]::ReadAllText($_.FullName)
  $o = $t
  if ($token)  { $t = $t.Replace($token, '<TOKEN>') }
  if ($domain) { $t = $t.Replace($domain, '<随机域名>.trycloudflare.com') }
  $t = $t.Replace($env:USERPROFILE, '%USERPROFILE%')
  if ($t -ne $o) { [IO.File]::WriteAllText($_.FullName, $t, (New-Object System.Text.UTF8Encoding $false)); $fixed++ }
}
Say ("  脱敏处理文件数: " + $fixed) 'Green'

Say '=== 4/4 提交并推送 ===' 'Cyan'
Push-Location $Repo
try {
  git add -A
  $st = git status --short
  if (-not $st) { Say '  没有变更，跳过' 'Yellow'; return }
  Say ($st -join "`n")
  git commit -m $Message | Out-Null
  Say '  已提交' 'Green'
  if (-not $NoPush) {
    $env:GIT_TERMINAL_PROMPT = '0'
    $out = git push 2>&1
    Remove-Item Env:\GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0) { Say '  推送失败：' 'Red'; $out | ForEach-Object { Say ("  " + $_) 'Red' }; exit 1 }
    Say '  已推送' 'Green'
  } else { Say '  -NoPush：只提交，未推送' 'Yellow' }
} finally { Pop-Location }
