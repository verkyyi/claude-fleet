#!/bin/bash
# worker-identity-selftest.sh — a session's lifelong identity (issue #1646, EPIC
# #1645 C1). On an isolated tmux server, a sandbox conf dir and a fake Claude with
# a real peer inbox, pins:
#   A  @fleet_id: fleet_window_fid mints a canonical UUID once and returns the same
#      one on every later ask; fleet_win_for_fid finds the window by it; two windows carrying one →
#      rc 2 AMBIGUOUS, never a pick; fleet_win_for_addr takes a key or an identity.
#   B  THE RENAME (the issue's 完成判据 + 上线证据): a child spawned by scratch-5
#      reports to it — then scratch-5's key changes to an issue's (a
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
#   H  what the inventory reports derives the frozen UUID (issue #3397): a fleet
#      frozen repo-less whose starter came a moment later, a one-line file of the
#      same, a fleet whose first repo was replaced — each reports the (repo,
#      checkout) its UUID was minted from, so the hub's re-derivation adds up; an
#      unmoved fleet is reported as before; fleet-up adds its repo before its conf.
# tmux / python3 / perl absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
. "$BIN/selftest-repo-fixture.sh"
REAL_TMUX=$(command -v tmux) || { echo 'worker-identity selftest: tmux absent — SKIP'; exit 0; }
st_need python3 perl

WORK="$(mktemp -d "${TMPDIR:-/tmp}/worker-identity.XXXXXX")" || exit 2
L="wid1646$$"
export TMPDIR="$WORK"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
: > "$FLEET_CONF_DIR/fleets/$L/conf"
fx_repo "$FLEET_CONF_DIR" "$L" acme/app FLEET_MAIN="$WORK/main"
mkdir -p "$WORK/main" "$WORK/app-scratch-5"
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_HUB_STATUS_CMD FLEET_CHILD_REPORT

st_tally
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
st_count; is_uuid "$PF" && [ "$(opt "$P" @fleet_id)" = "$PF" ] || st_miss "A: fleet_window_fid mints a canonical UUID and stamps it" "$PF"
st_count; [ "$(lib fleet_window_fid "$L" "$P" "$L")" = "$PF" ] || st_miss "A: a second ask returns the same identity — never re-minted"
st_count; [ "$(lib fleet_win_for_fid "$PF" "$L")" = "$P" ] || st_miss "A: fleet_win_for_fid finds the window by its identity"
st_count; [ "$(lib fleet_win_for_addr "$PF" "$L")" = "$P" ] && [ "$(lib fleet_win_for_addr scratch-5 "$L")" = "$P" ] \
  || st_miss "A: fleet_win_for_addr takes an identity or a key"
POOLW=$(tf new-window -d -P -F '#{window_id}' -n pooled 'while :; do sleep 300; done')
tf set-window-option -t "$POOLW" @fleet_id "$PF"
out=$(lib fleet_win_for_fid "$PF" "$L" 2>"$WORK/err"); rc=$?
st_count; [ "$rc" = 2 ] && [ -z "$out" ] && grep -q ambiguous "$WORK/err" || st_miss "A: two windows carrying one identity → rc 2, no pick" "rc=$rc out=$out $(cat "$WORK/err")"
tf kill-window -t "$POOLW"
st_count; lib fleet_win_for_fid 00000000-0000-4000-8000-000000000000 "$L" >/dev/null; [ $? = 1 ] || st_miss "A: an identity nobody carries → rc 1"

# --- B: the rename — reported, then reported again to the same window ---------------
Q=acme-app:   # every key carries the fleet's repo, one repo or five (issue #1939)
C=$(tf new-window -d -P -F '#{window_id}' -n kid 'while :; do sleep 300; done')
tf set-window-option -t "$C" @issue 600; tf set-window-option -t "$C" @origin scratch-5
lib fleet_stamp_origin_wid "$L" "$C" scratch-5 "$L"
st_count; [ -z "$(opt "$C" @origin_fid)" ] || st_miss "B: retired stamp helper writes no Parent"
tf set-window-option -t "$C" @origin_fid "$PF"   # pre-retirement fixture
rp() { out=$(env -u TMUX bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$C" --state blocked --summary "$1" 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err"); }
before=$(frames)
rp 'first: before the rename'
st_count; [ "$rc" = 0 ] && case "$out" in RETIRED:*) true ;; *) false ;; esac \
  || st_miss "B: report remains retired before rename" "rc=$rc out=$out err=$err"
R1=$out
# a re-mark: the scratch becomes the worker for #99 (its key changes).
tf set-window-option -t "$P" @issue 99; tf set-window-option -u -t "$P" @raw
st_count; [ "$(lib fleet_window_okey "$L" "$P")" = "${Q}issue-99" ] || st_miss "B: after the bind the parent's key is issue-99"
rp 'second: after the rename'
st_count; [ "$rc" = 0 ] && case "$out" in RETIRED:*) true ;; *) false ;; esac \
  || st_miss "B: report remains retired after rename" "rc=$rc out=$out err=$err"
R2=$out
st_count; [ "$(frames)" = "$before" ] || st_miss "B: retired reports send zero inbox frames" "$(frames) (was $before)"
st_count; [ "$(opt "$C" @origin)" = scratch-5 ] || st_miss "B: retired report does not rewrite historical origin" "$(opt "$C" @origin)"
st_count; [ ! -e "$FLEET_CONF_DIR/fleets/$L/children/${Q}issue-99.ndjson" ] || st_miss "B: no new parent ledger is created"
st_count; [ "$(lib fleet_origin_win "$L" "$C" "$L")" = "$P" ] && [ "$(opt "$C" @origin_fid)" = "$PF" ] \
  || st_miss "B: stable identity still resolves the renamed window"
# The contrast — a child from before #1646 (no @origin_fid) still books under the
# name its parent wore, scratch-5: a book the parent (issue-99 now) never reads,
# and a key the sidebar's nesting and the hub's inventory no longer know.
C0=$(tf new-window -d -P -F '#{window_id}' -n oldkid 'while :; do sleep 300; done')
tf set-window-option -t "$C0" @issue 601; tf set-window-option -t "$C0" @origin scratch-5
out=$(env -u TMUX bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$C0" --state blocked --summary x --dry-run 2>&1)
st_count; case "$out" in RETIRED:*) true ;; *) false ;; esac || st_miss "B: key-only stale parent cannot reactivate reporting" "$out"
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
st_count; [ -z "$hout" ] || st_miss "C: retired heal is silent" "$hout"
st_count; [ "$(opt "$C2" @origin)" = scratch-5 ] && [ "$(opt "$C2" @origin_gen)" = 3 ] || st_miss "C: heal preserves historical stamps without rewriting them"
st_count; [ "$(opt "$C3" @origin)" = scratch-5 ] || st_miss "C: no qualification writes a new Parent route"
st_count; [ -z "$(lib fleet_origin_heal "$L" "$L")" ] || st_miss "C: repeated old hook remains inert"
tf kill-window -t "$C2"; tf kill-window -t "$C3"

# --- D: worker_id, both forms --------------------------------------------------------
(cd "$BIN" && python3 -c 'import sys, fleet_control as c; c.Control(sys.argv[1]).inventory()' "$FLEET_CONF_DIR" >/dev/null 2>&1)
U=$(lib fleet_uuid "$L")
if is_uuid "$U"; then
  st_count; [ "$(lib fleet_worker_id "$L" "$P")" = "$U/$PF" ] || st_miss "D: worker_id is <fleet UUID>/<fleet_id>" "$(lib fleet_worker_id "$L" "$P")"
  st_count; [ "$(lib fleet_worker_id_key "$L" "$P")" = "$U/${Q}issue-99" ] || st_miss "D: the key-form alias" "$(lib fleet_worker_id_key "$L" "$P")"
  st_count; [ "$(lib fleet_worker_locate "wid:$U/$PF" "$L")" = "local $P $L" ] || st_miss "D: locate by the identity form"
  st_count; [ "$(lib fleet_worker_locate "wid:$U/issue-99" "$L")" = "local $P $L" ] || st_miss "D: the old <uuid>/<key> form still resolves"
  st_count; [ "$(lib fleet_worker_locate "wid:$PF" "$L")" = "local $P $L" ] || st_miss "D: a bare identity names this fleet's session"
  st_count; [ "$(lib fleet_key_wid "$L" issue-99 "$L")" = "$U/$PF" ] || st_miss "D: fleet_key_wid names a live key's session by identity"
  st_count; [ "$(lib fleet_key_wid "$L" issue-404 "$L")" = "$U/issue-404" ] || st_miss "D: …and a key nobody answers to by the key"
else
  st_miss "D: the sandbox control database minted no fleet UUID" "$U"
fi
for t in "$PF" "wid:$PF" "11111111-2222-4333-8444-555555555555/$PF"; do
  st_count; lib _fleet_wid_split "$t" >/dev/null || st_miss "D: _fleet_wid_split takes $t"
done
UPPER=$(printf '%s' "$PF" | tr 'a-f' 'A-F')
for t in "$UPPER" "wid:${PF}0" "11111111-2222-4333-8444-555555555555/$UPPER"; do
  st_count; lib _fleet_wid_split "$t" >/dev/null && st_miss "D: _fleet_wid_split must refuse $t"
done

# --- E: the roads that carry it --------------------------------------------------------
row=$(printf '%s|wrk-1|r/x|issue-7|%s|7|done|-|-|0|-\n' "$PF" "$WORK/app-scratch-5" \
      | python3 "$BIN/.fleet-restore-resolve.py" "$WORK/main" --lead --sid --fid 2>/dev/null)
st_count; [ "$(printf '%s\n' "$row" | head -1)" = "FID	$PF" ] && [ "$(printf '%s\n' "$row" | sed -n 2p | cut -f1-2)" = "WIN	issue-7" ] \
  || st_miss "E: the restore resolver writes FID <fleet_id> just before the WIN row" "$row"
row=$(printf 'not-a-uuid|wrk-1|r/x|issue-7|%s|7|done|-|-|0|-\n' "$WORK/app-scratch-5" \
      | python3 "$BIN/.fleet-restore-resolve.py" "$WORK/main" --lead --sid --fid 2>/dev/null)
st_count; ! printf '%s\n' "$row" | grep -q '^FID' || st_miss "E: a malformed identity writes no FID row" "$row"
st_count; grep -q '|#{@fleet_id}|#{@cc_session_id}|' "$BIN/fleet-restore.sh" && grep -q -- '--lead --sid --fid' "$BIN/fleet-restore.sh" \
  || st_miss "E: the snapshot feeds @fleet_id to the resolver"
st_count; grep -q "wopt \"\$wid\" '#{@fleet_id}'" "$BIN/fleet-migrate.sh" && grep -q '@fleet_id "$fid"' "$BIN/fleet-migrate.sh" \
  || st_miss "E: fleet-migrate.sh carries @fleet_id to the new window"
# fleet-move.sh's bundle: the identity rides as <sid>.fleet-id, read back by launch.
FMOVE_OUT=$(bash -c '
  BIN=$1; L=$2; W=$3
  . "$BIN/fleet-lib.sh"; . "$BIN/fleet-move.sh" >/dev/null 2>&1
  TM() { tmux -L "$L" "$@"; }
  fid_bundle "$W" sid-xyz
  [ "${#FIDTAR[@]}" -eq 3 ] || exit 1
  cat "${FIDTAR[1]}/${FIDTAR[2]}"; d=${FIDTAR[1]}; fid_bundle_drop; [ ! -e "$d" ] || exit 2' _ "$BIN" "$L" "$P" 2>&1)
st_count; [ "$FMOVE_OUT" = "$PF" ] || st_miss "E: fleet-move.sh bundles the identity as <sid>.fleet-id (and cleans up)" "$FMOVE_OUT"
st_count; grep -q '\$sid.fleet-id' "$BIN/fleet-move-remote.sh" && grep -q '@fleet_id "$_fid"' "$BIN/fleet-move-remote.sh" \
  || st_miss "E: fleet-move-remote.sh launch stamps the bundled identity"
for f in dash-issue-session.sh dash-raw-session.sh; do
  st_count; grep -q 'fleet_window_fid "$SESS" "$win" "$SOCK"' "$BIN/$f" || st_miss "E: $f mints the identity at spawn"
done
st_count; grep -q 'fleet_origin_heal ' "$BIN/fleet-cleanup-daemon.sh" || st_miss "E: fleet-cleanup-daemon.sh heals children's @origin after a key change"

# --- F: zsh answers what bash does ------------------------------------------------------
if command -v zsh >/dev/null 2>&1; then
  zf=$(zsh -c '. "$1/fleet-lib.sh"; fleet_window_fid "$2" "$3" "$2"' _ "$BIN" "$L" "$P" 2>/dev/null)
  st_count; [ "$zf" = "$PF" ] || st_miss "F: zsh's fleet_window_fid = bash's" "zsh=$zf bash=$PF"
  if is_uuid "${U:-}"; then
    zw=$(zsh -c '. "$1/fleet-lib.sh"; fleet_worker_id "$2" "$3"' _ "$BIN" "$L" "$P" 2>/dev/null)
    st_count; [ "$zw" = "$U/$PF" ] || st_miss "F: zsh's fleet_worker_id = bash's" "zsh=$zw"
  fi
  st_count; [ "$(TMUX="$(tf display-message -p '#{socket_path},0,0')" TMUX_PANE="$(tf display-message -p -t "$P" '#{pane_id}')" \
          zsh -c '. "$1/fleet-lib.sh"; fleet_origin_key' _ "$BIN" 2>/dev/null)" = "${Q}issue-99" ] \
    || st_miss "F: zsh's fleet_origin_key in the renamed parent's pane = issue-99"
  zn=$(zsh -c '. "$1/fleet-lib.sh"; fleet_fid_mint' _ "$BIN" 2>/dev/null)
  st_count; is_uuid "$zn" || st_miss "F: zsh's fleet_fid_mint mints a canonical UUID" "$zn"
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
st_count; [ ! -e "$GD/identity" ] || st_miss "G: a new fleet starts with no identity file"
GU=$(lib fleet_uuid "$G")
st_count; is_uuid "$GU" && [ "$GU" = "$OLD" ] || st_miss "G: the first fleet_uuid = the old algorithm's value" "got=$GU old=$OLD"
st_count; [ "$(head -1 "$GD/identity" 2>/dev/null)" = "$OLD" ] || st_miss "G: the first call writes fleets/<sess>/identity" "$(cat "$GD/identity" 2>&1)"
st_count; [ "$(ls -l "$GD/identity" 2>/dev/null | cut -c1-10)" = '-rw-------' ] || st_miss "G: the identity file is 0600" "$(ls -l "$GD/identity")"
st_count; [ "$(inv_id "$G")" = "$OLD" ] || st_miss "G: the inventory's fleet_id = the frozen value" "$(inv_id "$G")"
printf 'FLEET_REPO=acme/second\nFLEET_MAIN=%s/second\n' "$WORK" > "$GD/conf"
st_count; [ "$(lib fleet_uuid "$G")" = "$OLD" ] || st_miss "G: FLEET_REPO / FLEET_MAIN changed → fleet_uuid unchanged" "$(lib fleet_uuid "$G")"
st_count; [ "$(inv_id "$G")" = "$OLD" ] || st_miss "G: …and the inventory's fleet_id unchanged" "$(inv_id "$G")"
st_count; [ "$(lib fleet_uuid_home "$OLD")" = "$G" ] || st_miss "G: …and fleet_uuid_home still finds the fleet" "$(lib fleet_uuid_home "$OLD")"
st_count; [ "$(old_alg "$G" acme/second "$WORK/second")" != "$OLD" ] || st_miss "G: (contrast) the old algorithm would have moved"
printf 'FLEET_BASE_BRANCH=main\n' > "$GD/conf"
st_count; [ "$(lib fleet_uuid "$G")" = "$OLD" ] && [ "$(inv_id "$G")" = "$OLD" ] \
  || st_miss "G: no FLEET_REPO at all → the same identity" "$(lib fleet_uuid "$G") $(inv_id "$G")"
st_count; [ "$(lib fleet_uuid "$L")" = "${U:-x}" ] && [ "$(head -1 "$FLEET_CONF_DIR/fleets/$L/identity" 2>/dev/null)" = "${U:-y}" ] \
  || st_miss "G: the D fleet's value froze as it was minted"
NC="nocf1936$$"
st_count; is_uuid "$(lib fleet_uuid "$NC")" && [ ! -e "$FLEET_CONF_DIR/fleets/$NC" ] || st_miss "G: a name with no conf answers but writes nothing"
printf 'garbage\n' > "$GD/identity"
printf 'FLEET_REPO=acme/first\nFLEET_MAIN=%s/first\n' "$WORK" > "$GD/conf"
st_count; [ "$(lib fleet_uuid "$G")" = "$OLD" ] && [ "$(head -1 "$GD/identity")" = "$OLD" ] || st_miss "G: a damaged file is recomputed and rewritten" "$(cat "$GD/identity")"
st_count; awk '/fleet_uuid "\$s"/ { f = NR } /fleet-conf.sh" migrate/ { m = NR } END { exit !(f && m && f < m) }' "$BIN/fleet-install-apply.sh" \
  || st_miss "G: install-apply's conf pass freezes every fleet before fleet-conf.sh migrate"

# --- H: what the inventory reports still derives the frozen UUID (issue #3397) --------
# The hub re-derives every fleet UUID from the (repo, checkout) a heartbeat reports
# and drops one that does not add up. A UUID frozen from another triplet than the
# fleet's current one — a fresh login's fleet frozen in the moment between its conf
# and its starter repo, a repo added to a no-repo fleet, the first one removed —
# must still be reported with the triplet it was minted from.
derives() { (cd "$BIN" && python3 - "$FLEET_CONF_DIR" "$1" <<'PY' 2>&1
import json, sqlite3, sys, uuid, fleet_control as c
f = [x for x in c.Control(sys.argv[1]).inventory() if x["name"] == sys.argv[2]][0]
m = sqlite3.connect(sys.argv[1] + "/control/state.sqlite3").execute("SELECT value FROM metadata WHERE key='machine_id'").fetchone()[0]
want = str(uuid.uuid5(uuid.UUID(m), json.dumps([f["name"], f["repo"], f["checkout"]], ensure_ascii=False, sort_keys=True, separators=(",", ":"))))
print("ok" if want == f["fleet_id"] else "MISMATCH", f["fleet_id"], f["repo"] or "-", f["checkout"] or "-", ",".join(f["repos"]) or "-")
PY
); }
put_repo() {  # <fleet> <owner/name> <checkout> — what fleet_repo_register writes, sans clone
  local f; f=$(lib fleet_repo_conf_file "$1" "$2"); mkdir -p "${f%/*}"
  printf 'FLEET_REPO="%s"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="main"\n' "$2" "$3" > "$f"
  lib fleet_repo_order_put "$1" "$2"
}
# H1: the fresh-login race — conf first, frozen repo-less, the starter a beat later.
H="hrace3397$$"; HD="$FLEET_CONF_DIR/fleets/$H"; mkdir -p "$HD"; mkdir -p "$WORK/starter"
printf 'FLEET_MAX_SESSIONS=4\n' > "$HD/conf"
HU=$(lib fleet_uuid "$H")
st_count; [ "$HU" = "$(old_alg "$H" "" "")" ] || st_miss "H1: a conf with no repo yet freezes the repo-less triplet" "$HU"
st_count; [ "$(sed -n 2p "$HD/identity")" = "[\"$H\",\"\",\"\"]" ] || st_miss "H1: the identity file's 2nd line is the triplet it hashed" "$(cat "$HD/identity")"
put_repo "$H" acme/starter "$WORK/starter"
R=$(derives "$H")
st_count; case "$R" in "ok $HU - - acme/starter") ;; *) false ;; esac \
  || st_miss "H1: the starter added after the freeze → the inventory reports the minted triplet (derives) and still lists the repo" "$R"
# H2: a file older than its 2nd line (frozen repo-less by an earlier version).
printf '%s\n' "$HU" > "$HD/identity"
R=$(derives "$H")
st_count; case "$R" in "ok $HU "*) ;; *) false ;; esac || st_miss "H2: a one-line file frozen repo-less still derives" "$R"
# H3: frozen WITH a repo, which then left (removed / moved): the 2nd line is the answer.
H3="hmove3397$$"; H3D="$FLEET_CONF_DIR/fleets/$H3"; mkdir -p "$H3D" "$WORK/one" "$WORK/two"
printf 'FLEET_MAX_SESSIONS=4\n' > "$H3D/conf"; put_repo "$H3" acme/one "$WORK/one"
H3U=$(lib fleet_uuid "$H3")
st_count; [ "$H3U" = "$(old_alg "$H3" acme/one "$WORK/one")" ] || st_miss "H3: frozen from its first repo" "$H3U"
rm -rf "$H3D/repos"; put_repo "$H3" acme/two "$WORK/two"
R=$(derives "$H3")
st_count; case "$R" in "ok $H3U acme/one $WORK/one acme/two") ;; *) false ;; esac \
  || st_miss "H3: the first repo replaced → the minted repo + checkout reported, the hosted list current" "$R"
# H4: an unchanged fleet reports what it always did, byte for byte.
R=$(derives "$G")
st_count; case "$R" in "ok $OLD acme/first $WORK/first acme/first") ;; *) false ;; esac || st_miss "H4: an unmoved fleet is reported as before" "$R"
# H5: fleet-up registers the repo BEFORE the conf exists.
st_count; awk '/^add_repo$/ && !a { a = NR } /^fleet_write_conf "\$CONF"/ { w = NR } END { exit !(a && w && a < w) }' "$BIN/fleet-up.sh" \
  || st_miss "H5: fleet-up.sh runs add_repo before fleet_write_conf"

st_done
