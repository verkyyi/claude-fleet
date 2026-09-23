#!/bin/bash
# fleet-peer-send-identity-selftest.sh — identity addressing for fleet-peer-send.sh
# (issue #1046). `<sess>:<idx>` is a POSITION: a window closing renumbers every
# window after it, and on 2026-09-23 a hub's remembered index delivered three
# operator-authorising instructions to the WRONG worker. Pins, on an isolated tmux
# server with fake Claude processes and one real inbox socket per window:
#   • issue:<N> / #<N> / issue-<N> reach the window bound to #N AFTER a renumber;
#   • scratch-<N> reaches the @raw window by name / by its -scratch-<N> worktree;
#   • a stale `<sess>:<idx>` with --expect-issue refuses (exit 1, nothing sent);
#   • zero matches / several matches refuse; --repo disambiguates;
#   • EVERY path prints exactly one outcome line — `sent → …` on stdout for a
#     success (incl. the wake-delivery path, which used to print nothing),
#     one stderr line + non-zero for a failure.
# tmux / python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { printf 'fleet-peer-send-identity selftest: tmux absent — SKIP\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'fleet-peer-send-identity selftest: python3 absent — SKIP\n'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-peer-ident.XXXXXX")" || exit 2
L="fpsid$$"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR"
export FLEET_CLAUDE_COMM='FLEETFAKECLAUDE'
unset TMUX TMUX_PANE

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
ok() { CHECKS=$((CHECKS + 1)); }
tf() { "$REAL_TMUX" -L "$L" "$@"; }
LISTENER=""
cleanup() { [ -n "$LISTENER" ] && kill "$LISTENER" 2>/dev/null; "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

tf -f /dev/null new-session -d -s "$L" -n plan 'while :; do sleep 300; done' 2>/dev/null \
  || { printf 'fleet-peer-send-identity selftest: cannot start an isolated tmux server — SKIP\n' >&2; exit 0; }
tf set-option -t "$L" renumber-windows on

FAKE="bash -c ': FLEETFAKECLAUDE; while :; do sleep 300; done'"
# mkwin <name> <issue|-> [repo] [raw-worktree] → window id
mkwin() {
  local wid
  wid=$(tf new-window -d -P -F '#{window_id}' -n "$1" "$FAKE")
  [ "$2" != - ] && tf set-window-option -t "$wid" @issue "$2"
  [ -n "${3:-}" ] && tf set-window-option -t "$wid" @repo "$3"
  [ -n "${4:-}" ] && { tf set-window-option -t "$wid" @raw 1; tf set-window-option -t "$wid" @worktree "$4"; }
  printf '%s' "$wid"
}
idx_of() { tf display-message -p -t "$1" '#{window_index}'; }

filler=$(mkwin filler -)
wA=$(mkwin issue-11 11 acme/a)
wB=$(mkwin issue-12 12 acme/a)
wC=$(mkwin sc-renamed - acme/a "$WORK/repo-scratch-5")
sleep 0.6

# one registry record + key + inbox socket per fake Claude; one listener serves
# them all and appends `<socket-name>\t<content>` per delivered user frame.
socks=""
for w in "$wA" "$wB" "$wC"; do
  p=$(. "$BIN/fleet-lib.sh"; fleet_pane_claude_pid "$w" "$L")
  [ -n "$p" ] || { fail "rig: no fake Claude under $w"; exit 1; }
  n=${w#@}
  printf '{"pid":%s,"sessionId":"sid-%s","cwd":"%s","messagingSocketPath":"%s","name":"w%s"}\n' \
    "$p" "$n" "$WORK/wt-$n" "$WORK/in-$n.sock" "$n" > "$FLEET_CC_SESSIONS_DIR/$p.json"
  printf '{"peerToken":"tok-%s"}' "$n" > "$FLEET_CC_SESSIONS_DIR/$p.k.key"
  socks="$socks $WORK/in-$n.sock"
  eval "pid_${n}=$p"
done
python3 - "$WORK/got" $socks <<'PY' &
import json, os, select, socket, sys
out, paths = sys.argv[1], sys.argv[2:]
srv = {}
for p in paths:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(p); s.listen(8); srv[s] = os.path.basename(p)
while True:
    r, _, _ = select.select(list(srv), [], [], 60)
    if not r: break
    for s in r:
        c, _ = s.accept(); c.settimeout(3); buf = b""
        try:
            while True:
                d = c.recv(65536)
                if not d: break
                buf += d
        except Exception: pass
        c.close()
        for line in buf.decode().split("\n"):
            if line.strip():
                f = json.loads(line)
                if f.get("type") == "user":
                    with open(out, "a") as fh:
                        fh.write(srv[s] + "\t" + f["message"]["content"].replace("\n", " ") + "\n")
PY
LISTENER=$!
for _ in $(seq 1 50); do [ -S "$WORK/in-${wC#@}.sock" ] && break; sleep 0.1; done
: > "$WORK/got"

# send <args…> → sets out/err/rc; lines = total outcome lines on stdout+stderr
send() {
  out=$(bash "$BIN/fleet-peer-send.sh" "$@" 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err")
  lines=$( { [ -n "$out" ] && printf '%s\n' "$out"; [ -n "$err" ] && printf '%s\n' "$err"; } | grep -c .)
}
# landed <window-id> <marker> — the marker arrived at that window's inbox, and ONLY there
landed() {
  local i
  for i in $(seq 1 30); do grep -q "$2" "$WORK/got" 2>/dev/null && break; sleep 0.1; done
  [ "$(grep "$2" "$WORK/got" | cut -f1)" = "in-${1#@}.sock" ]
}
one_line() { ok; [ "$lines" -eq 1 ] || fail "$1: exactly one outcome line" "out=[$out] err=[$err]"; }

# --- 1. the drift: remember B's neighbour A's index, then close the filler ------
staleA="$L:$(idx_of "$wA")"
tf kill-window -t "$filler"; sleep 0.2
ok; [ "$(tf display-message -p -t "$staleA" '#{window_id}')" = "$wB" ] \
  || fail "rig: closing the filler must renumber B onto A's old index"

send -L "$L" issue:11 "m-issue-colon"
ok; [ "$rc" = 0 ] || fail "issue:11 after renumber → exit 0" "$err"
ok; landed "$wA" m-issue-colon || fail "issue:11 must reach A, not whoever sits at its old index" "$(cat "$WORK/got")"
exp="sent → pid $(eval echo "\$pid_${wA#@}") (issue-11 · "
ok; case "$out" in "$exp"*) ;; *) fail "success echo names pid + window + worktree" "$out" ;; esac
one_line "issue:11"

send -L "$L" '#12' "m-hash"
ok; [ "$rc" = 0 ] && landed "$wB" m-hash || fail "#12 → B" "$out $err"
one_line "#12"
send -L "$L" issue-11 "m-dash"
ok; [ "$rc" = 0 ] && landed "$wA" m-dash || fail "issue-11 → A" "$out $err"

# --- 2. scratch by its -scratch-<N> worktree (window renamed) and by name -------
send -L "$L" scratch-5 "m-scratch"
ok; [ "$rc" = 0 ] && landed "$wC" m-scratch || fail "scratch-5 → the @raw window in *-scratch-5" "$out $err"
one_line "scratch-5"
send -L "$L" sc-renamed "m-byname"
ok; [ "$rc" = 0 ] && landed "$wC" m-byname || fail "exact window name → that window" "$out $err"

# --- 3. positional + --expect-issue: stale index refuses, nothing sent ----------
send -L "$L" --expect-issue 11 "$staleA" "m-stale"
ok; [ "$rc" = 1 ] || fail "stale sess:idx with --expect-issue 11 → exit 1" "rc=$rc $out"
ok; [ -z "$out" ] || fail "a refusal prints nothing on stdout" "$out"
ok; sleep 0.3; grep -q m-stale "$WORK/got" && fail "a refused send must deliver NOTHING" "$(cat "$WORK/got")"
ok; case "$err" in *refused*issue-12*) ;; *) fail "refusal names the window actually there" "$err" ;; esac
one_line "--expect-issue refusal"
send -L "$L" --expect-issue 12 "$staleA" "m-pinned"
ok; [ "$rc" = 0 ] && landed "$wB" m-pinned || fail "matching --expect-issue → sends" "$out $err"

# --- 4. zero / ambiguous / --repo --------------------------------------------------
send -L "$L" issue:99 "m-none"
ok; [ "$rc" = 1 ] || fail "issue:99 (no window) → exit 1" "rc=$rc"
one_line "no match"
wD=$(mkwin other-11 11 acme/b)
send -L "$L" issue:11 "m-ambig"
ok; [ "$rc" = 1 ] || fail "two windows bound to #11 → exit 1" "rc=$rc $out"
ok; case "$err" in *ambiguous*issue-11*other-11*) ;; *) fail "ambiguity lists every candidate" "$err" ;; esac
one_line "ambiguous"
send -L "$L" --repo acme/a issue:11 "m-repo"
ok; [ "$rc" = 0 ] && landed "$wA" m-repo || fail "--repo acme/a issue:11 → A" "$out $err"
tf kill-window -t "$wD"
send -L "$L" issue:abc "x"
ok; [ "$rc" = 2 ] || fail "issue:abc → usage exit 2" "rc=$rc"
one_line "bad issue"

# --- 5. the formerly silent wake-delivery path now echoes -------------------------
SB="$WORK/sbin"; mkdir -p "$SB"
ln -s "$BIN/fleet-peer-send.sh" "$SB/fleet-peer-send.sh"; ln -s "$BIN/fleet-lib.sh" "$SB/fleet-lib.sh"
printf 'import sys\nsys.stdin.read()\nsys.exit(0)\n' > "$SB/fleet-sleep.py"
tf set-window-option -t "$wB" @worker_lifecycle sleeping
out=$(bash "$SB/fleet-peer-send.sh" -L "$L" issue:12 "m-wake" 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err")
ok; [ "$rc" = 0 ] || fail "wake-delivery success → exit 0" "$err"
ok; case "$out" in "sent → $wB via wake-delivery (issue-12 · "*) ;; *) fail "wake-delivery must echo sent →" "[$out]" ;; esac
ok; [ -z "$err" ] || fail "wake-delivery success: nothing on stderr" "$err"
printf 'import sys\nsys.stdin.read()\nsys.exit(1)\n' > "$SB/fleet-sleep.py"
out=$(bash "$SB/fleet-peer-send.sh" -L "$L" issue:12 "m-wake2" 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err")
ok; [ "$rc" = 1 ] && [ -z "$out" ] && [ "$(printf '%s\n' "$err" | grep -c .)" = 1 ] \
  || fail "a silent wake-delivery failure still gets one stderr line + exit 1" "rc=$rc out=[$out] err=[$err]"

[ "$FAIL" -eq 0 ] || { printf 'fleet-peer-send-identity selftest: %d FAIL\n' "$FAIL" >&2; exit 1; }
printf 'fleet-peer-send-identity selftest: OK (%d checks)\n' "$CHECKS"
