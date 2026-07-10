#!/bin/bash
# fleet-restore-selftest.sh — the steward snapshot+resume contract (issue #143).
#
# Workers survive a tmux-server crash: snapshot() records each work window's
# worktree + newest Claude transcript id, and restore() reopens them with
# `claude --resume <id>`. The STEWARD pane lives in the 'plan' PANEL window,
# which WIN rows exclude — so before #143 its transcript was never captured and
# a crash brought the steward back FRESH, losing its live conversation.
#
# The fix, exercised end-to-end here against a REAL isolated tmux server (its own
# socket, torn down at exit — never the user's live server) plus PATH-shimmed
# `tmux`/`claude` stubs so nothing real is launched:
#   • RESOLVER      the __STEWARD__ sentinel → a STEWARD row (path + newest id);
#                   panels drop to nothing; a work window still yields a WIN row.
#   • SNAPSHOT      a @steward-marked pane in a 'plan' window IS captured as a
#                   STEWARD row (path + id), even though the window is a panel.
#   • RESUME        steward-session.sh with STEWARD_RESUME_ID launches
#                   `claude --resume <id>`, NOT a fresh steward.
#   • FALLBACK      with no id it launches a FRESH steward that reads steward.md
#                   (the first-boot path — no regression).
#   • STALE ID      when `--resume` itself FAILS (pruned id), it falls back to a
#                   fresh steward via `||`, never a bare shell.
#
# tmux/python3 absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
RESOLVE="$BIN/.fleet-restore-resolve.py"
RESTORE="$BIN/fleet-restore.sh"
STEWARDSH="$BIN/steward-session.sh"
for f in "$RESOLVE" "$RESTORE" "$STEWARDSH"; do
  [ -f "$f" ] || { printf 'selftest: %s not found\n' "$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 absent — SKIP\n' >&2; exit 0; }
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

# Hermeticity: scrub ambient vars that would skew the scripts under test. QUIET
# silences restore()'s `say` (we assert on that output); the FLEET_*/STEWARD_*
# knobs would override the per-fleet conf / launch command we set up below.
unset QUIET FLEET_REPO FLEET_MAIN FLEET_BASE_BRANCH FLEET_STEWARD_CMD STEWARD_CMD STEWARD_RESUME_ID STEWARD_SESSION STEWARD_CWD

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
cat > "$WORK/bin/claude" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$WORK/claude-argv"
if [ -f "$WORK/fail-resume" ] && [ "\$1" = "--resume" ]; then exit 1; fi
exec /bin/sh
EOF
chmod +x "$WORK/bin/tmux" "$WORK/bin/claude"
export PATH="$WORK/bin:$PATH"

cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
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
# The steward pane's project dir gets a transcript; a panel and a work window too.
# Input rows are PIPE-delimited (matching tmux -F output); output rows are TAB.
STEW_PATH="$WORK/main"; mkdir -p "$STEW_PATH"; seed_transcript "$STEW_PATH" "stew-abc123"
WORK_PATH="$WORK/repo-issue-9"; mkdir -p "$WORK_PATH"; seed_transcript "$WORK_PATH" "wrk-def456"

out=$(printf '%s|%s|-\n%s|%s|9\n%s|%s|-\n' \
        "__STEWARD__" "$STEW_PATH" \
        "issue-9" "$WORK_PATH" \
        "dash" "$WORK/whatever" \
      | python3 "$RESOLVE")

printf '%s\n' "$out" | grep -qxF "STEWARD	$STEW_PATH	stew-abc123" \
  || fail "resolver: __STEWARD__ should emit a STEWARD row with the newest id (got: $out)"
printf '%s\n' "$out" | grep -qxF "WIN	issue-9	$WORK_PATH	wrk-def456	9" \
  || fail "resolver: a work window should still emit its WIN row (got: $out)"
printf '%s\n' "$out" | grep -q '^WIN	dash' \
  && fail "resolver: a panel (dash) must NOT emit a WIN row (got: $out)"
# a steward pane with no transcript yet → id '-'
noid=$(printf '__STEWARD__|%s|-\n' "$WORK/fresh" | python3 "$RESOLVE")
[ "$noid" = "STEWARD	$WORK/fresh	-" ] \
  || fail "resolver: a steward pane with no transcript should resolve id '-' (got: $noid)"

# ============================================================ 2. SNAPSHOT ======
# A real fleet layout: a 'plan' window with a @steward pane + a work window.
# snapshot() must capture the steward as a STEWARD row despite the panel name.
cat > "$FLEET_CONF_DIR/snap.conf" <<EOF
FLEET_REPO=acme/widgets
FLEET_MAIN=$STEW_PATH
FLEET_BASE_BRANCH=main
EOF
tmux new-session -d -s snap -x 200 -y 50 -c "$WORK_PATH" 2>/dev/null \
  || fail "could not start isolated tmux server"
tmux rename-window -t snap "issue-9"
tmux set-window-option -t snap:issue-9 @issue 9
# the hub 'plan' window: dash pane + a split @steward pane rooted at the base checkout
tmux new-window -t snap: -n plan -c "$WORK/whatever"
sp=$(tmux split-window -P -F '#{pane_id}' -t snap:plan -c "$STEW_PATH")
tmux set-option -p -t "$sp" @steward 1

bash "$RESTORE" --snapshot 2>/dev/null || fail "fleet-restore.sh --snapshot exited non-zero"
MAP="$FLEET_CONF_DIR/restore/snap.map"
[ -f "$MAP" ] || fail "snapshot wrote no map at $MAP"

grep -qxF "STEWARD	$STEW_PATH	stew-abc123" "$MAP" \
  || fail "snapshot: the @steward pane should be captured as a STEWARD row (map: $(cat "$MAP"))"
grep -q '^WIN	issue-9	' "$MAP" \
  || fail "snapshot: the work window should still be a WIN row (map: $(cat "$MAP"))"
grep -q '^WIN	plan	' "$MAP" \
  && fail "snapshot: the 'plan' panel must not be a WIN row (map: $(cat "$MAP"))"

# restore() must PARSE that STEWARD row and route the id into the steward launch.
# --dry-run exercises the parse+wiring without spawning fleet-up/claude, but only
# for a fleet that is DOWN — so drop the live snap session first.
tmux kill-session -t snap 2>/dev/null
dry=$(bash "$RESTORE" --dry-run 2>/dev/null)
# the display truncates the id at the first '-' (mirrors the worker line), so the
# 'stew…' prefix from 'stew-abc123' confirms restore parsed the STEWARD row's id.
printf '%s\n' "$dry" | grep -q 'steward → claude --resume stew' \
  || fail "restore --dry-run should report resuming the steward from the STEWARD row (got: $dry)"

# ============================================================ 3. RESUME/FALLBACK
# steward-session.sh builds the hub; assert the steward pane's launch command.
# poll for the claude stub's recorded argv (the pane starts asynchronously).
wait_argv() {
  # ~20s budget: the pane launch is async and a loaded CI box can lag well past
  # a couple seconds — a stingy timeout would flake, not catch a real regression.
  local _n
  for _n in $(seq 1 200); do
    [ -s "$WORK/claude-argv" ] && return 0
    tmux run-shell -t "$1" 'true' 2>/dev/null   # nudge the server; ~0.1s/iter
    perl -e 'select undef,undef,undef,0.1' 2>/dev/null || sleep 1
  done
  return 1
}

# --- RESUME: STEWARD_RESUME_ID present ⇒ `claude --resume <id>` ---------------
: > "$WORK/claude-argv"
tmux new-session -d -s res -x 200 -y 50 -c "$STEW_PATH" 2>/dev/null || fail "could not create session res"
env -u STEWARD_CMD -u FLEET_STEWARD_CMD \
  STEWARD_SESSION=res STEWARD_CWD="$STEW_PATH" STEWARD_RESUME_ID="stew-abc123" \
  bash "$STEWARDSH" >/dev/null 2>&1 || fail "steward-session.sh (resume) exited non-zero"
wait_argv res || fail "resume: the steward pane never launched claude (no recorded argv)"
grep -q -- '--resume stew-abc123' "$WORK/claude-argv" \
  || fail "resume: steward should launch 'claude --resume stew-abc123' (got: $(cat "$WORK/claude-argv"))"

# --- FALLBACK: no id ⇒ a FRESH steward that reads steward.md ------------------
: > "$WORK/claude-argv"
tmux new-session -d -s fresh -x 200 -y 50 -c "$STEW_PATH" 2>/dev/null || fail "could not create session fresh"
env -u STEWARD_CMD -u FLEET_STEWARD_CMD -u STEWARD_RESUME_ID \
  STEWARD_SESSION=fresh STEWARD_CWD="$STEW_PATH" \
  bash "$STEWARDSH" >/dev/null 2>&1 || fail "steward-session.sh (fresh) exited non-zero"
wait_argv fresh || fail "fallback: the steward pane never launched claude (no recorded argv)"
grep -q -- '--resume' "$WORK/claude-argv" \
  && fail "fallback: a steward with no id must NOT use --resume (got: $(cat "$WORK/claude-argv"))"
grep -q 'steward.md' "$WORK/claude-argv" \
  || fail "fallback: a fresh steward should read steward.md (got: $(cat "$WORK/claude-argv"))"

# --- STALE ID: `--resume` fails ⇒ fall back to a FRESH steward, not a bare shell
: > "$WORK/claude-argv"; : > "$WORK/fail-resume"   # make the stub fail on --resume
tmux new-session -d -s stale -x 200 -y 50 -c "$STEW_PATH" 2>/dev/null || fail "could not create session stale"
env -u STEWARD_CMD -u FLEET_STEWARD_CMD \
  STEWARD_SESSION=stale STEWARD_CWD="$STEW_PATH" STEWARD_RESUME_ID="stew-gone-77" \
  bash "$STEWARDSH" >/dev/null 2>&1 || fail "steward-session.sh (stale) exited non-zero"
# both should appear: the attempted resume, THEN the fresh fallback (|| path)
for _n in $(seq 1 200); do
  grep -q 'steward.md' "$WORK/claude-argv" && break
  tmux run-shell -t stale 'true' 2>/dev/null
  perl -e 'select undef,undef,undef,0.1' 2>/dev/null || sleep 1
done
grep -q -- '--resume stew-gone-77' "$WORK/claude-argv" \
  || fail "stale: the steward should first attempt --resume (got: $(cat "$WORK/claude-argv"))"
grep -q 'steward.md' "$WORK/claude-argv" \
  || fail "stale: a FAILED resume must fall back to a fresh steward, not a bare shell (got: $(cat "$WORK/claude-argv"))"
rm -f "$WORK/fail-resume"

printf 'selftest PASS: steward snapshot+resume — STEWARD row captured, resumed with --resume, fresh + stale-id fallbacks intact\n'
exit 0
