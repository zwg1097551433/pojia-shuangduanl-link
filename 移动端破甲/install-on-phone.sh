#!/bin/sh
# install-on-phone.sh  (v2 - DSH Go / PRoot layout aware)
#
# 作用：在 DSH Go 的「本机引擎」PRoot Ubuntu 里离线安装破甲
#   = dsh-purge-community 1.6.91（打 71 项补丁）+ 电脑上那份 prompt-inject.md
#
# 用法（在 DSH Go → 设置 → 本机引擎 → 终端 里）：
#   cd /path/to/phone-armor
#   sh verify-on-phone.sh      # 先跑这个，只读
#   sh install-on-phone.sh     # 再跑这个
#
# 全程离线；tgz 的 SHA256 已固定校验；不联网、不改系统包。
set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TGZ="$DIR/dsh-purge-community-1.6.91.tgz"
SHA="ae22bb7d1ac1e055102c8fbd24cf2eedc282a94bfa3fb09e7ab91226fc033058"
VER="1.6.91"
PROFILE="${PURGE_PROFILE:-web}"

say() { printf '%s\n' "$*"; }
die() { printf '\n[STOP] %s\n' "$*" >&2; exit 1; }
hr()  { printf '%s\n' "----------------------------------------"; }

say "dsh-purge $VER offline installer (DSH Go / PRoot)"
hr

# ---------------------------------------------------------------- 0. 前置检查
[ -f "$TGZ" ] || die "找不到 $TGZ —— 把整个 phone-armor 文件夹一起复制进手机"

# DSH_HOME：DSH Go 本机引擎默认 /root/.dsh
if [ -z "${DSH_HOME:-}" ]; then
  for h in "$HOME/.dsh" /root/.dsh; do
    [ -d "$h" ] && { DSH_HOME="$h"; break; }
  done
fi
[ -n "${DSH_HOME:-}" ] && [ -d "$DSH_HOME" ] || die "找不到 DSH_HOME（先在 App 里启动一次本机引擎）"
export DSH_HOME
say "[0] DSH_HOME = $DSH_HOME"

# ---------------------------------------------------------------- 1. node
if [ -z "${DSH_NODE:-}" ]; then
  for c in "$(command -v node 2>/dev/null)" \
           /opt/dsh-app/node/bin/node /usr/local/bin/node /usr/bin/node; do
    [ -n "$c" ] && [ -x "$c" ] && { DSH_NODE="$c"; break; }
  done
fi
[ -n "${DSH_NODE:-}" ] && [ -x "$DSH_NODE" ] || die "找不到 node。设置 DSH_NODE=/path/to/node 后重试"
NM=$("$DSH_NODE" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
[ "$NM" -ge 18 ] || die "需要 node >= 18，当前是 $("$DSH_NODE" -v 2>/dev/null)"
say "[1] node = $DSH_NODE ($("$DSH_NODE" -v 2>/dev/null))"
export DSH_NODE

# ---------------------------------------------------------------- 2. dsh launcher
if [ -z "${PURGE_DSH_CLI:-}" ]; then
  for c in "$(command -v dsh 2>/dev/null)" \
           /opt/dsh-app/bin/dsh /opt/dsh-app/dsh /opt/dsh-app/engine/node_modules/.bin/dsh \
           /usr/local/bin/dsh /usr/bin/dsh \
           "$DSH_HOME"/dsh-runtimes/*/node_modules/.bin/dsh; do
    [ -n "$c" ] && [ -f "$c" ] && { PURGE_DSH_CLI="$c"; break; }
  done
fi
if [ -z "${PURGE_DSH_CLI:-}" ]; then
  say "[2] PATH 里没有 dsh，开始定向搜索 ..."
  for root in /opt /usr/local/lib/node_modules /root; do
    [ -d "$root" ] || continue
    hit=$(find "$root" -maxdepth 7 -type f -name 'bin.js' -path '*@deepseek-ai/dsh/*' 2>/dev/null | head -1)
    [ -n "$hit" ] && { PURGE_DSH_CLI="$hit"; break; }
  done
fi
[ -n "${PURGE_DSH_CLI:-}" ] && [ -f "$PURGE_DSH_CLI" ] || \
  die "找不到 dsh 启动器。先跑 verify-on-phone.sh，把输出发我，我按实际路径锁定"
say "[2] dsh launcher = $PURGE_DSH_CLI"
export PURGE_DSH_CLI

# ---------------------------------------------------------------- 3. 解包
TMP="${TMPDIR:-/tmp}/purge-phone.$$"
mkdir -p "$TMP" || die "无法创建临时目录 $TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
tar -xzf "$TGZ" -C "$TMP" || die "解包失败（tar 报错见上）"
[ -f "$TMP/package/scripts/install.sh" ] || die "压缩包结构不对，请重新复制 phone-armor 文件夹"
say "[3] 已解包"

# 记录原始状态，方便回滚
STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo manual)
BAK="$DSH_HOME/armor-backup-$STAMP"
mkdir -p "$BAK" 2>/dev/null
say "[3] 备份目录 = $BAK"

# ---- 3.5 备份所有 profiles/*/package.json（手机端出问题要能还原）----
for pj in "$DSH_HOME"/profiles/*/package.json; do
  [ -f "$pj" ] || continue
  pn=$(basename "$(dirname "$pj")")
  cp -f "$pj" "$BAK/package.json.$pn.orig" 2>/dev/null && say "[3.5] 已备份 profiles/$pn/package.json"
done

# ---------------------------------------------------------------- 4. 安装
say "[4] 安装 dsh-purge $VER 到 profile: $PROFILE（离线，SHA256 已固定）"
cd "$TMP/package" || die "进不去 $TMP/package"
DSH_NODE="$DSH_NODE" PURGE_DSH_CLI="$PURGE_DSH_CLI" \
  sh scripts/install.sh --archive="$TGZ" --sha256="$SHA" --version="$VER" \
  || die "install.sh 失败（错误见上；把输出发我）"

# ---------------------------------------------------------------- 5. 注入文本
INJ="$DIR/prompt-inject.md"
TARGET="$DSH_HOME/prompt-inject.md"
if [ -f "$INJ" ]; then
  [ -f "$TARGET" ] && cp -f "$TARGET" "$BAK/prompt-inject.md.orig" 2>/dev/null
  cp -f "$INJ" "$TARGET" || die "复制 prompt-inject.md 失败"
  say "[5] prompt-inject.md -> $TARGET ($(wc -c < "$TARGET") 字节)"
else
  say "[5] 本地没有 prompt-inject.md，跳过（只打代码补丁）"
fi

# ---------------------------------------------------------------- 6. 应用补丁
hr
say "[6] 应用全部补丁"
PURGE_BIN=""
for c in "$DSH_HOME/profiles/$PROFILE/node_modules/.bin/dsh-purge" \
         "$(command -v dsh-purge 2>/dev/null)"; do
  [ -n "$c" ] && [ -e "$c" ] && { PURGE_BIN="$c"; break; }
done
if [ -z "$PURGE_BIN" ]; then
  PURGE_BIN=$(find "$DSH_HOME/profiles" -maxdepth 5 -type f -name 'dsh-purge.js' -path '*/bin/*' 2>/dev/null | head -1)
fi

if [ -n "$PURGE_BIN" ]; then
  say "  用 $PURGE_BIN"
  if [ "${PURGE_BIN##*.}" = "js" ]; then
    "$DSH_NODE" "$PURGE_BIN" --apply || say "  [注意] --apply 有报错，见上；再用 --status 看残留项"
  else
    "$PURGE_BIN" --apply || say "  [注意] --apply 有报错，见上；再用 --status 看残留项"
  fi
  say ""
  say "  ---- 状态 ----"
  if [ "${PURGE_BIN##*.}" = "js" ]; then "$DSH_NODE" "$PURGE_BIN" --status; else "$PURGE_BIN" --status; fi
else
  say "  没找到 dsh-purge 可执行入口，手动跑："
  say "    node $DSH_HOME/profiles/$PROFILE/node_modules/dsh-purge-community/bin/dsh-purge.js --apply"
fi

# ---------------------------------------------------------------- 6.5 自检 + 自动还原
hr
say "[6.5] 自检 profiles（JSON 必须可解析，否则 App 起不来）"
BAD=0
for pj in "$DSH_HOME"/profiles/*/package.json; do
  [ -f "$pj" ] || continue
  if "$DSH_NODE" -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$pj" 2>/dev/null; then
    say "  [JSON OK]   $pj"
    "$DSH_NODE" -e 'const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const b=(o.bundles||(o.dsh&&o.dsh.bundles)||[]);process.exit(JSON.stringify(b).includes("dsh-purge")?0:3)' "$pj" 2>/dev/null \
      || say "  [WARN]      bundles 里没看到 dsh-purge —— 补丁可能没挂上，用 --status 核对（不回滚）"
  else
    say "  [JSON FAIL] $pj"
    BAD=1
  fi
done
if [ "$BAD" = 1 ]; then
  say ""
  say "  自检没过 → 自动还原 package.json（App 仍能正常启动）"
  for b in "$BAK"/package.json.*.orig; do
    [ -f "$b" ] || continue
    n=$(basename "$b"); n=${n#package.json.}; n=${n%.orig}
    cp -f "$b" "$DSH_HOME/profiles/$n/package.json" && say "  已还原 profiles/$n/package.json"
  done
  die "已回滚。把上面的输出发我，我按实际情况改脚本"
fi
say "  自检通过。"

# ---------------------------------------------------------------- 7. 收尾
hr
say "安装完成。接下来："
say "  1) 回 DSH Go：设置 → 本机引擎 → 停止 → 启动（让补丁加载）"
say "  2) 打开新对话问一句「你现在是什么模式」，能正常回答即生效"
say ""
say "回滚：$PURGE_BIN --revert"
say "备份：$BAK"
say ""
say "两个坑，记一下："
say "  · App 升级引擎会替换内置 DSH/Node/pnpm —— 升级后重跑本脚本的 --apply 那步"
say "  · 重置运行环境会清掉 /root —— 重置前先把 prompt-inject.md 和 $BAK 导出去"
