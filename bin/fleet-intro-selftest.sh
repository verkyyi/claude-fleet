#!/bin/bash
# fleet-intro-selftest.sh — the SSH login banner, shell/fleet-intro.sh (issues
# #1068, #1255).
#
# Builds fake FLEET_CONF_DIR trees and runs the REAL script against each, in zh
# and en, asserting every line ≤ 40 terminal columns (CJK = 2) and ZERO tmux
# calls (a PATH shim counts any):
#
#   A. 0 fleets            → "○ 未配置" + the INSTALL.md pointer, nothing else.
#   B. 2 fleets            → "⚠ 有 2 个" + `fleet-repo.sh fold` (#979), no repos.
#   C. 1 fleet, 1 repo     → "claude fleet · 1 个仓库", the fleet line, the hide
#                            line — and nothing about running / sessions / branch.
#   D. 1 fleet, 3 repos (+1 repeat, dropped) → "3 个仓库"; a LIVE tmux session
#        on the shim's socket changes nothing.
#   F. intro.d             → system dir then $CONF_DIR/intro.d, file order, lines
#        verbatim between the fleet line and the hide line; a failing / silent /
#        non-executable hook prints nothing.
#   G. intro.d language    → a hook's FLEET_UI_LANG is the resolved zh/en (conf
#        beats login locale), #1259.
#
#   E. shell/fleet-login.zsh (issues #1166, #1711), the ~/.zshrc block that shows
#      the banner and then opens the CLIENT for an SSH login: no $SSH_TTY / inside
#      $TMUX / non-interactive / ~/.hushfleet / ~/.hushfleet-attach → bin/fleet
#      NOT run; interactive SSH → bin/fleet run exactly once, never
#      fleet-attach.sh / cf, and the shell carries on after it (a failing client
#      too); a login without $SSH_TTY prints the banner byte for byte as
#      fleet-intro.sh itself does. `cf` (shell/cw.zsh) prints that it is folded
#      into fleet and runs bin/fleet (`--guide` → `fleet guide`). zsh absent →
#      E SKIPs.
#
# tmux never touches the operator's server: a PATH shim counts any call (there
# must be none), drops `-L <sess>` and routes it onto one throwaway -S socket,
# killed at exit. tmux absent → D skips only its live-session half. The real
# /usr/local/etc/claude-fleet/intro.d is swapped for a sandbox dir. Exit 0 = pass.
set -uo pipefail

# The banner is localized since #1188 (bin/fleet-ui-lang.sh: FLEET_UI_LANG, else the
# login locale) — pin the Chinese every case below asserts, so the runner's LANG
# is moot. Case E inherits it on both sides of its byte-for-byte pair.
export FLEET_UI_LANG=zh

here=$(cd "$(dirname "$0")" && pwd)
INTRO="$here/../shell/fleet-intro.sh"
[ -f "$INTRO" ] || { echo "FAIL: $INTRO missing"; exit 1; }

T=$(mktemp -d "${TMPDIR:-/tmp}/fleet-intro-st.XXXXXX")
SOCK="$T/tmux.sock"
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=1; }

# the shim: strip `-L <label>`, count the call, run it on the isolated socket
mkdir -p "$T/shim"
cat > "$T/shim/tmux" <<SHIM
#!/bin/sh
echo call >> "$T/calls"
[ "\${1:-}" = -L ] && shift 2
exec "${REAL_TMUX:-/nonexistent/tmux}" -S "$SOCK" "\$@"
SHIM
chmod +x "$T/shim/tmux"

# run <conf-dir> → banner with ANSI stripped, in $out
run() {
  : > "$T/calls"
  out=$(env -u TMUX FLEET_CONF_DIR="$1" PATH="$T/shim:$PATH" sh "$INTRO" 2>&1 \
        | sed "s/$(printf '\033')\[[0-9;]*m//g")
  rc=$?
}
has()    { case "$out" in *"$1"*) ok "$2" ;; *) bad "$2 — missing [$1]"; printf '%s\n' "$out" ;; esac; }
hasnot() { case "$out" in *"$1"*) bad "$2 — unexpected [$1]"; printf '%s\n' "$out" ;; *) ok "$2" ;; esac; }
mkfleet() { # <conf-dir> <sess> <repo> <branch>
  mkdir -p "$1/fleets/$2"
  printf 'FLEET_REPO="%s"\nFLEET_BASE_BRANCH="%s"\n' "$3" "$4" > "$1/fleets/$2/conf"
}
mkrepo() { # <conf-dir> <sess> <slug> <repo> <branch>
  mkdir -p "$1/fleets/$2/repos"
  printf 'FLEET_REPO=%s\nFLEET_BASE_BRANCH=%s\n' "$4" "$5" > "$1/fleets/$2/repos/$3.conf"
}

# a sandbox system intro.d, so the machine's real one (this mini ships a vnc
# hook there) never leaks into an assertion
export FLEET_INTRO_SYS_D="$T/sysd"
mkdir -p "$FLEET_INTRO_SYS_D"

# every line of $out ≤ 40 terminal columns (East Asian Wide/Fullwidth = 2)
narrow() {
  local w
  w=$(printf '%s\n' "$out" | python3 -c '
import sys, unicodedata
print(max([sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in l.rstrip("\n")) for l in sys.stdin] or [0]))' 2>/dev/null) \
    || { ok "$1: width SKIP (no python3)"; return; }
  [ "$w" -le 40 ] && ok "$1: widest line $w ≤ 40 cols" || { bad "$1: widest line $w > 40 cols"; printf '%s\n' "$out"; }
}
notmux() {
  local c; c=$(wc -l < "$T/calls" | tr -d ' ')
  [ "$c" -eq 0 ] && ok "$1: zero tmux calls" || bad "$1: $c tmux calls"
}
# both <label> <conf-dir> <zh-needle> <en-needle> — run zh + en, width + tmux each
both() {
  FLEET_UI_LANG=en run "$2"
  has "$4" "$1 (en)"; narrow "$1 (en)"; notmux "$1 (en)"
  run "$2"
  has "$3" "$1 (zh)"; narrow "$1 (zh)"; notmux "$1 (zh)"
}

echo "A. no fleet"
mkdir -p "$T/a/fleets"
both A "$T/a" "claude fleet ○ 未配置" "claude fleet ○ not set up"
has "见 ~/.claude/fleet/docs/INSTALL.md" "points at INSTALL.md"
hasnot "打开客户端" "no action line"
hasnot "hushfleet" "no hide line"

echo "B. two fleets"
mkfleet "$T/b" one o/one master; mkfleet "$T/b" two o/two master
both B "$T/b" "claude fleet ⚠ 有 2 个，只能留一个" "claude fleet ⚠ 2 fleets, keep one"
has "运行 fleet-repo.sh fold" "points at fold"
hasnot "o/one" "lists no repos"

echo "C. one fleet, one repo"
mkfleet "$T/c" idlefleet me/app main
both C "$T/c" "claude fleet · 1 个仓库" "claude fleet · 1 repo
fleet   open the client
hide: touch ~/.hushfleet"
want="claude fleet · 1 个仓库
fleet   打开客户端
隐藏：touch ~/.hushfleet"
[ "$out" = "$want" ] && ok "zh banner is exactly 3 lines" || { bad "zh banner"; printf 'got:\n%s\nwant:\n%s\n' "$out" "$want"; }
for x in me/app main 运行 未启动 会话 ───; do hasnot "$x" "no [$x]"; done
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc"

echo "D. one fleet, three repos (+ a repeat), live session changes nothing"
mkfleet "$T/d" live z/first master
mkrepo "$T/d" live second b/second develop
mkrepo "$T/d" live third a/third main
mkrepo "$T/d" live zdup z/first master          # repeats the conf's repo → dropped
run "$T/d"; cold=$out
if [ -n "$REAL_TMUX" ]; then
  "$REAL_TMUX" -S "$SOCK" new-session -d -s live -n hub
  "$REAL_TMUX" -S "$SOCK" new-window -d -t live -n issue-1
  "$REAL_TMUX" -S "$SOCK" set-option -w -t live:issue-1 @issue 1
fi
both D "$T/d" "claude fleet · 3 个仓库" "claude fleet · 3 repos"
[ "$out" = "$cold" ] && ok "running and stopped print the same banner" || bad "banner differs when running"
hasnot "z/first" "no repo names"

echo "F. intro.d hooks"
mkfleet "$T/f" hooked me/app main
mkdir -p "$T/f/intro.d"
printf '#!/bin/sh\necho "sys1"\n' > "$FLEET_INTRO_SYS_D/10-a"
printf '#!/bin/sh\necho "sys2  两行"\necho "sys2b"\n' > "$FLEET_INTRO_SYS_D/20-b"
printf '#!/bin/sh\necho partial; echo noise >&2; exit 3\n' > "$FLEET_INTRO_SYS_D/30-fail"
printf '#!/bin/sh\n:\n' > "$FLEET_INTRO_SYS_D/40-empty"
printf '#!/bin/sh\necho NOEXEC\n' > "$FLEET_INTRO_SYS_D/50-noexec"
printf '#!/bin/sh\necho "user1"\n' > "$T/f/intro.d/05-u"     # sorts first, runs after the system dir
chmod +x "$FLEET_INTRO_SYS_D/10-a" "$FLEET_INTRO_SYS_D/20-b" "$FLEET_INTRO_SYS_D/30-fail" \
         "$FLEET_INTRO_SYS_D/40-empty" "$T/f/intro.d/05-u"
run "$T/f"
want="claude fleet · 1 个仓库
fleet   打开客户端
sys1
sys2  两行
sys2b
user1
隐藏：touch ~/.hushfleet"
[ "$out" = "$want" ] && ok "hooks: system dir then conf dir, file order, between fleet and hide; failing/empty/non-exec silent" \
  || { bad "hooks"; printf 'got:\n%s\nwant:\n%s\n' "$out" "$want"; }
narrow F; notmux F
rm -f "$FLEET_INTRO_SYS_D"/*

echo "G. intro.d hooks get the RESOLVED banner language (#1259)"
# the fleet conf's FLEET_UI_LANG beats an en_US login locale; the hook sees the
# resolved zh/en, never the raw conf value or $LANG
printf '#!/bin/sh\necho "lang=$FLEET_UI_LANG"\n' > "$FLEET_INTRO_SYS_D/10-lang"
chmod +x "$FLEET_INTRO_SYS_D/10-lang"
for g in zh:zh_CN en:english auto:; do
  mkfleet "$T/g-${g%%:*}" glang me/app main
  [ -n "${g#*:}" ] && printf 'FLEET_UI_LANG="%s"\n' "${g#*:}" >> "$T/g-${g%%:*}/fleets/glang/conf"
done
# a real login has NO FLEET_UI_LANG in its env (this file exports zh above) — an
# exported one would make the script's own assignment exported and hide the bug
unset FLEET_UI_LANG
hasline() { printf '%s\n' "$out" | grep -qx "$1" && ok "$2" || { bad "$2 — no line [$1]"; printf '%s\n' "$out"; }; }
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 run "$T/g-zh"
hasline "lang=zh" "zh conf (zh_CN) under en_US login → hook sees exactly zh"; has "打开客户端" "  … under a zh banner"
LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 run "$T/g-en"
hasline "lang=en" "en conf (english) under zh_CN login → hook sees exactly en"; has "open the client" "  … under an en banner"
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 run "$T/g-auto"
hasline "lang=en" "no conf value → hook sees the login locale's en"
export FLEET_UI_LANG=zh
rm -f "$FLEET_INTRO_SYS_D"/*

echo "E. fleet-login.zsh — banner + SSH opens the client (never on a managed machine)"
if ! command -v zsh >/dev/null 2>&1; then
  echo "  SKIP: zsh not installed"
else
  LOGIN="$here/../shell/fleet-login.zsh"
  # a stand-in install root: the real fleet-login.zsh + cw.zsh beside a stub intro,
  # a stub bin/fleet (the client) and a stub fleet-attach.sh that only count
  # themselves, so nothing attaches or spawns
  mkdir -p "$T/r/shell" "$T/r/bin" "$T/home"
  cp "$LOGIN" "$T/r/shell/fleet-login.zsh"
  cp "$here/../shell/cw.zsh" "$T/r/shell/cw.zsh"
  printf '#!/bin/sh\necho INTRO\n' > "$T/r/shell/fleet-intro.sh"; chmod +x "$T/r/shell/fleet-intro.sh"
  printf '#!/bin/sh\necho "FLEET $*" >> "%s/calls"; exit "${CLIENT_RC:-0}"\n' "$T" > "$T/r/bin/fleet"
  printf '#!/bin/sh\necho ATTACH >> "%s/calls"\n' "$T" > "$T/r/bin/fleet-attach.sh"
  printf '#!/bin/sh\necho "UP $*" >> "%s/calls"\n' "$T" > "$T/r/bin/fleet-up.sh"
  chmod +x "$T/r/bin/fleet" "$T/r/bin/fleet-attach.sh" "$T/r/bin/fleet-up.sh"
  # login <interactive:-i|""> [VAR=val…] → output in $out, client runs in $fn,
  # direct attaches in $an
  login() {
    local i=$1; shift
    : > "$T/calls"; rm -f "$T/home/.hushfleet" "$T/home/.hushfleet-attach"
    out=$(env -u TMUX -u SSH_TTY HOME="$T/home" FLEET_NODE_STATE="$T/node-none" "$@" \
          zsh -f $i -c ". '$T/r/shell/fleet-login.zsh'; echo AFTER" 2>&1)
    fn=$(grep -c '^FLEET' "$T/calls"); an=$(grep -c '^ATTACH' "$T/calls")
  }
  login -i SSH_TTY=/dev/ttys999
  [ "$fn" = 1 ] && ok "SSH interactive → bin/fleet once" || bad "SSH interactive → bin/fleet ${fn}×"
  [ "$(cat "$T/calls")" = "FLEET " ] && ok "  … with no arguments" || bad "client args: $(cat "$T/calls")"
  [ "$an" = 0 ] && ok "SSH interactive → never fleet-attach.sh" || bad "SSH interactive attached ${an}×"
  case "$out" in INTRO*AFTER) ok "banner first, shell continues after the client" ;; *) bad "order: $out" ;; esac
  login -i SSH_TTY=/dev/ttys999 CLIENT_RC=1
  [ "$fn" = 1 ] && case "$out" in *AFTER) true ;; *) false ;; esac \
    && ok "a failing client still leaves the shell" || bad "failing client: $out"
  login -i
  [ "$fn" = 0 ] && ok "no SSH_TTY → no client" || bad "no SSH_TTY → client ${fn}×"
  [ "$out" = "INTRO
AFTER" ] && ok "no SSH_TTY → banner only" || bad "no SSH_TTY out: $out"
  login -i SSH_TTY=/dev/ttys999 TMUX=/tmp/x,1,0
  [ "$fn" = 0 ] && [ "$out" = AFTER ] && ok "inside tmux → nothing" || bad "in tmux: client ${fn}× out=$out"
  # a managed machine (issue #2702): no banner, no client — a plain shell
  mkdir -p "$T/node-managed"; : > "$T/node-managed/machine.env"
  login -i SSH_TTY=/dev/ttys999 FLEET_NODE_STATE="$T/node-managed"
  [ "$fn" = 0 ] && [ "$out" = AFTER ] && ok "managed machine → no banner, no client" \
    || bad "managed machine: client ${fn}× out=$out"
  login "" SSH_TTY=/dev/ttys999
  [ "$fn" = 0 ] && [ "$out" = AFTER ] && ok "non-interactive (scp/rsync/ssh cmd) → nothing" \
    || bad "non-interactive: client ${fn}× out=$out"
  : > "$T/calls"; touch "$T/home/.hushfleet"
  out=$(env -u TMUX HOME="$T/home" FLEET_NODE_STATE="$T/node-none" SSH_TTY=/dev/ttys999 zsh -f -i -c ". '$T/r/shell/fleet-login.zsh'; echo AFTER" 2>&1)
  [ ! -s "$T/calls" ] && [ "$out" = AFTER ] && ok "hush file .hushfleet → nothing" || bad "hushfleet: $out"
  rm -f "$T/home/.hushfleet"; : > "$T/calls"; touch "$T/home/.hushfleet-attach"
  out=$(env -u TMUX HOME="$T/home" FLEET_NODE_STATE="$T/node-none" SSH_TTY=/dev/ttys999 zsh -f -i -c ". '$T/r/shell/fleet-login.zsh'; echo AFTER" 2>&1)
  [ ! -s "$T/calls" ] && [ "$out" = "INTRO
AFTER" ] && ok "hush file .hushfleet-attach → banner, nothing run" || bad "hushfleet-attach: $out"
  rm -f "$T/home/.hushfleet-attach"
  # a cf defined earlier in .zshrc is neither called nor needed
  : > "$T/calls"
  out=$(env -u TMUX HOME="$T/home" FLEET_NODE_STATE="$T/node-none" SSH_TTY=/dev/ttys999 zsh -f -i -c \
        "cf() { echo MINE; }; . '$T/r/shell/fleet-login.zsh'" 2>&1)
  [ "$(cat "$T/calls")" = "FLEET " ] && [ "$out" = INTRO ] && ok "a defined cf is not called" || bad "defined cf: $out"
  # nothing leaks into the login shell — no helper variable, no cf
  out=$(env -u TMUX HOME="$T/home" FLEET_NODE_STATE="$T/node-none" zsh -f -i -c ". '$T/r/shell/fleet-login.zsh' >/dev/null; echo \"\${here-unset} \${+functions[cf]}\"" 2>&1)
  [ "$out" = "unset 0" ] && ok "no helper variable or cf leaks" || bad "leaked: $out"
  # cf (shell/cw.zsh) is folded into fleet: one line saying so, then bin/fleet
  cfrun() { : > "$T/calls"; out=$(env -u TMUX HOME="$T/home" FLEET_NODE_STATE="$T/node-none" zsh -f -c ". '$T/r/shell/cw.zsh'; cf $*" 2>&1); }
  cfrun
  [ "$(cat "$T/calls")" = "FLEET " ] && ok "cf → bin/fleet" || bad "cf calls: $(cat "$T/calls")"
  case "$out" in *"cf 已并入 fleet"*) ok "cf says it is folded into fleet" ;; *) bad "cf notice: $out" ;; esac
  cfrun --guide
  [ "$(cat "$T/calls")" = "FLEET guide" ] && ok "cf --guide → fleet guide" || bad "cf --guide calls: $(cat "$T/calls")"
  cfrun o/r
  [ "$(cat "$T/calls")" = "UP o/r --no-attach
FLEET " ] && ok "cf o/r → fleet-up --no-attach, then bin/fleet" || bad "cf o/r calls: $(cat "$T/calls")"
  ! grep -q ATTACH "$T/calls" && ok "cf never attaches directly" || bad "cf attached"
  # the real pair: a non-SSH login's banner is fleet-intro.sh's, byte for byte
  mkdir -p "$T/e/fleets"
  want=$(env -u TMUX FLEET_CONF_DIR="$T/e" sh "$INTRO" 2>&1)
  got=$(env -u TMUX -u SSH_TTY HOME="$T/home" FLEET_NODE_STATE="$T/node-none" FLEET_CONF_DIR="$T/e" zsh -f -i -c ". '$LOGIN'" 2>&1)
  [ "$got" = "$want" ] && ok "real fleet-login.zsh: non-SSH banner byte-identical to fleet-intro.sh" \
    || { bad "real banner differs"; printf 'got:\n%s\nwant:\n%s\n' "$got" "$want"; }
fi

[ "$fail" -eq 0 ] && echo "PASS: fleet-intro-selftest" || echo "FAIL: fleet-intro-selftest"
exit "$fail"
