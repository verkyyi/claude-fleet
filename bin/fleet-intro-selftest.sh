#!/bin/bash
# fleet-intro-selftest.sh — the SSH login banner, shell/fleet-intro.sh (issue #1068).
#
# Builds fake FLEET_CONF_DIR trees and runs the REAL script against each:
#
#   A. 0 fleets            → "○ 未配置 fleet" + the INSTALL.md pointer, nothing else.
#   B. 2 fleets            → ONE warning line pointing at `fleet-repo.sh fold` (#979).
#   C. 1 fleet, 1 repo, no server → "○ 未启动", its repo row, the "启动" action.
#   D. 1 fleet, 3 repos, a LIVE session on an isolated socket →
#        "● 运行中 · 3 会话"; rows in fleet_repos order (the fleet conf's repo
#        first, then repos/*.conf by file name, a repeat dropped; all equal — no
#        "main" label, #788); per-repo
#        counts from windows carrying @issue (a hub window without @issue is not
#        a worker); a repo with none shows no count; the "回到 fleet" action;
#        and at most 2 tmux calls.
#
#   E. shell/fleet-login.zsh (issue #1166), the ~/.zshrc block that shows the
#      banner and then auto-attaches an SSH login: no $SSH_TTY / inside $TMUX /
#      non-interactive / ~/.hushfleet / ~/.hushfleet-attach → cf NOT called;
#      interactive SSH → cf called exactly once, and the shell carries on after
#      it (a failing cf too); a login without $SSH_TTY prints the banner byte for
#      byte as fleet-intro.sh itself does. zsh absent → E SKIPs.
#
# tmux never touches the operator's server: a PATH shim drops the script's
# `-L <sess>` and routes every call onto one throwaway -S socket, killed at exit.
# tmux absent → case D SKIPs (the rest still run). Exit 0 = pass.
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

echo "A. no fleet"
mkdir -p "$T/a/fleets"
run "$T/a"
has "○ 未配置 fleet" "unconfigured header"
has "INSTALL.md" "points at INSTALL.md"
hasnot "cf " "no action line"

echo "B. two fleets"
mkfleet "$T/b" one o/one master; mkfleet "$T/b" two o/two master
run "$T/b"
has "配置了 2 个 fleet" "warns on 2 fleets"
has "fleet-repo.sh fold" "points at fold"
hasnot "o/one" "lists no repos"

echo "C. one fleet, one repo, not running"
mkfleet "$T/c" idlefleet me/app main
run "$T/c"
has "○ 未启动" "stopped header"
hasnot "运行中" "not marked running"
has "me/app" "repo row"
has "main" "base branch"
has "启动 fleet 并进入" "start action"
[ "$rc" -eq 0 ] && ok "exit 0" || bad "exit $rc"

echo "D. one fleet, three repos, live session"
if [ -z "$REAL_TMUX" ]; then
  echo "  SKIP: tmux not installed"
else
  mkfleet "$T/d" live z/first master
  mkrepo "$T/d" live second b/second develop
  mkrepo "$T/d" live third a/third main
  mkrepo "$T/d" live zdup z/first master          # repeats the conf's repo → dropped
  tm() { "$REAL_TMUX" -S "$SOCK" "$@"; }
  tm new-session -d -s live -n hub
  tm new-window -d -t live -n issue-1; tm new-window -d -t live -n issue-2
  tm new-window -d -t live -n issue-3
  tm set-option -w -t live:issue-1 @repo a/third;  tm set-option -w -t live:issue-1 @issue 1
  tm set-option -w -t live:issue-2 @repo a/third;  tm set-option -w -t live:issue-2 @issue 2
  tm set-option -w -t live:issue-3 @repo z/first;  tm set-option -w -t live:issue-3 @issue 3
  tm set-option -w -t live:hub @repo z/first       # a hub, no @issue → not a worker
  run "$T/d"
  has "● 运行中 · 3 会话" "running header with total"
  has "回到 fleet" "attach action"
  hasnot "启动 fleet 并进入" "no start action"
  rows=$(printf '%s\n' "$out" | awk '/^   [^ ]/{print $1 "|" $2 "|" $3}')
  want="z/first|master|1
b/second|develop|
a/third|main|2"
  [ "$rows" = "$want" ] && ok "rows: conf repo first, overlays by file name, repeat dropped, per-repo counts" \
    || { bad "rows"; printf 'got:\n%s\nwant:\n%s\n' "$rows" "$want"; }
  hasnot "main repo" "no main-repo label"
  calls=$(wc -l < "$T/calls" | tr -d ' ')
  [ "$calls" -le 2 ] && ok "tmux calls: $calls (≤2)" || bad "tmux calls: $calls (>2)"
fi

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
