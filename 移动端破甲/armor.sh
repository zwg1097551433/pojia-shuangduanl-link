#!/bin/sh
# armor.sh — 破甲一键注入 / 自愈 / 回滚（DSH Go 本机引擎 · PRoot Ubuntu）
#
#   sh armor.sh check      只读体检：定位 HOME / node / @deepseek-ai / 当前补丁数
#   sh armor.sh install    一键注入（幂等：已就绪直接跳过）
#   sh armor.sh repair     强制重打（App 升级引擎 / 补丁被覆盖之后用）
#   sh armor.sh status     只看补丁数
#   sh armor.sh revert     回滚（撤补丁 + 从 bundles 摘除）
#
# 设计要点：
#   · 手机上没有 pnpm，所以不走官方 bootstrap，改为「解包 → 落 node_modules → 写 profile.bundles」；
#   · 包内 lib/ 全部是相对引用 + node: 内建，顶层零第三方依赖，因此落位后可直接跑；
#   · 只改 profile package.json 的 dsh.profile.bundles，不动 dependencies（避免 pnpm-lock 不一致）；
#   · 任何一步失败 → 还原 package.json；备份留在 $DSH_HOME/armor-backup-<时间戳>/。
set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# payload/ 布局（git 仓库）与同目录布局（手工传包）都支持
TGZ=""; INJ=""
for c in "$DIR/payload/dsh-purge-community-1.6.91.tgz" "$DIR/dsh-purge-community-1.6.91.tgz"; do
  [ -f "$c" ] && { TGZ="$c"; break; }
done
for c in "$DIR/payload/prompt-inject.md" "$DIR/prompt-inject.md"; do
  [ -f "$c" ] && { INJ="$c"; break; }
done
SHA="ae22bb7d1ac1e055102c8fbd24cf2eedc282a94bfa3fb09e7ab91226fc033058"
VER="1.6.91"
PROFILE="${PURGE_PROFILE:-web}"
CMD="${1:-install}"
FORCE=""
[ "$CMD" = "repair" ] && { FORCE=1; CMD=install; }

say() { printf '%s\n' "$*"; }
hr()  { say "----------------------------------------"; }
die() { printf '\n[STOP] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 探测
find_home() {
  for h in "${DSH_HOME:-}" "$HOME/.dsh" /root/.dsh; do
    [ -n "$h" ] && [ -f "$h/profiles/$PROFILE/package.json" ] && { printf '%s' "$h"; return 0; }
  done
  return 1
}

find_node() {
  for c in "$(command -v node 2>/dev/null)" /opt/dsh-app/node/bin/node \
           /opt/dsh-app/*/node/bin/node /usr/local/bin/node /usr/bin/node; do
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

find_aibase() {
  # 1) 固定候选：这些位置覆盖了 DSH Go 的全部常见布局，优先走它们
  for d in "${DSH_BASE:-}" \
           /opt/dsh-app/node_modules/@deepseek-ai \
           /opt/dsh-app/*/node_modules/@deepseek-ai \
           /opt/dsh-app/*/*/node_modules/@deepseek-ai \
           "$H"/node_modules/@deepseek-ai \
           "$H"/dsh-runtimes/*/node_modules/@deepseek-ai \
           "$H"/profiles/*/node_modules/@deepseek-ai \
           /usr/local/lib/node_modules/@deepseek-ai \
           /usr/lib/node_modules/@deepseek-ai; do
    [ -n "$d" ] && [ -d "$d/dsh-agent-instructions/lib" ] && { printf '%s' "$d"; return 0; }
  done
  # 2) 兜底：只在 node_modules 这类窄目录里找，深度 3。
  #    不要在 $DSH_HOME 根上 find —— 那里有几千个 session 文件和 node_modules，手机上会卡几十秒。
  for root in /opt/dsh-app "$H/node_modules" "$H/dsh-runtimes" /usr/local/lib/node_modules; do
    [ -d "$root" ] || continue
    for d in $(find "$root" -maxdepth 3 -type d -name '@deepseek-ai' 2>/dev/null | head -5); do
      [ -d "$d/dsh-agent-instructions/lib" ] && { printf '%s' "$d"; return 0; }
    done
  done
  return 1
}

# ---------------------------------------------------------------- 基础定位
H=$(find_home) || die "找不到 DSH_HOME（\$HOME/.dsh 或 /root/.dsh）。先在 App 里启动一次本机引擎。"
N="${DSH_NODE:-$(find_node)}"
[ -n "$N" ] && [ -x "$N" ] || die "找不到 node。显式指定：DSH_NODE=/path/to/node sh armor.sh $CMD"
AI="${DSH_BASE:-$(find_aibase)}"
PJ="$H/profiles/$PROFILE/package.json"
DEST="$H/profiles/$PROFILE/node_modules/dsh-purge-community"
MARK="$H/dsh-purge/armor.state"

purge_status() {
  [ -f "$DEST/bin/dsh-purge.js" ] || return 1
  DSH_BASE="$AI" DSH_HOME="$H" "$N" "$DEST/bin/dsh-purge.js" --status 2>&1
}

applied_count() {
  purge_status 2>/dev/null | sed -n 's/.*补丁 \([0-9][0-9]*\)\/\([0-9][0-9]*\) 已清洗.*/\1/p' | head -1
}

banner() {
  hr
  say "dsh-purge $VER · 一键注入器（$CMD）"
  hr
  say "  DSH_HOME   $H"
  say "  profile    $PROFILE"
  say "  node       $N ($("$N" -v 2>/dev/null))"
  say "  @deepseek-ai  ${AI:-未定位（apply 可能报缺宿主，用 DSH_BASE=... 指定）}"
  say "  插件目录   $DEST"
}

# ---------------------------------------------------------------- 子命令
do_check() {
  banner
  if [ -f "$DEST/bin/dsh-purge.js" ]; then
    say "  已安装：$("$N" -p 'require("'$DEST'/package.json").version' 2>/dev/null)"
    say ""
    purge_status | head -20
    say ""
    say "  已清洗补丁：$(applied_count) 条"
  else
    say "  未安装（插件目录不存在）"
  fi
  [ -f "$MARK" ] && { say ""; say "  marker:"; sed 's/^/    /' "$MARK"; }
  say ""
  df -h "$H" 2>/dev/null | sed 's/^/  /'
  hr
}

do_status() {
  A=$(applied_count)
  if [ -z "$A" ]; then say "未安装或无法读取补丁状态"; exit 1; fi
  purge_status | sed -n '/补丁 .* 已清洗/p;/注入状态/p'
}

do_install() {
  banner
  [ -f "$TGZ" ] || die "缺少包：$TGZ"
  [ -f "$PJ" ]  || die "profile 未初始化：$PJ（先在 App 里启动一次本机引擎）"

  # --- 幂等：已是目标版本且补丁数达标 → 跳过 ---
  if [ -z "$FORCE" ] && [ -f "$DEST/bin/dsh-purge.js" ]; then
    A=$(applied_count)
    if [ -n "${A:-}" ] && [ "$A" -ge 60 ]; then
      say "[1] 已注入（$A 条补丁已清洗），跳过。"
      say "    要强制重打：sh armor.sh repair"
      return 0
    fi
    say "[1] 检测到旧安装但补丁不足（${A:-0} 条），继续修复。"
  fi

  # --- SHA256 ---
  GOT=$("$N" -e 'const c=require("crypto"),f=require("fs");process.stdout.write(c.createHash("sha256").update(f.readFileSync(process.argv[1])).digest("hex"))' "$TGZ" 2>/dev/null)
  [ "$GOT" = "$SHA" ] || die "tgz SHA256 不匹配：$GOT"
  say "[2] SHA256 OK"

  # --- 备份 ---
  STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || date +%s)
  BAK="$H/armor-backup-$STAMP"
  mkdir -p "$BAK" || die "无法创建备份目录 $BAK"
  cp -f "$PJ" "$BAK/package.json.orig" || die "备份 package.json 失败"
  [ -f "$H/prompt-inject.md" ] && cp -f "$H/prompt-inject.md" "$BAK/prompt-inject.md.orig"
  say "[3] 备份 → $BAK"

  # --- 解包落位 ---
  TMP="${TMPDIR:-/tmp}/armor.$$"
  rm -rf "$TMP"; mkdir -p "$TMP" || die "无法创建临时目录"
  tar -xzf "$TGZ" -C "$TMP" || die "解包失败"
  [ -f "$TMP/package/bin/dsh-purge.js" ] || die "包结构异常（缺 bin/dsh-purge.js）"
  mkdir -p "$H/profiles/$PROFILE/node_modules"
  rm -rf "$DEST.new"
  cp -a "$TMP/package" "$DEST.new" || die "复制到 node_modules 失败"
  [ -d "$DEST" ] && mv "$DEST" "$BAK/dsh-purge-community.old"
  mv "$DEST.new" "$DEST" || die "落位失败"
  rm -rf "$TMP"
  say "[4] 插件落位 → $DEST"

  # --- 注册 bundle（只动 bundles，不碰 dependencies）---
  "$N" -e '
    const fs = require("fs"), p = process.argv[1];
    const o = JSON.parse(fs.readFileSync(p, "utf8"));
    o.dsh = o.dsh || {};
    o.dsh.profile = o.dsh.profile || {};
    const b = o.dsh.profile.bundles = o.dsh.profile.bundles || [];
    if (!b.includes("dsh-purge-community")) b.push("dsh-purge-community");
    fs.writeFileSync(p, JSON.stringify(o, null, 2) + "\n");
  ' "$PJ" || die "写 profile package.json 失败"
  say "[5] profile.bundles 已登记 dsh-purge-community"

  # --- 注入正文 ---
  if [ -f "$INJ" ]; then
    cp -f "$INJ" "$H/prompt-inject.md" || die "写 prompt-inject.md 失败"
    say "[6] prompt-inject.md → $H/prompt-inject.md ($(wc -c < "$H/prompt-inject.md") 字节)"
  else
    say "[6] 包里没有 prompt-inject.md，跳过正文"
  fi

  # --- 应用 ---
  hr
  say "[7] 应用补丁"
  if [ -z "$AI" ]; then
    say "    [!] 未定位 @deepseek-ai —— 试试 DSH_BASE=<含 dsh-agent-instructions/lib 的目录>"
  fi
  DSH_BASE="$AI" DSH_HOME="$H" "$N" "$DEST/bin/dsh-purge.js" --apply
  APPLY_RC=$?

  # --- 自检 ---
  A=$(applied_count)
  if [ -z "${A:-}" ] || [ "$A" -lt 1 ]; then
    say ""
    say "[!] apply 之后读不到补丁数 → 还原 package.json（App 仍可正常启动）"
    cp -f "$BAK/package.json.orig" "$PJ"
    rm -rf "$DEST"
    die "已回滚。把上面的输出发我"
  fi
  mkdir -p "$H/dsh-purge" 2>/dev/null
  printf 'ver=%s\napplied=%s\nrc=%s\nat=%s\nai=%s\nhome=%s\n' \
    "$VER" "$A" "$APPLY_RC" "$STAMP" "$AI" "$H" > "$MARK"
  say ""
  hr
  say "完成：$A 条补丁已清洗（marker: $MARK）"
  say "  回 App：设置 → 本机引擎 → 停止 → 启动，让补丁加载"
  say "  回滚：sh armor.sh revert"
  hr
}

do_revert() {
  banner
  [ -f "$DEST/bin/dsh-purge.js" ] || die "没有安装（$DEST 不存在）"
  say "[1] 撤补丁"
  DSH_BASE="$AI" DSH_HOME="$H" "$N" "$DEST/bin/dsh-purge.js" --revert
  say "[2] 从 bundles 摘除"
  "$N" -e '
    const fs = require("fs"), p = process.argv[1];
    const o = JSON.parse(fs.readFileSync(p, "utf8"));
    const b = o?.dsh?.profile?.bundles;
    if (Array.isArray(b)) o.dsh.profile.bundles = b.filter((x) => x !== "dsh-purge-community");
    fs.writeFileSync(p, JSON.stringify(o, null, 2) + "\n");
  ' "$PJ" || say "  [!] 改 package.json 失败，手动摘除 dsh-purge-community"
  rm -f "$MARK"
  say ""
  say "回滚完成。插件目录保留在 $DEST（确认无误后可手动删）。"
  say "prompt-inject.md 按设计保留（用户文件）。"
}

case "$CMD" in
  check)   do_check ;;
  status)  do_status ;;
  install) do_install ;;
  revert)  do_revert ;;
  *) say "用法：sh armor.sh [check|install|repair|status|revert]"; exit 1 ;;
esac
