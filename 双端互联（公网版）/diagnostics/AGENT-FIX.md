# DSH 双端互联 · 部署故障交接单

- 生成时间：2026-11-16 15:41:12
- 模式：Public　　端口：5289
- 卡住的阶段：自检（人工触发，未执行部署）
- 部署包位置：E:\deepseek工作区\phone-armor\双端互联（公网版）
- 机器：热火朝天　用户：热火朝天\10975

---

## 给这台电脑上的 agent（就是你）

用户把一个「双端互联」部署包拖到这**台电脑**，部署脚本在 **自检（人工触发，未执行部署）** 这一步停下来。
你所在的这台电脑已破甲，能执行命令、能读写文件。

**请自己动手修，不要反问用户技术细节。** 每一步都给了命令、期望结果、不符合时怎么办。修完看最后一节。

---

## 一、脚本执行结果

```
OK   定位 DSH 安装目录
```

失败信息：

```

```

---

## 二、环境事实（脚本已探测）

| 项 | 值 |
|---|---|
| DSH 程序 | F:\deepseek\DeepSeek Harness.exe |
| DSH CLI（bin.js） | F:\deepseek\resources\app\dsh\node_modules\@deepseek-ai\dsh\lib\bin.js |
| DSH_HOME | C:\Users\10975\.dsh |
| profiles | desktop, web |
| web profile 装 purge | True |
| .agent-presets | redteam, unrestricted |
| 系统 node |  |
| 系统 pnpm |  |
| 包内 cloudflared | True |
| 家目录 cloudflared | True |
| 端口占用 5288-5329 | 5288(pid 6928) |
| 防火墙 | Domain:False, Private:False, Public:False |
| 系统代理（会干扰 cloudflared） | HTTP= HTTPS= WinINET=127.0.0.1:7897 |
| 计划任务 | DSH-Phone-Tunnel-5288=Running, DSH-Phone-Web-5288=Running |

完整快照（纯文本）：`E:\deepseek工作区\phone-armor\双端互联（公网版）\diagnostics\env-snapshot.txt`

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
Test-Path "E:\deepseek工作区\phone-armor\双端互联（公网版）\bin\cloudflared.exe"
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
Get-Content "$env:USERPROFILE\.dsh\web-5289.log" -Tail 40
```

最近 25 行：

```
dsh web: listening on 192.168.1.2 over plain HTTP; restrict this port to a trusted proxy or network
dsh web: http://192.168.1.2:5289/?token=T_wcZS5P-kkEz6Rn_SW1sY3tbnAh1-HatBdbGKoW8ms
```

常见原因：

- EADDRINUSE → 端口被占，换端口。
- Unknown agent preset: redteam → web profile 缺 dsh-purge-community，回第 5 步。
- Cannot find module @deepseek-ai/... → profile 的 node_modules 被清过，删掉 `profiles\web\node_modules` 后重跑部署脚本。
- 退出码 0xC000013A（STATUS_CONTROL_C_EXIT）→ 启动器被控制台信号波及，确认用的是部署包生成的 `%USERPROFILE%\.dsh\web-launch.vbs`（wscript 无控制台方式）。

### 第 7 步 · 隧道日志（仅公网模式）

```powershell
Get-Content "$env:USERPROFILE\.dsh\tunnel-5289.log" -Tail 40
```

最近 25 行：

```
{"level":"info","time":"2026-11-16T07:17:40Z","message":"ICMP proxy will use 240e:3bb:ac5:5d40:f415:2a8b:a5cf:3a06 in zone 以太网 as source for IPv6"}
{"level":"info","time":"2026-11-16T07:17:40Z","message":"Starting metrics server on 127.0.0.1:20241/metrics"}
{"level":"info","event":0,"connection":"f3298bdf-9802-40fb-a27e-871d12198f5c","connIndex":0,"location":"lax11","ip":"2606:4700:a0::8","protocol":"quic","time":"2026-11-16T07:17:41Z","message":"Registered tunnel connection"}
{"level":"info","time":"2026-11-16T07:17:43Z","message":"+-------------------------------------------------------------------------------------+"}
{"level":"info","time":"2026-11-16T07:17:43Z","message":"|                               CONNECTIVITY PRE-CHECKS                               |"}
{"level":"info","time":"2026-11-16T07:17:43Z","message":"+-------------------------------------------------------------------------------------+"}
{"level":"info","time":"2026-11-16T07:17:43Z","message":"|  COMPONENT         TARGET                     STATUS  DETAILS                       |"}
{"level":"info","time":"2026-11-16T07:17:43Z","message":"|  DNS Resolution    region1.v2.argotunnel.com  PASS    DNS Resolved successfully     |"}
{"level":"info","time":"2026-11-16T07:17:43Z","message":"|  DNS Resolution    region2.v2.argotunnel.com  PASS    DNS Resolved successfully     |"}
{"level":"info","time":"2026-11-16T07:17:43Z","message":"|  UDP Connectivity  region1.v2.argotunnel.com  PASS    QUIC connection successful    |"}
{"level":"info","time":"2026-11-16T07:17:43Z","message":"|  UDP Connectivity  region2.v2.argotunnel.com  PASS    QUIC connection successful    |"}
{"level":"info","time":"2026-11-16T07:17:43Z","message":"|  TCP Connectivity  region1.v2.argotunnel.com  PASS    HTTP/2 connection successful  |"}
{"level":"info","time":"2026-11-16T07:17:43Z","message":"|  TCP Connectivity  region2.v2.argotunnel.com  PASS    HTTP/2 connection successful  |"}
{"level":"info","time":"2026-11-16T07:17:43Z","message":"|  Cloudflare API    api.cloudflare.com:443     PASS    API is reachable              |"}
{"level":"info","time":"2026-11-16T07:17:43Z","message":"|                                                                                     |"}
{"level":"info","time":"2026-11-16T07:17:43Z","message":"|  SUMMARY: Environment is healthy. cloudflared will use 'quic' as primary protocol.  |"}
{"level":"info","time":"2026-11-16T07:17:43Z","message":"+-------------------------------------------------------------------------------------+"}
{"level":"info","run_id":"6fe81e16-ebb3-485c-8c08-a628dc24f9ad","component":"DNS Resolution","target":"region1.v2.argotunnel.com","status":"pass","details":"DNS Resolved successfully","time":"2026-11-16T07:17:43Z","message":"precheck"}
{"level":"info","run_id":"6fe81e16-ebb3-485c-8c08-a628dc24f9ad","component":"DNS Resolution","target":"region2.v2.argotunnel.com","status":"pass","details":"DNS Resolved successfully","time":"2026-11-16T07:17:43Z","message":"precheck"}
{"level":"info","run_id":"6fe81e16-ebb3-485c-8c08-a628dc24f9ad","component":"UDP Connectivity","target":"region1.v2.argotunnel.com","status":"pass","details":"QUIC connection successful","time":"2026-11-16T07:17:43Z","message":"precheck"}
{"level":"info","run_id":"6fe81e16-ebb3-485c-8c08-a628dc24f9ad","component":"UDP Connectivity","target":"region2.v2.argotunnel.com","status":"pass","details":"QUIC connection successful","time":"2026-11-16T07:17:43Z","message":"precheck"}
{"level":"info","run_id":"6fe81e16-ebb3-485c-8c08-a628dc24f9ad","component":"TCP Connectivity","target":"region1.v2.argotunnel.com","status":"pass","details":"HTTP/2 connection successful","time":"2026-11-16T07:17:43Z","message":"precheck"}
{"level":"info","run_id":"6fe81e16-ebb3-485c-8c08-a628dc24f9ad","component":"TCP Connectivity","target":"region2.v2.argotunnel.com","status":"pass","details":"HTTP/2 connection successful","time":"2026-11-16T07:17:43Z","message":"precheck"}
{"level":"info","run_id":"6fe81e16-ebb3-485c-8c08-a628dc24f9ad","component":"Cloudflare API","target":"api.cloudflare.com:443","status":"pass","details":"API is reachable","time":"2026-11-16T07:17:43Z","message":"precheck"}
{"level":"info","run_id":"6fe81e16-ebb3-485c-8c08-a628dc24f9ad","hard_fail":false,"suggested_protocol":"quic","time":"2026-11-16T07:17:43Z","message":"precheck complete"}
```

- failed to request quick Tunnel / Unauthorized → 网络受限，改用局域网版部署包。
- no more connections active and exiting → cloudflared 退出了，手动拉起：`Start-ScheduledTask -TaskName 'DSH-Phone-Tunnel-5289'`。

### 第 8 步 · 插件安装日志

```

```

---

## 四、判定「部署成功」的硬标准

修好后重跑：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "E:\deepseek工作区\phone-armor\双端互联（公网版）\Deploy.ps1" -Mode Public -Port 5289
```

三条全中才算成功：

1. 输出里出现 `校验：局域网 index 200`
2. 公网模式还要出现 `校验：公网 index 200 + /api 200（信任栅栏通过）`
3. 末尾打印 `http://<内网IP>:5289/?token=...`（公网模式另有一条 `https://...trycloudflare.com/?token=...`）

自己验也行。注意：/api 必须先 GET 换 cookie 再 POST，直接 POST 只会得到 401。

```powershell
$s = New-Object Microsoft.PowerShell.Commands.WebRequestSession
(Invoke-WebRequest 'http://192.168.1.2:5289/' -WebSession $s -UseBasicParsing -MaximumRedirection 5).StatusCode
$h = @{ 'Origin'='http://192.168.1.2:5289'; 'Referer'='http://192.168.1.2:5289/'; 'Content-Type'='application/json' }
$b = '{"type":"client-request","rpcId":"p","method":"agentPresets/list","payload":{"args":{}}}'
(Invoke-WebRequest 'http://192.168.1.2:5289/api/agentPresets/list' -Method Post -Body $b -Headers $h -WebSession $s -UseBasicParsing).StatusCode
```

两条都应返回 200。

---

## 五、修完之后请你（agent）做三件事

1. 把实际执行的修复命令与结论，一条一句写进 `E:\deepseek工作区\phone-armor\双端互联（公网版）\diagnostics\AGENT-FIX-DONE.md`
2. 把最终可用的链接（局域网 / 公网）也抄进那个文件，方便用户直接复制到手机
3. 如果是**脚本本身的缺陷**（某段逻辑在你这台机器不成立），把期望行为写清楚，用户会反馈给部署包作者

---

> 本文件由 `Deploy.ps1` 自动生成；`E:\deepseek工作区\phone-armor\双端互联（公网版）\diagnostics\env-snapshot.txt` 是同一时刻的机器可读快照（纯文本）。