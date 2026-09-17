#!/bin/bash
# #651: a timed-out GitHub repo must not monopolize every issues phase.
# Real collector/timebox, fake gh/tmux/git; all files stay in this sandbox.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null || { echo 'collect-issues: python3 absent — SKIP'; exit 0; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/collect-issues-selftest.XXXXXX") || exit 2
HANGMARK="collect-issues-hang-$$"
cleanup() { pkill -9 -f "$HANGMARK" 2>/dev/null || :; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/conf" "$WORK/home"
for f in tmux-dash-collect.sh fleet-lib.sh usage-lib.sh; do cp "$BIN/$f" "$WORK/bin/"; done
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/fleet-restore.sh"
printf '#!/bin/sh\nexit 0\n' > "$WORK/fakepath/tmux"
printf '#!/bin/sh\nexit 1\n' > "$WORK/fakepath/git"
cat > "$WORK/fakepath/gh" <<'FAKE'
#!/bin/bash
mode="$1"; name=''
while [ "$#" -gt 0 ]; do
  case "$1" in --repo) shift; name=${1##*/} ;; name=*) name=${1#name=} ;; esac
  shift
done
printf '%s %s\n' "$mode" "$name" >> "$TEST_GH_LOG"
if [ "$name:$mode" = "${TEST_HANG:-}" ]; then
  # A bounded sleeper, with a unique argv marker to assert tree cleanup.
  exec -a "$TEST_HANGMARK" sleep 30
fi
case "$mode" in
  issue) printf 'bug\tMilestone\t#1\t·\tFresh %s\n' "$name" ;;
  api) printf '2\t1\n' ;;
esac
FAKE
chmod +x "$WORK/fakepath/"*
G="$WORK/.claude-dash/global"; C="$WORK/.claude-dash/fleets"
mkdir -p "$G"
for name in a b c; do
  mkdir -p "$C/acme-$name"
  printf 'old %s\n' "$name" > "$C/acme-$name/issues"
  printf 'old parents\n' > "$C/acme-$name/parents"
done
LOG="$WORK/gh.log"
run() {
  : > "$LOG"
  env PATH="$WORK/fakepath:$PATH" HOME="$WORK/home" TMPDIR="$WORK" \
    FLEET_CONF_DIR="$WORK/conf" FLEET_REPO='' FLEET_REPOS="${REPOS-acme/a acme/b acme/c}" \
    FLEET_NOTIFY_CMD='' FLEET_COLLECT_QUOTAWATCH=never \
    FLEET_COLLECT_QUOTAWATCH_BUDGET=0 FLEET_COLLECT_SOCKETS_BUDGET=0 \
    FLEET_COLLECT_SESSMAP_BUDGET=0 FLEET_COLLECT_GIT_BUDGET=0 \
    FLEET_COLLECT_CTX_BUDGET=0 FLEET_COLLECT_USAGE_BUDGET=0 \
    FLEET_COLLECT_SCRAPE_BUDGET=0 FLEET_COLLECT_BANNER_BUDGET=0 \
    FLEET_COLLECT_ESCALATE_BUDGET=0 FLEET_COLLECT_SNAPSHOT_BUDGET=0 \
    FLEET_COLLECT_ISSUES_BUDGET="${BUDGET:-5}" GH_TTL="${TTL:-0}" \
    TEST_GH_LOG="$LOG" TEST_HANG="${HANG:-}" TEST_HANGMARK="$HANGMARK" \
    bash "$WORK/bin/tmux-dash-collect.sh" "$@" > "$WORK/out" 2> "$WORK/err"
}
fail() { echo "collect-issues FAIL: $1" >&2; cat "$LOG" "$WORK/err" >&2; exit 1; }
eq() { [ "$2" = "$3" ] || fail "$1: expected [$2], got [$3]"; }
cursor() { cat "$G/collect.issues.cursor" 2>/dev/null || :; }
order() { sed -n 's/^issue //p' "$LOG" | tr '\n' ' '; }

HANG=a:issue run || fail 'a timed-out phase must let the collector finish'
eq 'first attempt' 'a ' "$(order)"
eq 'timeout preserves last good cache' 'old a' "$(cat "$C/acme-a/issues")"
eq 'the timed-out repo is durably claimed before fetch' acme/a "$(cursor)"
grep -q 'phase issues hit' "$WORK/err" || fail 'missing budget diagnostic'
grep -q 'next tick resumes after acme/a' "$WORK/err" || fail 'missing repo diagnostic'
pgrep -f "$HANGMARK" >/dev/null && fail 'timed-out gh survived the phase'

HANG=a:issue run || fail 'second tick failed'
eq 'later repos run before the recurring wedge' 'b c a ' "$(order)"
eq 'repo b refreshed' $'Milestone\t#1\t·\tFresh b' "$(cat "$C/acme-b/issues")"
eq 'repo c refreshed' $'Milestone\t#1\t·\tFresh c' "$(cat "$C/acme-c/issues")"
eq 'wedged repo still preserves cache' 'old a' "$(cat "$C/acme-a/issues")"

BUDGET=0 run || fail 'healthy tick failed'
eq 'healthy tick wraps and visits every repo once' 'b c a ' "$(order)"
eq 'completed round clears the cursor' '' "$(cursor)"
TTL=999999 BUDGET=0 run || fail 'TTL tick failed'
eq 'fresh caches cause no GitHub calls' '' "$(cat "$LOG")"

printf 'acme/a' > "$G/collect.issues.cursor"
TTL=999999 run --issues acme/b || fail 'targeted refresh failed'
eq 'targeted refresh still bypasses TTL' 'b ' "$(order)"
eq 'targeted refresh cannot move sweep cursor' acme/a "$(cursor)"

rm -f "$G/collect.issues.cursor"
printf 'old parents\n' > "$C/acme-a/parents"
HANG=a:api run || fail 'GraphQL timeout tick failed'
eq 'GraphQL timeout also saves repo cursor' acme/a "$(cursor)"
eq 'GraphQL timeout retains old parents' 'old parents' "$(cat "$C/acme-a/parents")"
HANG=a:api run || fail 'GraphQL retry tick failed'
eq 'GraphQL wedge cannot starve other repos' 'b c a ' "$(order)"

# Cursor identity, not an index: removing/reordering repos cannot skip a neighbour.
printf 'acme/b' > "$G/collect.issues.cursor"
REPOS='acme/c acme/a' BUDGET=0 run || fail 'removed cursor tick failed'
eq 'removed cursor falls back to queue start' 'c a ' "$(order)"
printf 'acme/a' > "$G/collect.issues.cursor"
REPOS='acme/c acme/a acme/b' BUDGET=0 run || fail 'reordered queue tick failed'
eq 'resume after identity in reordered queue' 'b c a ' "$(order)"

# Empty queue is legal on a fresh install (including bash 3.2 under set -u).
: > "$G/collect.repoqueue"
REPOS='' BUDGET=0 run || fail 'empty queue tick failed'
eq 'empty queue makes no calls' '' "$(cat "$LOG")"
echo 'collect-issues: OK (timeout fairness, caches, TTL, targeted refresh, queue changes)'
