#!/bin/bash
# fleet-peer-send-identity-selftest.sh — identity addressing for fleet-peer-send.sh
# (issue #1046). `<sess>:<idx>` is a POSITION: a window closing renumbers every
# window after it, and on 2026-09-23 a hub's remembered index delivered three
# operator-authorising instructions to the WRONG worker. Pins, on an isolated tmux
# server with fake Claude processes and one real inbox socket per window:
#   • issue:<N> / #<N> / issue-<N> reach the window bound to #N AFTER a renumber;
#   • scratch-<N> reaches the @raw window by its -scratch-<N> worktree;
#   • a `<sess>:<idx>` position and a bare window NAME refuse (exit 2, nothing
#     sent; issue #1537 — the resolver is fleet_win_for_key, and --expect-issue
#     pins an @id / %pane target, it does not make a position acceptable);
#   • zero matches / several matches refuse; --repo disambiguates;
#   • EVERY path prints exactly one outcome line — `sent → …` on stdout for a
#     success (incl. the journaled delivery path, which used to print nothing),
#     one stderr line + non-zero for a failure.
# tmux / python3 absent → SKIP (exit 0). Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
REAL_TMUX=$(command -v tmux) || { printf 'fleet-peer-send-identity selftest: tmux absent — SKIP\n'; exit 0; }
st_need python3

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-peer-ident.XXXXXX")" || exit 2
L="fpsid$$"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR"
export FLEET_CLAUDE_COMM='FLEETFAKECLAUDE'
unset TMUX TMUX_PANE

st_tally
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
  [ -n "$p" ] || { st_miss "rig: no fake Claude under $w"; exit 1; }
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
  local _
  for _ in $(seq 1 30); do grep -q "$2" "$WORK/got" 2>/dev/null && break; sleep 0.1; done
  [ "$(grep "$2" "$WORK/got" | cut -f1)" = "in-${1#@}.sock" ]
}
one_line() { st_count; [ "$lines" -eq 1 ] || st_miss "$1: exactly one outcome line" "out=[$out] err=[$err]"; }

# --- 1. the drift: remember B's neighbour A's index, then close the filler ------
staleA="$L:$(idx_of "$wA")"
tf kill-window -t "$filler"; sleep 0.2
st_count; [ "$(tf display-message -p -t "$staleA" '#{window_id}')" = "$wB" ] \
  || st_miss "rig: closing the filler must renumber B onto A's old index"

send -L "$L" issue:11 "m-issue-colon"
st_count; [ "$rc" = 0 ] || st_miss "issue:11 after renumber → exit 0" "$err"
st_count; landed "$wA" m-issue-colon || st_miss "issue:11 must reach A, not whoever sits at its old index" "$(cat "$WORK/got")"
exp="sent → pid $(eval echo "\$pid_${wA#@}") (issue-11 · "
st_count; case "$out" in "$exp"*) ;; *) st_miss "success echo names pid + window + worktree" "$out" ;; esac
one_line "issue:11"

send -L "$L" '#12' "m-hash"
st_count; [ "$rc" = 0 ] && landed "$wB" m-hash || st_miss "#12 → B" "$out $err"
one_line "#12"
send -L "$L" issue-11 "m-dash"
st_count; [ "$rc" = 0 ] && landed "$wA" m-dash || st_miss "issue-11 → A" "$out $err"

# --- 2. scratch by its -scratch-<N> worktree (window renamed); a NAME refuses ----
send -L "$L" scratch-5 "m-scratch"
st_count; [ "$rc" = 0 ] && landed "$wC" m-scratch || st_miss "scratch-5 → the @raw window in *-scratch-5" "$out $err"
one_line "scratch-5"
send -L "$L" sc-renamed "m-byname"
st_count; [ "$rc" = 2 ] && [ -z "$out" ] || st_miss "a window NAME is not an address → exit 2 (issue #1537)" "rc=$rc $out $err"
st_count; sleep 0.3; grep -q m-byname "$WORK/got" && st_miss "a refused name must deliver NOTHING" "$(cat "$WORK/got")"
one_line "name refusal"

# --- 3. a position refuses (issue #1537); --expect-issue pins an @id -------------
send -L "$L" "$staleA" "m-stale"
st_count; [ "$rc" = 2 ] || st_miss "a <sess>:<idx> position → exit 2" "rc=$rc $out"
st_count; [ -z "$out" ] || st_miss "a refusal prints nothing on stdout" "$out"
st_count; sleep 0.3; grep -q m-stale "$WORK/got" && st_miss "a refused send must deliver NOTHING" "$(cat "$WORK/got")"
st_count; case "$err" in *position*) ;; *) st_miss "refusal says it is a position" "$err" ;; esac
one_line "position refusal"
send -L "$L" --expect-issue 12 "$staleA" "m-pinned-pos"
st_count; [ "$rc" = 2 ] || st_miss "--expect-issue does not make a position acceptable" "rc=$rc $out $err"
send -L "$L" --expect-issue 11 "$wB" "m-wrong-pin"
st_count; [ "$rc" = 1 ] && case "$err" in *refused*issue-12*) true ;; *) false ;; esac \
  || st_miss "@id with the wrong --expect-issue → refused, names the window there" "rc=$rc $err"
one_line "--expect-issue refusal"
send -L "$L" --expect-issue 12 "$wB" "m-pinned"
st_count; [ "$rc" = 0 ] && landed "$wB" m-pinned || st_miss "@id with a matching --expect-issue → sends" "$out $err"

# --- 4. zero / ambiguous / --repo --------------------------------------------------
send -L "$L" issue:99 "m-none"
st_count; [ "$rc" = 1 ] || st_miss "issue:99 (no window) → exit 1" "rc=$rc"
one_line "no match"
wD=$(mkwin other-11 11 acme/b)
send -L "$L" issue:11 "m-ambig"
st_count; [ "$rc" = 1 ] || st_miss "two windows bound to #11 → exit 1" "rc=$rc $out"
st_count; case "$err" in *ambiguous*issue-11*other-11*) ;; *) st_miss "ambiguity lists every candidate" "$err" ;; esac
one_line "ambiguous"
send -L "$L" --repo acme/a issue:11 "m-repo"
st_count; [ "$rc" = 0 ] && landed "$wA" m-repo || st_miss "--repo acme/a issue:11 → A" "$out $err"
tf kill-window -t "$wD"
send -L "$L" issue:abc "x"
st_count; [ "$rc" = 2 ] || st_miss "issue:abc → usage exit 2" "rc=$rc"
one_line "bad issue"

# --- Parent retirement: old ancestry never reroutes; prev continuation still does --
export FLEET_ID_PUSH=0 FLEET_SKIP_GLOBAL_CONF=1 CCQUOTA_FLEET=0
mkdir -p "$FLEET_CONF_DIR/fleets/$L"
: > "$FLEET_CONF_DIR/fleets/$L/conf"
old=11111111-1111-4111-8111-111111111111
par=22222222-2222-4222-8222-222222222222
next=33333333-3333-4333-8333-333333333333
tf set-window-option -t "$wA" @fleet_id "$par"
tf set-window-option -t "$wC" @fleet_id "$next"
python3 - "$BIN" "$old" "$par" <<'PYOLD'
import sys
sys.path.insert(0, sys.argv[1])
import fleet_id
fleet_id.append(sys.argv[2], {"ev": "opened", "parent": sys.argv[3], "agent": "claude"})
fleet_id.append(sys.argv[2], {"ev": "closed", "reason": "exited"})
fleet_id.open_id(sys.argv[3], {"agent": "claude"})
PYOLD
cp "$FLEET_CONF_DIR/ids/$old.ndjson" "$WORK/old-history"
code=$(bash "$BIN/fleet-id.sh" short "$old")
send -L "$L" "#$code" m-no-parent
st_count; [ "$rc" = 1 ] && [ -z "$out" ] && case "$err" in *'no live successor; nothing sent'*) true ;; *) false ;; esac \
  || st_miss "closed ID refuses despite a live historical Parent" "$rc:$out:$err"
sleep 0.2
st_count; ! grep -q m-no-parent "$WORK/got" && [ ! -s "$FLEET_CONF_DIR/global/orphan-reports.ndjson" ] \
  || st_miss "closed-ID refusal writes no inbox frame or implicit reminder"
python3 "$BIN/fleet_id.py" open "$next" --agent claude --prev "$old" >/dev/null
send -L "$L" "#$code" m-prev-successor
st_count; [ "$rc" = 0 ] && landed "$wC" m-prev-successor || st_miss "closed conversation reaches its real prev successor" "$rc:$out:$err"
send -L "$L" "wid:$par" m-explicit-fid
st_count; [ "$rc" = 0 ] && landed "$wA" m-explicit-fid || st_miss "explicit FID still reaches the requested session" "$rc:$out:$err"
st_count; cmp -s "$WORK/old-history" "$FLEET_CONF_DIR/ids/$old.ndjson" || st_miss "routing preserves historical Parent bytes"

# --- 5. the formerly silent journaled-delivery path now echoes ---------------------
SB="$WORK/sbin"; mkdir -p "$SB"
ln -s "$BIN/fleet-peer-send.sh" "$SB/fleet-peer-send.sh"; ln -s "$BIN/fleet-lib.sh" "$SB/fleet-lib.sh"
printf 'import sys\nsys.stdin.read()\nsys.exit(0)\n' > "$SB/fleet_worker_life.py"
tf set-window-option -t "$wB" @sleep_evidence '{"session_id":"x"}'
out=$(bash "$SB/fleet-peer-send.sh" -L "$L" issue:12 "m-wake" 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err")
st_count; [ "$rc" = 0 ] || st_miss "journaled delivery success → exit 0" "$err"
st_count; case "$out" in "sent → $wB via delivery (issue-12 · "*) ;; *) st_miss "journaled delivery must echo sent →" "[$out]" ;; esac
st_count; [ -z "$err" ] || st_miss "journaled delivery success: nothing on stderr" "$err"
printf 'import sys\nsys.stdin.read()\nsys.exit(1)\n' > "$SB/fleet_worker_life.py"
out=$(bash "$SB/fleet-peer-send.sh" -L "$L" issue:12 "m-wake2" 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err")
st_count; [ "$rc" = 1 ] && [ -z "$out" ] && [ "$(printf '%s\n' "$err" | grep -c .)" = 1 ] \
  || st_miss "a silent delivery failure still gets one stderr line + exit 1" "rc=$rc out=[$out] err=[$err]"

st_done
