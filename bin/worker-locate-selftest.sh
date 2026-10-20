#!/bin/bash
# worker-locate-selftest.sh — addressing a worker by its worker_id (issue #1420,
# EPIC #1419 C1). On an isolated tmux server and a sandbox conf dir, pins:
#   A  fleet_uuid (fleet-lib.sh) mints the SAME fleet UUID as fleet_control.py's
#      inventory, so a shell-built worker_id equals what fleet_status reports;
#      fleet_worker_id builds `<uuid>/<fleet_id>` (issue #1646) and
#      fleet_worker_id_key `<uuid>/<key>` for an issue and a scratch window.
#   B  fleet_worker_locate: this fleet's worker_id / bare key / window → `local
#      <window> <sess>`; this fleet's not-live worker → `unknown` (the hub is never
#      asked); ANOTHER fleet's worker_id with a key a local window also holds →
#      `unknown`, never that window; a malformed target → rc 2; in a 2+ repo
#      fleet a bare key two repos hold is ambiguous, a `<slug>:` key is not.
#   C  the hub branch: off unless CCQUOTA_FLEET=1 (the degenerate case — a cache
#      on disk changes nothing); fresh cache → `remote <node>`; stale with no
#      refresher → `unknown` + one stderr note; FLEET_HUB_STATUS_CMD refreshes it.
#   D  the four scripts take `wid:`: a local worker_id behaves byte-for-byte like
#      today's target for the same window (fleet-peer-send.sh), a remote/unknown
#      one refuses with the reason and never touches the same-numbered local
#      window (fleet-peer-send.sh, fleet-await.sh, fleet-answer.sh; a remote
#      parent is relayed by fleet-report-parent.sh since #1421 — never to that
#      window), and fleet-await.sh maps this fleet's wid to <N>.
#   E  @origin_wid: fleet_stamp_origin_wid stamps the parent's worker_id for a key
#      origin — its identity form + @origin_fid when a live window answers to the
#      key (issue #1646), else the key form — nothing for a non-key origin or a
#      machine with no fleet UUID; the
#      spawn sites (dash-issue-session.sh, dash-raw-session.sh,
#      dash-restore-session.sh, fleet-await.sh) call it.
#   F  ONE resolver (issue #1537, EPIC #1529 E8) — fleet_win_for_key is the only
#      way a key becomes a window, and it refuses rather than guesses: a stamped @worktree is never second-guessed by the pane
#      cwd; two windows for one key → rc 2 AMBIGUOUS; a bare issue key in a 2+ repo
#      fleet → rc 2, and fleet-await --repo B waits on B's #N, never A's; a
#      `<sess>:<idx>` position and a window NAME are refused by fleet-peer-send.sh,
#      fleet-answer.sh, fleet-permission.sh and fleet_worker_locate (exit 2); inside
#      tmux with no TMUX_PANE a script reads its pane through fleet_pane_fmt, and the
#      five pane-identity reads go through fleet_pane_fmt; an unstamped @wid handle
#      is refused by fleet_wid_target and every caller checks its rc.
#      F6 (issue #1939): a ONE-repo fleet's keys carry the repo too
#      (`acme-app:issue-7`), a bare key still resolves there as the one repo's
#      alias (one version), fleet_key_qualify / fleet_key_alias spell the rule, and
#      adding a second repo changes no existing window's key.
# tmux / python3 absent → SKIP. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
. "$BIN/selftest-repo-fixture.sh"
REAL_TMUX=$(command -v tmux) || { echo 'worker-locate selftest: tmux absent — SKIP'; exit 0; }
st_need python3

WORK="$(mktemp -d "${TMPDIR:-/tmp}/worker-locate.XXXXXX")" || exit 2
L="wloc$$"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR/fleets/$L"
export FLEET_CC_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$FLEET_CC_SESSIONS_DIR"
: > "$FLEET_CONF_DIR/fleets/$L/conf"
fx_repo "$FLEET_CONF_DIR" "$L" acme/app FLEET_MAIN="$WORK/main"
unset TMUX TMUX_PANE CCQUOTA_FLEET FLEET_HUB_STATUS_CMD FLEET_HUB_CACHE_SECS

st_tally
tf() { "$REAL_TMUX" -L "$L" "$@"; }
cleanup() { "$REAL_TMUX" -L "$L" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
lib() { bash -c '. "$1/fleet-lib.sh"; shift; "$@"' _ "$BIN" "$@"; }

tf -f /dev/null new-session -d -s "$L" -n plan 'while :; do sleep 300; done' 2>/dev/null \
  || { echo 'worker-locate selftest: cannot start an isolated tmux server — SKIP' >&2; exit 0; }
w7=$(tf new-window -d -P -F '#{window_id}' -n issue-7 'while :; do sleep 300; done')
tf set-window-option -t "$w7" @issue 7
w3=$(tf new-window -d -P -F '#{window_id}' -n sc 'while :; do sleep 300; done')
tf set-window-option -t "$w3" @raw 1; tf set-window-option -t "$w3" @worktree "$WORK/app-scratch-3"

# --- E (part): no control db yet ⇒ no fleet UUID, no worker_id, no stamp ----------
st_count; [ -z "$(lib fleet_uuid "$L")" ] || st_miss "E: no control db must mean no fleet UUID"
st_count; [ -z "$(lib fleet_worker_id "$L" "$w7")" ] || st_miss "E: no fleet UUID must mean no worker_id"
lib fleet_stamp_origin_wid "$L" "$w3" issue-7 "$L"
st_count; [ -z "$(tf show-options -wqv -t "$w3" @origin_wid)" ] || st_miss "E: no fleet UUID must stamp no @origin_wid"

# --- A: the shell UUID is fleet_control.py's UUID ------------------------------------
PYID=$(cd "$BIN" && python3 -c 'import sys, fleet_control as c
f=[x for x in c.Control(sys.argv[1]).inventory() if x["name"]==sys.argv[2]]
print(f[0]["fleet_id"] if f else "")' "$FLEET_CONF_DIR" "$L" 2>"$WORK/py.err")
U=$(lib fleet_uuid "$L")
st_count; [ -n "$PYID" ] && [ "$U" = "$PYID" ] || st_miss "A: fleet_uuid must equal fleet_control's fleet_id" "sh=$U py=$PYID $(cat "$WORK/py.err")"
# Since issue #1646 a worker_id names the session's lifelong identity (@fleet_id,
# minted on first ask); the key form is fleet_worker_id_key, the readable alias.
wid7=$(lib fleet_worker_id "$L" "$w7"); fid7=$(tf show-options -wqv -t "$w7" @fleet_id)
st_count; [ -n "$fid7" ] && [ "$wid7" = "$U/$fid7" ] || st_miss "A: worker_id of the issue window is <uuid>/<fleet_id>" "$wid7 (fid $fid7)"
st_count; [ "$(lib fleet_worker_id "$L" "$w7")" = "$wid7" ] || st_miss "A: a second ask returns the same identity (never re-minted)"
wid3=$(lib fleet_worker_id "$L" "$w3"); fid3=$(tf show-options -wqv -t "$w3" @fleet_id)
st_count; [ -n "$fid3" ] && [ "$fid3" != "$fid7" ] && [ "$wid3" = "$U/$fid3" ] || st_miss "A: worker_id of the scratch window" "$wid3"
# The key carries the repo in a one-repo fleet too (issue #1939).
st_count; [ "$(lib fleet_worker_id_key "$L" "$w7")" = "$U/acme-app:issue-7" ] || st_miss "A: the key-form alias of the issue window" "$(lib fleet_worker_id_key "$L" "$w7")"
st_count; [ "$(lib fleet_worker_id_key "$L" "$w3")" = "$U/acme-app:scratch-3" ] || st_miss "A: the key-form alias of the scratch window" "$(lib fleet_worker_id_key "$L" "$w3")"

# --- B: locate ------------------------------------------------------------------------
F=11111111-2222-3333-4444-555555555555          # another machine's fleet
loc() { out=$(lib fleet_worker_locate "$@" 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err"); }
loc "wid:$U/issue-7" "$L";  st_count; [ "$out" = "local $w7 $L" ] || st_miss "B: own wid → local" "$out"
loc "$U/issue-7" "$L";      st_count; [ "$out" = "local $w7 $L" ] || st_miss "B: own wid without wid: → local" "$out"
loc "wid:issue-7" "$L";     st_count; [ "$out" = "local $w7 $L" ] || st_miss "B: bare key → local" "$out"
loc "wid:$U/scratch-3" "$L"; st_count; [ "$out" = "local $w3 $L" ] || st_miss "B: scratch wid → local" "$out"
loc "$L:issue-7" "$L";      st_count; [ "$out" = unknown ] && [ "$rc" = 2 ] || st_miss "B: a <sess>:<name> target is refused (issue #1537)" "$out rc=$rc"
loc "wid:$U/issue-8" "$L";  st_count; [ "$out" = unknown ] && [ "$rc" = 0 ] || st_miss "B: own fleet, not live → unknown" "$out rc=$rc"
loc "wid:$F/issue-7" "$L";  st_count; [ "$out" = unknown ] || st_miss "B: a foreign wid must NOT resolve to the local issue-7" "$out"
loc "wid:junk" "$L";        st_count; [ "$out" = unknown ] && [ "$rc" = 2 ] || st_miss "B: malformed → unknown rc 2" "$out rc=$rc"
loc "wid:NOTAUUID/issue-7" "$L"; st_count; [ "$rc" = 2 ] || st_miss "B: a bad uuid → rc 2" "$out rc=$rc"

# multi-repo: a bare issue key held by two repos' windows is AMBIGUOUS
mkdir -p "$FLEET_CONF_DIR/fleets/$L/repos"
printf 'FLEET_REPO=acme/app\n' > "$FLEET_CONF_DIR/fleets/$L/repos/acme-app.conf"
printf 'FLEET_REPO=acme/lib\n' > "$FLEET_CONF_DIR/fleets/$L/repos/acme-lib.conf"
tf set-window-option -t "$w7" @repo acme/app
w7b=$(tf new-window -d -P -F '#{window_id}' -n lib-7 'while :; do sleep 300; done')
tf set-window-option -t "$w7b" @issue 7; tf set-window-option -t "$w7b" @repo acme/lib
loc "wid:issue-7" "$L"; st_count; [ "$out" = unknown ] && case "$err" in *ambiguous*) true ;; *) false ;; esac \
  || st_miss "B: multi-repo bare key held twice → unknown + ambiguous" "$out / $err"
loc "wid:acme-lib:issue-7" "$L"; st_count; [ "$out" = "local $w7b $L" ] || st_miss "B: multi-repo slug key → that repo's window" "$out / $err"
tf kill-window -t "$w7b"; rm -rf "$FLEET_CONF_DIR/fleets/$L/repos"; fx_repo "$FLEET_CONF_DIR" "$L" acme/app FLEET_MAIN="$WORK/main"; tf set-window-option -u -t "$w7" @repo

# --- C: the hub branch ------------------------------------------------------------------
CACHE="$FLEET_CONF_DIR/control/hub-workers.tsv"
printf '%s/issue-7\tmac-a\n' "$F" > "$CACHE"
loc "wid:$F/issue-7" "$L"; st_count; [ "$out" = unknown ] && [ -z "$err" ] || st_miss "C: CCQUOTA_FLEET off ⇒ the cache is never read" "$out / $err"
export CCQUOTA_FLEET=1
loc "wid:$F/issue-7" "$L"; st_count; [ "$out" = "remote mac-a" ] || st_miss "C: fresh cache → remote mac-a" "$out / $err"
loc "wid:$U/issue-8" "$L"; st_count; [ "$out" = unknown ] || st_miss "C: own fleet never asks the hub" "$out"
touch -t 202001010000 "$CACHE"
loc "wid:$F/issue-7" "$L"; st_count; [ "$out" = unknown ] && [ "$(printf '%s\n' "$err" | grep -c .)" = 1 ] \
  || st_miss "C: stale cache, no refresher → unknown + one stderr note" "$out / $err"
export FLEET_HUB_STATUS_CMD="printf '%s/issue-9\tm4b\n' $F"
loc "wid:$F/issue-9" "$L"; st_count; [ "$out" = "remote m4b" ] || st_miss "C: FLEET_HUB_STATUS_CMD refreshes the cache" "$out / $err"
export FLEET_HUB_STATUS_CMD="printf '%s/issue-7\tmac-a\n' $F"; touch -t 202001010000 "$CACHE"
loc "wid:$F/issue-7" "$L"; st_count; [ "$out" = "remote mac-a" ] || st_miss "C: refreshed again" "$out / $err"

# --- D: the scripts ----------------------------------------------------------------------
run() { out=$(env -u TMUX "$@" 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err"); }
# peer-send: own wid ≡ today's issue target, byte for byte (both reach @w7, no Claude)
run bash "$BIN/fleet-peer-send.sh" -L "$L" issue:7 hi; base="$rc|$out|$err"
run bash "$BIN/fleet-peer-send.sh" -L "$L" "wid:$U/issue-7" hi
st_count; [ "$rc|$out|$err" = "$base" ] || st_miss "D: peer-send wid (local) must match issue:7 exactly" "[$rc|$out|$err] vs [$base]"
run bash "$BIN/fleet-peer-send.sh" -L "$L" "wid:$F/issue-7" hi
# No pane: sent as the operator (issue #1649) — handed to the hub, queued, says mac-a.
st_count; [ "$rc" = 3 ] && case "$out" in *"on mac-a"*) true ;; *) false ;; esac \
  || st_miss "D: peer-send remote wid from no pane → queued as the operator, says mac-a" "rc=$rc $out $err"
rm -f "$FLEET_CONF_DIR/control/hub-outbox/"*.json 2>/dev/null
run bash "$BIN/fleet-peer-send.sh" -L "$L" "wid:$U/issue-8" hi
st_count; [ "$rc" = 1 ] && case "$err" in *"no live worker"*) true ;; *) false ;; esac || st_miss "D: peer-send unknown wid → exit 1" "rc=$rc $err"
run bash "$BIN/fleet-peer-send.sh" -L "$L" "wid:bogus" hi
st_count; [ "$rc" = 2 ] || st_miss "D: peer-send malformed wid → exit 2" "rc=$rc $err"
# await
run bash "$BIN/fleet-await.sh" "wid:$F/issue-7" -L "$L" --parent issue-1 --timeout 5 --interval 1
st_count; [ "$rc" = 5 ] && [ "$(printf '%s\n' "$out" | head -1)" = NO-WORKER ] && case "$out" in *"lives on mac-a"*) true ;; *) false ;; esac \
  || st_miss "D: await remote wid → NO-WORKER (5), says mac-a" "rc=$rc $out / $err"
run bash "$BIN/fleet-await.sh" "wid:$U/issue-8" -L "$L" --parent issue-1 --no-spawn --timeout 5 --interval 1
st_count; [ "$rc" = 5 ] && case "$out" in *"#8 has no live worker (--no-spawn)"*) true ;; *) false ;; esac \
  || st_miss "D: await own wid → #8 through today's path" "rc=$rc $out / $err"
run bash "$BIN/fleet-await.sh" "wid:$U/scratch-3" -L "$L" --parent issue-1 --timeout 5
st_count; [ "$rc" = 2 ] || st_miss "D: await scratch wid → usage refusal" "rc=$rc $err"
# answer
run bash "$BIN/fleet-answer.sh" -L "$L" --show "wid:$F/issue-7"
st_count; [ "$rc" = 1 ] && case "$err" in *"lives on mac-a"*) true ;; *) false ;; esac || st_miss "D: answer remote wid → exit 1" "rc=$rc $err"
run bash "$BIN/fleet-answer.sh" -L "$L" --show "wid:$U/issue-8"
st_count; [ "$rc" = 1 ] && case "$err" in *"no live worker"*) true ;; *) false ;; esac || st_miss "D: answer unknown wid → exit 1" "rc=$rc $err"
# report-parent: a child whose parent key issue-7 is ALSO a local window
wc=$(tf new-window -d -P -F '#{window_id}' -n issue-20 'while :; do sleep 300; done')
tf set-window-option -t "$wc" @issue 20; tf set-window-option -t "$wc" @origin issue-7
run bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wc" --state blocked --summary x --dry-run; base="$out"
tf set-window-option -t "$wc" @origin_wid "$U/issue-7"
run bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wc" --state blocked --summary x --dry-run
st_count; [ "$out" = "$base" ] && case "$out" in *"$w7"*) true ;; *) false ;; esac \
  || st_miss "D: report-parent with a local @origin_wid behaves as before" "[$out] vs [$base]"
tf set-window-option -t "$wc" @origin_wid "$F/issue-7"
# A remote parent is relayed through the hub since #1421 (hub-relay-selftest.sh
# pins the relay); here: never the local issue-7.
run bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wc" --state blocked --summary x --dry-run
st_count; [ "$rc" = 0 ] && case "$out" in *"would relay to $F/issue-7 on mac-a"*) true ;; *) false ;; esac \
  && case "$out" in *"$w7"*) false ;; *) true ;; esac \
  || st_miss "D: report-parent with a remote parent → relayed to it, never the local issue-7" "rc=$rc out=$out err=$err"
run bash "$BIN/fleet-report-parent.sh" -L "$L" --win "$wc" --origin "wid:$F/issue-7" --state blocked --summary x --dry-run
st_count; [ "$rc" = 0 ] && case "$out" in *"would relay to $F/issue-7"*) true ;; *) false ;; esac \
  || st_miss "D: report-parent --origin wid:<remote> → relayed" "rc=$rc out=$out err=$err"

# --- E: @origin_wid stamping ---------------------------------------------------------------
lib fleet_stamp_origin_wid "$L" "$w3" issue-7 "$L"
st_count; [ "$(tf show-options -wqv -t "$w3" @origin_wid)" = "$U/$fid7" ] || st_miss "E: a key origin stamps the parent's identity-form worker_id (#1646)" "$(tf show-options -wqv -t "$w3" @origin_wid)"
st_count; [ "$(tf show-options -wqv -t "$w3" @origin_fid)" = "$fid7" ] || st_miss "E: …and the parent's identity as @origin_fid"
tf set-window-option -u -t "$w3" @origin_wid; tf set-window-option -u -t "$w3" @origin_fid
lib fleet_stamp_origin_wid "$L" "$w3" issue-77 "$L"
st_count; [ "$(tf show-options -wqv -t "$w3" @origin_wid)" = "$U/issue-77" ] && [ -z "$(tf show-options -wqv -t "$w3" @origin_fid)" ] \
  || st_miss "E: a key no live window answers to keeps the key form and stamps no @origin_fid"
tf set-window-option -u -t "$w3" @origin_wid
lib fleet_stamp_origin_wid "$L" "$w3" autofill "$L"
st_count; [ -z "$(tf show-options -wqv -t "$w3" @origin_wid)" ] || st_miss "E: a non-key origin stamps nothing"
for f in dash-issue-session.sh dash-raw-session.sh dash-restore-session.sh fleet-await.sh; do
  st_count; grep -q 'fleet_stamp_origin_wid ' "$BIN/$f" || st_miss "E: $f must stamp @origin_wid beside @origin"
done

# --- F: ONE resolver (issue #1537) ---------------------------------------------------------
unset CCQUOTA_FLEET FLEET_HUB_STATUS_CMD
wfk() { out=$(lib fleet_win_for_key "$@" 2>"$WORK/err"); rc=$?; err=$(cat "$WORK/err"); }
mkdir -p "$WORK/app-scratch-3" "$WORK/app-scratch-8"

# F2 a stamped @worktree is the identity; the pane cwd is never a second chance
w8=$(tf new-window -d -P -F '#{window_id}' -n sc8 -c "$WORK/app-scratch-3" 'while :; do sleep 300; done')
tf set-window-option -t "$w8" @worktree "$WORK/app-scratch-8"
wfk scratch-3 "$L"; st_count; [ "$out" = "$w3" ] || st_miss "F2: a window stamped scratch-8 must not answer to scratch-3 by its cwd" "$out / $err"
wfk scratch-8 "$L"; st_count; [ "$out" = "$w8" ] || st_miss "F2: it answers to its stamp" "$out / $err"
tf kill-window -t "$w8"

# F3 two windows for one key: AMBIGUOUS, named, nothing picked
w7x=$(tf new-window -d -P -F '#{window_id}' -n issue-7-dup 'while :; do sleep 300; done'); tf set-window-option -t "$w7x" @issue 7
wfk issue-7 "$L"; st_count; [ "$rc" = 2 ] && [ -z "$out" ] && case "$err" in *ambiguous*issue-7*issue-7-dup*) true ;; *) false ;; esac \
  || st_miss "F3: two windows for issue-7 → rc 2, nothing on stdout, both named on stderr" "rc=$rc out=$out err=$err"
run bash "$BIN/fleet-peer-send.sh" -L "$L" issue:7 hi
st_count; [ "$rc" = 1 ] && case "$err" in *ambiguous*) true ;; *) false ;; esac || st_miss "F3: peer-send refuses an ambiguous key" "rc=$rc $err"
tf kill-window -t "$w7x"

# F4 a 2+ repo fleet: a bare issue key is refused; the repo-qualified one resolves;
#    fleet-await --repo B waits on B's #7, never A's
mkdir -p "$FLEET_CONF_DIR/fleets/$L/repos"
printf 'FLEET_REPO=acme/app\n' > "$FLEET_CONF_DIR/fleets/$L/repos/acme-app.conf"
printf 'FLEET_REPO=acme/lib\n' > "$FLEET_CONF_DIR/fleets/$L/repos/acme-lib.conf"
tf set-window-option -t "$w7" @repo acme/app
w7b=$(tf new-window -d -P -F '#{window_id}' -n lib-7 'while :; do sleep 300; done')
tf set-window-option -t "$w7b" @issue 7; tf set-window-option -t "$w7b" @repo acme/lib
wfk issue-7 "$L"; st_count; [ "$rc" = 2 ] && [ -z "$out" ] && case "$err" in *ambiguous*) true ;; *) false ;; esac \
  || st_miss "F4: a bare issue key in a 2+ repo fleet → rc 2" "rc=$rc out=$out err=$err"
wfk acme-lib:issue-7 "$L"; st_count; [ "$out" = "$w7b" ] || st_miss "F4: the qualified key → that repo's window" "$out / $err"
wfk scratch-3 "$L"; st_count; [ "$out" = "$w3" ] || st_miss "F4: a scratch key needs no repo (its number is fleet-wide)" "$out / $err"
run bash "$BIN/fleet-peer-send.sh" -L "$L" issue:7 hi
st_count; [ "$rc" = 1 ] && case "$err" in *ambiguous*--repo*) true ;; *) false ;; esac || st_miss "F4: peer-send issue:7 without --repo → refused, says --repo" "rc=$rc $err"
run bash "$BIN/fleet-await.sh" 7 -L "$L" --parent scratch-3 --repo acme/lib --no-spawn --timeout 2 --interval 1
st_count; case "$err" in *"#7 is live ($w7b)"*) true ;; *) false ;; esac || st_miss "F4: fleet-await --repo acme/lib waits on B's #7, never A's" "rc=$rc out=$out err=$err"
st_count; [ "$(tf show-options -wqv -t "$w7b" @origin)" = scratch-3 ] && [ -z "$(tf show-options -wqv -t "$w7" @origin)" ] \
  || st_miss "F4: fleet-await adopted B's #7 only" "A=[$(tf show-options -wqv -t "$w7" @origin)] B=[$(tf show-options -wqv -t "$w7b" @origin)]"
run bash "$BIN/fleet-await.sh" 7 -L "$L" --parent scratch-3 --no-spawn --timeout 2 --interval 1
st_count; [ "$rc" = 2 ] && case "$err" in *"--repo"*) true ;; *) false ;; esac || st_miss "F4: fleet-await without --repo in a 2+ repo fleet → usage refusal" "rc=$rc $err"
tf kill-window -t "$w7b"; rm -rf "$FLEET_CONF_DIR/fleets/$L/repos"; fx_repo "$FLEET_CONF_DIR" "$L" acme/app FLEET_MAIN="$WORK/main"; tf set-window-option -u -t "$w7" @repo

# F6 (issue #1939) one spelling: a ONE-repo fleet keys acme-app:issue-7 too; the
#    bare key is that repo's alias; a second repo renames no session
okey() { lib fleet_window_okey "$L" "$1"; }
st_count; [ "$(okey "$w7")" = acme-app:issue-7 ] || st_miss "F6: a one-repo fleet's issue key carries the repo" "$(okey "$w7")"
st_count; [ "$(okey "$w3")" = acme-app:scratch-3 ] || st_miss "F6: a one-repo fleet's scratch key carries the repo" "$(okey "$w3")"
wfk acme-app:issue-7 "$L"; st_count; [ "$out" = "$w7" ] || st_miss "F6: the qualified key resolves" "$out / $err"
wfk issue-7 "$L"; st_count; [ "$rc" = 0 ] && [ "$out" = "$w7" ] || st_miss "F6: the bare key is the one repo's alias" "rc=$rc $out / $err"
wfk acme-lib:issue-7 "$L"; st_count; [ "$rc" = 1 ] || st_miss "F6: another repo's key never answers" "rc=$rc $out"
st_count; [ "$(lib fleet_key_qualify "$L" issue-7)" = acme-app:issue-7 ] || st_miss "F6: qualify a bare key" "$(lib fleet_key_qualify "$L" issue-7)"
st_count; [ "$(lib fleet_key_qualify "$L" acme-lib:scratch-2)" = acme-lib:scratch-2 ] || st_miss "F6: a qualified key passes as is"
st_count; [ "$(lib fleet_key_qualify "$L" hub)" = hub ] || st_miss "F6: a non-key passes as is"
st_count; [ "$(lib fleet_key_alias "$L" acme-app:scratch-3)" = scratch-3 ] || st_miss "F6: the alias of the one repo's key" "$(lib fleet_key_alias "$L" acme-app:scratch-3)"
st_count; [ -z "$(lib fleet_key_alias "$L" acme-lib:scratch-3)" ] || st_miss "F6: no alias for a repo that is not the fleet's"
O=$(lib fleet_origin_canon issue-7 '' "$L")
st_count; [ "$O" = acme-app:issue-7 ] || st_miss "F6: an explicit bare --origin is stamped qualified, never bare" "$O"
mkdir -p "$FLEET_CONF_DIR/fleets/$L/repos"
printf 'FLEET_REPO=acme/app\n' > "$FLEET_CONF_DIR/fleets/$L/repos/acme-app.conf"
printf 'FLEET_REPO=acme/lib\n' > "$FLEET_CONF_DIR/fleets/$L/repos/acme-lib.conf"
tf set-window-option -t "$w7" @repo acme/app; tf set-window-option -t "$w3" @repo acme/app
st_count; [ "$(okey "$w7")" = acme-app:issue-7 ] && [ "$(okey "$w3")" = acme-app:scratch-3 ] \
  || st_miss "F6: adding a second repo renames no session" "$(okey "$w7") $(okey "$w3")"
st_count; [ "$(lib fleet_key_qualify "$L" issue-7)" = issue-7 ] && [ -z "$(lib fleet_key_alias "$L" acme-app:issue-7)" ] \
  || st_miss "F6: in a 2+ repo fleet a bare key names no one repo"
rm -rf "$FLEET_CONF_DIR/fleets/$L/repos"; fx_repo "$FLEET_CONF_DIR" "$L" acme/app FLEET_MAIN="$WORK/main"; tf set-window-option -u -t "$w7" @repo; tf set-window-option -u -t "$w3" @repo

# F5 a position (<sess>:<idx>, <sess>:<name>) and a window NAME are not addresses
run bash "$BIN/fleet-peer-send.sh" -L "$L" "$L:1" hi
st_count; [ "$rc" = 2 ] && [ -z "$out" ] || st_miss "F5: peer-send <sess>:<idx> → exit 2, nothing sent" "rc=$rc out=$out err=$err"
run bash "$BIN/fleet-peer-send.sh" -L "$L" "$L:issue-7" hi;  st_count; [ "$rc" = 2 ] || st_miss "F5: peer-send <sess>:<name> → exit 2" "rc=$rc $err"
run bash "$BIN/fleet-peer-send.sh" -L "$L" plan hi;          st_count; [ "$rc" = 2 ] || st_miss "F5: peer-send a window NAME → exit 2" "rc=$rc $err"
run bash "$BIN/fleet-answer.sh" -L "$L" --show "$L:1";        st_count; [ "$rc" = 2 ] || st_miss "F5: fleet-answer <sess>:<idx> → exit 2" "rc=$rc $err"
run bash "$BIN/fleet-answer.sh" -L "$L" --show plan;          st_count; [ "$rc" = 2 ] || st_miss "F5: fleet-answer a window NAME → exit 2" "rc=$rc $err"
run bash "$BIN/fleet-permission.sh" -L "$L" --show "$L:1";    st_count; [ "$rc" = 2 ] || st_miss "F5: fleet-permission <sess>:<idx> → exit 2" "rc=$rc $err"
loc "$L:1" "$L";    st_count; [ "$out" = unknown ] && [ "$rc" = 2 ] || st_miss "F5: fleet_worker_locate <sess>:<idx> → unknown rc 2" "$out rc=$rc"

# F6 the caller's own pane or nothing: a script reads its pane through fleet_pane_fmt
for f in fleet-brief.sh fleet-report-parent.sh; do
  st_count; grep -q 'display-message -p -t "\${TMUX_PANE:-}"' "$BIN/$f" && st_miss "F6: $f still reads -t \"\${TMUX_PANE:-}\" — use fleet_pane_fmt"
done
st_count; sed -n '/^fleet_seat()/,/^}/p' "$BIN/fleet-lib.sh" | grep -q fleet_pane_fmt || st_miss "F6: fleet_seat must read its pane through fleet_pane_fmt"
st_count; grep -q 'TMUX_PANE=' "$BIN/dash-popup.sh" || st_miss "F6: dash-popup.sh must hand its TMUX_PANE to the popup (a popup has none)"

# F7 an unstamped @wid handle is refused — never handed to tmux as a window NAME
tf new-window -d -n z9 'while :; do sleep 300; done'
out=$(lib fleet_wid_target z9 "$L" 2>"$WORK/err"); rc=$?
st_count; [ "$rc" = 1 ] && [ -z "$out" ] || st_miss "F7: an unstamped handle → nothing, rc 1 (never the window NAMED z9)" "rc=$rc out=$out"
st_count; [ "$(lib fleet_wid_target "$w7" "$L")" = "$w7" ] || st_miss "F7: a window id still passes through"
for f in fleet-migrate.sh fleet-transfer.sh fleet-move.sh dash-pin-toggle.sh; do
  st_count; grep -Eq 'fleet_wid_target .*\)"? && \[ -n ' "$BIN/$f" || st_miss "F7: $f must check fleet_wid_target's rc (an empty target is -t \"\", the current window)"
done

st_done
