# install.ps1 — DSH 连接器 自适应安装
# 目标：在任何一台已破甲的 Windows 上，双击「安装.bat」即可完成全部部署。
# 原则：
#   1) 改任何 JSON 前先备份，写完用 Node 的 JSON.parse 自检，失败自动回滚
#   2) 脚本文件用 UTF-8 with BOM（PS 5.1 读中文必需）；写出的 JSON 必须无 BOM（DSH 的 JSON.parse 遇 BOM 崩）
#   3) 启动 App 前必须清 ELECTRON_RUN_AS_NODE（否则 App 以 Node 模式启动、无窗口）
#   4) 探测到的多项候选值（IP / DSH 路径）要打印出来，便于人工确认
$ErrorActionPreference = 'Stop'

$PKG    = Split-Path -Parent $PSScriptRoot          # 包根目录
$FILES  = Join-Path $PKG 'files'
$LOGLIST = New-Object System.Collections.ArrayList
$UTF8NOBOM = New-Object System.Text.UTF8Encoding $false
$UTF8BOM   = New-Object System.Text.UTF8Encoding $true

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c; [void]$LOGLIST.Add($m) }
function Die($m) {
  Say ("[失败] " + $m) 'Red'
  SaveLog
  Write-Host ""
  Write-Host "安装未完成。请把上面的输出截图发给作者。" -ForegroundColor Yellow
  Read-Host "按回车退出"
  exit 1
}
function SaveLog {
  try {
    $log = Join-Path $env:TEMP 'dsh-connector-install.log'
    [IO.File]::WriteAllText($log, ($LOGLIST -join "`r`n"), $UTF8NOBOM)
    Write-Host ("日志: " + $log) -ForegroundColor DarkGray
  } catch {}
}

Say "================================================" 'Cyan'
Say "  DSH 连接器 — 自适应安装" 'Cyan'
Say "================================================" 'Cyan'
Say ("时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say ""

# ---------------- 1. 探测 DSH ----------------
Say "[1/9] 探测 DeepSeek Harness…" 'White'
$EXE = ''
$procs = Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue
if ($procs) {
  foreach ($p in $procs) {
    try { if ($p.Path -and (Test-Path $p.Path)) { $EXE = $p.Path; break } } catch {}
  }
  if ($EXE) { Say ("  从运行进程找到: " + $EXE) 'Green' }
}
if (-not $EXE) {
  $cands = @(
    'F:\deepseek\DeepSeek Harness.exe',
    'C:\Program Files\DeepSeek Harness\DeepSeek Harness.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'),
    (Join-Path $env:LOCALAPPDATA 'DeepSeek Harness\DeepSeek Harness.exe')
  )
  foreach ($c in $cands) { if (Test-Path $c) { $EXE = $c; break } }
  if ($EXE) { Say ("  从常见路径找到: " + $EXE) 'Green' }
}
if (-not $EXE) { Die "找不到 DeepSeek Harness.exe，请先安装并至少启动过一次 DeepSeek" }

$DSH_APP   = Join-Path (Split-Path $EXE -Parent) 'resources\app'
$HOST_FILE = Join-Path $DSH_APP 'dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\index.js'
$PNPM      = Join-Path (Split-Path $EXE -Parent) 'resources\runtime\primary-runtime\dependencies\pnpm\bin\pnpm.cjs'
if (-not (Test-Path $HOST_FILE)) { Die ("找不到 desktop-host: " + $HOST_FILE) }
if (-not (Test-Path $PNPM)) {
  # 有些版本 pnpm 在别处，退而求其次允许缺失（后面装插件会用到）
  Say ("  警告：未找到 pnpm（" + $PNPM + "），插件安装可能失败") 'Yellow'
}

$DSH_HOME = Join-Path $env:USERPROFILE '.dsh'
if (-not (Test-Path $DSH_HOME)) { New-Item -ItemType Directory -Force -Path $DSH_HOME | Out-Null }
Say ("  DSH_HOME: " + $DSH_HOME) 'Green'
Say ""

# ---------------- 2. 探测局域网 IP ----------------
Say "[2/9] 探测局域网 IP…" 'White'
$ipCands = @()
try {
  $ipCands = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
      $_.IPAddress -notlike '127.*' -and
      $_.IPAddress -notlike '169.254.*' -and
      $_.IPAddress -ne '0.0.0.0'
    } | Select-Object -ExpandProperty IPAddress -Unique
} catch {
  $ipCands = @([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
    Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString })
}
$ipCands = @($ipCands | Where-Object { $_ })
if ($ipCands.Count -eq 0) { Die "没有探测到任何局域网 IP，请检查网络连接" }

Say ("  候选 IP：" + ($ipCands -join ', ')) 'DarkGray'
$LAN_IP = ''
foreach ($c in $ipCands) { if ($c -like '192.168.*') { $LAN_IP = $c; break } }
if (-not $LAN_IP) { foreach ($c in $ipCands) { if ($c -like '10.*') { $LAN_IP = $c; break } } }
if (-not $LAN_IP) { foreach ($c in $ipCands) { if ($c -match '^172\.(1[6-9]|2\d|3[01])\.') { $LAN_IP = $c; break } } }
if (-not $LAN_IP) { $LAN_IP = $ipCands[0] }
Say ("  选用: " + $LAN_IP) 'Green'
if ($ipCands.Count -gt 1) {
  Say "  提示：检测到多个网卡。如果这个 IP 不对（比如选到了虚拟网卡），" 'Yellow'
  Say ("        安装后编辑 " + (Join-Path $DSH_HOME 'connector\config.json') + " 里的 lanIp 即可") 'Yellow'
}
Say ""

# ---------------- 3. 复制程序文件 ----------------
Say "[3/9] 安装连接器程序…" 'White'
$CONN = Join-Path $DSH_HOME 'connector'
New-Item -ItemType Directory -Force -Path $CONN | Out-Null
Copy-Item (Join-Path $FILES 'connector\*') $CONN -Force -Recurse
Say ("  已复制到: " + $CONN) 'Green'
# 写 dsh-exe.txt：start-server.cmd 靠它定位 DeepSeek 的 exe —— 换电脑安装不用再改脚本
[IO.File]::WriteAllText((Join-Path $CONN 'dsh-exe.txt'), $EXE, $UTF8NOBOM)

# 写 config.json（无 BOM）
$cfgPath = Join-Path $CONN 'config.json'
$cfg = @{ lanIp = $LAN_IP; updatedAt = (Get-Date).ToString('o') }
[IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json), $UTF8NOBOM)
Say ("  写入 config.json: lanIp=" + $LAN_IP) 'Green'
Say ""

# ---------------- 4. 打 desktop-host 补丁 ----------------
Say "[4/9] 检查并应用 desktop-host 补丁…" 'White'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bak = "$HOST_FILE.bak-installer-$stamp"
$hostText = [IO.File]::ReadAllText($HOST_FILE, $UTF8NOBOM)
$changed = $false

# 补丁 A：--port 可配置（读 DSH_DESKTOP_PORT，默认 0 保持原行为）
if ($hostText -notmatch 'DSH_DESKTOP_PORT') {
  $pairs = @(
    @{ o = ('"--port",' + "`r`n" + "`t`t`t" + '"0"'); n = ('"--port",' + "`r`n" + "`t`t`t" + 'process.env.DSH_DESKTOP_PORT || "0"') },
    @{ o = ('"--port",' + "`n"   + "`t`t`t" + '"0"'); n = ('"--port",' + "`n"   + "`t`t`t" + 'process.env.DSH_DESKTOP_PORT || "0"') }
  )
  $hit = $false
  foreach ($p in $pairs) {
    if ($hostText.Contains($p.o)) { $hostText = $hostText.Replace($p.o, $p.n); $changed = $true; $hit = $true; break }
  }
  if ($hit) { Say "  [OK] --port 可配置" 'Green' } else { Say "  [警告] --port 未匹配，DSH 版本可能不同" 'Yellow' }
}

# 补丁 B：--trusted-host 可配置（外网隧道域名需要它才能过 /api 栅栏）
if ($hostText -match 'DSH_DESKTOP_PORT' -and $hostText -notmatch 'DSH_DESKTOP_TRUSTED') {
  $pairs2 = @(
    @{ o = ('process.env.DSH_DESKTOP_PORT || "0"' + "`r`n" + "`t`t" + ']'); n = ('process.env.DSH_DESKTOP_PORT || "0"' + "`r`n" + "`t`t" + '].concat(process.env.DSH_DESKTOP_TRUSTED ? ["--trusted-host", process.env.DSH_DESKTOP_TRUSTED] : [])') },
    @{ o = ('process.env.DSH_DESKTOP_PORT || "0"' + "`n"   + "`t`t" + ']'); n = ('process.env.DSH_DESKTOP_PORT || "0"' + "`n"   + "`t`t" + '].concat(process.env.DSH_DESKTOP_TRUSTED ? ["--trusted-host", process.env.DSH_DESKTOP_TRUSTED] : [])') }
  )
  $hit2 = $false
  foreach ($p in $pairs2) {
    if ($hostText.Contains($p.o)) { $hostText = $hostText.Replace($p.o, $p.n); $changed = $true; $hit2 = $true; break }
  }
  if ($hit2) { Say "  [OK] trusted-host 可配置" 'Green' } else { Say "  [警告] trusted-host 未匹配（外网通道可能不可用）" 'Yellow' }
}

# 补丁 C：把带 token 的 URL 写到 desktop-web-url.txt（插件/程序靠它拿 token）
if ($hostText -notmatch 'desktop-web-url') {
  $anchor = 'const url = ctx.connection.authenticatedUrl(`${ctx.webServer.protocol}//127.0.0.1:${String(ctx.webServer.port)}`);'
  if ($hostText.Contains($anchor)) {
    $injectLines = @(
      $anchor,
      '	try {',
      '		const __fs = await import("node:fs");',
      '		const __lan = process.env.DSH_DESKTOP_LAN || "";',
      '		let __body = `${url}` + "\n";',
      '		if (__lan) __body += url.replace("127.0.0.1", __lan) + "\n";',
      '		__fs.writeFileSync(join(resolveDshHome(), "desktop-web-url.txt"), __body, "utf8");',
      '	} catch (__e) { console.error("write desktop-web-url.txt failed", __e); }'
    )
    $inject = $injectLines -join "`r`n"
    $hostText = $hostText.Replace($anchor, $inject)
    $changed = $true
    Say "  [OK] URL 落盘" 'Green'
  } else {
    Say "  [警告] URL 落盘锚点未匹配" 'Yellow'
  }
}

if ($changed) {
  Copy-Item $HOST_FILE $bak -Force
  Say ("  已备份: " + $bak) 'DarkGray'
  [IO.File]::WriteAllText($HOST_FILE, $hostText, $UTF8NOBOM)
  $env:ELECTRON_RUN_AS_NODE = '1'
  $oc = Join-Path $env:TEMP 'host-check.txt'
  $ec = Join-Path $env:TEMP 'host-check.err.txt'
  $pc = Start-Process -FilePath $EXE -ArgumentList @('--check', $HOST_FILE) -Wait -PassThru -RedirectStandardOutput $oc -RedirectStandardError $ec -WindowStyle Hidden
  if ($pc.ExitCode -ne 0) {
    Copy-Item $bak $HOST_FILE -Force
    Say "  [失败] 补丁语法检查未通过，已自动回滚" 'Red'
    Die "补丁应用失败（已回滚，App 可正常启动）"
  }
  Say "  [OK] 补丁语法检查通过" 'Green'
} else {
  Say "  补丁已存在或无需修改" 'Green'
}
Say ""
Say "[5/9] 设置环境变量…" 'White'
[Environment]::SetEnvironmentVariable('DSH_DESKTOP_PORT', '14925', 'User')
[Environment]::SetEnvironmentVariable('DSH_DESKTOP_TRUSTED', ($LAN_IP + ':14925'), 'User')
[Environment]::SetEnvironmentVariable('DSH_DESKTOP_LAN', $LAN_IP, 'User')
Say ("  DSH_DESKTOP_PORT    = 14925") 'Green'
Say ("  DSH_DESKTOP_TRUSTED = " + $LAN_IP + ":14925") 'Green'
Say ("  DSH_DESKTOP_LAN     = " + $LAN_IP) 'Green'
Say ""

# ---------------- 6. 装插件 ----------------
Say "[6/9] 安装 DSH 插件…" 'White'
$PLUGIN_SRC = Join-Path $FILES 'plugin'
$PLUGIN_DST = Join-Path $DSH_HOME 'connector-plugin'
New-Item -ItemType Directory -Force -Path $PLUGIN_DST | Out-Null
Copy-Item (Join-Path $PLUGIN_SRC '*') $PLUGIN_DST -Force -Recurse
Say ("  插件源码: " + $PLUGIN_DST) 'Green'

$PROF = Join-Path $DSH_HOME 'profiles\desktop'
$PJ = Join-Path $PROF 'package.json'
if (-not (Test-Path $PJ)) { Die ("找不到 desktop profile: " + $PJ + "，请先启动一次 DeepSeek") }

$pjBak = "$PJ.bak-installer-$stamp"
Copy-Item $PJ $pjBak -Force
Say ("  profile 备份: " + $pjBak) 'DarkGray'

$pjRaw = [IO.File]::ReadAllText($PJ, $UTF8NOBOM)
$pj = $pjRaw | ConvertFrom-Json
$bundles = @($pj.dsh.profile.bundles)
if ($bundles -notcontains 'dsh-connector') { $bundles += 'dsh-connector' }
$pj.dsh.profile.bundles = $bundles
if (-not ($pj.dependencies.PSObject.Properties.Name -contains 'dsh-connector')) {
  $pj.dependencies | Add-Member -NotePropertyName 'dsh-connector' -NotePropertyValue ("link:" + $PLUGIN_DST.Replace('\','/')) -Force
} else {
  $pj.dependencies.'dsh-connector' = ("link:" + $PLUGIN_DST.Replace('\','/'))
}
[IO.File]::WriteAllText($PJ, ($pj | ConvertTo-Json -Depth 12), $UTF8NOBOM)

# JSON 自检（与 DSH 同标准）
$CheckJson = Join-Path $PLUGIN_DST 'check-json.mjs'
if (Test-Path $CheckJson) {
  $env:ELECTRON_RUN_AS_NODE = '1'
  $o2 = Join-Path $env:TEMP 'pj-check.txt'
  $p2 = Start-Process -FilePath $EXE -ArgumentList @($CheckJson, $PJ) -Wait -PassThru `
        -RedirectStandardOutput $o2 -RedirectStandardError (Join-Path $env:TEMP 'pj-check.err.txt') -WindowStyle Hidden
  Get-Content $o2 -ErrorAction SilentlyContinue | ForEach-Object { Say ("  " + $_) }
  if ($p2.ExitCode -ne 0) {
    Copy-Item $pjBak $PJ -Force
    Say "  [失败] package.json 校验未通过，已回滚" 'Red'
    Die "插件注册失败（package.json 已回滚，App 可正常启动）"
  }
  Say "  package.json 校验通过（无 BOM，可被 DSH 解析）" 'Green'
}
Say ""

# ---------------- 7. 自启 ----------------
Say "[7/9] 配置开机自启…" 'White'
$startup = [Environment]::GetFolderPath('Startup')
$vbsPath = Join-Path $startup '启动DSH连接器服务.vbs'
$cmdPath = Join-Path $CONN 'start-server.cmd'
$vbs = 'Set sh = CreateObject("WScript.Shell")' + "`r`n" + 'sh.Run """' + $cmdPath + '""", 0, False'
[IO.File]::WriteAllText($vbsPath, $vbs, $UTF8NOBOM)
Say ("  已创建: " + $vbsPath) 'Green'
# 清掉旧版遗留
$oldVbs = Join-Path $startup '启动DSH端口转发.vbs'
if (Test-Path $oldVbs) { Remove-Item $oldVbs -Force; Say "  已清理旧版自启" 'DarkGray' }
Say ""

# ---------------- 8. 桌面快捷方式 ----------------
Say "[8/9] 创建桌面快捷方式…" 'White'
$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop 'DSH连接器.lnk'
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut($lnkPath)
$lnk.TargetPath = Join-Path $env:WINDIR 'System32\mshta.exe'
$lnk.Arguments = '"' + (Join-Path $CONN 'DSH连接器.hta') + '"'
$lnk.WorkingDirectory = $CONN
$lnk.IconLocation = (Join-Path $CONN 'app.ico') + ',0'
$lnk.Description = 'DSH 连接器 — 手机访问桌面 DeepSeek'
$lnk.Save()
Say ("  已创建: " + $lnkPath) 'Green'
Say ""

# ---------------- 9. 完成 ----------------
Say "[9/9] 完成" 'White'
Say ""
Say "================================================" 'Green'
Say "  安装完成" 'Green'
Say "================================================" 'Green'
Say ("  DSH          : " + $EXE)
Say ("  连接器       : " + $CONN)
Say ("  插件         : " + $PLUGIN_DST)
Say ("  局域网 IP    : " + $LAN_IP)
Say ""
Say "下一步：" 'Yellow'
Say "  1) 完全退出 DeepSeek（托盘右键退出），再重新打开" 'Yellow'
Say "  2) 左侧栏会出现「连接器」入口" 'Yellow'
Say "  3) 双击桌面「DSH连接器」可独立打开控制面板" 'Yellow'
Say ""
Say "注意：" 'Red'
Say "  · 本机 IP 变化后（换网络/路由器重新分配），手机端会连不上。" 'Red'
Say "    此时托盘退出 DeepSeek 再重新打开即可恢复。" 'Red'
Say "  · DeepSeek 升级会覆盖 desktop-host 补丁，升级后请运行「检查补丁.bat」。" 'Red'
Say ""
SaveLog

$answer = Read-Host "现在重启 DeepSeek 吗？(Y/N)"
if ($answer -match '^[Yy]') {
  Say "正在重启 DeepSeek…" 'White'
  Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue | ForEach-Object {
    try { Stop-Process -Id $_.Id -Force } catch {}
  }
  Start-Sleep -Seconds 2
  $cleanEnv = @{}
  foreach ($k in [Environment]::GetEnvironmentVariables('Process').Keys) { $cleanEnv[$k] = [Environment]::GetEnvironmentVariable($k, 'Process') }
  $cleanEnv.Remove('ELECTRON_RUN_AS_NODE')
  Start-Process -FilePath $EXE -Environment $cleanEnv
  Say "已重启" 'Green'
} else {
  Say "请稍后手动重启 DeepSeek 使配置生效。" 'Yellow'
}
Write-Host ""
Read-Host "按回车退出"
