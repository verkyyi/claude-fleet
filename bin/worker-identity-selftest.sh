#!/bin/bash
# worker-identity-selftest.sh — a session's lifelong identity (issue #1646, EPIC
# #1645 C1). On an isolated tmux server, a sandbox conf dir and a fake Claude with
# a real peer inbox, pins:
#   A  @fleet_id: fleet_window_fid mints a canonical UUID once and returns the same
#      one on every later ask; fleet_win_for_fid finds the window by it; a
#      warm-pool window carrying it never answers; two windows carrying one →
#      rc 2 AMBIGUOUS, never a pick; fleet_win_for_addr takes a key or an identity.
#   B  THE RENAME (the issue's 完成判据 + 上线证据): a child spawned by scratch-5
#      reports to it — then scratch-5 is bound to an issue (fleet-bind.sh's
#      re-mark: @issue set, @raw unset), so its key is issue-99 — and the child's
#      next report still reaches the SAME window, `reported → …` both times, two
#      frames in its inbox, the second booked under issue-99 and the child's
#      @origin re-pointed there. A child with no @origin_fid (spawned before
#      #1646) is the contrast: it books under scratch-5, a book the parent no
#      longer reads and a key the sidebar and the hub no longer know.
#   C  fleet_origin_heal re-points a child's @origin at its parent's current key
#      (found by @origin_fid) and drops the old key's @origin_gen; a child whose
#      parent is not live, or with no @origin_fid, is left alone.
#   D  worker_id: fleet_worker_id is `<fleet UUID>/<fleet_id>`, fleet_worker_id_key
#      the old `<fleet UUID>/<key>`; fleet_worker_locate resolves BOTH to the
#      window (the old form is an alias for one version), _fleet_wid_split takes
#      both and refuses an upper-case or malformed identity; the identity form
#      still names the window after its key changed.
#   E  the roads that carry it (each never re-mints): the restore snapshot's FID
#      row (fleet-restore-selftest.sh pins the map end to end; here: the
#      resolver's --fid), fleet-migrate.sh, fleet-move.sh's bundle (fid_bundle →
#      `<sid>.fleet-id`, read back by fleet-move-remote.sh launch), the spawners
#      mint it, the bind sites and the cleanup tick heal.
#   F  zsh: sourced into zsh (Claude Code's Bash tool on the operator's Mac),
#      fleet_window_fid / fleet_worker_id / fleet_origin_key answer what bash does.
#   G  the FLEET's identity is frozen (issue #1936): a fleet with no identity file
#      gets, on its first fleet_uuid, exactly the old algorithm's value (uuid5 of
#      machine id + session/repo/checkout), written to fleets/<sess>/identity
#      0600; then FLEET_REPO / FLEET_MAIN changed — or gone — move neither
#      fleet_uuid, nor the inventory's fleet_id, nor fleet_uuid_home; a name with
#      no conf writes nothing; a damaged file is rewritten; install-apply's conf
#      pass freezes before fleet-conf.sh migrate.
# tmux / python3 / perl absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX=$(command -v tmux) || { echo 'worker-identity selftest: tmux absent — SKIP'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'worker-identity selftest: python3 absent — SKIP'; exit 0; }
command -v perl >/dev/null 2>&1 || { echo 'worker-identity selftest: perl absent — SKIP'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/worker-identity.XXXXXX")" || exit 2
L="wid1646$$"
export TMPDIR="$WORK"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
printf 'FLEET_REPO=acme/app\nFLEET_MAIN=%s/main\n' "$WORK" > "$FLEET_CONF_DIR/fleets/$L/conf"
mkdir -p "$WORK/main" "$WORK/app-scratch-5"
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_HUB_STATUS_CMD FLEET_CHILD_REPORT

FAIL=0; CHECKS=0
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf '      got: %s\n' "$2" >&2; }
ok() { CHECKS=$((CHECKS + 1)); }
tf() { "$REAL_TMUX" -L "$L" "$@"; }
opt() { tf show-options -wqv -t "$1" "$2"; }
INBOX_PID=''
cleanup() {
  "$REAL_TMUX" -L "$L" kill-server 2>/dev/null
  [ -n "$INBOX_PID" ] && kill "$INBOX_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
lib() { bash -c '. "$1/fleet-lib.sh"; shift; "$@"' _ "$BIN" "$@"; }
is_uuid() { printf '%s' "$1" | grep -Eqx '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'; }

tf -f /dev/null new-session -d -s "$L" -n home 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'worker-identity selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }

# The PARENT: scratch-5, a live fake Claude (a perl named `claude` — what
# fleet_pane_claude_pid matches) registered with a real peer inbox socket.
mkdir -p "$WORK/fakebin"; ln -sf "$(command -v perl)" "$WORK/fakebin/claude"
INBOX_LOG="$WORK/inbox.bin"; : > "$INBOX_LOG"; INBOX_SOCK="$WORK/inbox.sock"
python3 - "$INBOX_SOCK" "$INBOX_LOG" <<'PY' &
import os, socket, sys
path, log = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(path); s.listen(8)
while True:
    c, _ = s.accept()
    buf = b""
    while True:
        d = c.recv(65536)
        if not d: break
        buf += d
    c.close()
    with open(log, "ab") as fh: fh.write(buf + b"\n--frame--\n")
PY
INBOX_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$INBOX_SOCK" ] && break; sleep 0.3; done
[ -S "$INBOX_SOCK" ] || { echo 'worker-identity selftest: the fake inbox never appeared — SKIP' >&2; exit 0; }

P=$(tf new-window -d -P -F '#{window_id}' -n parent -c "$WORK/app-scratch-5" "PATH='$WORK/fakebin:\$PATH' exec claude -e 'sleep 600'")
tf set-window-option -t "$P" @raw 1; tf set-window-option -t "$P" @worktree "$WORK/app-scratch-5"
PPID_=''
for _ in 1 2 3 4 5 6 7 8 9 10; do
  PPID_=$(lib fleet_pane_claude_pid "$P" "$L" 2>/dev/null) && [ -n "$PPID_" ] && break
  sleep 0.3
done
[ -n "$PPID_" ] || { echo 'worker-identity selftest: no fake claude under the parent — SKIP' >&2; exit 0; }
printf '{"sessionId":"sid-parent","messagingSocketPath":"%s"}\n' "$INBOX_SOCK" > "$FLEET_CC_SESSIONS_DIR/$PPID_.json"
printf '{"peerToken":"tok-parent"}\n' > "$FLEET_CC_SESSIONS_DIR/$PPID_.deadbeef.key"
frames() { local n; n=$(grep -c -- '--frame--' "$INBOX_LOG" 2>/dev/null); printf '%s' "${n:-0}"; }

# --- A: @fleet_id ------------------------------------------------------------------
PF=$(lib fleet_window_fid "$L" "$P" "$L")
ok; is_uuid "$PF" && [ "$(opt "$P" @fleet_id)" = "$PF" ] || fail "A: fleet_window_fid mints a canonical UUID and stamps it" "$PF"
ok; [ "$(lib fleet_window_fid "$L" "$P" "$L")" = "$PF" ] || fail "A: a second ask returns the same identity — never re-minted"
ok; [ "$(lib fleet_win_for_fid "$PF" "$L")" = "$P" ] || fail "A: fleet_win_for_fid finds the window by its identity"
ok; [ "$(lib fleet_win_for_addr "$PF" "$L")" = "$P" ] && [ "$(lib fleet_win_for_addr scratch-5 "$L")" = "$P" ] \
  || fail "A: fleet_win_for_addr takes an identity or a key"
POOLW=$(tf new-window -d -P -F '#{window_id}' -n pooled 'while :; do sleep 300; done')
tf set-window-option -t "$POOLW" @pool 1; tf set-window-option -t "$POOLW" @fleet_id "$PF"
ok; [ "$(lib fleet_win_for_fid "$PF" "$L")" = "$P" ] || fail "A: a warm-pool window carrying the identity never answers"
tf set-window-option -u -t "$POOLW" @pool
out=$(lib fleet_win_for_fid "$PF" "$L" 2>"$WORK/err"); rc=$?
ok; [ "$rc" = 2 ] && [ -z "$out" ] && grep -q ambiguous "$WORK/err" || fail "A: two windows carrying one identity → rc 2, no pick" "rc=$rc out=$out $(cat "$WORK/err")"
tf kill-window -t "$POOLW"
ok; lib fleet_win_for_fid 00000000-0000-4000-8000-000000000000 "$L" >/dev/null; [ $? = 1 ] || fail "A: an identity nobody carries → rc 1"

# --- B: the rename — reported, then reported again to the same window ---------------
C=$(tf new-window -d -P -F '#{window_id}' -n kid 'while :; do sleep 300; done')
tf set-window-option -t "$C" @issue 600; tf set-window-option -t "$C" @origin scratch-5
lib fleet_stamp_origin_wid "$L" "$C" scratch-5 "$L"
ok; [ "$(opt "$C" @origin_fid)" = "$PF" ] || fail "B: a spawn stamps the parent's identity as @origin_fid (no fleet UUID needed)" "$(opt "$C" @origin_fid)"
rp() { out=$(env -u TMUX bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$C" --state blocked --summary "$1" 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err"); }
before=$(frames)
rp 'first: before the rename'
ok; [ "$rc" = 0 ] && case "$out" in "reported → scratch-5 ($P)"*) true ;; *) false ;; esac \
  || fail "B: before the rename the child reports to scratch-5" "rc=$rc out=$out err=$err"
R1=$out
# fleet-bind.sh's re-mark: the scratch becomes the worker for #99.
tf set-window-option -t "$P" @issue 99; tf set-window-option -u -t "$P" @raw
ok; [ "$(lib fleet_window_okey "$L" "$P")" = issue-99 ] || fail "B: after the bind the parent's key is issue-99"
rp 'second: after the rename'
ok; [ "$rc" = 0 ] && case "$out" in "reported → issue-99 ($P)"*) true ;; *) false ;; esac \
  || fail "B: after the rename the child STILL reports to the same window (now issue-99)" "rc=$rc out=$out err=$err"
R2=$out
ok; [ "$(frames)" = $((before + 2)) ] || fail "B: two frames reached the parent's inbox" "$(frames) (was $before)"
ok; [ "$(opt "$C" @origin)" = issue-99 ] || fail "B: the report re-pointed the child's @origin at the parent's current key" "$(opt "$C" @origin)"
ok; [ -s "$FLEET_CONF_DIR/fleets/$L/children/issue-99.ndjson" ] && grep -q 'second: after the rename' "$FLEET_CONF_DIR/fleets/$L/children/issue-99.ndjson" \
  || fail "B: the second report is booked under the key the parent answers to now"
# The contrast — a child from before #1646 (no @origin_fid) still books under the
# name its parent wore, scratch-5: a book the parent (issue-99 now) never reads,
# and a key the sidebar's nesting and the hub's inventory no longer know.
C0=$(tf new-window -d -P -F '#{window_id}' -n oldkid 'while :; do sleep 300; done')
tf set-window-option -t "$C0" @issue 601; tf set-window-option -t "$C0" @origin scratch-5
out=$(env -u TMUX bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$C0" --state blocked --summary x --dry-run 2>&1)
ok; case "$out" in *"would send to scratch-5 "*) true ;; *) false ;; esac || fail "B: a key-only child of a renamed parent is booked under the stale key (the contrast)" "$out"
tf kill-window -t "$C0"
printf '%s\n%s\n' "$R1" "$R2" > "$WORK/evidence.txt"
[ -n "${WORKER_IDENTITY_EVIDENCE:-}" ] && cp "$WORK/evidence.txt" "$WORKER_IDENTITY_EVIDENCE"

# --- C: fleet_origin_heal ------------------------------------------------------------
C2=$(tf new-window -d -P -F '#{window_id}' -n kid2 'while :; do sleep 300; done')
tf set-window-option -t "$C2" @issue 602; tf set-window-option -t "$C2" @origin scratch-5
tf set-window-option -t "$C2" @origin_fid "$PF"; tf set-window-option -t "$C2" @origin_gen 3
C3=$(tf new-window -d -P -F '#{window_id}' -n kid3 'while :; do sleep 300; done')
tf set-window-option -t "$C3" @issue 603; tf set-window-option -t "$C3" @origin scratch-5
tf set-window-option -t "$C3" @origin_fid 00000000-0000-4000-8000-000000000000
hout=$(lib fleet_origin_heal "$L" "$L")
ok; [ "$hout" = "healed $C2 scratch-5 → issue-99" ] || fail "C: heal names exactly the one child it re-pointed" "$hout"
ok; [ "$(opt "$C2" @origin)" = issue-99 ] && [ -z "$(opt "$C2" @origin_gen)" ] || fail "C: @origin re-pointed, the old key's @origin_gen dropped" "$(opt "$C2" @origin)|$(opt "$C2" @origin_gen)"
ok; [ "$(opt "$C3" @origin)" = scratch-5 ] || fail "C: a child whose parent is not live is left alone"
ok; [ -z "$(lib fleet_origin_heal "$L" "$L")" ] || fail "C: a second heal has nothing to do"
tf kill-window -t "$C2"; tf kill-window -t "$C3"

# --- D: worker_id, both forms --------------------------------------------------------
(cd "$BIN" && python3 -c 'import sys, fleet_control as c; c.Control(sys.argv[1]).inventory()' "$FLEET_CONF_DIR" >/dev/null 2>&1)
U=$(lib fleet_uuid "$L")
if is_uuid "$U"; then
  ok; [ "$(lib fleet_worker_id "$L" "$P")" = "$U/$PF" ] || fail "D: worker_id is <fleet UUID>/<fleet_id>" "$(lib fleet_worker_id "$L" "$P")"
  ok; [ "$(lib fleet_worker_id_key "$L" "$P")" = "$U/issue-99" ] || fail "D: the key-form alias" "$(lib fleet_worker_id_key "$L" "$P")"
  ok; [ "$(lib fleet_worker_locate "wid:$U/$PF" "$L")" = "local $P $L" ] || fail "D: locate by the identity form"
  ok; [ "$(lib fleet_worker_locate "wid:$U/issue-99" "$L")" = "local $P $L" ] || fail "D: the old <uuid>/<key> form still resolves"
  ok; [ "$(lib fleet_worker_locate "wid:$PF" "$L")" = "local $P $L" ] || fail "D: a bare identity names this fleet's session"
  ok; [ "$(lib fleet_key_wid "$L" issue-99 "$L")" = "$U/$PF" ] || fail "D: fleet_key_wid names a live key's session by identity"
  ok; [ "$(lib fleet_key_wid "$L" issue-404 "$L")" = "$U/issue-404" ] || fail "D: …and a key nobody answers to by the key"
else
  fail "D: the sandbox control database minted no fleet UUID" "$U"
fi
for t in "$PF" "wid:$PF" "11111111-2222-4333-8444-555555555555/$PF"; do
  ok; lib _fleet_wid_split "$t" >/dev/null || fail "D: _fleet_wid_split takes $t"
done
UPPER=$(printf '%s' "$PF" | tr 'a-f' 'A-F')
for t in "$UPPER" "wid:${PF}0" "11111111-2222-4333-8444-555555555555/$UPPER"; do
  ok; lib _fleet_wid_split "$t" >/dev/null && fail "D: _fleet_wid_split must refuse $t"
done

# --- E: the roads that carry it --------------------------------------------------------
row=$(printf '%s|wrk-1|r/x|issue-7|%s|7|done|-|-|0|-\n' "$PF" "$WORK/app-scratch-5" \
      | python3 "$BIN/.fleet-restore-resolve.py" "$WORK/main" --lead --sid --fid 2>/dev/null)
ok; [ "$(printf '%s\n' "$row" | head -1)" = "FID	$PF" ] && [ "$(printf '%s\n' "$row" | sed -n 2p | cut -f1-2)" = "WIN	issue-7" ] \
  || fail "E: the restore resolver writes FID <fleet_id> just before the WIN row" "$row"
row=$(printf 'not-a-uuid|wrk-1|r/x|issue-7|%s|7|done|-|-|0|-\n' "$WORK/app-scratch-5" \
      | python3 "$BIN/.fleet-restore-resolve.py" "$WORK/main" --lead --sid --fid 2>/dev/null)
ok; ! printf '%s\n' "$row" | grep -q '^FID' || fail "E: a malformed identity writes no FID row" "$row"
ok; grep -q '|#{@fleet_id}|#{@cc_session_id}|' "$BIN/fleet-restore.sh" && grep -q -- '--lead --sid --fid' "$BIN/fleet-restore.sh" \
  || fail "E: the snapshot feeds @fleet_id to the resolver"
ok; grep -q "wopt \"\$wid\" '#{@fleet_id}'" "$BIN/fleet-migrate.sh" && grep -q '@fleet_id "$fid"' "$BIN/fleet-migrate.sh" \
  || fail "E: fleet-migrate.sh carries @fleet_id to the new window"
# fleet-move.sh's bundle: the identity rides as <sid>.fleet-id, read back by launch.
FMOVE_OUT=$(bash -c '
  BIN=$1; L=$2; W=$3
  . "$BIN/fleet-lib.sh"; . "$BIN/fleet-move.sh" >/dev/null 2>&1
  TM() { tmux -L "$L" "$@"; }
  fid_bundle "$W" sid-xyz
  [ "${#FIDTAR[@]}" -eq 3 ] || exit 1
  cat "${FIDTAR[1]}/${FIDTAR[2]}"; d=${FIDTAR[1]}; fid_bundle_drop; [ ! -e "$d" ] || exit 2' _ "$BIN" "$L" "$P" 2>&1)
ok; [ "$FMOVE_OUT" = "$PF" ] || fail "E: fleet-move.sh bundles the identity as <sid>.fleet-id (and cleans up)" "$FMOVE_OUT"
ok; grep -q '\$sid.fleet-id' "$BIN/fleet-move-remote.sh" && grep -q '@fleet_id "$_fid"' "$BIN/fleet-move-remote.sh" \
  || fail "E: fleet-move-remote.sh launch stamps the bundled identity"
for f in dash-issue-session.sh dash-raw-session.sh; do
  ok; grep -q 'fleet_window_fid "$SESS" "$win" "$SOCK"' "$BIN/$f" || fail "E: $f mints the identity at spawn"
done
for f in fleet-bind.sh dash-enter.sh fleet-cleanup-daemon.sh; do
  ok; grep -q 'fleet_origin_heal ' "$BIN/$f" || fail "E: $f heals children's @origin after a key change"
done

# --- F: zsh answers what bash does ------------------------------------------------------
if command -v zsh >/dev/null 2>&1; then
  zf=$(zsh -c '. "$1/fleet-lib.sh"; fleet_window_fid "$2" "$3" "$2"' _ "$BIN" "$L" "$P" 2>/dev/null)
  ok; [ "$zf" = "$PF" ] || fail "F: zsh's fleet_window_fid = bash's" "zsh=$zf bash=$PF"
  if is_uuid "${U:-}"; then
    zw=$(zsh -c '. "$1/fleet-lib.sh"; fleet_worker_id "$2" "$3"' _ "$BIN" "$L" "$P" 2>/dev/null)
    ok; [ "$zw" = "$U/$PF" ] || fail "F: zsh's fleet_worker_id = bash's" "zsh=$zw"
  fi
  ok; [ "$(TMUX="$(tf display-message -p '#{socket_path},0,0')" TMUX_PANE="$(tf display-message -p -t "$P" '#{pane_id}')" \
          zsh -c '. "$1/fleet-lib.sh"; fleet_origin_key' _ "$BIN" 2>/dev/null)" = issue-99 ] \
    || fail "F: zsh's fleet_origin_key in the renamed parent's pane = issue-99"
  zn=$(zsh -c '. "$1/fleet-lib.sh"; fleet_fid_mint' _ "$BIN" 2>/dev/null)
  ok; is_uuid "$zn" || fail "F: zsh's fleet_fid_mint mints a canonical UUID" "$zn"
else
  echo 'worker-identity selftest: zsh absent — F skipped'
fi

# --- G: the fleet's identity is frozen (issue #1936) ----------------------------------
G="gfz1936$$"; GD="$FLEET_CONF_DIR/fleets/$G"; mkdir -p "$GD"
printf 'FLEET_REPO=acme/first\nFLEET_MAIN=%s/first\n' "$WORK" > "$GD/conf"
old_alg() { python3 - "$FLEET_CONF_DIR/control/state.sqlite3" "$@" <<'PY'
import json, sqlite3, sys, uuid
m = sqlite3.connect(sys.argv[1]).execute("SELECT value FROM metadata WHERE key='machine_id'").fetchone()[0]
print(uuid.uuid5(uuid.UUID(m), json.dumps(sys.argv[2:5], ensure_ascii=False, sort_keys=True, separators=(",", ":"))))
PY
}
inv_id() { (cd "$BIN" && python3 -c 'import sys, fleet_control as c
print([x["fleet_id"] for x in c.Control(sys.argv[1]).inventory() if x["name"] == sys.argv[2]][0])' "$FLEET_CONF_DIR" "$1" 2>/dev/null); }
OLD=$(old_alg "$G" acme/first "$WORK/first")
ok; [ ! -e "$GD/identity" ] || fail "G: a new fleet starts with no identity file"
GU=$(lib fleet_uuid "$G")
ok; is_uuid "$GU" && [ "$GU" = "$OLD" ] || fail "G: the first fleet_uuid = the old algorithm's value" "got=$GU old=$OLD"
ok; [ "$(cat "$GD/identity" 2>/dev/null)" = "$OLD" ] || fail "G: the first call writes fleets/<sess>/identity" "$(cat "$GD/identity" 2>&1)"
ok; [ "$(ls -l "$GD/identity" 2>/dev/null | cut -c1-10)" = '-rw-------' ] || fail "G: the identity file is 0600" "$(ls -l "$GD/identity")"
ok; [ "$(inv_id "$G")" = "$OLD" ] || fail "G: the inventory's fleet_id = the frozen value" "$(inv_id "$G")"
printf 'FLEET_REPO=acme/second\nFLEET_MAIN=%s/second\n' "$WORK" > "$GD/conf"
ok; [ "$(lib fleet_uuid "$G")" = "$OLD" ] || fail "G: FLEET_REPO / FLEET_MAIN changed → fleet_uuid unchanged" "$(lib fleet_uuid "$G")"
ok; [ "$(inv_id "$G")" = "$OLD" ] || fail "G: …and the inventory's fleet_id unchanged" "$(inv_id "$G")"
ok; [ "$(lib fleet_uuid_home "$OLD")" = "$G" ] || fail "G: …and fleet_uuid_home still finds the fleet" "$(lib fleet_uuid_home "$OLD")"
ok; [ "$(old_alg "$G" acme/second "$WORK/second")" != "$OLD" ] || fail "G: (contrast) the old algorithm would have moved"
printf 'FLEET_BASE_BRANCH=main\n' > "$GD/conf"
ok; [ "$(lib fleet_uuid "$G")" = "$OLD" ] && [ "$(inv_id "$G")" = "$OLD" ] \
  || fail "G: no FLEET_REPO at all → the same identity" "$(lib fleet_uuid "$G") $(inv_id "$G")"
ok; [ "$(lib fleet_uuid "$L")" = "${U:-x}" ] && [ "$(cat "$FLEET_CONF_DIR/fleets/$L/identity" 2>/dev/null)" = "${U:-y}" ] \
  || fail "G: the D fleet's value froze as it was minted"
NC="nocf1936$$"
ok; is_uuid "$(lib fleet_uuid "$NC")" && [ ! -e "$FLEET_CONF_DIR/fleets/$NC" ] || fail "G: a name with no conf answers but writes nothing"
printf 'garbage\n' > "$GD/identity"
printf 'FLEET_REPO=acme/first\nFLEET_MAIN=%s/first\n' "$WORK" > "$GD/conf"
ok; [ "$(lib fleet_uuid "$G")" = "$OLD" ] && [ "$(cat "$GD/identity")" = "$OLD" ] || fail "G: a damaged file is recomputed and rewritten" "$(cat "$GD/identity")"
ok; awk '/fleet_uuid "\$s"/ { f = NR } /fleet-conf.sh" migrate/ { m = NR } END { exit !(f && m && f < m) }' "$BIN/fleet-install-apply.sh" \
  || fail "G: install-apply's conf pass freezes every fleet before fleet-conf.sh migrate"

if [ "$FAIL" -gt 0 ]; then
  printf 'worker-identity selftest: %d of %d checks FAILED\n' "$FAIL" "$CHECKS" >&2
  exit 1
fi
printf 'worker-identity selftest: all %d checks passed\n' "$CHECKS"
