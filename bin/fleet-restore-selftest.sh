#!/bin/bash
# fleet-restore-selftest.sh — the snapshot+resume contract (issue #143), and the
# dash-only hub guarantee that replaced the hub-resume leg.
#
# Workers survive a tmux-server crash: snapshot() records each work window's
# worktree + newest Claude transcript id, and restore() reopens them with
# `claude --resume <id>`. The HUB pane lives in the 'plan' PANEL window,
# which WIN rows exclude — so before #143 its transcript was never captured and
# a crash brought the hub back FRESH, losing its live conversation.
#
# The fix, exercised end-to-end here against a REAL isolated tmux server (its own
# socket, torn down at exit — never the user's live server) plus PATH-shimmed
# `tmux`/`claude` stubs so nothing real is launched:
#   • RESOLVER      the __HUB__ sentinel → a HUB row (path + newest id);
#                   panels drop to nothing; a work window still yields a WIN row.
#   • SNAPSHOT      a @hub-marked pane in a 'plan' window IS captured as a
#                   HUB row (path + id), even though the window is a panel.
#   • RESUME        hub-session.sh with HUB_RESUME_ID launches
#                   `claude --resume <id>`, NOT a fresh hub.
#   • FALLBACK      with no id it launches a FRESH, bare `claude`
#                   (the first-boot path — no regression).
#   • STALE ID      when `--resume` itself FAILS (pruned id), it falls back to a
#                   fresh hub via `||`, never a bare shell.
#
# Also covers the per-window runtime-state restore (issue #153): the
# @claude_state|@prci|@pfg trio rides each WIN row (RESOLVER pass-through +
# SNAPSHOT capture), and restore() auto-continues ONLY a window that was
# 'working' at crash, leaving 'done'/idle windows parked.
#
# And the hub-only recovery contract (issue #160):
#   • SHRINK GUARD  a snapshot of a HUB-ONLY session (panels only, no work
#                   windows) must NOT erase a richer prior map's WIN rows — that
#                   was how a mid-restore snapshot destroyed the recovery data.
#   • RECONCILE     restore against an up-but-hub-only fleet must REOPEN the
#                   mapped work windows (resumed), not skip the live session; and
#                   a second restore must not duplicate them (idempotent).
#
# tmux/python3 absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
RESOLVE="$BIN/.fleet-restore-resolve.py"
RESTORE="$BIN/fleet-restore.sh"
HUBSH="$BIN/hub-session.sh"
for f in "$RESOLVE" "$RESTORE" "$HUBSH"; do
  [ -f "$f" ] || { printf 'selftest: %s not found\n' "$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 absent — SKIP\n' >&2; exit 0; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

# Hermeticity: scrub ambient vars that would skew the scripts under test. QUIET
# silences restore()'s `say` (we assert on that output); the FLEET_*/HUB_*
# knobs would override the per-fleet conf / launch command we set up below.
unset QUIET FLEET_REPO FLEET_MAIN FLEET_BASE_BRANCH FLEET_HUB_CMD HUB_CMD HUB_RESUME_ID HUB_SESSION HUB_CWD

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fr-selftest.XXXXXX")" || exit 2
# Resolve to the physical path: tmux reports pane_current_path with symlinks
# resolved (macOS /var → /private/var), so our seeded transcript slugs must match.
WORK="$(cd "$WORK" && pwd -P)"
export HOME="$WORK"                       # transcript lookups resolve under here
export FLEET_CONF_DIR="$WORK/conf"        # isolate the restore map + confs
mkdir -p "$WORK/bin" "$FLEET_CONF_DIR"

# Route the plain `tmux` (called unqualified by the scripts) onto a private socket.
SOCK="$WORK/tmux.sock"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
# A `claude` stub that records its argv (so we can assert resume-vs-fresh) then
# drops to a shell so the pane stays alive like the real launcher. If the marker
# file $WORK/fail-resume exists AND this invocation is a `--resume`, it records
# and EXITS NON-ZERO instead — simulating a stale/pruned transcript id, so we can
# assert the `|| fresh` fallback fires rather than leaving a bare shell.
# NB: match --resume ANYWHERE in argv, not just \$1 — the real `claude` accepts
# flags in any order, so the assertions must not depend on argv position.
cat > "$WORK/bin/claude" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/claude-argv"
case " \$* " in *" --resume "*) [ -f "$WORK/fail-resume" ] && exit 1 ;; esac
exec /bin/sh
EOF
chmod +x "$WORK/bin/tmux" "$WORK/bin/claude"
export PATH="$WORK/bin:$PATH"

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
# A bare EXIT trap does NOT fire when bash is killed by a signal — turn INT/TERM/HUP
# (Ctrl-C, a CI timeout) into a normal exit so cleanup still reaps the isolated
# server instead of leaking it to the machine (issue #152). fleet-selftest-reap.sh
# is the backstop for the runs that a SIGKILL still slips past.
trap 'exit 130' INT TERM HUP
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }

# slug: mirror the resolver's re.sub(r"[/._]", "-", path).
slug() { printf '%s' "$1" | sed 's/[/._]/-/g'; }
# seed a newest transcript <id>.jsonl in a path's project dir.
seed_transcript() {
  local path="$1" id="$2" d
  d="$HOME/.claude/projects/$(slug "$path")"
  mkdir -p "$d"
  : > "$d/$id.jsonl"
}

# ============================================================ 1. RESOLVER ======
# The hub pane's project dir gets a transcript; a panel and a work window too.
# Input rows are PIPE-delimited (matching tmux -F output); output rows are TAB.
STEW_PATH="$WORK/main"; mkdir -p "$STEW_PATH"; seed_transcript "$STEW_PATH" "stew-abc123"
WORK_PATH="$WORK/repo-issue-9"; mkdir -p "$WORK_PATH"; seed_transcript "$WORK_PATH" "wrk-def456"

# issue-9  : a bare 3-field row → the state trio defaults to '-' (nothing to restore).
# issue-9b : carries the @claude_state|@prci|@pfg trio (issue #153) → passed through.
out=$(printf '%s|%s|-\n%s|%s|9\n%s|%s|9|working|✓|#9ece6a\n%s|%s|-\n' \
        "__HUB__" "$STEW_PATH" \
        "issue-9" "$WORK_PATH" \
        "issue-9b" "$WORK_PATH" \
        "dash" "$WORK/whatever" \
      | python3 "$RESOLVE")

printf '%s\n' "$out" | grep -qxF "HUB	$STEW_PATH	stew-abc123" \
  || fail "resolver: __HUB__ should emit a HUB row with the newest id (got: $out)"
printf '%s\n' "$out" | grep -qxF "WIN	issue-9	$WORK_PATH	wrk-def456	9	-	-	-" \
  || fail "resolver: a bare work window WIN row should default the state trio to '-' (got: $out)"
printf '%s\n' "$out" | grep -qxF "WIN	issue-9b	$WORK_PATH	wrk-def456	9	working	✓	#9ece6a" \
  || fail "resolver: the @claude_state|@prci|@pfg trio should pass through onto the WIN row (got: $out)"
printf '%s\n' "$out" | grep -q '^WIN	dash' \
  && fail "resolver: a panel (dash) must NOT emit a WIN row (got: $out)"
# a hub pane with no transcript yet → id '-'
noid=$(printf '__HUB__|%s|-\n' "$WORK/fresh" | python3 "$RESOLVE")
[ "$noid" = "HUB	$WORK/fresh	-" ] \
  || fail "resolver: a hub pane with no transcript should resolve id '-' (got: $noid)"

# ============================================================ 2. SNAPSHOT ======
# A real fleet layout: a 'plan' window with a @hub pane + a work window.
# snapshot() must capture the hub pane as a HUB row despite the panel name.
cat > "$FLEET_CONF_DIR/snap.conf" <<EOF
FLEET_REPO=acme/widgets
FLEET_MAIN=$STEW_PATH
FLEET_BASE_BRANCH=main
EOF
tmux new-session -d -s snap -x 200 -y 50 -c "$WORK_PATH" 2>/dev/null \
  || fail "could not start isolated tmux server"
tmux rename-window -t snap "issue-9"
tmux set-window-option -t snap:issue-9 @issue 9
# issue-9 was mid-turn at crash: @claude_state=working (+ a green-PR glyph/color).
# snapshot must capture the trio so restore() can re-stamp + auto-continue it (#153).
tmux set-window-option -t snap:issue-9 @claude_state working
tmux set-window-option -t snap:issue-9 @prci "✓"
tmux set-window-option -t snap:issue-9 @pfg "#9ece6a"
# issue-10 was parked at 'done' — captured too, but restore must NOT auto-continue it.
tmux new-window -t snap: -n issue-10 -c "$WORK_PATH"
tmux set-window-option -t snap:issue-10 @issue 10
tmux set-window-option -t snap:issue-10 @claude_state "done"
# the hub 'plan' window: dash pane + a split @hub pane rooted at the base checkout
tmux new-window -t snap: -n plan -c "$WORK/whatever"
sp=$(tmux split-window -P -F '#{pane_id}' -t snap:plan -c "$STEW_PATH")
tmux set-option -p -t "$sp" @hub 1

bash "$RESTORE" --snapshot 2>/dev/null || fail "fleet-restore.sh --snapshot exited non-zero"
# One directory per fleet (issue #181): the snapshot writes fleets/<sess>/restore.map.
MAP="$FLEET_CONF_DIR/fleets/snap/restore.map"
[ -f "$MAP" ] || fail "snapshot wrote no map at $MAP"

grep -qxF "HUB	$STEW_PATH	stew-abc123" "$MAP" \
  || fail "snapshot: the @hub pane should be captured as a HUB row (map: $(cat "$MAP"))"
grep -q '^WIN	issue-9	' "$MAP" \
  || fail "snapshot: the work window should still be a WIN row (map: $(cat "$MAP"))"
grep -q '^WIN	plan	' "$MAP" \
  && fail "snapshot: the 'plan' panel must not be a WIN row (map: $(cat "$MAP"))"
# issue #153: the per-window runtime state trio rides on the WIN row.
grep -qE '^WIN	issue-9	.*	working	✓	#9ece6a$' "$MAP" \
  || fail "snapshot: issue-9's @claude_state|@prci|@pfg trio should be captured (map: $(cat "$MAP"))"
grep -qE '^WIN	issue-10	.*	done	-	-$' "$MAP" \
  || fail "snapshot: issue-10's 'done' state should be captured, unset prci/pfg as '-' (map: $(cat "$MAP"))"

# restore() must IGNORE the HUB row: the hub is dash-only, so there is no Claude
# session to bring back. --dry-run exercises the parse+wiring without spawning
# fleet-up/claude, but only for a fleet that is DOWN — so drop the live snap first.
tmux kill-session -t snap 2>/dev/null
dry=$(bash "$RESTORE" --dry-run 2>/dev/null)
# REGRESSION: a map carrying a HUB row (this one does — section 2 just wrote it)
# must NOT make restore announce or perform a hub resume. This is the exact path
# that used to bring back a hub Claude the operator had closed on purpose.
printf '%s\n' "$dry" | grep -q 'hub → claude --resume' \
  && fail "restore must NOT resume a hub Claude from a HUB row (got: $dry)"
# The work windows must still resume — only the hub leg is gone.
printf '%s\n' "$dry" | grep 'issue-9 ' | grep -q 'claude --resume wrk' \
  || fail "restore --dry-run should still resume the WORK windows (got: $dry)"
# issue #153: a 'working' window is flagged for auto-continue; a 'done' one is not.
printf '%s\n' "$dry" | grep 'issue-9 ' | grep -q '(auto-continue)' \
  || fail "restore --dry-run should mark the 'working' issue-9 window for auto-continue (got: $dry)"
printf '%s\n' "$dry" | grep 'issue-10 ' | grep -q '(auto-continue)' \
  && fail "restore --dry-run must NOT auto-continue the parked 'done' issue-10 window (got: $dry)"

# --- legacy map (pre-#153, 5-field WIN rows) + a no-transcript 'working' window --
# A map left on disk from before #153 has NO state trio; restore must parse it
# gracefully (resumed by id, never auto-continued — the resolver docstring promises
# "old maps parse fine"). And a 'working' window whose transcript can't be found
# (wid='-') must fall to the FRESH branch WITHOUT a nudge: telling a brand-new,
# context-less claude it was "restored … continue the task" would have it act on
# work it never saw (issue #153 review finding).
LEGACY="$FLEET_CONF_DIR/restore/legacy.map"
printf 'FLEET\tlegacy\tacme/widgets\t%s\tmain\n' "$STEW_PATH"                > "$LEGACY"
printf 'WIN\tissue-42\t%s\twrk-def456\t42\n'      "$WORK_PATH"              >> "$LEGACY"  # legacy 5-field row
printf 'WIN\tissue-77\t%s\t-\t77\tworking\t-\t-\n' "$WORK_PATH"             >> "$LEGACY"  # working, no transcript
dry2=$(bash "$RESTORE" --dry-run 2>/dev/null)
rm -f "$LEGACY"
printf '%s\n' "$dry2" | grep 'issue-42 ' | grep -q 'claude --resume wrk' \
  || fail "restore: a legacy 5-field WIN row should still resume by id (got: $dry2)"
printf '%s\n' "$dry2" | grep 'issue-42 ' | grep -q '(auto-continue)' \
  && fail "restore: a legacy row with no captured state must NOT be auto-continued (got: $dry2)"
printf '%s\n' "$dry2" | grep 'issue-77 ' | grep -q 'no transcript found' \
  || fail "restore: a 'working' window with no transcript should fall to the fresh branch (got: $dry2)"
printf '%s\n' "$dry2" | grep 'issue-77 ' | grep -q '(auto-continue)' \
  && fail "restore: a no-transcript 'working' window must NOT be nudged as if resumed (got: $dry2)"

# ====================================== 3. THE HUB NEVER LAUNCHES A CLAUDE =====
# hub-session.sh builds the hub; assert it builds the DASH ALONE. The old contract
# here was the opposite — resume by id, bare fresh launch, stale-id fallback — all
# of which spawned a Claude in a second pane. That pane restored itself unasked on
# every ⌂ tap / F9 / fleet-up / crash recovery, so it is gone.
#
# This is the LIVE counterpart to hub-session-selftest.sh's hermetic check: a stub
# `claude` on PATH records its argv, so "no claude was launched" is proven by the
# recording staying EMPTY rather than by inspecting a command string.

# Give an errant launch a real chance to show up before declaring the file empty —
# the pane starts asynchronously, so asserting immediately would pass vacuously.
settle() {
  local _n
  for _n in $(seq 1 20); do
    [ -s "$WORK/claude-argv" ] && return 0     # something launched — fail fast
    tmux run-shell -t "$1" 'true' 2>/dev/null  # nudge the server; ~0.1s/iter
    perl -e 'select undef,undef,undef,0.1' 2>/dev/null || sleep 1
  done
  return 1
}

# assert_dash_only <session> <label>
assert_dash_only() {
  local sess="$1" why="$2" panes
  settle "$sess" && fail "$why: the hub launched a claude (argv: $(cat "$WORK/claude-argv"))"
  [ ! -s "$WORK/claude-argv" ] \
    || fail "$why: no claude may be launched by the hub (argv: $(cat "$WORK/claude-argv"))"
  panes=$(tmux list-panes -t "$sess:plan" -F x 2>/dev/null | wc -l | tr -d ' ')
  [ "$panes" = 1 ] || fail "$why: the hub must be ONE pane (the dash), got $panes"
}

# --- REGRESSION: HUB_RESUME_ID from an OLD map must not resurrect anything ----
: > "$WORK/claude-argv"
tmux new-session -d -s res -x 200 -y 50 -c "$STEW_PATH" 2>/dev/null || fail "could not create session res"
env -u HUB_CMD -u FLEET_HUB_CMD \
  HUB_SESSION=res HUB_CWD="$STEW_PATH" HUB_RESUME_ID="stew-abc123" \
  bash "$HUBSH" >/dev/null 2>&1 || fail "hub-session.sh (stale-id) exited non-zero"
assert_dash_only res "HUB_RESUME_ID"

# --- a plain build is likewise dash-only -------------------------------------
: > "$WORK/claude-argv"
tmux new-session -d -s fresh -x 200 -y 50 -c "$STEW_PATH" 2>/dev/null || fail "could not create session fresh"
env -u HUB_CMD -u FLEET_HUB_CMD -u HUB_RESUME_ID \
  HUB_SESSION=fresh HUB_CWD="$STEW_PATH" \
  bash "$HUBSH" >/dev/null 2>&1 || fail "hub-session.sh (fresh) exited non-zero"
assert_dash_only fresh "fresh build"

# --- REGRESSION: a leftover FLEET_HUB_CMD in a conf is not a back door -------
: > "$WORK/claude-argv"
tmux new-session -d -s ovr -x 200 -y 50 -c "$STEW_PATH" 2>/dev/null || fail "could not create session ovr"
env -u HUB_CMD -u HUB_RESUME_ID \
  FLEET_HUB_CMD='claude "my own orders"; exec $SHELL' \
  HUB_SESSION=ovr HUB_CWD="$STEW_PATH" \
  bash "$HUBSH" >/dev/null 2>&1 || fail "hub-session.sh (override) exited non-zero"
assert_dash_only ovr "FLEET_HUB_CMD override"

# ================================= 4. HUB-ONLY RECOVERY (issue #160) ============
# A snapshot of a hub-only session must NOT shrink a richer map, and restore must
# reopen the missing work windows instead of skipping a live-but-hub-only fleet.
#
# Clean slate for restore()'s map glob: drop the earlier sections' maps — BOTH the
# new per-fleet layout (fleets/<sess>/restore.map, issue #181) and any legacy ones —
# so it can't wander onto the down 'snap' fleet (that would spawn a real fleet-up).
rm -f "$FLEET_CONF_DIR/restore/"*.map "$FLEET_CONF_DIR"/fleets/*/restore.map
TAB="$(printf '\t')"

# Two work windows in the durable map (their worktrees must exist so restore
# doesn't skip them). $WORK_PATH is the issue-9 worktree seeded in section 1.
# 5-field (pre-#153) WIN rows on purpose: they exercise the legacy-map parse in
# the reconcile path (missing state trio → no nudge/re-stamp, just resume).
W11="$WORK/repo-issue-11"; mkdir -p "$W11"
cat > "$FLEET_CONF_DIR/hubonly.conf" <<EOF
FLEET_REPO=acme/widgets
FLEET_MAIN=$STEW_PATH
FLEET_BASE_BRANCH=main
EOF
HMAP="$FLEET_CONF_DIR/restore/hubonly.map"
mkdir -p "$FLEET_CONF_DIR/restore"
{
  printf 'FLEET\thubonly\tacme/widgets\t%s\tmain\n' "$STEW_PATH"
  printf 'WIN\tissue-9\t%s\twrk-def456\t9\n'  "$WORK_PATH"
  printf 'WIN\tissue-11\t%s\twrk-xyz789\t11\n' "$W11"
  printf 'HUB\t%s\tstew-abc123\n' "$STEW_PATH"
} > "$HMAP"

# A LIVE hub-only session: just the 'plan' panel with a @hub pane, no work
# windows — exactly the mid-restore shape that used to destroy the map. Create it
# on the SAME isolated server the earlier sections are still using; do NOT
# kill-server first and restart — that races the socket teardown and flaked
# ("could not start hub-only session") in CI. The section-3 res/fresh/stale
# sessions keep the server alive; retire them AFTER hubonly exists so the
# --snapshot below sees only hubonly (deterministic map).
tmux new-session -d -s hubonly -x 200 -y 50 -c "$STEW_PATH" 2>/dev/null \
  || fail "could not start hub-only session"
tmux rename-window -t hubonly plan
hsp=$(tmux split-window -P -F '#{pane_id}' -t hubonly:plan -c "$STEW_PATH")
tmux set-option -p -t "$hsp" @hub 1
for _s in res fresh stale; do tmux kill-session -t "$_s" 2>/dev/null; done

# --- SHRINK GUARD: a hub-only snapshot must keep the richer prior WIN rows ------
bash "$RESTORE" --snapshot 2>/dev/null || fail "snapshot (hub-only) exited non-zero"
grep -q "^WIN${TAB}issue-9${TAB}" "$HMAP" \
  || fail "shrink-guard: a hub-only snapshot erased the issue-9 WIN row (map: $(cat "$HMAP"))"
grep -q "^WIN${TAB}issue-11${TAB}" "$HMAP" \
  || fail "shrink-guard: a hub-only snapshot erased the issue-11 WIN row (map: $(cat "$HMAP"))"

# ------------------- STALENESS ESCAPES + REJECT ALARM (issue #504) --------------
# Row-count-only rejection froze a real fleet's map at a week-dead layout: a fleet
# that permanently shrinks never "grows back", so every snapshot was rejected with
# one silent log line per cycle. The guard now (a) counts consecutive rejections
# and alarms via FLEET_NOTIFY_CMD, (b) ignores stored WIN rows whose worktree is
# gone, and (c) accepts the live layout once the stored map is over-age.

# The hub-only rejection above must have been COUNTED (visible-freeze contract).
# NB: counts here are ≥1, not ==1 — the tmux stub collapses every fleet_sockets
# entry onto ONE real socket, so one --snapshot can walk a session several times.
is_pos() { case "$1" in (''|0|*[!0-9]*) return 1;; (*) return 0;; esac; }
REJF="$FLEET_CONF_DIR/fleets/hubonly/.snapshot-rejects"
is_pos "$(cat "$REJF" 2>/dev/null)" \
  || fail "reject-count: a guarded rejection should be counted in $REJF (got: '$(cat "$REJF" 2>/dev/null)')"

# A dedicated fixture fleet (retired before the reconcile below): ONE live work
# window, a stored map claiming THREE.
SA="$WORK/repo-issue-21"; mkdir -p "$SA"
SB="$WORK/repo-issue-22"                    # never created — a DEAD stored row
SC="$WORK/repo-issue-23"                    # never created — a DEAD stored row
cat > "$FLEET_CONF_DIR/shrinky.conf" <<EOF
FLEET_REPO=acme/widgets
FLEET_MAIN=$STEW_PATH
FLEET_BASE_BRANCH=main
EOF
tmux new-session -d -s shrinky -x 200 -y 50 -c "$SA" 2>/dev/null \
  || fail "could not start shrinky session"
tmux rename-window -t shrinky issue-21
tmux set-window-option -t shrinky:issue-21 @issue 21
SMAP="$FLEET_CONF_DIR/fleets/shrinky/restore.map"
SREJF="$FLEET_CONF_DIR/fleets/shrinky/.snapshot-rejects"
mkdir -p "${SMAP%/*}"
mkmap() {  # (re)write the stored shrinky map with a WIN row per worktree path
  { printf 'FLEET\tshrinky\tacme/widgets\t%s\tmain\n' "$STEW_PATH"
    local p n=21
    for p in "$@"; do printf 'WIN\tissue-%s\t%s\t-\t%s\n' "$n" "$p" "$n"; n=$((n+1)); done
  } > "$SMAP"
}
win_rows() { awk -F'\t' '$1=="WIN"' "$SMAP" 2>/dev/null | wc -l | tr -d ' '; }

# DEAD-ROW escape: stored 3 rows, only 1 worktree still exists → live 1 ≥ 1 —
# the shrink is ACCEPTED and the dead rows drop out.
mkmap "$SA" "$SB" "$SC"
bash "$RESTORE" --snapshot 2>/dev/null || fail "snapshot (dead-row) exited non-zero"
[ "$(win_rows)" = 1 ] \
  || fail "dead-row escape: stored rows with no worktree must not block the overwrite (map: $(cat "$SMAP"))"
grep -q "issue-22" "$SMAP" \
  && fail "dead-row escape: the dead issue-22 row should be gone (map: $(cat "$SMAP"))"

# AGE escape: stored 3 rows, ALL worktrees live → a FRESH map still rejects
# (the #160 mid-restore protection is intact) …
SD="$WORK/repo-issue-24"; SE="$WORK/repo-issue-25"; mkdir -p "$SD" "$SE"
mkmap "$SA" "$SD" "$SE"
bash "$RESTORE" --snapshot 2>/dev/null
[ "$(win_rows)" = 3 ] \
  || fail "shrink-guard: a FRESH all-live-worktree map must still reject the shrink (map: $(cat "$SMAP"))"
is_pos "$(cat "$SREJF" 2>/dev/null)" \
  || fail "reject-count: shrinky's rejection should be counted (got: '$(cat "$SREJF" 2>/dev/null)')"
# … but an over-age map is stale, not mid-restore — the live layout wins.
touch -t 202001010000 "$SMAP" || fail "could not age the stored map"
FLEET_RESTORE_STALE_MAP_AGE=3600 bash "$RESTORE" --snapshot 2>/dev/null
[ "$(win_rows)" = 1 ] \
  || fail "age escape: an over-age stored map should accept the live shrink (map: $(cat "$SMAP"))"
[ -f "$SREJF" ] \
  && fail "reject-count: a successful snapshot write must reset the reject streak"

# REJECT ALARM: hitting FLEET_RESTORE_REJECT_ALARM consecutive rejects fires
# FLEET_NOTIFY_CMD once — not before the threshold.
cat > "$WORK/bin/notify-stub" <<EOF
#!/bin/sh
printf '%s\n' "\$1" >> "$WORK/notified"
EOF
chmod +x "$WORK/bin/notify-stub"
mkmap "$SA" "$SD" "$SE"
FLEET_RESTORE_REJECT_ALARM=100 FLEET_NOTIFY_CMD="$WORK/bin/notify-stub" \
  bash "$RESTORE" --snapshot 2>/dev/null
[ -f "$WORK/notified" ] \
  && fail "alarm: must NOT fire before the reject threshold (got: $(cat "$WORK/notified"))"
rm -f "$SREJF"           # deterministic streak start for the threshold-1 run
FLEET_RESTORE_REJECT_ALARM=1 FLEET_NOTIFY_CMD="$WORK/bin/notify-stub" \
  bash "$RESTORE" --snapshot 2>/dev/null
grep -q "restore.map frozen: shrinky" "$WORK/notified" 2>/dev/null \
  || fail "alarm: crossing the reject threshold should notify via FLEET_NOTIFY_CMD (got: '$(cat "$WORK/notified" 2>/dev/null)')"

# Retire the fixture BEFORE the reconcile below: kill its session AND drop its
# map/conf, so restore() can't wander onto a down 'shrinky' fleet (real fleet-up).
tmux kill-session -t shrinky 2>/dev/null
rm -rf "$FLEET_CONF_DIR/fleets/shrinky" "$FLEET_CONF_DIR/shrinky.conf"

# --- RECONCILE: restore an up-but-hub-only fleet reopens the missing windows ----
: > "$WORK/claude-argv"
out=$(bash "$RESTORE" 2>/dev/null)
printf '%s\n' "$out" | grep -q 'reconciling fleet hubonly' \
  || fail "reconcile: restore should reconcile (not skip) a live hub-only fleet (got: $out)"
lw=$(tmux list-windows -t hubonly -F '#{window_name}' 2>/dev/null)
printf '%s\n' "$lw" | grep -qxF issue-9 \
  || fail "reconcile: restore did not reopen the missing issue-9 window (windows: $lw)"
printf '%s\n' "$lw" | grep -qxF issue-11 \
  || fail "reconcile: restore did not reopen the missing issue-11 window (windows: $lw)"
# the reopened window resumed its transcript (launched through fleet-claude.sh,
# which transparently exec's `claude --resume <id>`; the pane starts async → poll)
for _n in $(seq 1 200); do
  grep -q -- '--resume wrk-def456' "$WORK/claude-argv" && break
  tmux run-shell -t hubonly 'true' 2>/dev/null
  perl -e 'select undef,undef,undef,0.1' 2>/dev/null || sleep 1
done
grep -q -- '--resume wrk-def456' "$WORK/claude-argv" \
  || fail "reconcile: issue-9 should resume via 'claude --resume wrk-def456' (argv: $(cat "$WORK/claude-argv"))"

# --- IDEMPOTENT: a second restore must not duplicate the now-live windows -------
bash "$RESTORE" >/dev/null 2>&1
dup=$(tmux list-windows -t hubonly -F '#{window_name}' 2>/dev/null | grep -cxF issue-9)
[ "$dup" = 1 ] \
  || fail "reconcile: a second restore duplicated the issue-9 window (count: $dup)"

printf 'selftest PASS: hub snapshot+resume + per-window state trio (#153) + hub-only recovery (#160) + shrink-guard staleness escapes & reject alarm (#504) — HUB row captured but NEVER resumed (dash-only hub), working-window auto-continue wired, snapshot keeps a richer map (dead-row/age escapes unfreeze it, rejects counted+alarmed), restore reconciles missing windows idempotently\n'
exit 0
