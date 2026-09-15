#!/bin/bash
# fleet-collect-guard-selftest.sh — the collector's overlap guard, heartbeat, and
# quota-watch-FIRST ordering (issue #551).
#
# Background (#551): the ccquota pre-emptive rotation sat at the END of the
# collector tick, after the gh/git/python phases; a tick that stalled or died
# early never reached it, and nothing said so — the cache went 2.5h stale and a
# whole 5h window was lost. This pins the collector-side half of the fix:
#
#   1. ORDER      — the quota watch completes BEFORE the first gh call of the tick
#                   (the fake gh records whether quotawatch.heartbeat already says
#                   done); the tick writes collect.heartbeat with phase=done, end=,
#                   and a phases= list that names quotawatch + issues + snapshot;
#                   the pidfile is gone after a clean exit.
#   2. SKIP       — a live previous tick (command line matches) younger than
#                   FLEET_COLLECT_DEADLINE ⇒ this tick exits 0 without writing
#                   anything (sessmap untouched, no ccquota call, pidfile kept).
#   3. SUPERSEDE  — a live previous tick past the deadline ⇒ it is TERMed and this
#                   tick runs.
#   4. DEAD/RECYCLED — a dead holder pid, or a live pid whose command is NOT a
#                   collector (pid reuse), ⇒ this tick runs and kills nothing.
#   5. KICK       — `--issues <repo>` bypasses the guard (webhook kick) and fetches
#                   even while a tick holds the pidfile.
#
# Drives the REAL collector + fleet-quotawatch.sh + fleet-account.sh against a
# FAKE gh / tmux / ccquota (no network, no tmux server). HOME is the scratch dir
# so the usage scan never touches real transcripts. Needs python3 (collector hard
# dep) — SKIPs if absent. Exit 0 = pass, non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
for f in tmux-dash-collect.sh fleet-quotawatch.sh fleet-account.sh fleet-lib.sh usage-lib.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/collect-guard-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
HOLDER=''; SLEEPER=''
trap '[ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null; [ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/accounts" "$WORK/conf/fleets/sessA" "$WORK/.claude-dash/global"
for f in tmux-dash-collect.sh fleet-quotawatch.sh fleet-account.sh fleet-lib.sh usage-lib.sh; do cp "$BIN/$f" "$WORK/bin/"; done
chmod +x "$WORK/bin/"*.sh
printf 'tok-a\n' > "$WORK/accounts/a"
printf 'FLEET_REPO="acme/widgets"\n' > "$WORK/conf/fleets/sessA/conf"
C="$WORK/.claude-dash"; G="$C/global"

# fake gh: on `issue list`, record whether the quota watch has ALREADY completed
# this tick (1 = quotawatch.heartbeat says done) — then answer an empty backlog.
cat > "$WORK/fakepath/gh" <<'FAKE'
#!/bin/bash
if [ "${1:-}" = issue ] && [ "${2:-}" = list ]; then
  { grep -c '^phase=done' "$FAKE_QHB" 2>/dev/null || echo 0; } >> "$FAKE_GH_MARK"
fi
exit 0
FAKE
cat > "$WORK/fakepath/ccquota" <<'FAKE'
#!/bin/bash
echo "$*" >> "$FAKE_LOG"
# verdict: go|hold|unknown only (cmd/ccquota/budget.go) — never "ok" (issue #668).
printf '{"verdict":"go","accounts":[{"account_uuid":"u-a","label":"a","headroom_pct":90,"five_hour":{"utilization":10,"resets_at":"2026-09-12T05:00:00Z"},"seven_day":{"utilization":5,"resets_at":"2026-09-16T05:00:00Z"}}]}'
FAKE
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
label=""
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then label="$2"; shift 2; fi
case "${1:-}" in
  has-session)   exit 0 ;;
  list-sessions) [ -n "$label" ] && printf '%s\n' "$label"; exit 0 ;;
  *) exit 0 ;;
esac
FAKE
printf '#!/bin/bash\nsleep 300\n' > "$WORK/fakepath/tmux-dash-collect-holder"
chmod +x "$WORK/fakepath/"*

run_collector() {  # args pass through to the collector
  PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 GH_TTL=0 \
  FLEET_REPO="" FLEET_REPOS="" FLEET_NOTIFY_CMD="" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_ACCOUNTS_DIR="$WORK/accounts" CCQUOTA_HUB_URL="http://hub.test:8787" FLEET_ACCOUNT_QUOTA_TTL=0 \
  FAKE_LOG="$WORK/ccquota.calls" FAKE_GH_MARK="$WORK/gh.mark" FAKE_QHB="$G/quotawatch.heartbeat" \
  FLEET_COLLECT_DEADLINE="${DEADLINE:-600}" \
    bash "$WORK/bin/tmux-dash-collect.sh" "$@" >"$WORK/stdout" 2>"$WORK/stderr"
}
fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         printf -- '--- stderr ---\n' >&2; cat "$WORK/stderr" >&2 2>/dev/null
         printf -- '--- collect.heartbeat ---\n' >&2; cat "$G/collect.heartbeat" >&2 2>/dev/null; exit 1; }
ccq_calls() { grep -c . "$WORK/ccquota.calls" 2>/dev/null || echo 0; }
hbget()     { sed -n "s/^$1=//p" "$G/collect.heartbeat" | head -1; }

# 1. ORDER + heartbeat ------------------------------------------------------------
run_collector || fail "1: a full tick must exit 0"
[ "$(head -1 "$WORK/gh.mark" 2>/dev/null)" = 1 ] || fail "1: the quota watch must have COMPLETED before the first gh call (gh.mark: $(cat "$WORK/gh.mark" 2>/dev/null))"
[ "$(ccq_calls)" = 1 ]                        || fail "1: one tick ⇒ one ccquota fetch (got $(ccq_calls))"
[ -f "$G/account.quota.ts" ]                  || fail "1: the tick must stamp account.quota.ts"
[ "$(hbget phase)" = "done" ]                 || fail "1: collect.heartbeat phase=done after a clean tick"
[ -n "$(hbget end)" ] && [ -n "$(hbget dur)" ] || fail "1: collect.heartbeat end= and dur= written"
ph=$(hbget phases)
case "$ph" in *quotawatch=*) : ;; *) fail "1: phases= must name quotawatch (got: $ph)";; esac
case "$ph" in *issues=*)     : ;; *) fail "1: phases= must name issues (got: $ph)";;     esac
case "$ph" in *snapshot=*)   : ;; *) fail "1: phases= must name snapshot (got: $ph)";;   esac
case "$ph" in quotawatch=*)  : ;; *) fail "1: quotawatch must be the FIRST phase (got: $ph)";; esac
[ ! -e "$G/collect.pid" ]                     || fail "1: collect.pid must be removed after a clean exit"
grep -q 'sessA' "$G/sessmap"                  || fail "1: sanity — sessmap written"
[ "$(sed -n 's/^caller=//p' "$G/quotawatch.heartbeat")" = collect ] || fail "1: the watch run from the collector stamps caller=collect"

# 2. SKIP ---------------------------------------------------------------------------
bash "$WORK/fakepath/tmux-dash-collect-holder" >/dev/null 2>&1 </dev/null & HOLDER=$!; disown "$HOLDER"
sleep 0.2
printf '%s\t%s\n' "$HOLDER" "$(date +%s)" > "$G/collect.pid"
printf 'SENTINEL\n' > "$G/sessmap"
before=$(ccq_calls)
run_collector || fail "2: a skipped tick must exit 0"
grep -q 'skip — tick' "$WORK/stderr"          || fail "2: live holder younger than the deadline ⇒ skip line on stderr"
[ "$(cat "$G/sessmap")" = SENTINEL ]          || fail "2: a skipped tick must write nothing (sessmap changed)"
[ "$(ccq_calls)" = "$before" ]                || fail "2: a skipped tick must not run the quota watch"
[ "$(cut -f1 "$G/collect.pid")" = "$HOLDER" ] || fail "2: skip must leave the holder's pidfile"
kill -0 "$HOLDER" 2>/dev/null                 || fail "2: skip must not kill the holder"

# 3. SUPERSEDE ----------------------------------------------------------------------
printf '%s\t%s\n' "$HOLDER" "$(( $(date +%s) - 1000 ))" > "$G/collect.pid"
run_collector || fail "3: a superseding tick must exit 0"
grep -q 'exceeded the 600s deadline' "$WORK/stderr" || fail "3: past the deadline ⇒ kill line on stderr"
sleep 0.3; kill -0 "$HOLDER" 2>/dev/null && fail "3: the wedged holder must be TERMed"
HOLDER=''
grep -q 'sessA' "$G/sessmap"                  || fail "3: the superseding tick must run (sessmap rewritten)"
[ "$(ccq_calls)" = $((before+1)) ]            || fail "3: the superseding tick runs the quota watch"
[ ! -e "$G/collect.pid" ]                     || fail "3: pidfile removed after the superseding tick"

# 4. DEAD / RECYCLED -----------------------------------------------------------------
printf '999999\t%s\n' "$(date +%s)" > "$G/collect.pid"; printf 'SENTINEL\n' > "$G/sessmap"
run_collector || fail "4: dead-holder tick must exit 0"
grep -q 'sessA' "$G/sessmap"                  || fail "4: a dead holder is taken over"
sleep 300 >/dev/null 2>&1 & SLEEPER=$!; disown "$SLEEPER"
printf '%s\t%s\n' "$SLEEPER" "$(date +%s)" > "$G/collect.pid"; printf 'SENTINEL\n' > "$G/sessmap"
run_collector || fail "4b: recycled-pid tick must exit 0"
grep -q 'skip' "$WORK/stderr" && fail "4b: a live pid that is NOT a collector must not be honoured as a holder"
grep -q 'sessA' "$G/sessmap"                  || fail "4b: recycled pid ⇒ the tick runs"
kill -0 "$SLEEPER" 2>/dev/null                || fail "4b: an unrelated live process must never be killed"
kill "$SLEEPER" 2>/dev/null; SLEEPER=''

# 5. KICK bypasses the guard --------------------------------------------------------
bash "$WORK/fakepath/tmux-dash-collect-holder" >/dev/null 2>&1 </dev/null & HOLDER=$!; disown "$HOLDER"
sleep 0.2
printf '%s\t%s\n' "$HOLDER" "$(date +%s)" > "$G/collect.pid"
marks=$(grep -c . "$WORK/gh.mark")
run_collector --issues acme/widgets || fail "5: --issues kick must exit 0"
[ "$(grep -c . "$WORK/gh.mark")" = $((marks+1)) ] || fail "5: the --issues kick must fetch even while a tick holds the pidfile"
[ "$(cut -f1 "$G/collect.pid")" = "$HOLDER" ] || fail "5: the kick must not touch the pidfile"
kill "$HOLDER" 2>/dev/null; HOLDER=''

printf 'selftest PASS: collect guard — quota watch first + heartbeat phases, skip, supersede, dead/recycled holder, --issues bypass (#551)\n'
exit 0
