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
#   C. 1 fleet, 1 repo     → "claude fleet · 1 个仓库", the cf line, the hide
#                            line — and nothing about running / sessions / branch.
#   D. 1 fleet, 3 repos (+1 repeat, dropped) → "3 个仓库"; a LIVE tmux session
#        on the shim's socket changes nothing.
#   F. intro.d             → system dir then $CONF_DIR/intro.d, file order, lines
#        verbatim between cf and the hide line; a failing / silent /
#        non-executable hook prints nothing. A hook sees the banner's RESOLVED
#        language exported as $FLEET_UI_LANG — the conf's over env/locale (#1257).
#
#   E. shell/fleet-login.zsh (issue #1166), the ~/.zshrc block that shows the
#      banner and then auto-attaches an SSH login: no $SSH_TTY / inside $TMUX /
#      non-interactive / ~/.hushfleet / ~/.hushfleet-attach → cf NOT called;
#      interactive SSH → cf called exactly once, and the shell carries on after
#      it (a failing cf too); a login without $SSH_TTY prints the banner byte for
#      byte as fleet-intro.sh itself does. zsh absent → E SKIPs.
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
hasnot "cf " "no action line"
hasnot "hushfleet" "no hide line"

echo "B. two fleets"
mkfleet "$T/b" one o/one master; mkfleet "$T/b" two o/two master
both B "$T/b" "claude fleet ⚠ 有 2 个，只能留一个" "claude fleet ⚠ 2 fleets, keep one"
has "运行 fleet-repo.sh fold" "points at fold"
hasnot "o/one" "lists no repos"

echo "C. one fleet, one repo"
mkfleet "$T/c" idlefleet me/app main
both C "$T/c" "claude fleet · 1 个仓库" "claude fleet · 1 repo
cf   enter fleet
hide: touch ~/.hushfleet"
want="claude fleet · 1 个仓库
cf   进入 fleet
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
cf   进入 fleet
sys1
sys2  两行
sys2b
user1
隐藏：touch ~/.hushfleet"
[ "$out" = "$want" ] && ok "hooks: system dir then conf dir, file order, between cf and hide; failing/empty/non-exec silent" \
  || { bad "hooks"; printf 'got:\n%s\nwant:\n%s\n' "$out" "$want"; }
narrow F; notmux F
rm -f "$FLEET_INTRO_SYS_D"/*
# the hook's language is the banner's: the fleet conf beats env + locale (#1257)
printf '#!/bin/sh\necho "lang=$FLEET_UI_LANG"\n' > "$FLEET_INTRO_SYS_D/10-lang"
chmod +x "$FLEET_INTRO_SYS_D/10-lang"
rm -f "$T/f/intro.d/05-u"
mkfleet "$T/fz" zhf me/app main; echo 'FLEET_UI_LANG=zh' >> "$T/fz/fleets/zhf/conf"
mkfleet "$T/fe" enf me/app main; echo 'FLEET_UI_LANG=en' >> "$T/fe/fleets/enf/conf"
FLEET_UI_LANG=en LANG=en_US.UTF-8 LC_ALL='' run "$T/fz"
has "lang=zh" "zh conf under en env/locale → hook sees zh"; has "进入 fleet" "… under a zh banner"
FLEET_UI_LANG=zh LANG=zh_CN.UTF-8 LC_ALL='' run "$T/fe"
has "lang=en" "en conf under zh env/locale → hook sees en"; has "enter fleet" "… under an en banner"
FLEET_UI_LANG='' LANG=en_US.UTF-8 LC_ALL='' run "$T/f"
has "lang=en" "no conf lang, empty env → hook sees the locale's en, not empty"
# the reported case: FLEET_UI_LANG UNSET on an en_US login, zh conf — a plain
# shell var never reaches the hook, which then falls back to the locale's en
unset FLEET_UI_LANG
LANG=en_US.UTF-8 LC_ALL='' run "$T/fz"
has "lang=zh" "zh conf, FLEET_UI_LANG unset, en_US locale → hook sees zh"
export FLEET_UI_LANG=zh
rm -f "$FLEET_INTRO_SYS_D"/*

echo "E. fleet-login.zsh — banner + SSH auto-attach"
if ! command -v zsh >/dev/null 2>&1; then
  echo "  SKIP: zsh not installed"
else
  LOGIN="$here/../shell/fleet-login.zsh"
  # a stand-in shell/ dir: the real fleet-login.zsh beside a stub intro + a stub
  # cw.zsh whose cf only counts itself, so nothing attaches or spawns
  mkdir -p "$T/sh" "$T/home"
  cp "$LOGIN" "$T/sh/fleet-login.zsh"
  printf '#!/bin/sh\necho INTRO\n' > "$T/sh/fleet-intro.sh"; chmod +x "$T/sh/fleet-intro.sh"
  printf 'cf() { echo CF >> "%s/cf"; return "${CF_RC:-0}"; }\n' "$T" > "$T/sh/cw.zsh"
  # login <interactive:-i|""> [VAR=val…] → output in $out, cf calls in $cfn
  login() {
    local i=$1; shift
    : > "$T/cf"; rm -f "$T/home/.hushfleet" "$T/home/.hushfleet-attach"
    out=$(env -u TMUX -u SSH_TTY HOME="$T/home" "$@" \
          zsh -f $i -c ". '$T/sh/fleet-login.zsh'; echo AFTER" 2>&1)
    cfn=$(grep -c CF "$T/cf")
  }
  login -i SSH_TTY=/dev/ttys999
  [ "$cfn" = 1 ] && ok "SSH interactive → cf once" || bad "SSH interactive → cf ${cfn}×"
  case "$out" in INTRO*AFTER) ok "banner first, shell continues after cf" ;; *) bad "order: $out" ;; esac
  login -i SSH_TTY=/dev/ttys999 CF_RC=1
  [ "$cfn" = 1 ] && case "$out" in *AFTER) true ;; *) false ;; esac \
    && ok "a failing cf still leaves the shell" || bad "failing cf: $out"
  login -i
  [ "$cfn" = 0 ] && ok "no SSH_TTY → no cf" || bad "no SSH_TTY → cf ${cfn}×"
  [ "$out" = "INTRO
AFTER" ] && ok "no SSH_TTY → banner only" || bad "no SSH_TTY out: $out"
  login -i SSH_TTY=/dev/ttys999 TMUX=/tmp/x,1,0
  [ "$cfn" = 0 ] && [ "$out" = AFTER ] && ok "inside tmux → nothing" || bad "in tmux: cf ${cfn}× out=$out"
  login "" SSH_TTY=/dev/ttys999
  [ "$cfn" = 0 ] && [ "$out" = AFTER ] && ok "non-interactive (scp/rsync/ssh cmd) → nothing" \
    || bad "non-interactive: cf ${cfn}× out=$out"
  : > "$T/cf"; touch "$T/home/.hushfleet"
  out=$(env -u TMUX HOME="$T/home" SSH_TTY=/dev/ttys999 zsh -f -i -c ". '$T/sh/fleet-login.zsh'; echo AFTER" 2>&1)
  [ "$(grep -c CF "$T/cf")" = 0 ] && [ "$out" = AFTER ] && ok "hush file .hushfleet → nothing" || bad "hushfleet: $out"
  rm -f "$T/home/.hushfleet"; : > "$T/cf"; touch "$T/home/.hushfleet-attach"
  out=$(env -u TMUX HOME="$T/home" SSH_TTY=/dev/ttys999 zsh -f -i -c ". '$T/sh/fleet-login.zsh'; echo AFTER" 2>&1)
  [ "$(grep -c CF "$T/cf")" = 0 ] && [ "$out" = "INTRO
AFTER" ] && ok "hush file .hushfleet-attach → banner, no cf" || bad "hushfleet-attach: $out"
  rm -f "$T/home/.hushfleet-attach"
  # a cf already defined (cw.zsh sourced earlier in .zshrc) is used, not re-sourced
  : > "$T/cf"
  out=$(env -u TMUX HOME="$T/home" SSH_TTY=/dev/ttys999 zsh -f -i -c \
        "cf() { echo MINE; }; . '$T/sh/fleet-login.zsh'" 2>&1)
  [ "$(grep -c CF "$T/cf")" = 0 ] && [ "$out" = "INTRO
MINE" ] && ok "an existing cf is kept" || bad "existing cf: $out"
  # nothing but cf leaks into the login shell
  out=$(env -u TMUX HOME="$T/home" zsh -f -i -c ". '$T/sh/fleet-login.zsh' >/dev/null; echo \"\${here-unset}\"" 2>&1)
  [ "$out" = unset ] && ok "no helper variable leaks" || bad "leaked here=$out"
  # the real pair: a non-SSH login's banner is fleet-intro.sh's, byte for byte
  mkdir -p "$T/e/fleets"
  want=$(env -u TMUX FLEET_CONF_DIR="$T/e" sh "$INTRO" 2>&1)
  got=$(env -u TMUX -u SSH_TTY HOME="$T/home" FLEET_CONF_DIR="$T/e" zsh -f -i -c ". '$LOGIN'" 2>&1)
  [ "$got" = "$want" ] && ok "real fleet-login.zsh: non-SSH banner byte-identical to fleet-intro.sh" \
    || { bad "real banner differs"; printf 'got:\n%s\nwant:\n%s\n' "$got" "$want"; }
fi

[ "$fail" -eq 0 ] && echo "PASS: fleet-intro-selftest" || echo "FAIL: fleet-intro-selftest"
exit "$fail"
