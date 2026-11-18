#!/bin/sh
# verify-on-phone.sh — READ-ONLY probe. Run this FIRST inside DSH Go (本机引擎 → 终端).
# It prints what the armor install needs. Nothing is modified.
set -u

say() { printf '%s\n' "$*"; }
hr()  { printf '%s\n' "----------------------------------------"; }

hr
say "DSH Go / PRoot armor pre-check"
hr

# ---- OS / arch ----
say "[os]   $(uname -s 2>/dev/null) $(uname -r 2>/dev/null) $(uname -m 2>/dev/null)"
if [ -f /etc/os-release ]; then . /etc/os-release 2>/dev/null; say "[dist] ${PRETTY_NAME:-unknown}"; fi
say "[user] $(id 2>/dev/null)"
say "[home] HOME=${HOME:-unset}"

# ---- node ----
hr
say "[node candidates]"
for c in "$(command -v node 2>/dev/null)" /usr/local/bin/node /usr/bin/node \
         /opt/dsh-app/node/bin/node /opt/dsh-app/*/node/bin/node; do
  [ -n "$c" ] && [ -x "$c" ] && say "  OK  $c  ->  $("$c" -v 2>/dev/null)"
done
[ -z "$(command -v node 2>/dev/null)" ] && say "  PATH node: none"

# ---- dsh launcher ----
hr
say "[dsh launcher candidates]"
for c in "$(command -v dsh 2>/dev/null)" /usr/local/bin/dsh /usr/bin/dsh /opt/dsh/bin/dsh \
         "$HOME/.dsh/dsh-runtimes/current/node_modules/.bin/dsh"; do
  [ -n "$c" ] && [ -e "$c" ] && say "  OK  $c  ($(ls -l "$c" 2>/dev/null | sed 's/.*-> //'))"
done
say "  -- deeper search (bounded) --"
for d in /opt /usr/local/lib/node_modules /root /etc/dsh-app; do
  [ -d "$d" ] && find "$d" -maxdepth 6 -name 'bin.js' -path '*dsh*' 2>/dev/null | head -8 | sed 's/^/  bin.js: /'
done
for d in /opt /etc/dsh-app; do
  [ -d "$d" ] && find "$d" -maxdepth 5 -type d -name 'dsh-app' 2>/dev/null | head -5 | sed 's/^/  dir:    /'
done

# ---- DSH_HOME ----
hr
say "[DSH_HOME]"
for h in "${DSH_HOME:-}" "$HOME/.dsh" /root/.dsh; do
  [ -n "$h" ] && [ -d "$h" ] && say "  exists: $h  ($(ls -1 "$h" 2>/dev/null | tr '\n' ' '))"
done
say "  prompt-inject.md:"
for h in "${DSH_HOME:-}" "$HOME/.dsh" /root/.dsh; do
  [ -n "$h" ] && [ -f "$h/prompt-inject.md" ] && say "    FOUND $h/prompt-inject.md  $(wc -c < "$h/prompt-inject.md") bytes"
done
say "  profiles:"
for h in "$HOME/.dsh" /root/.dsh; do
  [ -d "$h/profiles" ] && ls -1 "$h/profiles" 2>/dev/null | sed 's/^/    /'
done

# ---- engine layout hints ----
hr
say "[engine layout hints]"
[ -f /etc/dsh-app/dsh-web.patch.yml ] && say "  /etc/dsh-app/dsh-web.patch.yml  $(wc -c < /etc/dsh-app/dsh-web.patch.yml) bytes"
[ -d /opt/dsh-app ] && say "  /opt/dsh-app -> $(ls -1 /opt/dsh-app 2>/dev/null | tr '\n' ' ')"
[ -d /opt/dsh-app/phone ] && say "  /opt/dsh-app/phone -> $(ls -1 /opt/dsh-app/phone 2>/dev/null | tr '\n' ' ')"
say "  running dsh processes:"
ps -ef 2>/dev/null | grep -i '[d]sh' | head -6 | sed 's/^/    /'

# ---- existing purge ----
hr
say "[existing dsh-purge]"
found=0
for p in "$HOME/.dsh/profiles"/*/node_modules/dsh-purge-community /opt/dsh-app/*/node_modules/dsh-purge-community; do
  [ -d "$p" ] && { say "  installed: $p"; found=1; }
done
[ "$found" = 0 ] && say "  not installed yet"

# ---- storage ----
hr
say "[disk]"
df -h / /root 2>/dev/null | sed 's/^/  /'
say "[sdcard]"
[ -d /sdcard ] && say "  /sdcard reachable" || say "  /sdcard not mounted in this PRoot (use App 内文件导出)"

hr
say "Send this whole output back — the installer gets pinned to these exact paths."
