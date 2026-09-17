#!/bin/bash
# fleet-cleanup-selftest.sh — hermetic tests for the seat-agnostic, no-merge
# janitor bin/fleet-cleanup.sh (issue #277). Derived from fleet-land-selftest.sh
# with every merge case dropped (cleanup never merges) and the cleanup-specific
# cases added. No network, no real repo, no tmux server: fake gh/git/tmux on PATH,
# a temp base checkout, and FLEET_HISTORY_LEDGER pointed at a temp file.
#
# Covers:
#   MERGED           → cleaned:<sha>  (+ ledger row BEFORE teardown captured the
#                                       worktree path, teardown order window →
#                                       worktree → branch, base pull happened)
#   CLOSED-unmerged  → cleaned:closed (orphan reaped, closed-unlanded ledger row,
#                                       NO base pull) — but ONLY past the liveness
#                                       gate (issue #544):
#     window `working`                  → skip:live  (a session mid-turn)
#     transcript moved AFTER closedAt   → skip:live  (working ON the close; #534,
#                                         and the ⌃o-restore case — no timeout)
#     transcript quiet < the grace      → skip:live
#     no readable transcript + a window → skip:live  (cannot prove it idle)
#     dirty worktree                    → skip:dirty (autoclean's KEEP rule)
#     --dry-run over a live one         → skip:live, not dry:would-reap-closed
#   OPEN             → skip:not-final (nothing torn down, nothing recorded)
#   already-torn-down (MERGED, no worktree/window) → skip:nothing (idempotent,
#                                       no duplicate ledger row, no teardown)
#   self-cwd cleanup → teardown DETACHES into the tmux server (worker-safe), and the
#                      detached command drives bin/fleet-worktree-drop.sh
#   the drop itself  → the worktree is RENAMED into a sibling .fleet-trash/ with its
#                      bytes intact and pruned from the registry, never deleted
#                      inline (issue #586 — a 308k-file delete held the daemon 67min)
#   --dry-run        → dry:*  (no teardown, no mutation)
#   NON-issue head (a scratch that grew into a PR, issue #589):
#     knob OFF (default) → skip:nothing, NOTHING torn down — the historic behavior
#     knob ON  + clean + tip==merged head + window `done` → cleaned:* + teardown
#                                            (dropped into .fleet-trash, not deleted)
#     knob ON  + window working → skip:busy      (the operator's own workbench)
#     knob ON  + dirty worktree → skip:dirty
#     knob ON  + commits past the merge → skip:unmerged
#     knob ON  + protected head branch  → skip:protected
#     knob ON  + no window in the worktree → skip:nothing (fails CLOSED; that case
#                                            belongs to worktree-autoclean.sh)
#     knob ON  + CLOSED-unmerged        → skip:nothing (never in scope)
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CLEAN="$BIN/fleet-cleanup.sh"
[ -x "$CLEAN" ] || { echo "selftest: $CLEAN missing/not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-cleanup-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/main/.git" "$WORK/fakebin" "$WORK/conf" "$WORK/leases" "$WORK/dash"
ORDER_LOG="$WORK/order"; PULL_LOG="$WORK/pull"; LEDGER="$WORK/ledger.tsv"

# --- fake git: no-op success; log teardown ops + the base pull in order --------
# worktree list prints a block so the issue-42 worktree resolves UNLESS WT_GONE=1
# (the already-torn-down scenario). worktree remove / branch -D / pull append to
# their logs so the test can assert ordering and whether the base was pulled.
cat > "$WORK/fakebin/git" <<GITFAKE
#!/bin/bash
if [ "\${1:-}" = "-C" ]; then shift 2; fi
case "\${1:-}" in
  worktree)
    case "\${2:-}" in
      list)   [ "\${WT_GONE:-0}" = 1 ] || printf 'worktree %s/wt-issue-42\nHEAD deadbeef\nbranch refs/heads/issue-42\n\n' "$WORK"
              [ "\${SCRATCH_WT:-0}" = 1 ] && printf 'worktree %s/wt-scratch-99\nHEAD %s\nbranch refs/heads/scratch-99\n\n' "$WORK" "\${FAKE_TIP:-cafe1234}"
              : ;;
      remove) printf 'worktree-remove %s\n' "\${!#}" >> "$ORDER_LOG" ;;
      prune)  printf 'worktree-prune\n'  >> "$ORDER_LOG" ;;
      *)      : ;;
    esac ;;
  branch)  printf 'branch-D %s\n' "\${3:-}" >> "$ORDER_LOG" ;;   # git branch -D <b>
  pull)    printf 'pull\n' >> "$PULL_LOG"
           [ "\${FAKE_RESUME_ON_PULL:-0}" = 1 ] && touch "$WORK/resumed"
           : ;;          # git pull --ff-only
  status)  [ "\${FAKE_DIRTY:-0}" = 1 ] && printf ' M some/file\n'; : ;;
  rev-parse) printf '%s\n' "\${FAKE_TIP:-deadbeef}" ;;
  *) : ;;                                             # fetch → succeed silently
esac
exit 0
GITFAKE

# --- fake gh: pr_fields TSV per scenario --------------------------------------
cat > "$WORK/fakebin/gh" <<GHFAKE
#!/bin/bash
sub="\${1:-}"; action="\${2:-}"; num="\${3:-}"
[ "\$sub" = pr ] || exit 0
case "\$action" in
  view)
    case "\$*" in
      *"--json state,headRefOid"*)
        # 4th field = closedAt (issue #544) — the clock the closed gate compares
        # transcript activity against. Empty for a PR that never closed.
        case "\${GH_SCENARIO:-merged}" in
          merged)        printf 'MERGED\tdeadbeef\tissue-42\t-\t%s\n' "\${FAKE_MERGED_AT-}" ;;
          closed)        printf 'CLOSED\tsha-%s\tissue-42\t%s\n' "\$num" "\${FAKE_CLOSED_AT:-}" ;;
          open)          printf 'OPEN\tsha-%s\tissue-42\t\n' "\$num" ;;
          scratch)       printf 'MERGED\tcafe1234\tscratch-99\t-\t%s\n' "\${FAKE_MERGED_AT-}" ;;
          scratchclosed) printf 'CLOSED\tcafe1234\tscratch-99\t%s\n' "\${FAKE_CLOSED_AT:-}" ;;
          protected)     printf 'MERGED\tcafe1234\tmaster\t\n' ;;
        esac ;;
      *"--json title"*) printf 'Fake PR %s\t2026-01-01T00:00:00Z\tsha-%s\n' "\$num" "\$num" ;;
    esac ;;
esac
exit 0
GHFAKE

# --- fake tmux: window-id for display-message; log kill-window/run-shell -------
# FAKE_SELF_WIN is the window-id display-message reports as "ours" — @1 (≠ the
# worker window @7) drives the INLINE teardown; @7 forces the DETACHED self path.
# WIN_GONE=1 drops the worker window (already-torn-down scenario).
cat > "$WORK/fakebin/tmux" <<TMUXFAKE
#!/bin/bash
if [ "\${1:-}" = "-L" ]; then
  [ "\${2:-}" = testsess ] || exit 1
  shift 2
fi
case "\${1:-}" in
  list-panes)
    case "\$*" in *pane_pid*) printf '500\n'; exit 0 ;; esac
    # fleet_wt_window's cwd probe: window @9 sits in the scratch-99 worktree.
    [ "\${SCRATCH_WIN:-0}" = 1 ] && printf '@9 %s/wt-scratch-99\n' "$WORK"; : ;;
  list-windows)
    case "\$*" in
      *claude_state*)
        [ "\${SCRATCH_WIN:-0}" = 1 ] && printf '@9 %s\n' "\${SCRATCH_STATE:-done}"
        [ "\${WIN_GONE:-0}" = 1 ] || printf '@7 %s\n' "\${WIN_STATE_FAKE:-done}"
        : ;;
      *)              [ "\${WIN_GONE:-0}" = 1 ] || echo '@7 42'
                      [ "\${FAKE_DUPLICATE:-0}" = 1 ] && echo '@8 42'
                      : ;;   # window @7 → issue 42
    esac ;;
  display-message)
    case "\$*" in
      *reap_state_ts*|*claude_state_ts*) echo 1; exit 0 ;;
      *reap_seen*) echo \$(( \$(date -u +%s) - 2 )); exit 0 ;;
      *reap_due*) echo 1; exit 0 ;;
      *reap_key*)
        case "\${GH_SCENARIO:-merged}" in scratch) echo 'merged:42:cafe1234' ;; *) echo 'merged:42:deadbeef' ;; esac
        exit 0 ;;
    esac
    case "\$*" in *claude_state*)
      [ "\${FAKE_STATE_FAIL:-0}" = 1 ] && exit 1
      [ -f "$WORK/resumed" ] && { echo working; exit 0; }
      case "\$*" in *'@9'*) printf '%s\n' "\${SCRATCH_STATE:-done}" ;;
        *) printf '%s\n' "\${WIN_STATE_FAKE-done}" ;; esac
      exit 0 ;; esac
    case "\$*" in *window_id*) echo "\${FAKE_SELF_WIN:-@1}" ;; *session_name*) echo 'testsess' ;; *) echo '' ;; esac ;;
  kill-window)   printf 'kill-window %s\n' "\${!#}" >> "$ORDER_LOG" ;;
  run-shell)     printf 'run-shell\n' >> "$ORDER_LOG" ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/git" "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

# Deterministic process tree for the REAL shared liveness helper. No host ps or
# live tmux server participates in these destructive-path regression fixtures.
cat > "$WORK/fakebin/ps" <<'PSFAKE'
#!/bin/bash
[ "${FAKE_PS_FAIL:-0}" = 1 ] && exit 1
[ "${FAKE_PS_MISSING:-0}" = 1 ] && exit 0
case "$*" in
  *etime*) printf '500 1 02:00:00 zsh\n501 500 %s codex\n' "${FAKE_AGENT_AGE:-01:00:00}" ;;
  *) printf '500 zsh\n501 codex\n' ;;
esac
PSFAKE
chmod +x "$WORK/fakebin/ps"

# Freeze only the cleanup clock when requested, to test the exact boundary
# without sleeps. Timestamp parsing/formatting still uses the host BSD/GNU date.
REAL_DATE=$(command -v date)
cat > "$WORK/fakebin/date" <<DATEFAKE
#!/bin/bash
if [ "\$*" = '+%s' ] && [ -n "\${FAKE_NOW:-}" ]; then
  printf '%s\n' "\$FAKE_NOW"
else
  exec "$REAL_DATE" "\$@"
fi
DATEFAKE
chmod +x "$WORK/fakebin/date"

# --- portable clock helpers (macOS BSD date first, GNU second) ----------------
# GNU `date -r` means "reference FILE", so it fails on a bare epoch and falls
# through to the -d form; BSD `date -d` is a DST flag and fails on "@<epoch>".
stamp_of() { date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null; }
iso_ago()  { local e=$(( $(date +%s) - $1 ))
             date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }

# The closed gate reads the WORKER'S TRANSCRIPT, so the fixture needs a real file
# with a controlled mtime under a CLAUDE_PROJECTS_DIR inside $WORK (never the
# operator's own ~/.claude/projects — that would make the suite non-hermetic and
# its verdict depend on whose machine it runs on). The dir name is
# fleet_transcript_dir's encoding of the worktree path.
PROJ="$WORK/projects"
make_transcript() {  # $1 = seconds ago the session last spoke, or "none"
  rm -rf "$PROJ"; mkdir -p "$PROJ"
  [ "${1:-3600}" = none ] && return 0
  local enc dir
  enc=$(printf '%s' "$WORK/wt-issue-42" | LC_ALL=C tr -c 'A-Za-z0-9' '-')
  dir="$PROJ/$enc"; mkdir -p "$dir"
  printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' > "$dir/sess-1.jsonl"
  touch -t "$(stamp_of $(( $(date +%s) - $1 )))" "$dir/sess-1.jsonl" 2>/dev/null
}

# run fleet-cleanup against the fakes. $1=scenario; remaining args pass through.
run_clean() {
  local scenario="$1"; shift
  : > "$ORDER_LOG"; : > "$PULL_LOG"
  rm -f "$WORK/resumed"
  make_transcript "${FAKE_TX_AGE:-3600}"
  # A REAL worktree dir (issue #586): teardown no longer shells out to
  # `git worktree remove` — it RENAMES the tree into a sibling .fleet-trash/, so the
  # test needs actual bytes on disk to watch move, and a clean trash each run.
  rm -rf "$WORK/.fleet-trash" "$WORK/wt-issue-42"
  if [ "${WT_GONE:-0}" != 1 ]; then
    mkdir -p "$WORK/wt-issue-42"; echo payload > "$WORK/wt-issue-42/keep.txt"
  fi
  GH_SCENARIO="$scenario" FAKE_SELF_WIN="${FAKE_SELF_WIN:-@1}" \
  WT_GONE="${WT_GONE:-0}" WIN_GONE="${WIN_GONE:-0}" \
  WIN_STATE_FAKE="${WIN_STATE_FAKE-done}" \
  FAKE_CLOSED_AT="${FAKE_CLOSED_AT:-$(iso_ago 1800)}" \
  FAKE_MERGED_AT="${FAKE_MERGED_AT-$(iso_ago 1800)}" \
  CLAUDE_PROJECTS_DIR="$PROJ" \
  SCRATCH_WT="${SCRATCH_WT:-0}" SCRATCH_WIN="${SCRATCH_WIN:-0}" \
  SCRATCH_STATE="${SCRATCH_STATE:-done}" FAKE_DIRTY="${FAKE_DIRTY:-0}" \
  FAKE_TIP="${FAKE_TIP:-deadbeef}" \
  FLEET_CLEANUP_SCRATCH_HEADS="${FLEET_CLEANUP_SCRATCH_HEADS:-0}" \
  TMUX="${FAKE_TMUX:-}" TMUX_PANE="${FAKE_PANE:-}" PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/dash" \
  FLEET_CONF_DIR="$WORK/conf" FLEET_SESSION="testsess" \
  FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH="master" \
  FLEET_HISTORY_LEDGER="$LEDGER" \
  LAND_LEASE_DIR="$WORK/leases" LAND_POLL=0 LAND_QUEUE_TIMEOUT=2 \
    "$CLEAN" --pr 42 "$@" 2>"$WORK/err"
}

# --- 1. MERGED → cleaned + ledger-before-teardown + ordered teardown + base pull
# A transfer lease must protect even a clean MERGED worker, not just the
# existing CLOSED-unmerged gate. No teardown or GitHub mutation may occur.
mkdir -p "$WORK/conf/rotating" "$WORK/wt-issue-42"
TRANSFER_WT=$(cd "$WORK/wt-issue-42" && pwd -P)
TRANSFER_LEASE="$WORK/conf/rotating/$(printf '%s' "$TRANSFER_WT" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
printf '%s %s 900 transfer-test\n' "$$" "$(date +%s)" > "$TRANSFER_LEASE"
tok="$(run_clean merged)"; err="$(cat "$WORK/err")"
[ "$tok" = 'skip:live' ] || fail "transfer lease must protect a merged worker, got '$tok'" "$err"
[ ! -s "$ORDER_LOG" ] && [ -f "$WORK/wt-issue-42/keep.txt" ] || fail 'transfer lease allowed teardown' "$err"
ok 'MERGED worker with transfer lease → skip:live, no teardown'
rm "$TRANSFER_LEASE"

# Automatic cleanup waits for GitHub mergedAt, before ANY mutation. Old/missing
# closedAt must not become a substitute clock for a recent/missing mergedAt.
for merged_time in "$(iso_ago 60)" "$(iso_ago -3600)" '' '-' 'garbled' 'yesterday' '2026-02-30T00:00:00Z'; do
  : > "$LEDGER"
  tok="$(FAKE_MERGED_AT="$merged_time" run_clean merged --auto)"
  [ "$tok" = skip:grace ] || fail "automatic grace should retain mergedAt='$merged_time', got '$tok'" "$(cat "$WORK/err")"
  [ ! -s "$ORDER_LOG" ] && [ ! -s "$PULL_LOG" ] && [ ! -s "$LEDGER" ] \
    && [ -f "$WORK/wt-issue-42/keep.txt" ] || fail 'grace mutated the worktree/base/ledger'
done
ok 'automatic recent/future/missing/invalid mergedAt defers before mutations'
tok="$(FAKE_MERGED_AT="$(iso_ago 60)" run_clean merged --auto --dry-run)"
[ "$tok" = skip:grace ] || fail 'automatic dry-run must report the grace'
ok 'automatic dry-run observes merged grace'
tok="$(run_clean merged --auto)"
case "$tok" in cleaned:*) ;; *) fail "expired automatic grace should clean, got '$tok'" ;; esac
ok 'expired automatic grace proceeds through normal cleanup'
tok="$(FAKE_NOW=1767226199 FAKE_MERGED_AT=2026-01-01T00:00:00Z run_clean merged --auto --dry-run)"
[ "$tok" = skip:grace ] || fail '599 seconds must still defer'
tok="$(FAKE_NOW=1767226200 FAKE_MERGED_AT=2026-01-01T00:00:00Z run_clean merged --auto --dry-run)"
[ "$tok" = dry:would-clean-merged ] || fail "exactly 600 seconds must pass the grace, got $tok" "$(cat "$WORK/err")"
ok 'automatic grace boundary is exact (599/600 seconds)'
tok="$(WT_GONE=1 WIN_GONE=1 FAKE_MERGED_AT='' run_clean merged --auto)"
[ "$tok" = skip:nothing ] || fail 'already-reaped automatic cleanup must remain idempotent'
ok 'no debris needs no merge clock'

# A non-exported fleet overlay wins over defaults/environment. Invalid knobs
# fall back to 600; leading zeroes are decimal, not Bash octal arithmetic.
for grace in 3600 invalid -1 999999999999999999999999 31536001 00003600; do
  printf 'FLEET_CLEANUP_MERGED_GRACE=%s\n' "$grace" > "$WORK/conf/testsess.conf"
  tok="$(FAKE_MERGED_AT="$(iso_ago 60)" run_clean merged --auto)"
  [ "$tok" = skip:grace ] || fail "grace config '$grace' should retain recent merge, got '$tok'"
done
printf 'FLEET_CLEANUP_MERGED_GRACE=3600\n' > "$WORK/conf/testsess.conf"
tok="$(run_clean merged --auto)"
[ "$tok" = skip:grace ] || fail 'per-fleet non-exported grace was ignored'
printf 'FLEET_CLEANUP_MERGED_GRACE=0\n' > "$WORK/conf/testsess.conf"
tok="$(FAKE_MERGED_AT='' run_clean merged --auto)"
case "$tok" in cleaned:*) ;; *) fail "explicit zero must disable the delay, got '$tok'" ;; esac
tok="$(FAKE_MERGED_AT="$(iso_ago -3600)" run_clean merged --auto --dry-run)"
[ "$tok" = dry:would-clean-merged ] || fail 'zero grace ignores even a future merge clock after the notice'
rm "$WORK/conf/testsess.conf"
ok 'per-fleet grace, invalid fallback, decimal input and explicit zero'
tok="$(FAKE_MERGED_AT='' run_clean merged)"
case "$tok" in cleaned:*) ;; *) fail 'manual cleanup must not acquire the automatic delay' ;; esac
ok 'manual cleanup stays immediate without a merge clock'
tok="$(run_clean closed --auto)"
[ "$tok" = cleaned:closed ] || fail 'automatic CLOSED-unmerged cleanup must keep its separate policy'
ok 'automatic CLOSED-unmerged keeps its existing policy'

# A merged PR plus expired grace must still leave a live or unverified worker.
for active_state in working looping busy waiting ''; do
  : > "$LEDGER"
  tok="$(WIN_STATE_FAKE="$active_state" run_clean merged --auto)"
  [ "$tok" = skip:live ] || fail "automatic state '$active_state' should defer, got '$tok'"
  [ ! -s "$ORDER_LOG" ] && [ ! -s "$PULL_LOG" ] && [ ! -s "$LEDGER" ] \
    && [ -f "$WORK/wt-issue-42/keep.txt" ] || fail 'active worker was mutated'
done
ok 'automatic MERGED working/looping/busy/waiting/unset state is retained'
for scenario in young ps-failure missing-pid state-failure missing-window duplicate-window self-call; do
  : > "$LEDGER"
  case "$scenario" in
    young) tok="$(FAKE_AGENT_AGE=00:10 run_clean merged --auto)" ;;
    ps-failure) tok="$(FAKE_PS_FAIL=1 run_clean merged --auto)" ;;
    missing-pid) tok="$(FAKE_PS_MISSING=1 run_clean merged --auto)" ;;
    state-failure) tok="$(FAKE_STATE_FAIL=1 run_clean merged --auto)" ;;
    missing-window) tok="$(WIN_GONE=1 run_clean merged --auto)" ;;
    duplicate-window) tok="$(FAKE_DUPLICATE=1 run_clean merged --auto)" ;;
    self-call) tok="$(FAKE_TMUX=fake FAKE_PANE=%7 FAKE_SELF_WIN=@7 run_clean merged --auto)" ;;
  esac
  [ "$tok" = skip:live ] || fail "automatic $scenario should defer, got '$tok'" "$(cat "$WORK/err")"
  [ ! -s "$ORDER_LOG" ] && [ ! -s "$PULL_LOG" ] && [ ! -s "$LEDGER" ] \
    && [ -f "$WORK/wt-issue-42/keep.txt" ] || fail "automatic $scenario mutated the worker"
done
ok 'young agent, failed probes and missing window/pid all fail closed'
tok="$(WIN_STATE_FAKE=working run_clean merged --auto --dry-run)"
[ "$tok" = skip:live ] || fail 'dry-run must apply automatic liveness'
printf 'FLEET_REAP_MIN_AGE=7200\n' > "$WORK/conf/testsess.conf"
tok="$(run_clean merged --auto)"
[ "$tok" = skip:live ] || fail 'automatic process age must read non-exported fleet config'
printf 'FLEET_REAP_MIN_AGE=0\n' > "$WORK/conf/testsess.conf"
tok="$(FAKE_AGENT_AGE=00:10 run_clean merged --auto --dry-run)"
[ "$tok" = dry:would-clean-merged ] || fail 'age zero must disable just the age check'
tok="$(WIN_STATE_FAKE=working run_clean merged --auto)"
[ "$tok" = skip:live ] || fail 'age zero must never override active state'
rm "$WORK/conf/testsess.conf"
ok 'automatic dry-run, fleet process-age override and zero-age state protection'
tok="$(FAKE_RESUME_ON_PULL=1 run_clean merged --auto)"
[ "$tok" = skip:live ] || fail "worker resumed during pull should defer, got '$tok'"
[ -s "$PULL_LOG" ] && [ ! -s "$ORDER_LOG" ] && [ -f "$WORK/wt-issue-42/keep.txt" ] \
  || fail 'post-pull liveness recheck did not prevent teardown'
ok 'automatic post-pull recheck protects a resumed worker (earlier ledger may remain)'
tok="$(FAKE_SELF_WIN=@7 run_clean merged --auto)"
case "$tok" in cleaned:*) ;; *) fail 'daemon active-window lookup must not masquerade as self' ;; esac
grep -qx 'kill-window @7' "$ORDER_LOG" || fail 'automatic cleanup must stay synchronous'
grep -qx run-shell "$ORDER_LOG" && fail 'automatic cleanup must never queue unguarded teardown'
ok 'automatic daemon remains synchronous even when target is the active window'
tok="$(FAKE_TMUX=fake FAKE_PANE=%1 FAKE_SELF_WIN=@1 run_clean merged --auto)"
case "$tok" in cleaned:*) ;; *) fail 'automatic caller in another pane should use inherited socket' ;; esac
grep -qx 'kill-window @7' "$ORDER_LOG" || fail 'inherited-socket cleanup did not complete'
ok 'automatic caller outside target inherits socket (empty socket-argument array)'
tok="$(FAKE_DIRTY=1 run_clean merged --auto)"
[ "$tok" = skip:dirty ] || fail 'automatic merged issue must preserve post-merge uncommitted work'
[ ! -s "$ORDER_LOG" ] || fail 'dirty merged issue was disposed'
tok="$(FAKE_TIP=new-work run_clean merged --auto)"
[ "$tok" = skip:unmerged ] || fail 'automatic merged issue must preserve post-merge commits'
[ ! -s "$ORDER_LOG" ] || fail 'new commits after merge were disposed'
ok 'automatic merged issue requires clean worktree and exact merged head'

: > "$LEDGER"
tok="$(run_clean merged)"; err="$(cat "$WORK/err")"
case "$tok" in cleaned:*) ;; *) fail "1 expected cleaned:*, got '$tok'" "$err" ;; esac
# teardown ordering: kill-window BEFORE worktree-remove BEFORE branch-D
order="$(tr '\n' ' ' < "$ORDER_LOG")"
case "$order" in
  "kill-window @7 "*"worktree-prune "*"branch-D"*) ;;
  *) fail "1 teardown order wrong (want kill-window → worktree drop/prune → branch-D): [$order]" "$err" ;;
esac
# The worktree is MOVED aside, never deleted inline (issue #586): a synchronous
# delete of a 308k-file tree once held this teardown — and the whole daemon — for
# 67 minutes. Assert the bytes are intact in the trash, i.e. it really was a rename.
[ -e "$WORK/wt-issue-42" ] && fail "1 the worktree dir is still in place — no drop happened" "$err"
trashed="$(find "$WORK/.fleet-trash" -mindepth 1 -maxdepth 1 -name 'wt-issue-42.*' 2>/dev/null | head -1)"
[ -n "$trashed" ] || fail "1 the worktree was not renamed into .fleet-trash" "$err"
[ "$(cat "$trashed/keep.txt" 2>/dev/null)" = payload ] \
  || fail "1 trashed content missing — teardown deleted instead of renaming" "$err"
# ledger row recorded BEFORE removal (it captured the still-live worktree path)
[ -s "$LEDGER" ] || fail "1 no history ledger row was written" "$err"
grep -q 'wt-issue-42' "$LEDGER" || fail "1 ledger row missing the worktree path (recorded after removal?)" "$err"
# base fast-forward happened
[ -s "$PULL_LOG" ] || fail "1 merged cleanup must fast-forward the base (git pull --ff-only)" "$err"
ok "1 MERGED → cleaned + ledger-before-teardown + ordered teardown + base pull"

# ======= CLOSED-unmerged: the liveness gate, issue #544 ========================
# The default fixture is an ABANDONED session: the transcript went quiet an hour
# ago, the PR closed 30 minutes ago (so the last word predates the close), and the
# window is `done`. Each case below perturbs exactly one of those.

# --- 2. CLOSED-unmerged, session demonstrably gone → reaped + recorded ---------
: > "$LEDGER"
tok="$(run_clean closed)"; err="$(cat "$WORK/err")"
[ "$tok" = "cleaned:closed" ] || fail "2 expected cleaned:closed, got '$tok'" "$err"
[ -e "$WORK/wt-issue-42" ] && fail "2 closed-unmerged must reap the orphan worktree" "$err"
[ -n "$(find "$WORK/.fleet-trash" -mindepth 1 -maxdepth 1 -name 'wt-issue-42.*' 2>/dev/null)" ] \
  || fail "2 the orphan worktree was not dropped into .fleet-trash" "$err"
[ -s "$PULL_LOG" ] && fail "2 closed-unmerged must NOT fast-forward the base (nothing merged)" "$err"
# It IS recorded now (issue #544): a reaped closed-unmerged worker used to vanish
# from /fleet-history entirely — no transcript pointer, no sha, no way back.
[ -s "$LEDGER" ] || fail "2 closed-unmerged must record a closed-unlanded ledger row" "$err"
grep -q 'wt-issue-42' "$LEDGER" || fail "2 the closed row must carry the worktree path (recorded before teardown?)" "$err"
ok "2 CLOSED-unmerged + session gone → cleaned:closed, reaped, closed row recorded, no base pull"

# --- 2b. the #534 case: the session spoke AFTER the PR closed → never reaped ---
# A failed squash + a hand-deleted remote branch closes the PR while its worker is
# still resolving the conflict. No grace can cover that — the rule is "activity
# after closedAt", which has no timeout, so ⌃o restore works again too.
: > "$LEDGER"
tok="$(FAKE_TX_AGE=5 FAKE_CLOSED_AT="$(iso_ago 600)" run_clean closed)"; err="$(cat "$WORK/err")"
[ "$tok" = "skip:live" ] || fail "2b a session that spoke after closedAt must defer with skip:live, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "2b a live closed-unmerged session must not be torn down" "$err"
[ -d "$WORK/wt-issue-42" ] || fail "2b the live worktree must survive the deferral" "$err"
[ -s "$LEDGER" ] && fail "2b a deferred reap must not record the session as closed" "$err"
ok "2b CLOSED-unmerged, transcript moved after closedAt → skip:live (the #534 regression)"

# --- 2c. quiet, but not for long enough → grace -------------------------------
: > "$LEDGER"
tok="$(FAKE_TX_AGE=120 FAKE_CLOSED_AT="$(iso_ago 60)" run_clean closed)"; err="$(cat "$WORK/err")"
[ "$tok" = "skip:live" ] || fail "2c a window idle under the grace must defer with skip:live, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "2c a window inside the grace must not be torn down" "$err"
ok "2c CLOSED-unmerged, idle < FLEET_CLEANUP_CLOSED_GRACE → skip:live"

# --- 2d. the window says it is mid-turn → hands off, whatever the clock says ---
: > "$LEDGER"
tok="$(WIN_STATE_FAKE=working run_clean closed)"; err="$(cat "$WORK/err")"
[ "$tok" = "skip:live" ] || fail "2d a 'working' window must defer with skip:live, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "2d a working window must not be torn down" "$err"
ok "2d CLOSED-unmerged, window @claude_state=working → skip:live"

# --- 2e. a live window we cannot read → fail CLOSED, do not guess -------------
: > "$LEDGER"
tok="$(FAKE_TX_AGE=none run_clean closed)"; err="$(cat "$WORK/err")"
[ "$tok" = "skip:live" ] || fail "2e an unreadable live window must fail closed with skip:live, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "2e an unprovable window must not be torn down" "$err"
ok "2e CLOSED-unmerged, live window with no transcript → skip:live (fails closed)"

# --- 2f. dirty worktree → the SAME answer worktree-autoclean.sh gives ---------
# This is the byte-for-byte regression: `worktree remove --force` deleted the
# uncommitted conflict resolution. Both the verdict and the tree are asserted.
: > "$LEDGER"
tok="$(FAKE_DIRTY=1 run_clean closed)"; err="$(cat "$WORK/err")"
[ "$tok" = "skip:dirty" ] || fail "2f a dirty closed-unmerged worktree must refuse with skip:dirty, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "2f a dirty worktree must not be torn down" "$err"
[ "$(cat "$WORK/wt-issue-42/keep.txt" 2>/dev/null)" = payload ] \
  || fail "2f the dirty worktree's content must survive untouched" "$err"
ok "2f CLOSED-unmerged, dirty worktree → skip:dirty (never force-dropped)"

# --- 2g. no live window at all → nothing to protect, reap the orphan ----------
: > "$LEDGER"
tok="$(WIN_GONE=1 FAKE_TX_AGE=none run_clean closed)"; err="$(cat "$WORK/err")"
[ "$tok" = "cleaned:closed" ] || fail "2g a windowless closed orphan must be reaped, got '$tok'" "$err"
[ -e "$WORK/wt-issue-42" ] && fail "2g the windowless orphan worktree must be dropped" "$err"
ok "2g CLOSED-unmerged, no live window → cleaned:closed (nothing to protect)"

# --- 2g2. a live window whose worktree is already gone → reapable on `working` --
# A prior tick dropped the tree but its kill-window failed. There is no file work
# to lose and no transcript dir (it is keyed by the worktree path), so `working` is
# the whole gate — anything stricter would leak that window, and a `gh pr view` per
# tick, forever.
: > "$LEDGER"
tok="$(WT_GONE=1 FAKE_TX_AGE=none run_clean closed)"; err="$(cat "$WORK/err")"
[ "$tok" = "cleaned:closed" ] || fail "2g2 a worktree-less closed window must be reapable, got '$tok'" "$err"
grep -q 'kill-window @7' "$ORDER_LOG" || fail "2g2 the orphan window must be killed" "$err"
tok="$(WT_GONE=1 FAKE_TX_AGE=none WIN_STATE_FAKE=working run_clean closed)"; err="$(cat "$WORK/err")"
[ "$tok" = "skip:live" ] || fail "2g2 a worktree-less window that is 'working' must defer, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "2g2 a working worktree-less window must not be torn down" "$err"
ok "2g2 CLOSED-unmerged, worktree gone + live window → reaped unless 'working'"

# --- 2h. --dry-run over a LIVE one classifies honestly, not "would reap" ------
# Every gate check is a read, so it runs in --dry-run too; a dry-run that said
# `dry:would-reap-closed` over a live session would be reporting a lie.
: > "$LEDGER"
tok="$(FAKE_TX_AGE=5 FAKE_CLOSED_AT="$(iso_ago 600)" run_clean closed --dry-run)"; err="$(cat "$WORK/err")"
[ "$tok" = "skip:live" ] || fail "2h --dry-run over a live closed PR must report skip:live, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "2h --dry-run must not tear anything down" "$err"
tok="$(run_clean closed --dry-run)"; err="$(cat "$WORK/err")"
[ "$tok" = "dry:would-reap-closed" ] || fail "2h --dry-run over a gone session must report dry:would-reap-closed, got '$tok'" "$err"
ok "2h --dry-run runs the gate: skip:live when live, dry:would-reap-closed when gone"

# --- 3. OPEN → skip:not-final, nothing torn down, nothing recorded ------------
: > "$LEDGER"
tok="$(run_clean open)"; err="$(cat "$WORK/err")"
[ "$tok" = "skip:not-final" ] || fail "3 expected skip:not-final, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "3 an OPEN (not-final) PR must not be torn down" "$err"
[ -s "$LEDGER" ]    && fail "3 an OPEN PR must not record a ledger row" "$err"
ok "3 OPEN → skip:not-final, no teardown, no ledger"

# --- 4. already-torn-down (MERGED, no worktree/window) → skip:nothing, idempotent
: > "$LEDGER"
tok="$(WT_GONE=1 WIN_GONE=1 run_clean merged)"; err="$(cat "$WORK/err")"
[ "$tok" = "skip:nothing" ] || fail "4 expected skip:nothing on an already-cleaned PR, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "4 already-cleaned PR must not tear anything down" "$err"
[ -s "$LEDGER" ]    && fail "4 already-cleaned PR must not append a duplicate ledger row" "$err"
ok "4 already-torn-down → skip:nothing (idempotent, no dup ledger, no teardown)"

# --- 5. self-cwd cleanup → teardown DETACHES into the tmux server (worker-safe) -
: > "$LEDGER"
tok="$(FAKE_SELF_WIN=@7 run_clean merged)"; err="$(cat "$WORK/err")"
case "$tok" in cleaned:*) ;; *) fail "5 expected cleaned:* on the self-cwd path, got '$tok'" "$err" ;; esac
grep -qx run-shell "$ORDER_LOG" || fail "5 self-cwd teardown must detach via tmux run-shell" "$err"
[ -d "$WORK/wt-issue-42" ] || fail "5 self-cwd teardown must NOT drop the worktree inline (it detaches)" "$err"
case "$err" in
  *fleet-worktree-drop.sh*) ;;
  *) fail "5 the detached command must drive the drop shim (run-shell runs under /bin/sh)" "$err" ;;
esac
ok "5 self-cwd cleanup → teardown detaches into the tmux server"

# --- 6. --dry-run → dry:*, no teardown, no mutation ---------------------------
: > "$LEDGER"
tok="$(run_clean merged --dry-run)"; err="$(cat "$WORK/err")"
[ "$tok" = "dry:would-clean-merged" ] || fail "6 expected dry:would-clean-merged, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "6 --dry-run must not tear anything down" "$err"
[ -s "$LEDGER" ]    && fail "6 --dry-run must not record a ledger row" "$err"
ok "6 --dry-run classifies without mutating"

# ======= non-issue (scratch) heads, issue #589 ==================================
# A `scratch-<N>` worktree + a window sitting in it; the PR merged at cafe1234.
scratch() { # $1 = gh scenario; remaining args pass through to run_clean
  # Real bytes on disk so the drop (issue #586) can be asserted as a RENAME.
  mkdir -p "$WORK/wt-scratch-99" && printf 'payload\n' > "$WORK/wt-scratch-99/keep.txt"
  rm -rf "$WORK/.fleet-trash"
  SCRATCH_WT=1 SCRATCH_WIN="${SCRATCH_WIN:-1}" \
  SCRATCH_STATE="${SCRATCH_STATE:-done}" FAKE_DIRTY="${FAKE_DIRTY:-0}" \
  FAKE_TIP="${FAKE_TIP:-cafe1234}" \
  FLEET_CLEANUP_SCRATCH_HEADS="${FLEET_CLEANUP_SCRATCH_HEADS:-1}" \
    run_clean "$@"
}

# --- 7. knob OFF (the default) → the historic behavior, byte for byte ----------
: > "$LEDGER"
tok="$(FLEET_CLEANUP_SCRATCH_HEADS=0 scratch scratch)"; err="$(cat "$WORK/err")"
[ "$tok" = "skip:nothing" ] || fail "7 knob off must leave a non-issue head alone, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "7 knob off must tear NOTHING down for a non-issue head" "$err"
[ -s "$LEDGER" ]    && fail "7 knob off must not record a ledger row" "$err"
ok "7 non-issue head, knob OFF → skip:nothing (default behavior unchanged)"

# --- 8. knob ON + clean + tip==merged head + window done → reaped --------------
: > "$LEDGER"
tok="$(FAKE_MERGED_AT="$(iso_ago 60)" scratch scratch --auto)"
[ "$tok" = skip:grace ] || fail 'automatic scratch cleanup needs merged grace too'
[ ! -s "$ORDER_LOG" ] && [ ! -s "$PULL_LOG" ] && [ ! -s "$LEDGER" ] \
  && [ -f "$WORK/wt-scratch-99/keep.txt" ] || fail 'scratch grace allowed mutation'
ok 'automatic opted-in scratch head also waits for grace'
: > "$LEDGER"
tok="$(FAKE_AGENT_AGE=00:10 scratch scratch --auto)"
[ "$tok" = skip:live ] || fail 'automatic scratch head must pass process-age gate'
[ ! -s "$ORDER_LOG" ] && [ ! -s "$PULL_LOG" ] && [ ! -s "$LEDGER" ] || fail 'young scratch agent was mutated'
ok 'automatic scratch head also passes shared process liveness'
: > "$LEDGER"
tok="$(scratch scratch)"; err="$(cat "$WORK/err")"
case "$tok" in cleaned:*) ;; *) fail "8 expected cleaned:* for an armed scratch head, got '$tok'" "$err" ;; esac
order="$(tr '\n' ' ' < "$ORDER_LOG")"
case "$order" in
  "kill-window @9 "*"worktree-prune "*"branch-D scratch-99"*) ;;
  *) fail "8 teardown must kill @9 then drop the worktree then branch -D scratch-99: [$order]" "$err" ;;
esac
# Dropped, not deleted (issue #586) — the same rename-into-.fleet-trash the
# issue-<N> path takes, so a huge scratch worktree cannot hold the daemon either.
[ -e "$WORK/wt-scratch-99" ] && fail "8 the scratch worktree dir is still in place — no drop happened" "$err"
trashed="$(find "$WORK/.fleet-trash" -mindepth 1 -maxdepth 1 -name 'wt-scratch-99.*' 2>/dev/null | head -1)"
[ -n "$trashed" ] || fail "8 the scratch worktree was not renamed into .fleet-trash" "$err"
[ "$(cat "$trashed/keep.txt" 2>/dev/null)" = payload ] \
  || fail "8 trashed content missing — teardown deleted instead of renaming" "$err"
grep -q 'wt-scratch-99' "$LEDGER" || fail "8 the reaped scratch session must land in the ledger" "$err"
[ -s "$PULL_LOG" ] || fail "8 a merged scratch-head cleanup must fast-forward the base" "$err"
ok "8 non-issue head, knob ON + gate green → cleaned + teardown + ledger + base pull"

# --- 9. window is working → the operator's own workbench, hands off ------------
: > "$LEDGER"
tok="$(SCRATCH_STATE=working scratch scratch)"; err="$(cat "$WORK/err")"
[ "$tok" = "skip:busy" ] || fail "9 a working window must refuse with skip:busy, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "9 a working window must not be torn down" "$err"
ok "9 non-issue head, window working → skip:busy (no teardown)"

# --- 10. dirty worktree → never silently delete work --------------------------
tok="$(FAKE_DIRTY=1 scratch scratch)"; err="$(cat "$WORK/err")"
[ "$tok" = "skip:dirty" ] || fail "10 a dirty worktree must refuse with skip:dirty, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "10 a dirty worktree must not be torn down" "$err"
ok "10 non-issue head, dirty worktree → skip:dirty (no teardown)"

# --- 11. local commits past the merged head → never merged, keep them ---------
tok="$(FAKE_TIP=beef9999 scratch scratch)"; err="$(cat "$WORK/err")"
[ "$tok" = "skip:unmerged" ] || fail "11 a tip past the merge must refuse with skip:unmerged, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "11 unmerged commits must not be torn down" "$err"
ok "11 non-issue head, commits past the merge → skip:unmerged (no teardown)"

# --- 12. CLOSED-unmerged non-issue head → never in scope, even armed ----------
tok="$(scratch scratchclosed)"; err="$(cat "$WORK/err")"
[ "$tok" = "skip:nothing" ] || fail "12 a CLOSED non-issue head must stay out of scope, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "12 a CLOSED non-issue head must not be torn down" "$err"
ok "12 non-issue head, CLOSED-unmerged → skip:nothing (opt-in is MERGED-only)"

# --- 12b. no live window in the worktree → fail CLOSED, not "nobody home" -----
tok="$(SCRATCH_WIN=0 scratch scratch)"
err="$(cat "$WORK/err")"
[ "$tok" = "skip:nothing" ] || fail "12b a worktree with no live window must fail closed, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "12b a worktree with no live window must not be torn down" "$err"
ok "12b non-issue head, no window in the worktree → skip:nothing (fails closed)"

# --- 13. a protected head branch is never reapable ---------------------------
tok="$(scratch protected)"; err="$(cat "$WORK/err")"
[ "$tok" = "skip:protected" ] || fail "13 a protected head must refuse with skip:protected, got '$tok'" "$err"
[ -s "$ORDER_LOG" ] && fail "13 a protected branch must not be torn down" "$err"
ok "13 non-issue head on a protected branch → skip:protected (no teardown)"

printf '\nselftest OK: %s assertions passed (no-merge janitor bin/fleet-cleanup.sh)\n' "$pass"
exit 0
