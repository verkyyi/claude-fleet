#!/bin/bash
# fleet-collect-git-budget-selftest.sh — the collector's git phase: no `git status`,
# a wall-clock budget, and round-robin fairness (issue #552).
#
# Background (#552): the git phase ran one un-timeboxed `git status --porcelain`
# per live worktree. On a 24haowan-monorepo worktree that single call was measured
# at 4m42s, and with ~15 such worktrees live the phase alone took minutes — which
# pushed the whole tick past its own 60s StartInterval. launchd does not overlap a
# StartInterval job, so the collector's real cadence degraded to "one tick's
# duration" (measured: 5.3 min between runs) and every cache behind git went
# stale. This pins the fix:
#
#   1. NO-STATUS   — the phase never runs `git status` again. The dirty column it
#                    fed was read by nothing, so it was pure cost. The cache line
#                    keeps its shape: "branch<TAB>", field 2 empty.
#   2. DECORATION  — ahead/behind still decorate the branch (b+ahead-behind), now
#                    parsed without the two awk forks per worktree.
#   3. BUDGET      — a worktree that WEDGES cannot hang the tick: the phase is
#                    killed at FLEET_COLLECT_GIT_BUDGET, the tick runs on to
#                    completion (phase=done), and stderr says so.
#   4. ROUND-ROBIN — global/collect.git.cursor is stamped with a worktree BEFORE
#                    its git work, so the NEXT tick starts after it. A permanently
#                    wedged worktree is retried once per rotation instead of
#                    eating every tick's budget — the ones behind it still refresh.
#   5. SLOW-LOG    — a worktree slower than FLEET_COLLECT_GIT_SLOW is named on
#                    stderr (the heartbeat only carries the phase total).
#
# Drives the REAL collector against a FAKE git / gh / tmux / ccquota (no network,
# no tmux server, no repos). HOME is the scratch dir so the usage scan never
# touches real transcripts. Needs python3 (collector hard dep) — SKIPs if absent.
# Exit 0 = pass, non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
for f in tmux-dash-collect.sh fleet-quotawatch.sh fleet-account.sh fleet-lib.sh usage-lib.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/collect-git-budget-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/accounts" "$WORK/conf/fleets/sessA" "$WORK/.claude-dash/global"
for f in tmux-dash-collect.sh fleet-quotawatch.sh fleet-account.sh fleet-lib.sh usage-lib.sh; do cp "$BIN/$f" "$WORK/bin/"; done
chmod +x "$WORK/bin/"*.sh
printf 'tok-a\n' > "$WORK/accounts/a"
printf 'FLEET_REPO="acme/widgets"\n' > "$WORK/conf/fleets/sessA/conf"
C="$WORK/.claude-dash"; G="$C/global"

# Three "live worktrees". sort -u in the collector orders them wt1 < wt2 < wt3, so
# the rotation below is deterministic.
WT1="$WORK/wt1"; WT2="$WORK/wt2"; WT3="$WORK/wt3"
printf '%s\n%s\n%s\n' "$WT3" "$WT1" "$WT2" > "$WORK/panepaths"   # unsorted on purpose

# fake tmux — answers the pane-path enumeration the git/ctx phases do; everything
# else is a silent exit 0 (no sessmap/escalation work in this test).
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
label=""
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then label="$2"; shift 2; fi
case "${1:-}" in
  has-session)   exit 0 ;;
  list-sessions) [ -n "$label" ] && printf '%s\n' "$label"; exit 0 ;;
  list-windows)
    for a in "$@"; do
      [ "$a" = '#{pane_current_path}' ] || continue
      case "${FAKE_TMUX_EMPTY_SESS:-}" in all|"$label") exit 0 ;; esac
      if [ "$label" = "${FAKE_TMUX_FAIL_SESS:-}" ]; then
        cat "$FAKE_PANEPATHS"; exit 1   # partial output is not a complete view
      fi
      if [ "$label" = sessB ]; then cat "$FAKE_OTHER_PATHS"; else cat "$FAKE_PANEPATHS"; fi
      exit 0
    done
    exit 0 ;;
  *) exit 0 ;;
esac
FAKE

# fake git — logs "<path><TAB><argv>" per call so the test can assert WHICH
# subcommands ran and in WHAT order. Optional per-path hang/slow, keyed by suffix.
# ⚠️ The slow sleep fires on EVERY call, and the collector makes THREE per worktree
# (rev-parse --git-dir, rev-parse --abbrev-ref, rev-list), so a worktree marked slow
# costs 3 × FAKE_GIT_SLOW_SECS, not FAKE_GIT_SLOW_SECS. Section 5 budgets for that.
cat > "$WORK/fakepath/git" <<'FAKE'
#!/bin/bash
path=''
if [ "${1:-}" = "-C" ]; then path="$2"; shift 2; fi
printf '%s\t%s\n' "$path" "$*" >> "$FAKE_GIT_LOG"
case "$path" in *"${FAKE_GIT_HANG:-__nomatch__}") sleep 60 ;; esac
case "$path" in *"${FAKE_GIT_SLOW:-__nomatch__}") sleep "${FAKE_GIT_SLOW_SECS:-2}" ;; esac
case "${1:-} ${2:-}" in
  'rev-parse --git-dir')    printf '.git\n';   exit 0 ;;
  'rev-parse --abbrev-ref') printf 'b-%s\n' "${path##*/}"; exit 0 ;;
  'rev-list --left-right')  printf '1\t2\n';   exit 0 ;;   # behind=1 ahead=2
esac
exit 0
FAKE

cat > "$WORK/fakepath/gh" <<'FAKE'
#!/bin/bash
exit 0
FAKE
cat > "$WORK/fakepath/ccquota" <<'FAKE'
#!/bin/bash
# verdict: go|hold|unknown only (cmd/ccquota/budget.go) — never "ok" (issue #668).
printf '{"verdict":"go","accounts":[{"account_uuid":"u-a","label":"a","headroom_pct":90,"five_hour":{"utilization":10,"resets_at":"2026-09-12T05:00:00Z"},"seven_day":{"utilization":5,"resets_at":"2026-09-16T05:00:00Z"}}]}'
FAKE
chmod +x "$WORK/fakepath/"*

GIT_LOG="$WORK/git.log"
export FAKE_GIT_HANG='' FAKE_GIT_SLOW='' FAKE_GIT_SLOW_SECS=2
run_collector() {
  : > "$GIT_LOG"
  PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 GH_TTL=999999 \
  FLEET_REPO="" FLEET_REPOS="" FLEET_NOTIFY_CMD="" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_ACCOUNTS_DIR="$WORK/accounts" CCQUOTA_HUB_URL="http://hub.test:8787" FLEET_ACCOUNT_QUOTA_TTL=999999 \
  FAKE_PANEPATHS="$WORK/panepaths" FAKE_GIT_LOG="$GIT_LOG" \
  FAKE_OTHER_PATHS="$WORK/otherpaths" FAKE_TMUX_FAIL_SESS="${FAKE_TMUX_FAIL_SESS:-}" \
  FAKE_TMUX_EMPTY_SESS="${FAKE_TMUX_EMPTY_SESS:-}" \
  FAKE_GIT_HANG="${FAKE_GIT_HANG:-}" FAKE_GIT_SLOW="${FAKE_GIT_SLOW:-}" FAKE_GIT_SLOW_SECS="$FAKE_GIT_SLOW_SECS" \
  FLEET_COLLECT_GIT_BUDGET="${BUDGET:-30}" FLEET_COLLECT_GIT_SLOW="${SLOW:-10}" \
    bash "$WORK/bin/tmux-dash-collect.sh" >"$WORK/stdout" 2>"$WORK/stderr"
}
fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         printf -- '--- stderr ---\n' >&2; cat "$WORK/stderr" >&2 2>/dev/null
         printf -- '--- git.log ---\n' >&2; cat "$GIT_LOG" >&2 2>/dev/null
         printf -- '--- cursor ---\n%s\n' "$(cat "$G/collect.git.cursor" 2>/dev/null)" >&2
         exit 1; }
ok()    { printf '  ok — %s\n' "$1"; }
# cache_key — MUST stay byte-identical to cache_key() in tmux-dash-collect.sh
gk()    { local k=${1//_/_u}; k=${k//\//_s}; k=${k// /_w}; printf '%s' "$k"; }
cache() { cat "$G/git_$(gk "$1")" 2>/dev/null; }
hbget() { sed -n "s/^$1=//p" "$G/collect.heartbeat" | head -1; }
cursor(){ cat "$G/collect.git.cursor" 2>/dev/null; }
# the worktree paths the fake git was called with, in order, deduped consecutively
git_order() { cut -f1 "$GIT_LOG" | awk 'NF && $0!=prev{print; prev=$0}'; }

# 1. NO-STATUS + DECORATION + cache shape ----------------------------------------
run_collector || fail "1: a full tick must exit 0"
grep -q 'status' "$GIT_LOG" && fail "1: the git phase must NEVER run \`git status\` (that was the 4m42s call)"
ok "no \`git status\` anywhere in the tick"
exp=$(printf 'b-wt1+2-1\t')
[ "$(cache "$WT1")" = "$exp" ] || fail "1: git_<key> must be 'branch+ahead-behind<TAB>' with an EMPTY field 2, got [$(cache "$WT1")]"
[ "$(cache "$WT2")" = "$(printf 'b-wt2+2-1\t')" ] || fail "1: wt2 cache wrong: [$(cache "$WT2")]"
[ "$(cache "$WT3")" = "$(printf 'b-wt3+2-1\t')" ] || fail "1: wt3 cache wrong: [$(cache "$WT3")]"
ok "every live worktree cached as branch+ahead-behind<TAB> (field 2 empty)"
case "$(hbget phases)" in *git=*) : ;; *) fail "1: phases= must name git (got: $(hbget phases))" ;; esac
[ "$(hbget phase)" = "done" ] || fail "1: the tick must reach phase=done"
[ "$(cursor)" = "$WT3" ]    || fail "1: the cursor must name the LAST worktree claimed (wt3), got [$(cursor)]"
ok "heartbeat carries git=, tick completes, cursor parked on the last worktree"

# 2. ROUND-ROBIN — the next tick starts AFTER the cursor -------------------------
printf '%s' "$WT1" > "$G/collect.git.cursor"
run_collector || fail "2: a full tick must exit 0"
first=$(git_order | head -1)
[ "$first" = "$WT2" ] || fail "2: with the cursor on wt1 the scan must RESUME at wt2, started at [$first]"
[ "$(git_order | tr '\n' ' ')" = "$WT2 $WT3 $WT1 " ] || fail "2: rotation order wrong: [$(git_order | tr '\n' ' ')]"
ok "the scan resumes after the cursor and wraps (wt2 → wt3 → wt1)"

# 3. BUDGET — a wedged worktree cannot hang the tick -----------------------------
rm -f "$G"/git_*; printf '%s' "$WT3" > "$G/collect.git.cursor"   # ⇒ this tick starts at wt1
FAKE_GIT_HANG=/wt1 BUDGET=2 run_collector || fail "3: the tick must still exit 0 with a wedged worktree"
grep -q 'hit the 2s budget' "$WORK/stderr" || fail "3: stderr must name the blown FLEET_COLLECT_GIT_BUDGET"
[ "$(hbget phase)" = "done" ] || fail "3: a blown git budget must NOT abort the tick (phase=$(hbget phase))"
[ "$(cursor)" = "$WT1" ]    || fail "3: the cursor must name the WEDGED worktree it claimed, got [$(cursor)]"
[ -z "$(cache "$WT2")" ]    || fail "3: worktrees behind the wedge must not have been reached this tick"
ok "a wedged worktree is killed at the budget; the tick runs on to phase=done"

# 4. ROUND-ROBIN under a permanent wedge — the rest still refresh ----------------
FAKE_GIT_HANG=/wt1 BUDGET=2 run_collector || fail "4: the follow-up tick must exit 0"
[ "$(cache "$WT2")" = "$(printf 'b-wt2+2-1\t')" ] || fail "4: wt2 must refresh on the tick AFTER the wedge (round-robin), got [$(cache "$WT2")]"
[ "$(cache "$WT3")" = "$(printf 'b-wt3+2-1\t')" ] || fail "4: wt3 must refresh on the tick AFTER the wedge, got [$(cache "$WT3")]"
[ -z "$(cache "$WT1")" ]                          || fail "4: the wedged worktree itself must stay uncached"
ok "a permanently wedged worktree is retried once per rotation — it never starves the others"

# 5. SLOW-LOG — a slow worktree is named on stderr -------------------------------
# The window is deliberately WIDE (issue #693). What this section tests is whether
# slow and fast are told apart and whether the slow one is named — not how fast a
# shared CI runner forks a shell. Two things make a narrow window flaky:
#
#   a. the collector times each worktree with bash `SECONDS` (integer, no `date`
#      fork), so every measurement carries a ±1s quantization artifact: a 20ms
#      worktree reads as 1s whenever its work straddles a second boundary. With the
#      old SLOW=1 the fast assertion therefore meant "must measure EXACTLY 0" — zero
#      margin by construction, and it went red on CI (run 34969471087, shard 1)
#      while the same commit passed in a sibling run.
#   b. a no-sleep path on a noisy shared VM is fast but not BOUNDED.
#
# So: slow = 3 × 3s = 9s (see the fake git's ×3 note above), threshold 5s. The fast
# worktrees get ~4s of real headroom over the artifact, the slow one clears the
# threshold by 4s, and neither side is pressed against runner jitter.
FAKE_GIT_SLOW=/wt2 FAKE_GIT_SLOW_SECS=3 SLOW=5 BUDGET=30 run_collector || fail "5: the tick must exit 0"
grep -q "git took .*s on $WT2" "$WORK/stderr" || fail "5: a worktree slower than FLEET_COLLECT_GIT_SLOW must be named on stderr"
grep -q "git took .*s on $WT3" "$WORK/stderr" && fail "5: a FAST worktree must not be logged as slow"
ok "a worktree over FLEET_COLLECT_GIT_SLOW is named on stderr; fast ones are not"

# 6. CACHE SWEEP — complete cross-fleet inventory, distinct escaped path keys ---
WT4="$WORK/other space_under_score"
DEAD="$WORK/other/space_under_score"
mkdir -p "$WORK/conf/fleets/sessB" "$DEAD"
printf 'FLEET_REPO="acme/other"\n' > "$WORK/conf/fleets/sessB/conf"
printf '%s\n' "$WT4" > "$WORK/otherpaths"
seed_dead() {
  printf 'stale-git' > "$G/git_$(gk "$DEAD")"
  printf 'stale-ctx' > "$G/ctx_$(gk "$DEAD")"
}
dead_kept() { [ -f "$G/git_$(gk "$DEAD")" ] && [ -f "$G/ctx_$(gk "$DEAD")" ]; }
dead_gone() { [ ! -e "$G/git_$(gk "$DEAD")" ] && [ ! -e "$G/ctx_$(gk "$DEAD")" ]; }
for wt in "$WT1" "$WT2" "$WT3" "$WT4"; do printf 'live-ctx' > "$G/ctx_$(gk "$wt")"; done
printf 'native-ctx' > "$G/ctx_codex_sessB_1_2_session"
printf 'unrelated' > "$G/git_unrelated"
printf 'outside' > "$WORK/outside"
ln -s "$WORK/outside" "$G/ctx_$(gk "$WORK/symlink")"
mkdir "$G/git_$(gk "$WORK/directory")"
printf 'pending' > "$G/git_$(gk "$WT4").123"
seed_dead
run_collector || fail '6: sweep tick must succeed'
dead_gone || fail '6: inactive worktree caches survived a complete inventory'
for wt in "$WT1" "$WT2" "$WT3" "$WT4"; do
  [ "$(cat "$G/ctx_$(gk "$wt")")" = live-ctx ] || fail '6: live context cache was evicted'
  [ -s "$G/git_$(gk "$wt")" ] || fail '6: live git cache was lost'
done
[ "$(cat "$G/ctx_codex_sessB_1_2_session")" = native-ctx ] || fail '6: swept native session cache'
[ "$(cat "$G/git_unrelated")" = unrelated ] || fail '6: swept an unrelated key'
[ -L "$G/ctx_$(gk "$WORK/symlink")" ] && [ "$(cat "$WORK/outside")" = outside ] || fail '6: followed or removed a symlink'
[ -d "$G/git_$(gk "$WORK/directory")" ] || fail '6: removed a directory'
[ "$(cat "$G/git_$(gk "$WT4").123")" = pending ] || fail '6: removed a live atomic-write temporary'
ok 'complete cross-fleet sweep removes stale path caches and preserves live/other namespaces'

# An earlier socket fails, then a later socket succeeds: the final exit status
# alone would authorize an unsafe sweep. Also cover a successful but empty view.
seed_dead
for mode in failed empty all_empty malformed; do
  case "$mode" in
    failed) FAKE_TMUX_FAIL_SESS=sessA run_collector ;;
    empty) FAKE_TMUX_EMPTY_SESS=sessA run_collector ;;
    all_empty) FAKE_TMUX_EMPTY_SESS=all run_collector ;;
    malformed)
      printf 'not-an-absolute-path\n' >> "$WORK/panepaths"
      run_collector
      printf '%s\n%s\n%s\n' "$WT3" "$WT1" "$WT2" > "$WORK/panepaths"
      ;;
  esac
  dead_kept || fail "7: $mode inventory pruned caches"
  [ "$(cat "$G/ctx_$(gk "$WT1")")" = live-ctx ] || fail "7: $mode inventory lost the missing fleet's cache"
done
ok 'failed, partial, empty and malformed inventories preserve caches'

# Pruning must use the full inventory even when the very first git call wedges.
for wt in "$WT1" "$WT2" "$WT3" "$WT4"; do printf 'prior-branch\t' > "$G/git_$(gk "$wt")"; done
printf '%s' "$WT4" > "$G/collect.git.cursor"   # sorted WT4 precedes wt1
FAKE_GIT_HANG=/wt1 BUDGET=5 run_collector || fail '8: a truncated git phase must still finish the tick'
[ "$(cursor)" = "$WT1" ] || fail '8: expected the first git worktree to wedge'
dead_gone || fail '8: sweep must happen before budgeted git work'
for wt in "$WT1" "$WT2" "$WT3" "$WT4"; do
  [ "$(cache "$wt")" = $'prior-branch\t' ] || fail '8: evicted an unvisited live git cache'
  [ "$(cat "$G/ctx_$(gk "$wt")")" = live-ctx ] || fail '8: evicted an unvisited live context cache'
done
ok 'a budget-truncated scan retains every live worktree, including those never visited'

printf 'selftest PASS: collect git phase — budget · round-robin · cache sweep (#552/#647)\n'
