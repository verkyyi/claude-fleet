#!/bin/bash
# fleet-park-selftest.sh — parking a stuck session (issue #2671, EPIC #2668 C3):
# bin/fleet-park.sh → bin/fleet_park.py, its road through the steward's beat
# (bin/fleet_steward.py), fleet-restore.sh's guard (fleet_parked in fleet-lib.sh).
#
# An isolated tmux server (a PATH shim maps every `tmux -L <x>` onto its socket),
# a real git worktree with a bare remote; GitHub, the peer channel, the stop, the
# spawn and the parent report are seams that log.
#
#   A  judge: a worker blocked past FLEET_PARK_BLOCKED_SECS is picked — waiting on
#      its open decision row, else a reply; a busy one (/loop, bg job), a fresh
#      one and one whose branch just moved are not
#   B  park: asked for its handoff (peer channel, no GitHub write), still pending
#      until it writes one; then the screen kept, the branch pushed, the parent told
#      blocked, the window retired + stopped, the worktree (uncommitted file too)
#      kept, `blocked` + ONE 「停放：等 …」 comment with the fleet:park mark,
#      park.idx + fleet_parked, a `park` event
#   C  a session that never answers: past FLEET_PARK_GRACE it is parked anyway,
#      the comment points at the screen it kept
#   D  wake: the row answered ⇒ `blocked` off, dash-issue-session.sh --resume <the
#      same sid> --seed-file <reads the handoff> --force; out of the book
#   E  no room (spawn rc 2): it stays parked, `blocked` goes back on
#   F  a condition already met before the park lands cancels it — the window stays
#   G  the steward holder's beat (`beat --holder`, EPIC #3111 C4) moves parks and
#      stamps the count; FLEET_STEWARD_PARK=0 leaves the book untouched
#   I  the metric: the parked stretch is one `stuck` segment ended by the park
#   J  parking runs ONLY under `beat --holder` with a holder (issue #3115): a bare
#      `beat`, and `beat --holder` when nobody holds the steward role, park nothing,
#      ask nothing and touch neither book
#   H  a restore from a map taken while it was still open (bin/fleet-restore.sh,
#      the reboot / lost-server road) does not reopen the parked one — and does
#      reopen an ordinary missing one beside it
#   K  a session with NO issue, owned by a hub task record (@task T42, a no-repo
#      session — issue #3387): judged stuck, waiting on `task:T42`; parked with
#      no GitHub write, 「停放」 on its record alone, stopped by `fid:<fleet_id>`,
#      booked as T42 (fleet_parked_fid; a restore leaves it closed); the record
#      unchanged, or changed with a question still open ⇒ it stays; answered ⇒
#      dash-raw-session.sh --task T42 --no-repo --resume <the same sid> --seed-file
#      <reads the handoff and the record>, and the record's 「停放」 cleared
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/park-st.XXXXXX")
fails=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
REAL_TMUX=''
for t in $(type -ap tmux); do case "$t" in */tmux-shim/*) ;; *) REAL_TMUX=$t; break ;; esac; done
[ -n "$REAL_TMUX" ] || { echo "SKIP  no tmux"; exit 0; }
cleanup() { "$REAL_TMUX" -S "$WORK/t.sock" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

export FLEET_CONF_DIR="$WORK/conf" FLEET_UI_LANG=zh FLEET_SKIP_GLOBAL_CONF=1 FLEET_SESSION=pk \
       CLAUDE_PROJECTS_DIR="$WORK/projects" FLEET_HANDOFF_DIR="$WORK/handoff" FLEET_DECISION_TZ=UTC
mkdir -p "$FLEET_CONF_DIR/fleets/pk/repos" "$WORK/tbin" "$WORK/seam" "$WORK/projects" "$WORK/handoff"
printf 'FLEET_REPO="o/r"\n' > "$FLEET_CONF_DIR/fleets/pk/repos/o-r.conf"
printf '# fleet pk\n' > "$FLEET_CONF_DIR/fleets/pk/conf"

cat > "$WORK/tbin/tmux" <<EOF
#!/bin/sh
case "\${1:-}" in -L) shift 2 ;; -L*) shift ;; esac
exec "$REAL_TMUX" -S "$WORK/t.sock" "\$@"
EOF
chmod +x "$WORK/tbin/tmux"
export PATH="$WORK/tbin:$PATH"

# --- seams ------------------------------------------------------------------------
S="$WORK/seam"
printf '#!/bin/sh\nf="%s/state.$1"; [ -f "$f" ] && cat "$f" || echo blocked\n' "$S" > "$S/state"
printf '#!/bin/sh\n[ -f "%s/busy.$1" ]\n' "$S" > "$S/busy"
printf '#!/bin/sh\n{ printf "%%s\\t" "$1"; cat; echo; } >> "%s/sent"\n' "$S" > "$S/send"
cat > "$S/stop" <<EOF
#!/bin/sh
case "\$2" in
  fid:*) w=\$(tmux list-windows -t pk -F '#{window_id} #{@fleet_id}' | awk -v f="\${2#fid:}" '\$2 == f { print \$1; exit }') ;;
  *) n=\${2##*issue-}
     w=\$(tmux list-windows -t pk -F '#{window_id} #{@issue}' | awk -v n="\$n" '\$2 == n { print \$1; exit }') ;;
esac
[ -n "\$w" ] || exit 5
echo "\$1 \$2 parking=\$(tmux show-options -wqv -t "\$w" @parking)" >> "$S/stopped"
tmux kill-window -t "\$w"
EOF
cat > "$S/gh" <<EOF
#!/bin/sh
if [ "\$1" = read ]; then f="$S/ghstate.\$3-\$4"; f=\$(echo "\$f" | tr / -); [ -f "\$f" ] && printf '{"state":"%s"}\n' "\$(cat "\$f")" || echo '{"state":"OPEN"}'; exit 0; fi
printf '%s\n' "\$*" >> "$S/gh.log"
[ "\$1" = comment ] && { echo "--- \$2#\$3" >> "$S/comments"; cat >> "$S/comments"; }
exit 0
EOF
cat > "$S/spawn" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$S/spawned"
for a in "\$@"; do [ "\$prev" = --seed-file ] && cat "\$a" > "$S/seed.last"; prev=\$a; done
exit \$(cat "$S/spawn.rc" 2>/dev/null || echo 0)
EOF
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/reported"\n' "$S" > "$S/report"
cat > "$S/task" <<EOF
#!/bin/sh
if [ "\$1" = get ]; then [ -f "$S/rec.\$2" ] && cat "$S/rec.\$2" || exit 1; exit 0; fi
printf '%s\n' "\$*" >> "$S/task.log"
EOF
cat > "$S/raw" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$S/raw.log"
for a in "\$@"; do [ "\$prev" = --seed-file ] && cat "\$a" > "$S/rawseed.last"; prev=\$a; done
exit 0
EOF
printf '#!/bin/sh\nprintf "{\\"comments\\": []}\\n"\n' > "$S/comments-cmd"
chmod +x "$S"/*
export FLEET_PARK_STATE_CMD="$S/state" FLEET_PARK_BUSY_CMD="$S/busy" FLEET_PARK_SEND_CMD="$S/send" \
       FLEET_PARK_STOP_CMD="$S/stop" FLEET_PARK_GH_CMD="$S/gh" FLEET_PARK_SPAWN_CMD="$S/spawn" \
       FLEET_PARK_REPORT_CMD="$S/report" FLEET_DECISION_COMMENTS_CMD="$S/comments-cmd" FLEET_PARK_TASK_CMD="$S/task" FLEET_PARK_RAW_CMD="$S/raw"
park() { python3 "$BIN/fleet_park.py" "$@"; }
o() { tmux show-options -wqv -t "$1" "$2"; }

# --- the fleet: one tmux session, workers in real worktrees -----------------------
git init -q --bare "$WORK/remote.git"
NOW=$(date +%s); OLD=$((NOW - 3600))
mkwin() { # mkwin <issue> <commit-age-secs> → window id; worktree $WORK/wt-<n>
  local n=$1 age=$2 wt="$WORK/wt-$1" sid w fid
  git init -q -b "issue-$n" "$wt"
  git -C "$wt" remote add origin "$WORK/remote.git"
  echo "work $n" > "$wt/f.txt"; git -C "$wt" add f.txt
  GIT_COMMITTER_DATE="@$((NOW - age))" GIT_AUTHOR_DATE="@$((NOW - age))" \
    git -C "$wt" -c user.email=t@t -c user.name=t commit -q -m "step $n"
  echo "half-done" > "$wt/wip.txt"
  sid=$(python3 -c 'import uuid; print(uuid.uuid4())'); fid=$(python3 -c 'import uuid; print(uuid.uuid4())')
  mkdir -p "$WORK/projects/$(printf '%s' "$wt" | LC_ALL=C tr -c 'A-Za-z0-9' '-')"
  touch -t "$(date -r "$OLD" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$OLD" +%Y%m%d%H%M.%S)" \
    "$WORK/projects/$(printf '%s' "$wt" | LC_ALL=C tr -c 'A-Za-z0-9' '-')/$sid.jsonl"
  w=$(tmux new-window -d -P -F '#{window_id}' -t pk: -n "issue-$n" -c "$wt" "sh -c 'echo SCREEN-OF-$n; exec sleep 600'")
  tmux set-option -w -t "$w" @fleet_role worker \; set-option -w -t "$w" @issue "$n" \; \
       set-option -w -t "$w" @repo o/r \; set-option -w -t "$w" @worktree "$wt" \; \
       set-option -w -t "$w" @fleet_id "$fid" \; set-option -w -t "$w" @cc_session_id "$sid" \; \
       set-option -w -t "$w" @claude_state needs \; set-option -w -t "$w" @claude_state_ts "$OLD" \; \
       set-option -w -t "$w" @origin issue-1
  printf '%s' "$w"
}
"$REAL_TMUX" -S "$WORK/t.sock" -f /dev/null new-session -d -s pk -n home -x 120 -y 30 'exec sleep 600' \
  || { echo "SKIP  cannot start an isolated tmux server"; exit 0; }
W7=$(mkwin 7 7200); W8=$(mkwin 8 7200); W9=$(mkwin 9 7200); W10=$(mkwin 10 60); W11=$(mkwin 11 7200)
W12=$(mkwin 12 7200)
tmux set-option -w -t "$W7" @task T41                                # a hub task record (issue #3330)
touch "$S/busy.$W8"                                                  # a /loop or a bg job
tmux set-option -w -t "$W9" @claude_state_ts "$((NOW - 100))"       # blocked a moment ago
echo 'done' > "$S/state.$W10"                                          # idle, but its branch just moved
echo 'working' > "$S/state.$W11"                                       # 11 is parked by hand (C):
touch "$WORK/projects/$(printf '%s' "$WORK/wt-11" | LC_ALL=C tr -c 'A-Za-z0-9' '-')/$(o "$W11" @cc_session_id).jsonl"
echo 'done' > "$S/state.$W12"                                          # idle an hour, nothing moved
SID7=$(o "$W7" @cc_session_id); FID7=$(o "$W7" @fleet_id)
mkdir -p "$FLEET_CONF_DIR/global"
python3 -c '
import json, sys
json.dump({"v": 1, "rows": {"d1": {"id": "d1", "item": "要不要换库", "src": "gh:o/r#7", "state": "open"}}},
          open(sys.argv[1], "w"))' "$FLEET_CONF_DIR/global/steward.state.json"
sleep 0.3
bash "$BIN/fleet-restore.sh" --snapshot >/dev/null 2>&1    # the map a reboot would restore from (H)

# --- A: judge ---------------------------------------------------------------------
cand=$(park candidates --session pk)
refs=$(printf '%s\n' "$cand" | cut -f1 | tr '\n' ' ')
[ "$refs" = "o/r#7 o/r#12 " ] && ok "A the long-blocked and the long-stalled are candidates, nothing else" \
  || bad "A candidates [$refs] — want o/r#7 o/r#12: $cand"
printf '%s\n' "$cand" | grep -q '^o/r#12.*60 分钟没有进展' && ok "A a stall says how long" || bad "A stall why: $cand"
tmux kill-window -t "$W12"
printf '%s\n' "$cand" | grep -q $'\tanswer:d1\t' && ok "A it waits on its open decision row" \
  || bad "A its wait is not answer:d1: $cand"
python3 -c '
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["rows"]["d1"]["src"] = "gh:o/r#99"; json.dump(d, open(p, "w"))' \
  "$FLEET_CONF_DIR/global/steward.state.json"
park candidates --session pk | grep -q $'\treply:o/r#7\t' && ok "A no open row ⇒ it waits on a reply" \
  || bad "A no row: not reply:o/r#7: $(park candidates --session pk)"
python3 -c '
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["rows"]["d1"]["src"] = "gh:o/r#7"; json.dump(d, open(p, "w"))' \
  "$FLEET_CONF_DIR/global/steward.state.json"

# --- B: park through the handoff --------------------------------------------------
park tick --judge --session pk >/dev/null
grep -q '\[fleet park\]' "$S/sent" 2>/dev/null && grep -q "^$W7" "$S/sent" \
  && ok "B the stuck worker is asked for its handoff over the peer channel" || bad "B no request: $(cat "$S/sent" 2>&1)"
[ ! -s "$S/gh.log" ] && ok "B asking writes nothing to GitHub" || bad "B the request wrote: $(cat "$S/gh.log")"
park tick --session pk >/dev/null
tmux list-windows -t pk -F '#{window_id}' | grep -qx "$W7" && ok "B no handoff yet, grace not out ⇒ still open" \
  || bad "B parked before the handoff or the grace"
HP=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pending"]["o/r#7"]["handoff"])' "$FLEET_CONF_DIR/global/park.json")
mkdir -p "$(dirname "$HP")"; printf '# handoff\nnext: swap the lib\n' > "$HP"
park tick --session pk >/dev/null
tmux list-windows -t pk -F '#{window_id}' | grep -qx "$W7" && bad "B the window is still there after its handoff" \
  || ok "B handoff written ⇒ the window is closed"
grep -q 'issue-7 parking=o/r#7$' "$S/stopped" && ok "B the stop sees @parking (session-end-hook keeps the issue open, #2949)" \
  || bad "B no @parking at the stop: $(cat "$S/stopped" 2>&1)"
[ -f "$WORK/wt-7/wip.txt" ] && ok "B the worktree stays, uncommitted work in it" || bad "B the worktree or its wip is gone"
[ "$(git --git-dir="$WORK/remote.git" rev-parse issue-7 2>/dev/null)" = "$(git -C "$WORK/wt-7" rev-parse HEAD)" ] \
  && ok "B the branch is pushed" || bad "B the branch is not on the remote"
grep -q 'SCREEN-OF-7' "$FLEET_CONF_DIR"/fleets/pk/park/*-7.capture.txt 2>/dev/null && ok "B the screen is kept" \
  || bad "B no capture of the screen"
grep -q -- "--state blocked --win $W7" "$S/reported" 2>/dev/null && ok "B the parent is told blocked" \
  || bad "B no blocked report: $(cat "$S/reported" 2>&1)"
[ -f "$FLEET_CONF_DIR/global/retired/$FID7" ] && ok "B the window is retired (restore --auto never pulls it back)" \
  || bad "B no retired mark for $FID7"
grep -qx 'label o/r 7 add' "$S/gh.log" && ok "B labelled blocked" || bad "B no blocked label: $(cat "$S/gh.log")"
grep -q "停放：等 有人答「要不要换库」" "$S/comments" && grep -q "交接：$HP" "$S/comments" \
  && grep -q "<!-- fleet:park wait=answer:d1 sid=$SID7 -->" "$S/comments" \
  && ok "B one 停放 comment: what it waits for, the handoff, the mark" || bad "B the comment: $(cat "$S/comments")"
[ "$(cat "$S/task.log" 2>/dev/null)" = "set T41 --parked 停放：等 有人答「要不要换库」" ] \
  && ok "B its hub record says 停放 too (issue #3330)" || bad "B the record: $(cat "$S/task.log" 2>&1)"
[ "$(grep -c '^comment' "$S/gh.log")" = 1 ] && ok "B exactly one comment" || bad "B comments: $(grep -c '^comment' "$S/gh.log")"
( . "$BIN/fleet-lib.sh"; fleet_parked o/r 7 ) && ok "B fleet_parked o/r 7 (fleet-restore.sh skips it)" \
  || bad "B fleet_parked does not know it: $(cat "$FLEET_CONF_DIR/global/park.idx" 2>&1)"
grep -q '"ev": "park", "ref": "o/r#7"' "$FLEET_CONF_DIR/logs/park.ndjson" && ok "B a park event is logged" \
  || bad "B no park event: $(cat "$FLEET_CONF_DIR/logs/park.ndjson" 2>&1)"

# --- C: a session that never answers ----------------------------------------------
park park issue-11 --wait time:2099-01-01T00:00:00Z --session pk >/dev/null
FLEET_PARK_GRACE=0 park tick --session pk >/dev/null
tmux list-windows -t pk -F '#{window_id}' | grep -qx "$W11" && bad "C unanswered past the grace, still open" \
  || ok "C no handoff past the grace ⇒ parked anyway"
grep -A4 -- '--- o/r#11' "$S/comments" | grep -q '屏幕存档' && ok "C its comment points at the kept screen" \
  || bad "C comment: $(grep -A4 -- '--- o/r#11' "$S/comments")"
[ "$(git --git-dir="$WORK/remote.git" rev-parse issue-11 2>/dev/null)" = "$(git -C "$WORK/wt-11" rev-parse HEAD)" ] \
  && ok "C its branch is pushed by the fleet" || bad "C issue-11 not pushed"

# --- D: wake on the answer -----------------------------------------------------------
park tick --session pk >/dev/null
[ ! -s "$S/spawned" ] && ok "D the row still open ⇒ nothing wakes" || bad "D woke early: $(cat "$S/spawned")"
python3 -c '
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["rows"]["d1"]["state"] = "answered"; json.dump(d, open(p, "w"))' \
  "$FLEET_CONF_DIR/global/steward.state.json"
park tick --session pk >/dev/null
grep -q "^7 pk --repo o/r --force --seed-file .* --resume $SID7 --origin issue-1" "$S/spawned" \
  && ok "D reopened on the SAME conversation ($SID7)" || bad "D spawn: $(cat "$S/spawned" 2>&1)"
grep -q "$HP" "$S/seed.last" 2>/dev/null && grep -q '不要从头来' "$S/seed.last" \
  && ok "D its first turn reads the handoff and goes on" || bad "D seed: $(cat "$S/seed.last" 2>&1)"
grep -qx 'label o/r 7 remove' "$S/gh.log" && ok "D blocked comes off" || bad "D label: $(cat "$S/gh.log")"
[ "$(tail -1 "$S/task.log")" = "set T41 --clear parked" ] && [ "$(grep -c T41 "$S/task.log")" = 2 ] \
  && ok "D …and off its hub record; #11 (no record) never touched one" || bad "D the record: $(cat "$S/task.log")"
( . "$BIN/fleet-lib.sh"; fleet_parked o/r 7 ) && bad "D still in park.idx after waking" || ok "D out of the book"
( . "$BIN/fleet-lib.sh"; fleet_parked o/r 11 ) && ok "D the other one stays parked" || bad "D #11 lost its park"

# --- E: no room ----------------------------------------------------------------------
echo 2 > "$S/spawn.rc"; : > "$S/gh.log"
park wake o/r#11 --session pk >/dev/null 2>&1 && bad "E a refused spawn reads as woken" || ok "E a refused spawn is not woken"
( . "$BIN/fleet-lib.sh"; fleet_parked o/r 11 ) && ok "E it stays parked" || bad "E dropped from the book"
[ "$(tail -1 "$S/gh.log")" = 'label o/r 11 add' ] && ok "E blocked goes back on" || bad "E labels: $(cat "$S/gh.log")"
rm -f "$S/spawn.rc"

# --- F: met before it lands ----------------------------------------------------------
park park issue-9 --wait time:2000-01-01T00:00:00Z --session pk >/dev/null
park tick --session pk >/dev/null
tmux list-windows -t pk -F '#{window_id}' | grep -qx "$W9" && ok "F a condition already met cancels the park" \
  || bad "F parked although its condition held"
grep -q '"ev": "cancel", "ref": "o/r#9"' "$FLEET_CONF_DIR/logs/park.ndjson" && ok "F a cancel event" || bad "F no cancel event"

# --- G: the steward's beat -------------------------------------------------------------
printf '#!/bin/sh\n:\n' > "$S/none"; chmod +x "$S/none"
printf '#!/bin/sh\nprintf "@9\\n"\n' > "$S/holder"; chmod +x "$S/holder"
beat() { env FLEET_STEWARD_HOLDER_CMD="$S/holder" FLEET_STEWARD_WINDOWS_CMD="$S/none" FLEET_STEWARD_CHILDREN_CMD="$S/none" \
             FLEET_STEWARD_SEND_CMD="$S/none" FLEET_STEWARD_STAMP_CMD="$S/none" FLEET_STEWARD_DOCTOR_CMD="$S/none" FLEET_STEWARD_IDLE_CMD="$S/none" \
             python3 "$BIN/fleet_steward.py" beat --holder --force --session pk; }
card=$(beat 2>&1)
printf '%s\n' "$card" | grep -q '停放 1 个' && ok "G the beat's card counts the parked" || bad "G card: $card"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if [p["ref"] for p in d.get("parked", [])] == ["o/r#11"] else 1)' \
  "$FLEET_CONF_DIR/global/steward.state.json" && ok "G steward.state.json lists what is parked" \
  || bad "G parked list: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("parked"))' "$FLEET_CONF_DIR/global/steward.state.json")"
cp "$FLEET_CONF_DIR/global/park.json" "$WORK/park.before"
touch -t 200001010000 "$FLEET_CONF_DIR/global/park.json"
FLEET_STEWARD_PARK=0 beat >/dev/null 2>&1
cmp -s "$WORK/park.before" "$FLEET_CONF_DIR/global/park.json" \
  && [ "$(date -r "$FLEET_CONF_DIR/global/park.json" +%Y 2>/dev/null || stat -c %y "$FLEET_CONF_DIR/global/park.json" | cut -c1-4)" = 2000 ] \
  && ok "G FLEET_STEWARD_PARK=0 ⇒ the book is not touched" || bad "G FLEET_STEWARD_PARK=0 still parked"

# --- I: the stuck metric ---------------------------------------------------------
grep '"ev": "stuck"' "$FLEET_CONF_DIR/logs/park.ndjson" | grep '"ref": "o/r#7"' | grep -q '"how": "parked"' \
  && ok "I #7's stuck stretch is one segment, ended by its park" \
  || bad "I no parked segment for #7: $(grep stuck "$FLEET_CONF_DIR/logs/park.ndjson")"

# --- J: no holder, no park (issue #3115) -----------------------------------------
python3 -c '
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d.pop("next_at", None); json.dump(d, open(p, "w"))' \
  "$FLEET_CONF_DIR/global/steward.state.json"
python3 -c '
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["observed_at"] = 0; d["stuck"] = {"o/r#99": 1}; json.dump(d, open(p, "w"))' \
  "$FLEET_CONF_DIR/global/park.json"
cp "$FLEET_CONF_DIR/global/park.json" "$WORK/park.j"
cp "$FLEET_CONF_DIR/global/steward.state.json" "$WORK/state.j"
: > "$S/sent"
for how in bare unheld; do
  if [ "$how" = bare ]; then
    env FLEET_STEWARD_HOLDER_CMD="$S/holder" FLEET_STEWARD_WINDOWS_CMD="$S/none" FLEET_STEWARD_CHILDREN_CMD="$S/none" \
        python3 "$BIN/fleet_steward.py" beat --force --session pk >/dev/null 2>&1
  else
    env FLEET_STEWARD_HOLDER_CMD="$S/none" FLEET_STEWARD_WINDOWS_CMD="$S/none" FLEET_STEWARD_CHILDREN_CMD="$S/none" \
        python3 "$BIN/fleet_steward.py" beat --holder --force --session pk >/dev/null 2>&1
  fi
  rc=$?
  [ "$rc" = 3 ] && [ ! -s "$S/sent" ] && cmp -s "$WORK/park.j" "$FLEET_CONF_DIR/global/park.json" \
    && cmp -s "$WORK/state.j" "$FLEET_CONF_DIR/global/steward.state.json" \
    && ok "J $how beat: rc 3, nothing parked, asked or written" \
    || bad "J $how beat: rc $rc, sent [$(cat "$S/sent")]"
done

# --- H: a restore from the map taken before the park -----------------------------
# #11 is still parked (#7 woke in D); #10 is an ordinary window lost beside it.
grep -q $'\tissue-11\t' "$FLEET_CONF_DIR/fleets/pk/restore.map" 2>/dev/null || bad "H the snapshot never mapped issue-11"
tmux kill-window -t "$W10"
out=$(env -u QUIET bash "$BIN/fleet-restore.sh" --dry-run 2>&1)
printf '%s\n' "$out" | grep -q 'issue-11: parked' && ok "H restore leaves the parked one closed, and says so" \
  || bad "H restore: $(printf '%s\n' "$out" | tail -8)"
printf '%s\n' "$out" | grep 'issue-11' | grep -qv 'parked' && bad "H restore touches the parked issue-11: $out" \
  || ok "H restore does nothing else with it"
printf '%s\n' "$out" | grep 'issue-10' | grep -qv 'parked' && ok "H an ordinary lost window still takes restore's road" \
  || bad "H restore lost its ordinary road: $(printf '%s\n' "$out" | tail -8)"

# --- K: a session with no issue, owned by a hub task record (issue #3387) ---------
rec() { printf '{"task": {"id": "T42", "updated_at": "%s", "asked": "%s"}, "live": ""}\n' "$1" "$2" > "$S/rec.T42"; }
rec 2026-10-11T10:00:00Z ''
W13=$(tmux new-window -d -P -F '#{window_id}' -t pk: -n '我的会话' -c "$WORK" "sh -c 'echo SCREEN-OF-T42; exec sleep 600'")
SID13=$(python3 -c 'import uuid; print(uuid.uuid4())'); FID13=$(python3 -c 'import uuid; print(uuid.uuid4())')
tmux set-option -w -t "$W13" @fleet_role worker \; set-option -w -t "$W13" @norepo 1 \; \
     set-option -w -t "$W13" @task T42 \; set-option -w -t "$W13" @fleet_id "$FID13" \; \
     set-option -w -t "$W13" @cc_session_id "$SID13" \; set-option -w -t "$W13" @norepo_sid "$SID13" \; \
     set-option -w -t "$W13" @claude_state needs \; set-option -w -t "$W13" @claude_state_ts "$OLD" \; \
     set-option -w -t "$W13" @origin issue-1
sleep 0.2
FLEET_RESTORE_STALE_MAP_AGE=0 bash "$BIN/fleet-restore.sh" --snapshot >/dev/null 2>&1   # H's closed windows: the shrink guard
grep -q "$FID13" "$FLEET_CONF_DIR/fleets/pk/restore.map" 2>/dev/null || bad "K the snapshot never mapped T42's window"
park candidates --session pk | grep -q $'^T42\t'"$W13"$'\ttask:T42\t' && ok "K a no-issue session with a record is a candidate, waiting on task:T42" \
  || bad "K candidates: $(park candidates --session pk)"
: > "$S/gh.log"; : > "$S/sent"; : > "$S/task.log"
park tick --judge --session pk >/dev/null
grep -q "^$W13"$'\t''\[fleet park\]' "$S/sent" && ok "K asked for its handoff over the peer channel" || bad "K no request: $(cat "$S/sent")"
HP13=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pending"]["T42"]["handoff"])' "$FLEET_CONF_DIR/global/park.json" 2>/dev/null)
[ -n "$HP13" ] && { mkdir -p "$(dirname "$HP13")"; printf '# handoff\nnext: the design page\n' > "$HP13"; }
park tick --session pk >/dev/null
tmux list-windows -t pk -F '#{window_id}' | grep -qx "$W13" && bad "K still open after its handoff" || ok "K handoff written ⇒ the window is closed"
grep -q "^pk fid:$FID13 parking=T42\$" "$S/stopped" && ok "K stopped by its identity (fid:), @parking set" \
  || bad "K stop: $(tail -2 "$S/stopped")"
[ ! -s "$S/gh.log" ] && ok "K no GitHub write at all" || bad "K wrote to GitHub: $(cat "$S/gh.log")"
[ "$(cat "$S/task.log")" = "set T42 --parked 停放：等 任务记录 T42 上有回音" ] && ok "K 「停放」 on its record" \
  || bad "K the record: $(cat "$S/task.log")"
grep -q 'SCREEN-OF-T42' "$FLEET_CONF_DIR/fleets/pk/park/task-T42.capture.txt" 2>/dev/null && ok "K the screen is kept" || bad "K no capture"
grep -q -- "--state blocked --win $W13" "$S/reported" && ok "K the parent is told blocked" || bad "K no report"
( . "$BIN/fleet-lib.sh"; fleet_parked_fid "$FID13" ) && ok "K booked as T42 (fleet_parked_fid)" \
  || bad "K park.idx: $(cat "$FLEET_CONF_DIR/global/park.idx")"
out=$(env -u QUIET bash "$BIN/fleet-restore.sh" --dry-run 2>&1)
printf '%s\n' "$out" | grep -q '我的会话: parked' && ok "K a restore leaves it closed" \
  || bad "K restore: $(printf '%s\n' "$out" | grep '我的会话'; printf '%s\n' "$out" | tail -5)"
park tick --session pk >/dev/null
[ ! -s "$S/raw.log" ] && ok "K the record unchanged ⇒ nothing wakes" || bad "K woke early: $(cat "$S/raw.log")"
rec 2026-10-11T10:05:00Z '要不要换方案'
park tick --session pk >/dev/null
[ ! -s "$S/raw.log" ] && ok "K changed, but a question still open ⇒ still parked" || bad "K woke on an open question"
rec 2026-10-11T10:09:00Z ''
park tick --session pk >/dev/null
grep -q "^pk --task T42 --seed-file .*task-T42.seed --node local --no-repo --resume $SID13 --name 我的会话 --origin issue-1\$" "$S/raw.log" \
  && ok "K answered ⇒ reopened on the SAME conversation ($SID13), no repo, its record" || bad "K wake: $(cat "$S/raw.log" 2>&1)"
grep -q "$HP13" "$S/rawseed.last" 2>/dev/null && grep -q 'T42' "$S/rawseed.last" && grep -q '不要从头来' "$S/rawseed.last" \
  && ok "K its first turn reads the handoff and the record" || bad "K seed: $(cat "$S/rawseed.last" 2>&1)"
[ "$(tail -1 "$S/task.log")" = "set T42 --clear parked" ] && ok "K the record's 「停放」 cleared" || bad "K record: $(cat "$S/task.log")"
( . "$BIN/fleet-lib.sh"; fleet_parked_fid "$FID13" ) && bad "K still booked after waking" || ok "K out of the book"
[ ! -s "$S/gh.log" ] && ok "K the wake wrote nothing to GitHub either" || bad "K wake wrote: $(cat "$S/gh.log")"

[ "$fails" = 0 ] && { echo "fleet-park-selftest: all passed"; exit 0; }
echo "fleet-park-selftest: $fails failed"; exit 1
