#!/bin/bash
# spawn-origin-gate-selftest.sh — a spawn's parent must be a LIVE session (issue
# #1355, EPIC #1645 C2). On an isolated tmux server (`-L <label>`) and a sandbox
# conf dir, pins:
#   A  fleet_origin_gate (fleet-lib.sh): a live key → 0; a key no window answers
#      to → 4 + 「上级 <key> 不是活着的会话」; inside tmux with no $TMUX_PANE and no
#      --origin → 4; the same with an explicit `--origin hub` → 0; a pane, no
#      $TMUX at all (headless), `autofill`/`bridge`, a free label and an
#      --origin-wid (vetted by the placing machine) → 0.
#   B  fleet_epic_parent_key: a worker pane → its key; a hub pane / no pane →
#      rc 1, nothing printed, one stderr hint — never the EPIC's key.
#   C  dash-issue-session.sh end to end: no $TMUX_PANE → exit 4 and no window;
#      a closed parent (`--origin issue-99`) → exit 4 and no window; a live
#      parent and `--origin hub` get PAST the gate (to the FLEET_MAIN check,
#      exit 1 here — the sandbox has no checkout).
#   D  dash-raw-session.sh: no $TMUX_PANE → exit 4, no window; `--origin hub`
#      passes the gate.
#   E  fleet-issue-file.sh --spawn from a lost pane → exit 4 BEFORE any gh call.
# tmux absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { echo 'spawn-origin-gate selftest: tmux absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/spawn-origin-gate.XXXXXX")" || exit 2
L="sog$$"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
export FLEET_UI_QUIET=1 TMPDIR="$WORK"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s/main\n' "$WORK" > "$FLEET_CONF_DIR/fleets/$L/conf"
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_HUB_STATUS_CMD FLEET_HUB_CACHE_SECS

# gh shim: records every call; nothing in this test may reach GitHub.
mkdir -p "$WORK/shim"
cat > "$WORK/shim/gh" <<EOF
#!/bin/sh
echo "gh \$*" >> "$WORK/gh.log"; exit 1
EOF
chmod +x "$WORK/shim/gh"
export PATH="$WORK/shim:$PATH"

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
ok() { CHECKS=$((CHECKS + 1)); }
tf() { "$REAL_TMUX" -L "$L" "$@"; }
cleanup() { "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

tf -f /dev/null new-session -d -s "$L" -n home -c "$WORK" 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'spawn-origin-gate selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }
SOCKPATH=$(tf display-message -p '#{socket_path}')
w7=$(tf new-window -d -P -F '#{window_id}' -n issue-7 -c "$WORK" 'while :; do sleep 300; done')
tf set-window-option -t "$w7" @issue 7
p7=$(tf display-message -p -t "$w7" '#{pane_id}')
phub=$(tf display-message -p -t "$L:home" '#{pane_id}')
INTMUX="$SOCKPATH,1,0"
nwin() { tf list-windows -t "$L" -F x | wc -l | tr -d ' '; }

# gate <TMUX> <TMUX_PANE> <args…> → "rc|stdout"
gate() {
  local t="$1" p="$2"; shift 2
  local out rc
  out=$(TMUX="$t" TMUX_PANE="$p" bash -c '. "$1/fleet-lib.sh"; shift; fleet_origin_gate "$@"' _ "$BIN" "$@"); rc=$?
  printf '%s|%s' "$rc" "$out"
}

# --- A: fleet_origin_gate ---------------------------------------------------------
r=$(gate '' '' "$L" '' issue-7);              ok; [ "$r" = '0|' ] || fail "A: a live parent key passes" "$r"
r=$(gate '' '' "$L" issue-99 issue-99)
ok; case "$r" in '4|上级 issue-99 不是活着的会话'*) ;; *) fail "A: a key no window answers to → 4 + reason" "$r" ;; esac
r=$(gate "$INTMUX" '' "$L" '' '')
ok; case "$r" in '4|cannot tell who is spawning'*) ;; *) fail "A: lost pane, no --origin → 4" "$r" ;; esac
r=$(gate "$INTMUX" '' "$L" hub '');           ok; [ "$r" = '0|' ] || fail "A: lost pane + --origin hub → 0" "$r"
r=$(gate "$INTMUX" '' "$L" issue-7 issue-7);  ok; [ "$r" = '0|' ] || fail "A: lost pane + a live --origin key → 0" "$r"
r=$(gate "$INTMUX" '' "$L" issue-99 issue-99)
ok; case "$r" in '4|上级 issue-99'*) ;; *) fail "A: lost pane + a dead --origin key → 4" "$r" ;; esac
r=$(gate "$INTMUX" "$phub" "$L" '' '');       ok; [ "$r" = '0|' ] || fail "A: a hub pane (empty origin) → 0" "$r"
r=$(gate '' '' "$L" '' '');                   ok; [ "$r" = '0|' ] || fail "A: headless (no \$TMUX) → 0" "$r"
r=$(gate '' '' "$L" autofill autofill);       ok; [ "$r" = '0|' ] || fail "A: autofill → 0" "$r"
r=$(gate '' '' "$L" bridge bridge);           ok; [ "$r" = '0|' ] || fail "A: bridge → 0" "$r"
r=$(gate '' '' "$L" otherfleet otherfleet);   ok; [ "$r" = '0|' ] || fail "A: a free label (#516 source fleet) → 0" "$r"
r=$(gate "$INTMUX" '' "$L" '' issue-5 "abc/issue-5"); ok; [ "$r" = '0|' ] || fail "A: --origin-wid (another machine vetted it) → 0" "$r"

# --- B: fleet_epic_parent_key -----------------------------------------------------
pk() { TMUX="$1" TMUX_PANE="$2" bash -c '. "$1/fleet-lib.sh"; fleet_epic_parent_key "$2" acme/app 1645' _ "$BIN" "$L" 2>"$WORK/pk.err"; }
out=$(pk "$INTMUX" "$p7"); rc=$?;  ok; [ "$rc:$out" = '0:issue-7' ] || fail "B: a worker pane → its own key" "$rc:$out"
out=$(pk "$INTMUX" "$phub"); rc=$?; ok; [ "$rc:$out" = '1:' ] || fail "B: a hub pane → rc 1, never the EPIC's key" "$rc:$out"
ok; grep -q 'scratch or worker pane' "$WORK/pk.err" || fail "B: the refusal says where to run it" "$(cat "$WORK/pk.err")"
out=$(pk "$INTMUX" ''); rc=$?;     ok; [ "$rc:$out" = '1:' ] || fail "B: no \$TMUX_PANE → rc 1" "$rc:$out"
out=$(pk '' ''); rc=$?;            ok; [ "$rc:$out" = '1:' ] || fail "B: headless → rc 1" "$rc:$out"

# --- C: dash-issue-session.sh end to end ------------------------------------------
dis() { local t="$1" p="$2"; shift 2; TMUX="$t" TMUX_PANE="$p" bash "$BIN/dash-issue-session.sh" "$@" 2>"$WORK/dis.err" >/dev/null; }
n0=$(nwin)
dis "$INTMUX" '' 41 "$L" --title t; rc=$?
ok; [ "$rc" = 4 ] || fail "C: no \$TMUX_PANE → exit 4" "rc=$rc $(cat "$WORK/dis.err")"
ok; grep -q 'cannot tell who is spawning' "$WORK/dis.err" || fail "C: … and says why on stderr" "$(cat "$WORK/dis.err")"
ok; [ "$(nwin)" = "$n0" ] || fail "C: … and opens no window" "$(nwin) vs $n0"
dis '' '' 41 "$L" --title t --origin issue-99; rc=$?
ok; [ "$rc" = 4 ] || fail "C: a closed parent → exit 4" "rc=$rc $(cat "$WORK/dis.err")"
ok; grep -q '上级 issue-99 不是活着的会话' "$WORK/dis.err" || fail "C: … naming the parent" "$(cat "$WORK/dis.err")"
ok; [ "$(nwin)" = "$n0" ] || fail "C: … and opens no window" "$(nwin) vs $n0"
dis "$INTMUX" '' 41 "$L" --title t --origin hub; rc=$?
ok; [ "$rc" = 1 ] && grep -q 'FLEET_MAIN is not a git checkout' "$WORK/dis.err" \
  || fail "C: --origin hub passes the gate (stops at the sandbox's missing checkout)" "rc=$rc $(cat "$WORK/dis.err")"
dis "$INTMUX" "$p7" 41 "$L" --title t; rc=$?
ok; [ "$rc" = 1 ] && grep -q 'FLEET_MAIN is not a git checkout' "$WORK/dis.err" \
  || fail "C: a live worker pane passes the gate" "rc=$rc $(cat "$WORK/dis.err")"

# --- D: dash-raw-session.sh -------------------------------------------------------
TMUX="$INTMUX" TMUX_PANE='' bash "$BIN/dash-raw-session.sh" --name x "$L" >/dev/null 2>"$WORK/raw.err"; rc=$?
ok; [ "$rc" = 4 ] && grep -q 'cannot tell who is spawning' "$WORK/raw.err" || fail "D: no \$TMUX_PANE → exit 4" "rc=$rc $(cat "$WORK/raw.err")"
ok; [ "$(nwin)" = "$n0" ] || fail "D: … and opens no window" "$(nwin) vs $n0"
TMUX='' bash "$BIN/dash-raw-session.sh" --name x --origin scratch-88 "$L" >/dev/null 2>"$WORK/raw.err"; rc=$?
ok; [ "$rc" = 4 ] && grep -q '上级 scratch-88' "$WORK/raw.err" || fail "D: a closed parent → exit 4" "rc=$rc $(cat "$WORK/raw.err")"
TMUX="$INTMUX" TMUX_PANE='' bash "$BIN/dash-raw-session.sh" --name x --origin hub "$L" >/dev/null 2>"$WORK/raw.err"; rc=$?
ok; [ "$rc" != 4 ] || fail "D: --origin hub passes the gate" "rc=$rc $(cat "$WORK/raw.err")"
ok; grep -q -- "--origin='\${ORIGIN:-hub}'" "$BIN/dash-raw-session.sh" || fail "D: the --bg re-exec always states its origin (run-shell -b has no pane)"

# --- E: fleet-issue-file.sh --spawn from a lost pane ------------------------------
: > "$WORK/gh.log"
TMUX="$INTMUX" TMUX_PANE='' bash "$BIN/fleet-issue-file.sh" --title t --repo acme/app --spawn >/dev/null 2>"$WORK/fif.err"; rc=$?
ok; [ "$rc" = 4 ] || fail "E: --spawn from a lost pane → exit 4" "rc=$rc $(cat "$WORK/fif.err")"
ok; [ ! -s "$WORK/gh.log" ] || fail "E: … before filing anything" "$(cat "$WORK/gh.log")"

[ "$FAIL" = 0 ] || { printf 'spawn-origin-gate selftest: %d FAILED (of %d)\n' "$FAIL" "$CHECKS" >&2; exit 1; }
printf 'spawn-origin-gate selftest: OK (%d checks)\n' "$CHECKS"
