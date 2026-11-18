# 移动端破甲（DSH Go 本机引擎）

不依赖电脑：把破甲装进手机自己的 DSH 引擎里。

DSH Go 的「本机引擎」是一个 PRoot Ubuntu 24.04 + Node，跑的就是官方 `@deepseek-ai/dsh`——**同一份补丁表能逐项命中**，所以电脑上那份破甲可以原样搬到手机。

---

## 一、前置条件

| 项 | 要求 |
|---|---|
| App | DSH Go（Android 8+），**已初始化「本机运行环境」**（约 1 GB） |
| 引擎 | 在 App 里至少启动过一次本机引擎（否则 `~/.dsh` 不存在） |
| 环境 | PRoot 里能执行 `sh`、`tar`、`node`（Ubuntu 自带；node 由 App 提供） |
| 网络 | **不需要**（tgz 与注入文本都在本包内，SHA256 已固定） |

## 二、把包传到手机

任选：微信文件传输助手 / 网盘 / USB 拷贝 / App 的文件导入。
建议解压到 `/root/phone-armor`（PRoot 内路径），例如：

```sh
mkdir -p /root/phone-armor
# 把 5 个文件放进去后：
cd /root/phone-armor
```

## 三、两步安装

```sh
# 1) 只读探测（不改任何东西）
sh verify-on-phone.sh

# 2) 离线安装
sh install-on-phone.sh
```

`verify-on-phone.sh` 会打印：架构 / node 候选 / **dsh 启动器候选**（PATH → `/opt/dsh-app/*` → `find` 搜索 `*@deepseek-ai/dsh*/bin.js`）/ `DSH_HOME` / `profiles` / `/etc/dsh-app/dsh-web.patch.yml` / 正在跑的 dsh 进程 / 磁盘余量。

**先看它的输出**：如果 `[dsh launcher candidates]` 全是空，说明 App 把引擎放在终端看不到的目录，需要另走一条路（把输出发出来按实际情况改）。

`install-on-phone.sh` 做六件事：
1. 校验 tgz 的 SHA256（`ae22bb7d…3058`，与官方 `SHA256SUMS.txt` 一致）
2. 探 node（≥18）与 dsh 启动器
3. 解包到临时目录
4. 离线安装 `dsh-purge-community 1.6.91`（官方 `scripts/install.sh --archive --sha256 --version`，Linux 走 `web` profile）
5. 把 `prompt-inject.md`（25128 字节）覆盖进 `$DSH_HOME/prompt-inject.md`，原文件自动备份
6. 跑 `dsh-purge --apply` 并打印 `--status`

## 四、生效与验证

回 App：**设置 → 本机引擎 → 停止 → 启动**（让补丁加载），然后：

```sh
node "$DSH_HOME/profiles/web/node_modules/dsh-purge-community/bin/dsh-purge.js" --status
```

补丁数与电脑一致即成功（电脑上实测 65/71 applied，其余为 `skipped` 的可选项）。

回滚：

```sh
node "$DSH_HOME/profiles/web/node_modules/dsh-purge-community/bin/dsh-purge.js" --revert
```

## 五、三个必须记住的坑

| 坑 | 后果 | 对策 |
|---|---|---|
| **App 升级引擎会替换内置 DSH/Node/pnpm** | 补丁被覆盖，破甲失效 | 升级后重跑 `--apply` 那一节 |
| **重置运行环境会清掉 `/root`** | purge、`prompt-inject.md`、工作区全没 | 重置前先把 `prompt-inject.md` 和备份导出 |
| **连续两次启动失败 → 安全模式（不加载插件）** | 看着像"破甲把引擎搞挂了" | 这是 App 的保护，修好后点「恢复正常模式」 |

另外：DSH Go 本机引擎固定 `dsh web --patch /etc/dsh-app/dsh-web.patch.yml --host 127.0.0.1 --port 3080`。我们改的是 `node_modules` 代码层，与这个 patch 层不冲突，但**同一插件的 config 项可能被 App 的 patch 覆盖**。

## 六、文件说明

| 文件 | 作用 |
|---|---|
| `verify-on-phone.sh` | 只读探测，**先跑这个** |
| `install-on-phone.sh` | 离线安装破甲 |
| `dsh-purge-community-1.6.91.tgz` | 官方 release 包，2107052 字节 |
| `SHA256SUMS.txt` | 官方校验和 |
| `prompt-inject.md` | 电脑上正在用的破甲注入文本，25128 字节 |

两个 `.sh` 已规范成 **LF 换行**。若经过某些 Windows 工具中转变成 CRLF，`sh` 会报 `^M: not found`——改用 `dos2unix` 或 `sed -i 's/\r$//' *.sh` 修一下。

## 七、两个场景怎么选

| | 移动端破甲（本包） | 双端互联（公网/局域网） |
|---|---|---|
| 引擎位置 | 手机本地 | 电脑 |
| 电脑要不要开 | 不用 | 必须 |
| 插件原生界面 | 完整 | 完整（浏览器版） |
| 手机操控（读屏/点按） | 支持 | 不支持 |
| 文件/工作区 | 手机的 | 电脑的 |
| 命令执行 | 手机 PRoot 里 | 电脑上 |
