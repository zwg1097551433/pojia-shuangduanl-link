# remove-connector-plugin.ps1 — 安全撤销 DSH 连接器插件
# 与安装脚本同一标准：备份 → 改 JSON（无 BOM）→ 自检 → 失败自动回滚 → 重启 App
# 不使用 Set-Content -Encoding UTF8（PS 5.1 会写 BOM，DSH 的 JSON.parse 会崩）
$ErrorActionPreference = 'Stop'

$EXE   = 'F:\deepseek\DeepSeek Harness.exe'
$PROF  = Join-Path $env:USERPROFILE '.dsh\profiles\desktop'
$PJ    = Join-Path $PROF 'package.json'
$LINK  = Join-Path $PROF 'node_modules\dsh-connector'
$PLUGIN = Join-Path $env:USERPROFILE '.dsh\connector-plugin'
$CHECK = Join-Path $PLUGIN 'check-json.mjs'
$STAMP = Get-Date -Format 'yyyyMMdd-HHmmss'
$BAK   = "$PJ.bak-remove-$STAMP"
$LOG   = New-Object System.Collections.ArrayList

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c; [void]$LOG.Add($m) }
function Fail($m) { Say ("[STOP] " + $m) 'Red'; Finish 1 }
function Finish($code) {
  $logPath = Join-Path $PLUGIN 'remove.log'
  try { [IO.File]::WriteAllText($logPath, ($LOG -join "`r`n"), (New-Object System.Text.UTF8Encoding $false)) } catch {}
  exit $code
}

Say "=== 撤销 DSH 连接器插件 ===" 'Cyan'
Say ("时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

if (-not (Test-Path $PJ)) { Fail "找不到 $PJ" }

# ---------- 1. 备份 ----------
Copy-Item $PJ $BAK -Force
Say ("备份: " + $BAK) 'DarkGray'

# ---------- 2. 改 JSON（无 BOM） ----------
try {
  $raw = [IO.File]::ReadAllText($PJ, (New-Object System.Text.UTF8Encoding $false))
  $j = $raw | ConvertFrom-Json
  $bundles = @($j.dsh.profile.bundles) | Where-Object { $_ -ne 'dsh-connector' }
  $j.dsh.profile.bundles = @($bundles)
  if ($j.dependencies -and ($j.dependencies.PSObject.Properties.Name -contains 'dsh-connector')) {
    $j.dependencies.PSObject.Properties.Remove('dsh-connector')
  }
  $json = $j | ConvertTo-Json -Depth 12
  [IO.File]::WriteAllText($PJ, $json, (New-Object System.Text.UTF8Encoding $false))
  Say "已从 bundles / dependencies 移除 dsh-connector（无 BOM）" 'Green'
} catch {
  Say ("改 package.json 失败: " + $_.Exception.Message) 'Red'
  Copy-Item $BAK $PJ -Force
  Say "已回滚" 'Yellow'
  Finish 1
}

# ---------- 3. 自检 ----------
if (Test-Path $CHECK) {
  $env:ELECTRON_RUN_AS_NODE = '1'
  $o = Join-Path $env:TEMP 'connector-rm.out.txt'
  $p = Start-Process -FilePath $EXE -ArgumentList @($CHECK, $PJ) -Wait -PassThru `
        -RedirectStandardOutput $o -RedirectStandardError (Join-Path $env:TEMP 'connector-rm.err.txt') -WindowStyle Hidden
  $out = Get-Content $o -ErrorAction SilentlyContinue
  $out | ForEach-Object { Say ("  " + $_) }
  if ($p.ExitCode -ne 0) {
    Say "自检未通过 → 回滚" 'Red'
    Copy-Item $BAK $PJ -Force
    Say "已回滚" 'Yellow'
    Finish 1
  }
} else {
  Say "（校验器缺失，跳过自检）" 'Yellow'
}

# ---------- 4. 删 node_modules 链接 ----------
if (Test-Path $LINK) {
  try {
    $item = Get-Item $LINK -Force
    if ($item.LinkType) { $item.Delete() } else { Remove-Item $LINK -Recurse -Force }
    Say "已删除 node_modules\dsh-connector 链接" 'Green'
  } catch {
    Say ("删链接失败（不影响启动）: " + $_.Exception.Message) 'Yellow'
  }
} else {
  Say "链接已不存在" 'DarkGray'
}

# ---------- 5. 重启 App ----------
Say "重启 DeepSeek Harness…"
Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue | ForEach-Object {
  try { Stop-Process -Id $_.Id -Force } catch {}
}
Start-Sleep -Seconds 2
if (Test-Path $EXE) { Start-Process $EXE; Say "已重启" 'Green' }

Say ""
Say "=== 撤销完成 ===" 'Green'
Say ("bundles: " + ((Get-Content $PJ -Raw -Encoding UTF8 | ConvertFrom-Json).dsh.profile.bundles -join ', '))
Finish 0
