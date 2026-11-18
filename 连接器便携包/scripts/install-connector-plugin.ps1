# install-connector-plugin.ps1 — 安全安装 DSH 连接器插件
# 原则：改任何 JSON 前先备份；写完立刻用 Node 的 JSON.parse 自检；失败自动回滚。
# 绝不使用 Set-Content -Encoding UTF8（PS 5.1 会写 BOM，DSH 的 JSON.parse 会崩）。
$ErrorActionPreference = 'Stop'

$EXE   = 'F:\deepseek\DeepSeek Harness.exe'
$PNPM  = 'F:\deepseek\resources\runtime\primary-runtime\dependencies\pnpm\bin\pnpm.cjs'
$PROF  = Join-Path $env:USERPROFILE '.dsh\profiles\desktop'
$PJ    = Join-Path $PROF 'package.json'
$PLUGIN = Join-Path $env:USERPROFILE '.dsh\connector-plugin'
$CHECK = Join-Path $PLUGIN 'check-json.mjs'
$STAMP = Get-Date -Format 'yyyyMMdd-HHmmss'
$BAK   = "$PJ.bak-connector-$STAMP"
$LOG   = New-Object System.Collections.ArrayList

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c; [void]$LOG.Add($m) }
function Fail($m) { Say ("[STOP] " + $m) 'Red'; Finish 1 }
function Finish($code) {
  $logPath = Join-Path $PLUGIN 'install.log'
  try { [IO.File]::WriteAllText($logPath, ($LOG -join "`r`n"), (New-Object System.Text.UTF8Encoding $false)) } catch {}
  exit $code
}

Say "=== 安装 DSH 连接器插件 ===" 'Cyan'
Say ("时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# ---------- 0. 前置检查 ----------
if (-not (Test-Path $EXE))  { Fail "找不到 DSH: $EXE" }
if (-not (Test-Path $PNPM)) { Fail "找不到 pnpm: $PNPM" }
if (-not (Test-Path $PJ))   { Fail "找不到 profile: $PJ" }
if (-not (Test-Path $PLUGIN)) { Fail "找不到插件目录: $PLUGIN" }

# ---------- 1. 备份 ----------
Copy-Item $PJ $BAK -Force
Say ("备份: " + $BAK) 'DarkGray'

# ---------- 2. pnpm add link: ----------
$env:ELECTRON_RUN_AS_NODE = '1'
$o = Join-Path $env:TEMP 'connector-add.out.txt'
$e = Join-Path $env:TEMP 'connector-add.err.txt'
Say "执行 pnpm add link:…"
$p = Start-Process -FilePath $EXE -ArgumentList @($PNPM, 'add', "link:$PLUGIN") `
      -WorkingDirectory $PROF -Wait -PassThru `
      -RedirectStandardOutput $o -RedirectStandardError $e -WindowStyle Hidden
if ($p.ExitCode -ne 0) {
  Say ("pnpm add 失败 (exit " + $p.ExitCode + ")") 'Red'
  Get-Content $e -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object { Say ("  " + $_) 'Red' }
  Copy-Item $BAK $PJ -Force
  Say "已回滚 package.json" 'Yellow'
  Finish 1
}
Say "pnpm add 成功" 'Green'

# ---------- 3. 写 bundles（无 BOM） ----------
try {
  $raw = [IO.File]::ReadAllText($PJ, (New-Object System.Text.UTF8Encoding $false))
  $j = $raw | ConvertFrom-Json
  $bundles = @($j.dsh.profile.bundles)
  if ($bundles -notcontains 'dsh-connector') {
    $j.dsh.profile.bundles = @($bundles + 'dsh-connector')
  }
  $json = $j | ConvertTo-Json -Depth 12
  [IO.File]::WriteAllText($PJ, $json, (New-Object System.Text.UTF8Encoding $false))
  Say "bundles 已写入（无 BOM）" 'Green'
} catch {
  Say ("写 bundles 失败: " + $_.Exception.Message) 'Red'
  Copy-Item $BAK $PJ -Force
  Say "已回滚" 'Yellow'
  Finish 1
}

# ---------- 4. 自检（与 DSH 同标准） ----------
Say "自检 package.json…"
$p2 = Start-Process -FilePath $EXE -ArgumentList @($CHECK, $PJ) -Wait -PassThru `
        -RedirectStandardOutput $o -RedirectStandardError $e -WindowStyle Hidden
$checkOut = Get-Content $o -ErrorAction SilentlyContinue
$checkOut | ForEach-Object { Say ("  " + $_) }
if ($p2.ExitCode -ne 0) {
  Say "自检未通过 → 回滚" 'Red'
  Copy-Item $BAK $PJ -Force
  Say "已回滚 package.json（App 可正常启动）" 'Yellow'
  Finish 1
}

# ---------- 5. 完成 ----------
Say ""
Say "=== 安装完成 ===" 'Green'
Say ("bundles: " + ((Get-Content $PJ -Raw -Encoding UTF8 | ConvertFrom-Json).dsh.profile.bundles -join ', '))
Say ""
Say "请完全退出 DeepSeek（托盘右键退出）再重新打开，左侧栏会出现「连接器」。"
Say ("如出问题，双击桌面「撤销连接器插件.bat」；备份在 " + $BAK)
Finish 0
