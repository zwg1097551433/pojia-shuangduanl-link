# Deploy.ps1 — DSH 双端互联 一键部署（自适应 + 故障交接给目标机 AI）
#
# 设计前提：目标电脑上有**已破甲的 DeepSeek Harness**。所以脚本不硬扛所有环境差异：
#   · 能自动适配的就自动适配（路径、端口、pnpm、cloudflared、profile、预设）
#   · 适配不了的，生成 diagnostics\AGENT-FIX.md —— 一份写给对面 agent 的执行剧本
#   · 控制台会明确提示「把哪个文件拖给你的 AI」
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Deploy.ps1
#   .\Deploy.ps1 -Mode Lan | -Mode Public
#   .\Deploy.ps1 -SelfCheck     只体检 + 生成交接单，不改任何东西
#   .\Deploy.ps1 -RefreshLink   只重新读取访问链接
#   .\Deploy.ps1 -Uninstall     删除任务、停止服务
#   .\Deploy.ps1 -Port 5290     换端口
#
# 本文件必须保存为 UTF-8 **带 BOM**（PowerShell 5.1 按 ANSI 读会把中文引号吃坏）。
param(
  [ValidateSet('Auto','Public','Lan')]
  [string]$Mode = 'Auto',
  [int]$Port = 5288,
  [string]$BindIp = '',
  [string]$DshHome = '',
  [switch]$SkipPurge,
  [switch]$SelfCheck,
  [switch]$RefreshLink,
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$Here        = Split-Path -Parent $MyInvocation.MyCommand.Path
$DiagDir     = Join-Path $Here 'diagnostics'
$TaskTunnelBase = 'DSH-Phone-Tunnel'
$TaskWebBase    = 'DSH-Phone-Web'
$TaskTunnel  = $TaskTunnelBase
$TaskWeb     = $TaskWebBase
$script:Steps = New-Object System.Collections.ArrayList
$script:Facts = @{}
$script:FailStep = $null
$script:FailMsg  = $null
$script:LogTail  = @{}

function Say  ($m, $c='Gray') { Write-Host $m -ForegroundColor $c }
function Rule { Write-Host ('-' * 62) -ForegroundColor DarkGray }
function Note ($m) { Say "  $m" DarkGray }

function Write-Step {
  param([string]$Name, [string]$Status, [string]$Detail = '')
  [void]$script:Steps.Add([pscustomobject]@{ name = $Name; status = $Status; detail = $Detail })
}
function Invoke-Step {
  param([string]$Name, [scriptblock]$Body, [switch]$Critical)
  Say "· $Name" Gray
  try {
    $out = & $Body
    Write-Step -Name $Name -Status 'ok'
    return $out
  } catch {
    $msg = $_.Exception.Message
    Write-Step -Name $Name -Status 'fail' -Detail $msg
    Say "  [失败] $msg" Red
    if ($Critical) { $script:FailStep = $Name; $script:FailMsg = $msg; throw }
    return $null
  }
}

# ================================================================ 环境快照
function Get-SafeProp { param($Obj, $Name) try { $Obj.$Name } catch { $null } }
function Get-LogTail {
  param([string]$Path, [int]$Lines = 40)
  if (-not (Test-Path $Path)) { return @() }
  try { return @(Get-Content $Path -Tail $Lines -Encoding UTF8 -ErrorAction SilentlyContinue) } catch { return @() }
}

# 纯文本快照：PS 5.1 上 ConvertTo-Json 对复杂哈希表会卡死，这里改手工拼文本，
# 对 AI 反而更好读，也少一个不可控依赖。
function FactsToText {
  param($Facts)
  $sb = New-Object System.Text.StringBuilder
  foreach ($k in ($Facts.Keys | Sort-Object)) {
    $v = $Facts[$k]
    if ($null -eq $v) { [void]$sb.AppendLine("$k = (null)"); continue }
    if ($v -is [string]) {
      $one = ($v -replace "`r?`n", ' ')
      if ($one.Length -gt 600) { $one = $one.Substring(0,600) + ' ...[truncated]' }
      [void]$sb.AppendLine("$k = $one"); continue
    }
    if ($v -is [array]) {
      $parts = foreach ($item in $v) {
        if ($item -is [string]) { $item }
        elseif ($item.PSObject -and $item.PSObject.Properties.Name.Count -gt 0 -and $item.PSObject.Properties.Name.Count -le 8) {
          ($item.PSObject.Properties | ForEach-Object { "$($_.Name)=$(($_.Value -as [string]))" }) -join ','
        } else { "$item" }
      }
      [void]$sb.AppendLine("$k = [" + (($parts) -join ' | ') + "]"); continue
    }
    if ($v.PSObject -and $v.PSObject.Properties.Name.Count -gt 0 -and $v.PSObject.Properties.Name.Count -le 10) {
      [void]$sb.AppendLine("$k = " + (($v.PSObject.Properties | ForEach-Object { "$($_.Name)=$(($_.Value -as [string]))" }) -join ',')); continue
    }
    [void]$sb.AppendLine("$k = $v")
  }
  return $sb.ToString()
}
function Collect-Snapshot {
  $f = @{}
  $f.timestamp = (Get-Date).ToString('s')
  $f.mode = $Mode
  $f.port = $Port
  $f.computer = $env:COMPUTERNAME
  $f.user = "$env:USERDOMAIN\$env:USERNAME"
  $f.isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $f.os = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Caption) $($_.Version)" })
  $f.psVersion = $PSVersionTable.PSVersion.ToString()
  $f.packageRoot = $Here

  # 进程
  $procs = @(Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue)
  $f.harnessProcesses = @($procs | ForEach-Object { [pscustomobject]@{ pid = $_.ProcessId; path = $_.ExecutablePath } })
  $f.harnessRunning = ($procs.Count -gt 0)

  # 候选安装
  $f.dsh = $null
  foreach ($p in $procs) {
    if (-not $p.ExecutablePath) { continue }
    $cli = Join-Path (Split-Path $p.ExecutablePath -Parent) 'resources\app\dsh\node_modules\@deepseek-ai\dsh\lib\bin.js'
    if (Test-Path $cli) { $f.dsh = [pscustomobject]@{ exe = $p.ExecutablePath; cli = $cli }; break }
  }

  # DSH_HOME 与 profile（注意：不要用 $home，它是只读自动变量）
  $homeDir = $DshHome
  if (-not $homeDir) { if ($env:DSH_HOME) { $homeDir = $env:DSH_HOME } else { $homeDir = Join-Path $env:USERPROFILE '.dsh' } }
  $f.dshHome = $homeDir
  $f.dshHomeExists = (Test-Path $homeDir)
  if (Test-Path $homeDir) {
    $f.profiles = @(Get-ChildItem (Join-Path $homeDir 'profiles') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $f.sessionDirs = @(Get-ChildItem (Join-Path $homeDir 'sessions') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $webP = Join-Path $homeDir 'profiles\web'
    $f.webProfileExists = (Test-Path $webP)
    $f.webPurgeInstalled = (Test-Path (Join-Path $webP 'node_modules\dsh-purge-community'))
    $f.webPackageJson = if (Test-Path (Join-Path $webP 'package.json')) { (Get-Content (Join-Path $webP 'package.json') -Raw -Encoding UTF8) } else { $null }
    $f.promptInject = (Test-Path (Join-Path $homeDir 'prompt-inject.md'))
    $f.agentPresets = @(Get-ChildItem (Join-Path $homeDir '.agent-presets') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    # 不做全递归（.dsh 下有上千个文件，会卡住部署），只探已知位置
    $f.pnpmCandidates = @()
    if ($f.dsh) {
      $dshDir = Split-Path $f.dsh.exe -Parent
      foreach ($c in @(
          (Join-Path $dshDir 'resources\runtime\primary-runtime\dependencies\pnpm\bin\pnpm.cjs'),
          (Join-Path $dshDir 'resources\runtime\dependencies\pnpm\bin\pnpm.cjs')
        )) { if (Test-Path $c) { $f.pnpmCandidates += $c } }
    }
  }

  # 系统 node / pnpm
  $f.nodeOnPath = (Get-Command node -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
  $f.pnpmOnPath = (Get-Command pnpm -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })

  # 网络
  $f.ipv4 = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
      ForEach-Object { [pscustomobject]@{ ip = $_.IPAddress; ifAlias = $_.InterfaceAlias; metric = $_.InterfaceMetric } })
  $f.portInUse = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
      Where-Object { $_.LocalPort -ge 5288 -and $_.LocalPort -le 5329 } |
      ForEach-Object { [pscustomobject]@{ port = $_.LocalPort; pid = $_.OwningProcess } })
  $f.firewall = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ name = $_.Name; enabled = $_.Enabled } })

  # 代理（会干扰 cloudflared）。注意 PS 5.1 不支持 try 作表达式，先取值再组装
  $winHttpProxy = $null
  try { $winHttpProxy = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue).ProxyServer } catch {}
  $f.proxyEnv = [pscustomobject]@{
    HTTP_PROXY = $env:HTTP_PROXY; HTTPS_PROXY = $env:HTTPS_PROXY; ALL_PROXY = $env:ALL_PROXY
    NO_PROXY = $env:NO_PROXY
    winHttp = $winHttpProxy
  }

  # 工具
  $f.cloudflared = [pscustomobject]@{
    inHome   = (Test-Path (Join-Path $homeDir 'bin\cloudflared.exe'))
    inBundle = (Test-Path (Join-Path $Here 'bin\cloudflared.exe'))
    onPath   = (Get-Command cloudflared -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })
  }
  $f.nodeOnDisk = @()
  # 用 -TaskName 通配直接过滤，别枚举全部任务（几百条会拖慢部署）
  $f.tasks = @(Get-ScheduledTask -TaskName 'DSH-Phone-*' -ErrorAction SilentlyContinue |
      ForEach-Object { [pscustomobject]@{ name = $_.TaskName; state = "$($_.State)" } })

  # 日志尾部
  $script:LogTail['web']    = Get-LogTail (Join-Path $homeDir "web-$Port.log")
  $script:LogTail['tunnel'] = Get-LogTail (Join-Path $homeDir "tunnel-$Port.log")
  $script:LogTail['pnpm']   = Get-LogTail -Path (Join-Path $env:TEMP 'dshpnpm.err.txt') -Lines 30

  $script:Facts = $f
  return $f
}

# ================================================================ 交接单
function Write-Handoff {
  param([string]$Reason)

  New-Item -ItemType Directory -Force -Path $DiagDir | Out-Null
  $snapPath = Join-Path $DiagDir 'env-snapshot.txt'
  try { Set-Content -Path $snapPath -Value (FactsToText $script:Facts) -Encoding UTF8 } catch {}

  $stepsText = ($script:Steps | ForEach-Object {
      $mark = if ($_.status -eq 'ok') { 'OK  ' } else { 'FAIL' }
      if ($_.detail) { "$mark $($_.name) — $($_.detail)" } else { "$mark $($_.name)" }
    }) -join "`r`n"

  $webTail  = ((@($script:LogTail['web'])     | Select-Object -Last 25) -join "`r`n")
  $tunTail  = ((@($script:LogTail['tunnel'])  | Select-Object -Last 25) -join "`r`n")
  $pnpmTail = ((@($script:LogTail['pnpm'])    | Select-Object -Last 15) -join "`r`n")

  $dshExe = ''
  $dshCli = ''
  if ($script:Facts.dsh) { $dshExe = $script:Facts.dsh.exe; $dshCli = $script:Facts.dsh.cli }
  else { $dshExe = '未定位'; $dshCli = '未定位' }
  $homeDir = $script:Facts.dshHome

  # 单引号 here-string：Markdown 里的反引号和 $ 原样保留，不会被 PowerShell 转义
  $tmpl = @'
# DSH 双端互联 · 部署故障交接单

- 生成时间：{{TIME}}
- 模式：{{MODE}}　　端口：{{PORT}}
- 卡住的阶段：{{REASON}}
- 部署包位置：{{HERE}}
- 机器：{{COMPUTER}}　用户：{{USER}}

---

## 给这台电脑上的 agent（就是你）

用户把一个「双端互联」部署包拖到这**台电脑**，部署脚本在 **{{REASON}}** 这一步停下来。
你所在的这台电脑已破甲，能执行命令、能读写文件。

**请自己动手修，不要反问用户技术细节。** 每一步都给了命令、期望结果、不符合时怎么办。修完看最后一节。

---

## 一、脚本执行结果

```
{{STEPS}}
```

失败信息：

```
{{FAILMSG}}
```

---

## 二、环境事实（脚本已探测）

| 项 | 值 |
|---|---|
| DSH 程序 | {{DSH_EXE}} |
| DSH CLI（bin.js） | {{DSH_CLI}} |
| DSH_HOME | {{HOME}} |
| profiles | {{PROFILES}} |
| web profile 装 purge | {{PURGE}} |
| .agent-presets | {{PRESETS}} |
| 系统 node | {{NODE}} |
| 系统 pnpm | {{PNPM}} |
| 包内 cloudflared | {{CF_BUNDLE}} |
| 家目录 cloudflared | {{CF_HOME}} |
| 端口占用 5288-5329 | {{PORTS}} |
| 防火墙 | {{FW}} |
| 系统代理（会干扰 cloudflared） | {{PROXY}} |
| 计划任务 | {{TASKS}} |

完整快照（纯文本）：`{{SNAP}}`

---

## 三、修复剧本（按顺序，做完一步再下一步）

### 第 1 步 · 确认 DSH 装在哪

```powershell
Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" | Select-Object ProcessId, ExecutablePath
```

期望：至少一条有 ExecutablePath。

- 全为空 → 让用户先启动一次桌面版 DeepSeek Harness，再重跑部署脚本。
- 有路径但该目录下 `resources\app\dsh\node_modules\@deepseek-ai\dsh\lib\bin.js` 不存在 → 精简包或被改过，用下面这条定位真实 CLI：

```powershell
Get-ChildItem '<DSH安装目录>' -Recurse -Depth 6 -Filter 'bin.js' -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -match '@deepseek-ai[\\/]dsh[\\/]lib[\\/]bin\.js$' } |
  Select-Object -First 3 FullName
```

### 第 2 步 · 确认 DSH_HOME

```powershell
$h = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
Test-Path $h
Get-ChildItem $h -ErrorAction SilentlyContinue | Select-Object Name
Get-ChildItem (Join-Path $h 'profiles') -ErrorAction SilentlyContinue | Select-Object Name
```

期望 True 且能看到 profiles。

- False → 桌面版从未初始化。启动一次 DSH 后重试；或用 `-DshHome '<真实路径>'` 指定。
- 有 profiles 但没有 web → 正常，脚本会自动建；也可手动 `New-Item -ItemType Directory -Force "$h\profiles\web"`。

### 第 3 步 · 端口

```powershell
Get-NetTCPConnection -State Listen | Where-Object { $_.LocalPort -ge 5288 -and $_.LocalPort -le 5330 } |
  Select-Object LocalPort, OwningProcess
```

- 被别的程序占 → 换端口：`Deploy.ps1 -Port 5300`（任务名带端口，互不影响）。
- 占用者是残留的 dsh web（`Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'bin\.js.*web' }`）→ `Stop-Process -Id <pid> -Force` 后重试。

### 第 4 步 · cloudflared（仅公网模式需要）

```powershell
Test-Path "$env:USERPROFILE\.dsh\bin\cloudflared.exe"
Test-Path "{{HERE}}\bin\cloudflared.exe"
```

- 两个都 False → 从部署包 `bin\cloudflared.exe` 复制到 `%USERPROFILE%\.dsh\bin\`，或下载：

```powershell
Invoke-WebRequest 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile "$env:USERPROFILE\.dsh\bin\cloudflared.exe"
```

- 若系统代理开着（见上表 PROXY），cloudflared 的 QUIC 会被拖死，先清代理变量再重试：

```powershell
$env:HTTP_PROXY=''; $env:HTTPS_PROXY=''; $env:ALL_PROXY=''
```

### 第 5 步 · pnpm（给 web profile 装破甲插件用）

```powershell
Get-ChildItem '<DSH安装目录>\resources\runtime' -Recurse -Depth 3 -Filter 'pnpm.cjs' -ErrorAction SilentlyContinue |
  Select-Object -First 3 FullName
```

脚本的用法是：`ELECTRON_RUN_AS_NODE=1 "<DSH程序>" "<pnpm.cjs>" add <tgz>`。

- 找不到 → `Deploy.ps1 -SkipPurge` 跳过插件安装。破甲本身在 `prompt-inject.md` 和引擎补丁里，**不影响能不能用**，只是少了红队工具面板。

### 第 6 步 · web 起不来就看日志

```powershell
Get-Content "$env:USERPROFILE\.dsh\web-{{PORT}}.log" -Tail 40
```

最近 25 行：

```
{{TAIL_WEB}}
```

常见原因：

- EADDRINUSE → 端口被占，换端口。
- Unknown agent preset: redteam → web profile 缺 dsh-purge-community，回第 5 步。
- Cannot find module @deepseek-ai/... → profile 的 node_modules 被清过，删掉 `profiles\web\node_modules` 后重跑部署脚本。
- 退出码 0xC000013A（STATUS_CONTROL_C_EXIT）→ 启动器被控制台信号波及，确认用的是部署包生成的 `%USERPROFILE%\.dsh\web-launch.vbs`（wscript 无控制台方式）。

### 第 7 步 · 隧道日志（仅公网模式）

```powershell
Get-Content "$env:USERPROFILE\.dsh\tunnel-{{PORT}}.log" -Tail 40
```

最近 25 行：

```
{{TAIL_TUN}}
```

- failed to request quick Tunnel / Unauthorized → 网络受限，改用局域网版部署包。
- no more connections active and exiting → cloudflared 退出了，手动拉起：`Start-ScheduledTask -TaskName 'DSH-Phone-Tunnel-{{PORT}}'`。

### 第 8 步 · 插件安装日志

```
{{TAIL_PNPM}}
```

---

## 四、判定「部署成功」的硬标准

修好后重跑：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "{{HERE}}\Deploy.ps1" -Mode {{MODE}} -Port {{PORT}}
```

三条全中才算成功：

1. 输出里出现 `校验：局域网 index 200`
2. 公网模式还要出现 `校验：公网 index 200 + /api 200（信任栅栏通过）`
3. 末尾打印 `http://<内网IP>:{{PORT}}/?token=...`（公网模式另有一条 `https://...trycloudflare.com/?token=...`）

自己验也行。注意：/api 必须先 GET 换 cookie 再 POST，直接 POST 只会得到 401。

```powershell
$s = New-Object Microsoft.PowerShell.Commands.WebRequestSession
(Invoke-WebRequest '{{LAN_URL}}' -WebSession $s -UseBasicParsing -MaximumRedirection 5).StatusCode
$h = @{ 'Origin'='{{LAN_ORIGIN}}'; 'Referer'='{{LAN_ORIGIN}}/'; 'Content-Type'='application/json' }
$b = '{"type":"client-request","rpcId":"p","method":"agentPresets/list","payload":{"args":{}}}'
(Invoke-WebRequest '{{LAN_ORIGIN}}/api/agentPresets/list' -Method Post -Body $b -Headers $h -WebSession $s -UseBasicParsing).StatusCode
```

两条都应返回 200。

---

## 五、修完之后请你（agent）做三件事

1. 把实际执行的修复命令与结论，一条一句写进 `{{DIAG}}\AGENT-FIX-DONE.md`
2. 把最终可用的链接（局域网 / 公网）也抄进那个文件，方便用户直接复制到手机
3. 如果是**脚本本身的缺陷**（某段逻辑在你这台机器不成立），把期望行为写清楚，用户会反馈给部署包作者

---

> 本文件由 `Deploy.ps1` 自动生成；`{{SNAP}}` 是同一时刻的机器可读快照（纯文本）。
'@

  $md = $tmpl
  $md = $md.Replace('{{TIME}}', (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
  $md = $md.Replace('{{MODE}}', [string]$Mode)
  $md = $md.Replace('{{PORT}}', [string]$Port)
  $md = $md.Replace('{{REASON}}', [string]$Reason)
  $md = $md.Replace('{{HERE}}', $Here)
  $md = $md.Replace('{{COMPUTER}}', $env:COMPUTERNAME)
  $md = $md.Replace('{{USER}}', "$env:USERDOMAIN\$env:USERNAME")
  $md = $md.Replace('{{STEPS}}', $stepsText)
  $md = $md.Replace('{{FAILMSG}}', [string]$script:FailMsg)
  $md = $md.Replace('{{DSH_EXE}}', [string]$dshExe)
  $md = $md.Replace('{{DSH_CLI}}', [string]$dshCli)
  $md = $md.Replace('{{HOME}}', [string]$homeDir)
  $md = $md.Replace('{{PROFILES}}', ((@($script:Facts.profiles)) -join ', '))
  $md = $md.Replace('{{PURGE}}', [string]$script:Facts.webPurgeInstalled)
  $md = $md.Replace('{{PRESETS}}', ((@($script:Facts.agentPresets)) -join ', '))
  $md = $md.Replace('{{NODE}}', [string]$script:Facts.nodeOnPath)
  $md = $md.Replace('{{PNPM}}', [string]$script:Facts.pnpmOnPath)
  $md = $md.Replace('{{CF_BUNDLE}}', [string]$script:Facts.cloudflared.inBundle)
  $md = $md.Replace('{{CF_HOME}}', [string]$script:Facts.cloudflared.inHome)
  $md = $md.Replace('{{PORTS}}', (((@($script:Facts.portInUse)) | ForEach-Object { "$($_.port)(pid $($_.pid))" }) -join ', '))
  $md = $md.Replace('{{FW}}', (((@($script:Facts.firewall)) | ForEach-Object { "$($_.name):$($_.enabled)" }) -join ', '))
  $md = $md.Replace('{{PROXY}}', "HTTP=$($script:Facts.proxyEnv.HTTP_PROXY) HTTPS=$($script:Facts.proxyEnv.HTTPS_PROXY) WinINET=$($script:Facts.proxyEnv.winHttp)")
  $md = $md.Replace('{{TASKS}}', (((@($script:Facts.tasks)) | ForEach-Object { "$($_.name)=$($_.state)" }) -join ', '))
  $md = $md.Replace('{{SNAP}}', [string]$snapPath)
  $md = $md.Replace('{{DIAG}}', $DiagDir)
  $md = $md.Replace('{{TAIL_WEB}}', $webTail)
  $md = $md.Replace('{{TAIL_TUN}}', $tunTail)
  $md = $md.Replace('{{TAIL_PNPM}}', $pnpmTail)

  $firstIp = $script:Facts.ipv4 | ForEach-Object { $_.ip } | Select-Object -First 1
  if (-not $firstIp) { $firstIp = '127.0.0.1' }
  $lanBase = "http://${firstIp}:$Port"
  $md = $md.Replace('{{LAN_ORIGIN}}', $lanBase)
  $md = $md.Replace('{{LAN_URL}}', "$lanBase/")
  $md = $md.Replace([string][char]0, '')

  $handoff = Join-Path $DiagDir 'AGENT-FIX.md'
  [IO.File]::WriteAllText($handoff, $md, (New-Object System.Text.UTF8Encoding $false))
  return $handoff
}


# ================================================================ 0. 模式
if ($Mode -eq 'Auto') {
  $Mode = if ($Here -match '局域网|LAN|Lan|lan') { 'Lan' } else { 'Public' }
}
Say "模式 / Mode: $Mode" Cyan
Rule

# ================================================================ 1. 权限
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $RefreshLink -and -not $SelfCheck) {
  Say "需要管理员权限（注册计划任务）。正在请求提权 ..." Yellow
  $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Mode',$Mode,'-Port',$Port)
  if ($BindIp) { $argList += @('-BindIp',$BindIp) }
  if ($DshHome) { $argList += @('-DshHome',$DshHome) }
  if ($SkipPurge) { $argList += '-SkipPurge' }
  Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
  exit 0
}

# ================================================================ 2. 定位 DSH
function Find-DshInstall {
  $hit = $null
  $seen = @()
  Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath } | ForEach-Object {
      $exe = $_.ExecutablePath
      if ($seen -contains $exe -or $hit) { return }
      $seen += $exe
      $cli = Join-Path (Split-Path $exe -Parent) 'resources\app\dsh\node_modules\@deepseek-ai\dsh\lib\bin.js'
      if (Test-Path $cli) { $hit = [pscustomobject]@{ Exe = $exe; Cli = $cli } }
    }
  if ($hit) { return $hit }

  $roots = @("$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:LOCALAPPDATA", "$env:APPDATA", "$env:USERPROFILE")
  foreach ($d in @('C:\','D:\','E:\','F:\','G:\')) {
    if (Test-Path $d) { $roots += (Join-Path $d 'DeepSeek Harness') }
  }
  foreach ($r in ($roots | Select-Object -Unique)) {
    if (-not (Test-Path $r)) { continue }
    $cli = Join-Path $r 'resources\app\dsh\node_modules\@deepseek-ai\dsh\lib\bin.js'
    if (Test-Path $cli) { return [pscustomobject]@{ Exe = (Join-Path $r 'DeepSeek Harness.exe'); Cli = $cli } }
  }
  # 最后兜底：只查一级子目录名含 DeepSeek，避免全盘递归把部署拖死
  foreach ($r in @("$env:ProgramFiles","${env:ProgramFiles(x86)}","$env:LOCALAPPDATA")) {
    if (-not (Test-Path $r)) { continue }
    $dirs = @(Get-ChildItem $r -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*DeepSeek*' -or $_.Name -like '*Harness*' })
    foreach ($d in $dirs) {
      $cli = Join-Path $d.FullName 'resources\app\dsh\node_modules\@deepseek-ai\dsh\lib\bin.js'
      if (Test-Path $cli) { return [pscustomobject]@{ Exe = (Join-Path $d.FullName 'DeepSeek Harness.exe'); Cli = $cli } }
    }
  }
  return $null
}

$dsh = Invoke-Step -Name '定位 DSH 安装目录' -Critical -Body { Find-DshInstall }
if (-not $dsh) {
  Collect-Snapshot | Out-Null
  $h = Write-Handoff -Reason '定位 DSH 安装目录'
  Say ""
  Say "无法自动定位 DSH，已生成交接单：" Yellow
  Say "  $h" Cyan
  Say "把上面这个文件拖给这台电脑上的 DeepSeek，让它按里面的剧本修。" Yellow
  exit 2
}
Say "DSH 程序   : $($dsh.Exe)"
Say "DSH CLI    : $($dsh.Cli)"

if (-not $DshHome) {
  if ($env:DSH_HOME) { $DshHome = $env:DSH_HOME } else { $DshHome = Join-Path $env:USERPROFILE '.dsh' }
}
if (-not (Test-Path $DshHome)) {
  Collect-Snapshot | Out-Null
  $h = Write-Handoff -Reason "DSH_HOME 不存在（$DshHome）"
  Say "DSH_HOME 不存在：$DshHome" Red
  Say "交接单：$h" Cyan
  exit 2
}
Say "DSH_HOME   : $DshHome"

# ================================================================ 3. 网络与端口
if (-not $BindIp) {
  $cand = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    Sort-Object -Property SkipAsSource, InterfaceMetric
  $BindIp = ($cand | Select-Object -First 1).IPAddress
  if (-not $BindIp) { $BindIp = '127.0.0.1' }
}
Say "绑定地址   : $BindIp"

function Test-PortFree ($p) { -not (Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue) }

# 端口被占时先看是不是「本脚本自己的旧 web」：是就杀掉复用，避免实例越堆越多、端口一路往上漂
if (-not $RefreshLink -and -not (Test-PortFree $Port)) {
  $busy = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
  $ownerProc = $null
  try { $ownerProc = Get-CimInstance Win32_Process -Filter "ProcessId=$($busy.OwningProcess)" -ErrorAction SilentlyContinue } catch {}
  $isOurWeb = $false
  if ($ownerProc -and $ownerProc.CommandLine) {
    if ($ownerProc.CommandLine -match 'bin\.js' -and $ownerProc.CommandLine -match '\bweb\b') { $isOurWeb = $true }
  }
  if ($isOurWeb) {
    Say "端口 $Port 上是本脚本遗留的 web 实例 (pid $($busy.OwningProcess))，复用它" Yellow
    try { Stop-Process -Id $busy.OwningProcess -Force -ErrorAction Stop } catch {}
    Start-Sleep -Milliseconds 900
  }
}
if (-not $RefreshLink -and -not (Test-PortFree $Port)) {
  $busy = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
  Say "端口 $Port 被其它程序占用 (pid $($busy.OwningProcess))，向上寻找空闲端口 ..." Yellow
  $found = $false
  for ($p = $Port + 1; $p -lt $Port + 40; $p++) { if (Test-PortFree $p) { $Port = $p; $found = $true; break } }
  if (-not $found) {
    Collect-Snapshot | Out-Null
    $h = Write-Handoff -Reason '端口全部被占用'
    Say "5288-5328 全部被占用。交接单：$h" Red
    exit 2
  }
}
Say "端口       : $Port"
$TaskTunnel = "$TaskTunnelBase-$Port"
$TaskWeb    = "$TaskWebBase-$Port"

# ================================================================ 4. 路径
$cfBin     = Join-Path $DshHome 'bin\cloudflared.exe'
$vbs       = Join-Path $DshHome 'web-launch.vbs'
$webLog    = Join-Path $DshHome "web-$Port.log"
$tunLog    = Join-Path $DshHome "tunnel-$Port.log"
$urlFile   = Join-Path $Here 'phone-url.txt'
$urlRemote = Join-Path $Here 'phone-url-remote.txt'

# ================================================================ 5. 自检模式
if ($SelfCheck) {
  Say ""
  Say "自检模式：只收集环境，不改动任何东西" Yellow
  Collect-Snapshot | Out-Null
  New-Item -ItemType Directory -Force -Path $DiagDir | Out-Null
  Set-Content -Path (Join-Path $DiagDir 'env-snapshot.txt') -Value (FactsToText $script:Facts) -Encoding UTF8
  Rule
  Say "DSH 程序      : $(if ($script:Facts.dsh) { $script:Facts.dsh.exe } else { '未定位' })"
  Say "DSH_HOME      : $($script:Facts.dshHome)（存在 $($script:Facts.dshHomeExists)）"
  Say "profiles      : $($script:Facts.profiles -join ', ')"
  Say "web 装 purge  : $($script:Facts.webPurgeInstalled)"
  Say "agent-presets : $($script:Facts.agentPresets -join ', ')"
  Say "cloudflared   : 包内=$($script:Facts.cloudflared.inBundle) 家目录=$($script:Facts.cloudflared.inHome)"
  Say "IPv4          : $((($script:Facts.ipv4 | ForEach-Object { $_.ip }) -join ', '))"
  Say "计划任务      : $((($script:Facts.tasks | ForEach-Object { "$($_.name)=$($_.state)" }) -join ', '))"
  Rule
  $h = Write-Handoff -Reason '自检（人工触发，未执行部署）'
  Say "交接单已生成：$h" Green
  Say "要让它修，把这个文件拖给这台电脑的 DeepSeek。" Yellow
  exit 0
}

# ================================================================ 6. 链接回收
function Get-Token {
  param([string]$LogPath, [int]$TimeoutSec = 45)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path $LogPath) {
      $m = Select-String -Path $LogPath -Pattern 'token=([A-Za-z0-9_\-]+)' -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($m) { return $m.Matches[0].Groups[1].Value }
    }
    Start-Sleep -Milliseconds 700
  }
  return $null
}
function Get-Domain {
  param([string]$LogPath, [int]$TimeoutSec = 90)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path $LogPath) {
      $m = Select-String -Path $LogPath -Pattern 'https://([a-z0-9-]+\.trycloudflare\.com)' -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($m) { return $m.Matches[0].Groups[1].Value }
    }
    Start-Sleep -Milliseconds 800
  }
  return $null
}
function Show-Links {
  param([string]$Token, [string]$Domain)
  $lan = "http://${BindIp}:${Port}/"
  if ($Token) { $lan = "$lan`?token=$Token" }
  [IO.File]::WriteAllText($urlFile, $lan, (New-Object System.Text.UTF8Encoding $false))
  Rule
  Say "局域网（同一 WiFi）" Yellow
  Say "  $lan" Cyan
  if ($Mode -eq 'Public' -and $Domain) {
    $remote = "https://$Domain/"
    if ($Token) { $remote = "$remote`?token=$Token" }
    [IO.File]::WriteAllText($urlRemote, $remote, (New-Object System.Text.UTF8Encoding $false))
    Say "公网（任意网络 / 4G）" Yellow
    Say "  $remote" Cyan
  }
  Rule
  Say "链接已写入: $urlFile" DarkGray
  if ($Mode -eq 'Public') { Say "            $urlRemote" DarkGray }

  # 把「手机要用的那条」直接放进剪贴板，省掉手抄出错
  $copyValue = $lan
  if ($Mode -eq 'Public' -and $Domain) { $copyValue = $remote }
  try {
    Set-Clipboard -Value $copyValue -ErrorAction Stop
    Say "已复制到剪贴板，直接在微信/QQ 里 Ctrl+V 发到手机即可。" Green
  } catch {
    Say "（剪贴板不可用，请手动复制上面的链接）" DarkGray
  }

  Say "token 每次重启 web 会变；cookie 有效 30 天，同一地址第二次访问可省略 token。" DarkGray
}

if ($RefreshLink) {
  $tok = Get-Token -LogPath $webLog -TimeoutSec 5
  $dom = $null
  if ($Mode -eq 'Public') { $dom = Get-Domain -LogPath $tunLog -TimeoutSec 3 }
  if (-not $tok) { Say "web 日志里没有 token（服务可能没在跑），先跑一次完整部署。" Red; exit 1 }
  Show-Links -Token $tok -Domain $dom
  exit 0
}

# ================================================================ 7. 停止/卸载
function Stop-DshPhoneTasks {
  foreach ($t in @($TaskTunnel, $TaskWeb)) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
      Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
      Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
      Say "已删除任务 $t" DarkGray
    }
  }
  # 只清理指向本端口的隧道
  Get-CimInstance Win32_Process -Filter "Name='cloudflared.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'trycloudflare' -and $_.CommandLine -match ":$Port\b" } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {} }
  Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'bin\.js' -and $_.CommandLine -match '\bweb\b' -and $_.CommandLine -match "--port\s+$Port\b" } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; Say "已停止 web pid $($_.ProcessId)" DarkGray } catch {} }
}

if ($Uninstall) {
  Stop-DshPhoneTasks
  Say "卸载完成。桌面版 DSH 不受影响。" Green
  exit 0
}

Stop-DshPhoneTasks

# ================================================================ 8. 破甲插件与预设
function Ensure-PurgeInWebProfile {
  if ($SkipPurge) { return 'skipped' }
  $webProfile = Join-Path $DshHome 'profiles\web'
  if (Test-Path (Join-Path $webProfile 'node_modules\dsh-purge-community')) { return 'installed' }

  $tgz = Join-Path $Here 'payload\dsh-purge-community-1.6.91.tgz'
  if (-not (Test-Path $tgz)) { return 'no-payload' }

  $pnpm = $null
  $cands = @()
  $dshDir = Split-Path $dsh.Exe -Parent
  $cands += (Join-Path $dshDir 'resources\runtime\primary-runtime\dependencies\pnpm\bin\pnpm.cjs')
  if (Test-Path (Join-Path $dshDir 'resources\runtime')) {
    $cands += @(Get-ChildItem (Join-Path $dshDir 'resources\runtime') -Recurse -Depth 4 -Filter 'pnpm.cjs' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
  }
  foreach ($c in $cands) { if ($c -and (Test-Path $c)) { $pnpm = $c; break } }
  if (-not $pnpm) { return 'no-pnpm' }

  New-Item -ItemType Directory -Force -Path $webProfile | Out-Null
  $spec = 'file:' + ($tgz -replace '\\','/')
  $env:ELECTRON_RUN_AS_NODE = '1'
  $po = Join-Path $env:TEMP 'dshpnpm.out.txt'
  $pe = Join-Path $env:TEMP 'dshpnpm.err.txt'
  $p = Start-Process -FilePath $dsh.Exe -ArgumentList @($pnpm,'add',$spec) -WorkingDirectory $webProfile `
        -Wait -PassThru -RedirectStandardOutput $po -RedirectStandardError $pe -WindowStyle Hidden
  if ($p.ExitCode -ne 0) { return "pnpm-failed(exit $($p.ExitCode))" }

  $pkgJson = Join-Path $webProfile 'package.json'
  if (Test-Path $pkgJson) {
    try {
      $j = Get-Content $pkgJson -Raw -Encoding UTF8 | ConvertFrom-Json
      if (-not $j.dsh) { $j | Add-Member -NotePropertyName dsh -NotePropertyValue ([pscustomobject]@{ profile = [pscustomobject]@{ bundles = @() } }) -Force }
      $bundles = @($j.dsh.profile.bundles)
      if ($bundles -notcontains 'dsh-purge-community') {
        $j.dsh.profile.bundles = @($bundles + 'dsh-purge-community')
        $j | ConvertTo-Json -Depth 12 | Set-Content -Path $pkgJson -Encoding UTF8
      }
    } catch { return 'json-failed' }
  }
  return 'installed-now'
}

function Ensure-Presets {
  if ($SkipPurge) { return }
  $src = Join-Path $Here 'payload\agent-presets'
  if (-not (Test-Path $src)) { return }
  $dst = Join-Path $DshHome '.agent-presets'
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  foreach ($name in @('redteam','unrestricted')) {
    $s = Join-Path $src $name
    $d = Join-Path $dst $name
    if ((Test-Path $s) -and -not (Test-Path $d)) {
      Copy-Item $s $d -Recurse -Force
      Say "预设已复制: $name" DarkGray
    }
  }
}

$purgeState = Invoke-Step -Name 'web profile 破甲插件' -Body { Ensure-PurgeInWebProfile }
switch ($purgeState) {
  'installed'     { Say "  dsh-purge-community 已存在" DarkGray }
  'installed-now' { Say "  已安装 dsh-purge-community（红队/无限制模式可用）" Green }
  'skipped'       { Say "  跳过（-SkipPurge）" DarkGray }
  'no-payload'    { Say "  部署包缺 payload\*.tgz，跳过；不影响破甲本身" Yellow }
  'no-pnpm'       { Say "  没找到 DSH 自带 pnpm，跳过；不影响破甲本身" Yellow }
  default         { Say "  未完成（$purgeState），继续部署" Yellow }
}
Invoke-Step -Name '复制预设' -Body { Ensure-Presets } | Out-Null

# ================================================================ 9. cloudflared
$cfReady = $false
if ($Mode -eq 'Public') {
  $local = Join-Path $Here 'bin\cloudflared.exe'
  if (-not (Test-Path $cfBin)) {
    if (Test-Path $local) {
      New-Item -ItemType Directory -Force -Path (Split-Path $cfBin -Parent) | Out-Null
      Copy-Item $local $cfBin -Force
      Say "cloudflared: 从部署包复制" DarkGray
    } else {
      Say "cloudflared: 包里没有，尝试下载 ..." Yellow
      New-Item -ItemType Directory -Force -Path (Split-Path $cfBin -Parent) | Out-Null
      for ($i = 1; $i -le 3; $i++) {
        try {
          Invoke-WebRequest 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile $cfBin -TimeoutSec 300 -UseBasicParsing
          break
        } catch { Start-Sleep -Seconds 3 }
      }
    }
  }
  if (Test-Path $cfBin) { $cfReady = $true; Say "cloudflared: $cfBin" DarkGray }
  else {
    Say "cloudflared 不可用，公网模式无法继续。" Red
    Collect-Snapshot | Out-Null
    $h = Write-Handoff -Reason 'cloudflared 不可用（公网模式下为关键依赖）'
    Say "交接单：$h" Cyan
    Say "或者改用局域网部署包（不依赖 cloudflared）。" Yellow
    exit 2
  }
}

# ================================================================ 10. 启动器
$vbsBody = @'
' web-launch.vbs — 由 Deploy.ps1 生成，请勿手改
Option Explicit
Dim a, port, bindIp, th, dshHome, exe, cli, logFile, cmd, sh, rc
Set a = WScript.Arguments
port = a(0) : bindIp = a(1) : th = a(2) : dshHome = a(3) : exe = a(4) : cli = a(5) : logFile = a(6)
Set sh = CreateObject("WScript.Shell")
sh.Environment("PROCESS")("ELECTRON_RUN_AS_NODE") = "1"
sh.Environment("PROCESS")("DSH_HOME") = dshHome
cmd = """" & exe & """ """ & cli & """ web --host " & bindIp & " --port " & port & " --no-open"
If th <> "-" Then cmd = cmd & " --trusted-host " & th
cmd = "cmd /c """ & cmd & " > """ & logFile & """ 2>&1"""
rc = sh.Run(cmd, 0, True)
WScript.Quit 1
'@
Set-Content -Path $vbs -Value $vbsBody -Encoding Default
Say "启动器     : $vbs" DarkGray

# ================================================================ 11. 隧道
$domain = $null
if ($Mode -eq 'Public') {
  if (Test-Path $tunLog) { Remove-Item $tunLog -Force }
  $tunArg = "tunnel --url http://${BindIp}:${Port} --no-autoupdate --logfile `"$tunLog`" --loglevel info"
  $okT = Invoke-Step -Name '注册并启动隧道任务' -Body {
    $actT = New-ScheduledTaskAction -Execute $cfBin -Argument $tunArg
    $trgT = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $setT = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
              -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
              -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -StartWhenAvailable
    $priT = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType S4U -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskTunnel -Action $actT -Trigger $trgT -Settings $setT -Principal $priT -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskTunnel
    $true
  } -Critical
  Say "  等待域名 ..." Yellow
  $domain = Get-Domain -LogPath $tunLog -TimeoutSec 90
  if (-not $domain) {
    Collect-Snapshot | Out-Null
    $h = Write-Handoff -Reason '隧道没有拿到 trycloudflare 域名'
    Say "隧道没拿到域名。交接单：$h" Red
    exit 2
  }
  Say "公网域名   : $domain" Green
  Write-Step -Name '隧道分配域名' -Status 'ok' -Detail $domain
}

# ================================================================ 12. web
if (Test-Path $webLog) { Remove-Item $webLog -Force }
$thArg = if ($domain) { $domain } else { '-' }
# 用 .cmd 包装并让 cmd.exe 直接作为任务进程：
# wscript 会在某些环境下提前返回，导致任务变 Ready、崩溃后不自动重启（实测踩过）。
# cmd.exe 会一直等 electron 退出，任务保持 Running，RestartCount 才有效。
$webCmd = Join-Path $DshHome "run-web-$Port.cmd"
$thExtra = ''
if ($domain) { $thExtra = " --trusted-host $domain" }
$cmdLines = @(
  '@echo off',
  'set ELECTRON_RUN_AS_NODE=1',
  "set DSH_HOME=$DshHome",
  "`"$($dsh.Exe)`" `"$($dsh.Cli)`" web --host $BindIp --port $Port --no-open$thExtra > `"$webLog`" 2>&1"
)
Set-Content -Path $webCmd -Encoding Default -Value $cmdLines
Invoke-Step -Name '注册并启动 web 任务' -Critical -Body {
  $actW = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"$webCmd`""
  $trgW = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
  $setW = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
            -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -StartWhenAvailable
  $priW = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType S4U -RunLevel Highest
  Register-ScheduledTask -TaskName $TaskWeb -Action $actW -Trigger $trgW -Settings $setW -Principal $priW -Force | Out-Null
  Start-ScheduledTask -TaskName $TaskWeb
  $true
} | Out-Null

Say "  等待 token ..." Yellow
$token = Get-Token -LogPath $webLog -TimeoutSec 60
if (-not $token) {
  Collect-Snapshot | Out-Null
  $h = Write-Handoff -Reason 'web 启动后没有打印 token'
  Say "web 没打印 token。交接单：$h" Red
  Say "日志：$webLog" Yellow
  exit 2
}
Write-Step -Name 'web 打印 token' -Status 'ok'

# ================================================================ 13. 校验
$global:probeSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
function Probe-Index {
  param([string]$Uri)
  try { return (Invoke-WebRequest $Uri -WebSession $global:probeSession -UseBasicParsing -TimeoutSec 25 -MaximumRedirection 5).StatusCode }
  catch { $r = $_.Exception.Response; if ($r) { return [int]$r.StatusCode } else { return -1 } }
}
function Probe-Api {
  param([string]$Uri, [string]$Origin, [string]$Body)
  $hdr = @{ 'Origin' = $Origin; 'Referer' = "$Origin/"; 'Content-Type' = 'application/json' }
  try { return (Invoke-WebRequest $Uri -Method Post -Body $Body -Headers $hdr -WebSession $global:probeSession -UseBasicParsing -TimeoutSec 25).StatusCode }
  catch { $r = $_.Exception.Response; if ($r) { return [int]$r.StatusCode } else { return -1 } }
}

$lanOrigin = "http://${BindIp}:${Port}"
$okIndex = $false
for ($i = 1; $i -le 6; $i++) {
  if ((Probe-Index -Uri "$lanOrigin/?token=$token") -eq 200) { $okIndex = $true; break }
  Start-Sleep -Seconds 3
}
if ($okIndex) { Say "校验：局域网 index 200" Green; Write-Step '局域网 index' 'ok' }
else { Say "局域网校验未通过，但服务已启动" Yellow; Write-Step '局域网 index' 'warn' }

$pubOk = $null
if ($Mode -eq 'Public') {
  $pubOrigin = "https://$domain"
  $okPub = $false
  for ($i = 1; $i -le 8; $i++) {
    if ((Probe-Index -Uri "$pubOrigin/?token=$token") -eq 200) { $okPub = $true; break }
    Start-Sleep -Seconds 5
  }
  $body = '{"type":"client-request","rpcId":"probe","method":"agentPresets/list","payload":{"args":{}}}'
  $apiSt = 0
  for ($i = 1; $i -le 5; $i++) {
    $apiSt = Probe-Api -Uri "$pubOrigin/api/agentPresets/list" -Origin $pubOrigin -Body $body
    if ($apiSt -eq 200) { break }
    Start-Sleep -Seconds 3
  }
  if ($okPub -and $apiSt -eq 200) {
    Say "校验：公网 index 200 + /api 200（信任栅栏通过）" Green
    Write-Step '公网 index+api' 'ok'
    $pubOk = $true
  } elseif ($okPub) {
    Say "公网 index 通了，/api 返回 $apiSt —— web 可能没带 --trusted-host" Yellow
    Write-Step '公网 index+api' 'warn' "api=$apiSt"
    $pubOk = $false
  } else {
    Say "公网 index 未通（边缘可能要 30-60 秒），链接仍有效" Yellow
    Write-Step '公网 index+api' 'warn' 'index timeout'
    $pubOk = $false
  }
}

# ================================================================ 14. 结果
Show-Links -Token $token -Domain $domain
if ($Mode -eq 'Public') { Say "任务：$TaskWeb + $TaskTunnel（登录自启、崩溃自动重启）" DarkGray }
else { Say "任务：$TaskWeb（登录自启、崩溃自动重启）" DarkGray }
Say "重新取链接：.\Deploy.ps1 -RefreshLink      卸载：.\Deploy.ps1 -Uninstall" DarkGray

# 有告警就把交接单也生成出来，方便 AI 顺手看
$warned = @($script:Steps | Where-Object { $_.status -eq 'warn' -or $_.status -eq 'fail' })
if ($warned.Count -gt 0 -or ($Mode -eq 'Public' -and $pubOk -ne $true)) {
  Collect-Snapshot | Out-Null
  $h = Write-Handoff -Reason '部署已完成，但存在告警（见执行结果）'
  Rule
  Say "有告警项，已生成交接单：" Yellow
  Say "  $h" Cyan
  Say "如果手机打不开，把这个文件拖给这台电脑的 DeepSeek 让它修。" Yellow
}

exit 0