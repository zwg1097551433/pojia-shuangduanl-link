# 双端互联（公网版）

让手机在**任意网络（4G / 别的 WiFi）**上使用这台电脑上已破甲的 DSH。

手机打开的是一个网页前端，真正的引擎、文件系统、shell 都在这台电脑上跑；Cloudflare 隧道只负责把公网流量送进来。

---

## 一、前置条件

| 项 | 要求 |
|---|---|
| 系统 | Windows 10/11 |
| DSH | 桌面版已安装且**已破甲**（`dsh-purge` 打过多项补丁） |
| 权限 | 管理员（脚本会自行弹 UAC 提权） |
| 状态 | **DeepSeek Harness 至少启动过一次**（脚本靠运行中的进程定位安装目录） |
| 网络 | 能访问 `github.com`（首次下载 cloudflared 需要；部署包里已带则不需要） |

## 二、部署

1. 把**整个文件夹**复制到目标电脑（不要只拷 `Deploy.ps1`，`payload\` 和 `bin\` 要一起）
2. 双击 **`一键部署.bat`**
3. 等 20–90 秒，窗口里出现三行：

```
校验：局域网 index 200
校验：公网 index 200 + /api 200（信任栅栏通过）
公网（任意网络 / 4G）
  https://xxxx.trycloudflare.com/?token=yyyy
```

4. 把那条 `https://...` 整条复制到手机浏览器**地址栏**（不是搜索框），回车

首次可能白屏或 `530`，等 30–60 秒刷新一两次即正常。

## 三、手机侧使用要点

- **token 会变**：每次重启 web 都会换。链接失效（401）时回电脑跑 `重新取链接.bat` 拿新链接。
- **cookie 有效 30 天**：同一个域名第二次访问可以不带 token。
- **域名会变**：每次重建隧道 Cloudflare 都分配新域名，此时旧 cookie 失效。
- **同一会话别两端同时操作**：DSH 有写锁，会报 `session/writer-owned`。手机上新建会话即可。

## 四、目录结构

```
双端互联（公网版）\
  Deploy.ps1                主脚本（UTF-8 带 BOM，勿用记事本另存为 ANSI）
  一键部署.bat               部署（自动提权）
  重新取链接.bat             token 轮换后取新链接
  卸载.bat                   删任务、停进程（桌面 DSH 不受影响）
  bin\cloudflared.exe       隧道客户端（离线可用）
  payload\
    dsh-purge-community-1.6.91.tgz     web profile 没装破甲插件时自动补齐
    agent-presets\                     红队模式 / 无限制模式预设
  phone-url.txt              局域网链接（每次部署重写）
  phone-url-remote.txt       公网链接（每次部署重写）
```

## 五、它做了什么（便于排错）

1. 从运行中的 `DeepSeek Harness.exe` 反推安装目录和 `bin.js`，**不写死路径**
2. 取 `DSH_HOME`（默认 `%USERPROFILE%\.dsh`）、探测局域网 IP
3. 端口 5288 被占则自动向上找空闲端口（任务名带端口，公网版/局域网版可共存）
4. 检查 web profile 是否装了 `dsh-purge-community`，没装则用 DSH 自带 pnpm 装 + 注册 bundle
5. 复制红队/无限制预设（仅在缺失时）
6. 注册两个计划任务（S4U 主体、登录自启、崩溃自动重启）：
   - `DSH-Phone-Tunnel-5288` → cloudflared quick tunnel
   - `DSH-Phone-Web-5288` → `wscript` 启动 web（无控制台，不会被 Ctrl+C 波及）
7. 从日志抓域名和 token，拼链接，最后用**正确姿势**校验：
   先 `GET /?token=` 换 cookie，再 `POST /api/...`（直接 POST 只会得到 401）

## 六、排错

| 现象 | 原因 | 处理 |
|---|---|---|
| 手机 `403`，弹窗 `directoryPicker/list failed` | 浏览器 `Origin` 与 `Host` 不一致 | 确认 web 启动参数含 `--trusted-host <当前域名>`；换域名后必须重跑部署 |
| 手机 `401` | 链接缺 `?token=` 或 token 已轮换 | 跑 `重新取链接.bat` |
| 手机 `530` / `1033` | 边缘未就绪 / 隧道进程没了 | 刷新等 60 秒；还不行看「任务计划程序」里 `DSH-Phone-Tunnel-5288` 是否 Running |
| 手机 `502` | web 进程没了 | 看 `%USERPROFILE%\.dsh\web-5288.log`；任务应自动重启 |
| 部署时提示「端口被占用」 | 上次的实例没退 | 先跑 `卸载.bat` |
| 脚本报语法错误、中文乱码 | 文件被存成了 ANSI/UTF-8 无 BOM | 重新复制原始 `Deploy.ps1`（UTF-8 带 BOM） |

## 七、换一台电脑

整套文件夹可直接搬运。目标机要求：Windows、已破甲 DSH、启动过一次桌面版。跑 `一键部署.bat` 即可，路径全部自适应。

## 八、安全提醒

这个链接 + token **等于这台电脑的完全控制权**（该运行时无沙箱、无审批）。只发给自己，用完可以 `卸载.bat` 关闭公网入口。

---

## 九、AI 自修复机制（核心设计）

目标电脑上跑着**已破甲的 DeepSeek**——它就是最好的修理工。所以脚本不硬扛所有环境差异，而是"卡住就把话交给它"。

| 情况 | 脚本行为 | 你要做的 |
|---|---|---|
| 全部成功、无告警 | 只打印链接 | 直接用 |
| 成功但有告警（公网未通、`/api` 不符） | 额外生成 `diagnostics\AGENT-FIX.md` | 手机打不开时，把这个文件拖进 DeepSeek |
| 关键步骤失败 | 生成交接单 + 退出码 2 | 同上，让它按剧本修 |
| 想先体检 | `Deploy.ps1 -SelfCheck`（不改任何东西，6 秒） | 同上 |

关键失败点：找不到 DSH 安装目录 / `DSH_HOME` 不存在 / 端口 5288-5328 全占 / cloudflared 不可用 / 隧道拿不到域名 / web 没打印 token。

### 交接单里有什么

1. **执行结果**：逐项 `OK` / `FAIL` + 失败信息
2. **环境事实表**：DSH 路径、`DSH_HOME`、profiles、purge 安装状态、presets、node/pnpm、cloudflared 三处位置、端口占用、防火墙、**系统代理**（这个会拖死 QUIC）、计划任务状态
3. **8 步修复剧本**：每步给命令、期望结果、不符合时怎么办
4. **成功判据**：三条硬标准，附手动验证脚本（含"必须先 GET 换 cookie 再 POST `/api`"这个坑）
5. **收尾要求**：让 AI 把修复过程写进 `AGENT-FIX-DONE.md`，并抄上最终链接

同目录还有 `diagnostics\env-snapshot.txt`——纯文本快照，AI 直接读。

### 实测数据（本机）

```
-Deploy.ps1 -SelfCheck        6.6 秒，生成 12295 字节交接单
-Deploy.ps1 -Mode Public      28 秒，公网 index 200 + /api 200
```

## 十、脚本自己踩过的坑（都已修）

| 坑 | 现象 | 处理 |
|---|---|---|
| `ConvertTo-Json` 在 PS 5.1 上对复杂哈希表**卡死** | 自检 4 分钟不返回 | 快照改成纯文本 `env-snapshot.txt`，去掉该依赖 |
| 双引号 here-string 里的 `` `0 `` | `0xC000013A` 变成 NUL 字符，md 被识别为二进制 | 交接单改用单引号模板 + 占位符替换 |
| 端口避让后只清理"新端口" | 旧实例堆积，端口一路往上漂 | 端口占用者若是自己的 web，直接杀掉复用 |
| `cmd` 中转启动进程 | 任务返回 `0xC000013A`，隧道被 Ctrl+C 波及 | 隧道直接作为任务 Action；web 用 `wscript`（GUI，无控制台） |
| `wscript` 启动即返回 | 任务变 `Ready`，崩溃不重启 | VBS 改阻塞 `sh.Run(...,True)` + `WScript.Quit 1` |
| `$home` 只读自动变量 | 变量写不进，`DSH_HOME` 传错 | 全部改 `$DshHome` / `$homeDir` |
| `.ps1` 存成 UTF-8 无 BOM | PS 5.1 按 GBK 读，中文吃引号 → 满屏语法错误 | 统一 UTF-8 **带 BOM** |
| 校验时直接 POST `/api` | 401 误判为部署失败 | 先 GET 换 cookie，同会话再 POST |
| 清理 cloudflared 未按端口过滤 | 部署局域网版把公网版隧道杀了 | 命令行按 `:$Port` 匹配 |
