#!/bin/bash
# fleet-gh-share-selftest.sh — one account, one set of background reads (issue #1271).
#
# Two sandbox "logins" (FLEET_GH_SHARE_ID a / b — each its own TMPDIR cache, its
# own gh shim log) share ONE token and one shared dir, and run the REAL collector
# and pr-refresh. Pins:
#   1. only the leader calls gh; the follower's caches equal the leader's copy;
#   2. the leader stops beating → the other takes over on its first tick past
#      FLEET_GH_LEADER_STALE (3 ticks in production), and the old one, back, follows;
#   3. different repo sets share only the intersection — a repo the leader does
#      not poll is still fetched by the follower;
#   4. a stale copy (leader's daemon wedged) is never adopted — the follower fetches;
#   5. the bridge's shared listing is taken only when it began at/before our watermark;
#   6. FLEET_GH_SHARE off (the default) → both fetch, no shared dir is created.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gh-share-selftest.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/conf/fleets/f1"
printf 'FLEET_REPO=acme/a\n' > "$WORK/conf/fleets/f1/conf"   # one "live" fleet (fake tmux answers has-session)
for f in tmux-dash-collect.sh tmux-pr-refresh.sh fleet-lib.sh usage-lib.sh fleet-gh-lib.sh; do
  cp "$BIN/$f" "$WORK/bin/"
done
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/fleet-restore.sh"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/fleet-emit.sh"
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
case "$mode" in
  issue) printf 'bug\tMilestone\t#1\t·\tFresh %s by %s\n' "$name" "$FLEET_GH_SHARE_ID" ;;
  pr)    printf 'issue-1\t#7\tOPEN\t✓\tready\t%s\n' "$FLEET_GH_SHARE_ID" ;;
  api)   printf '2\t1\n' ;;
esac
FAKE
chmod +x "$WORK/fakepath/"*
SHARED="$WORK/shared"
pass=0
fail() { echo "gh-share FAIL: $1" >&2; for l in a b; do echo "--- $l"; cat "$WORK/$l.gh" "$WORK/$l.err" 2>/dev/null; done >&2; exit 1; }
eq() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail "$1: expected [$2], got [$3]"; fi; }

# run <login> <collect|pr> [repos] — one daemon tick as that login
run() {
  local who="$1" what="$2" repos="${3:-acme/a}" script=tmux-dash-collect.sh
  [ "$what" = pr ] && script=tmux-pr-refresh.sh
  mkdir -p "$WORK/$who.tmp"
  env PATH="$WORK/fakepath:$PATH" HOME="$WORK/$who.tmp" TMPDIR="$WORK/$who.tmp" \
    GH_TOKEN=one-shared-token FLEET_GH_SHARE="${SHARE-1}" FLEET_GH_SHARED_DIR="$SHARED" \
    FLEET_GH_SHARE_ID="$who" FLEET_GH_LEADER_STALE="${STALE:-60}" FLEET_GH_LOG="$WORK/gh-limit.log" \
    FLEET_CONF_DIR="$WORK/conf" FLEET_REPO='' FLEET_REPOS="$repos" \
    FLEET_NOTIFY_CMD='' FLEET_COLLECT_QUOTAWATCH=never FLEET_DAEMON_IDLE_AFTER=0 \
    FLEET_COLLECT_QUOTAWATCH_BUDGET=0 FLEET_COLLECT_SOCKETS_BUDGET=0 \
    FLEET_COLLECT_SESSMAP_BUDGET=0 FLEET_COLLECT_GIT_BUDGET=0 \
    FLEET_COLLECT_CTX_BUDGET=0 FLEET_COLLECT_USAGE_BUDGET=0 \
    FLEET_COLLECT_SCRAPE_BUDGET=0 FLEET_COLLECT_BANNER_BUDGET=0 \
    FLEET_COLLECT_ESCALATE_BUDGET=0 FLEET_COLLECT_SNAPSHOT_BUDGET=0 \
    FLEET_COLLECT_ISSUES_BUDGET=10 GH_TTL=0 FLEET_PR_REFRESH_INTERVAL=1 \
    TEST_GH_LOG="$WORK/$who.gh" \
    bash "$WORK/bin/$script" > "$WORK/$who.out" 2> "$WORK/$who.err"
}
calls() { grep -c "^$2 " "$WORK/$1.gh" 2>/dev/null || :; }
issues() { cat "$WORK/$1.tmp/.claude-dash/fleets/$2/issues" 2>/dev/null; }
prmap() { cat "$WORK/$1.tmp/.claude-dash/fleets/$2/prmap" 2>/dev/null; }
reset_logs() { : > "$WORK/a.gh"; : > "$WORK/b.gh"; }
lib() {  # lib <login> <shell snippet> — the gh lib as that login
  env GH_TOKEN=one-shared-token FLEET_GH_SHARE=1 FLEET_GH_SHARED_DIR="$SHARED" \
    FLEET_GH_SHARE_ID="$1" FLEET_GH_LEADER_STALE="${STALE:-60}" FLEET_GH_LOG="$WORK/gh-limit.log" \
    bash -c ". '$WORK/bin/fleet-gh-lib.sh'; $2"
}

# --- 1. one leader fetches, the follower reads its copy ----------------------
reset_logs
run a collect; run b collect
run a pr;      run b pr
run a collect; run b collect
eq 'leader a: issues fetched every tick'   2 "$(calls a issue)"
eq 'leader a: PR map fetched'              1 "$(calls a pr)"
eq 'follower b: no gh call at all'         0 "$(wc -l < "$WORK/b.gh" | tr -d ' ')"
eq 'follower b has the leader issues'      "$(issues a acme-a)" "$(issues b acme-a)"
eq 'follower b issues came from a'         $'Milestone\t#1\t·\tFresh a by a' "$(issues b acme-a)"
eq 'follower b has the leader PR map'      "$(prmap a acme-a)" "$(prmap b acme-a)"
eq 'lib: a leads'                          a "$(lib a fleet_gh_leader)"
eq 'lib: b agrees a leads'                 a "$(lib b fleet_gh_leader)"
eq 'shared dir is sticky (1777)'           yes "$([ -k "$SHARED" ] && [ -k "$(ls -d "$SHARED"/*/ | head -1)" ] && echo yes)"
eq 'shared dir is world-writable'          777 "$(stat -f %Lp "$SHARED" 2>/dev/null || stat -c %a "$SHARED" | sed 's/^1//')"

# --- 2. leader stops → b takes over past the stale bound; a back → follows ----
reset_logs
STALE=2; export STALE
sleep 3                                    # a's last beat is now stale
run b collect
eq 'b took over on its first tick past stale' 1 "$(calls b issue)"
eq 'lib: b leads now'                      b "$(lib b fleet_gh_leader)"
run a collect                              # a is back: its since restarts → newest
eq 'returning a does not displace b'       0 "$(calls a issue)"
eq 'returning a reads b'                   $'Milestone\t#1\t·\tFresh a by b' "$(issues a acme-a)"
grep -q 'share-lead login=b' "$WORK/gh-limit.log" || fail 'takeover not logged'
pass=$((pass+1))
STALE=60

# --- 3. different repo sets share only the intersection ----------------------
reset_logs
run b collect acme/a                       # leader b polls acme/a only
run a collect 'acme/a acme/z'              # follower a also hosts acme/z
eq 'follower adopts the shared repo'       0 "$(grep -c '^issue a$' "$WORK/a.gh")"
eq 'follower fetches the repo the leader does not poll' 1 "$(grep -c '^issue z$' "$WORK/a.gh")"

# --- 4. a stale copy is never adopted ------------------------------------------
reset_logs
run b collect                              # b beats + publishes
pub="$(ls -d "$SHARED"/*/pub.b/acme-a)"
touch -t 200001010000 "$pub/issues.ts"     # the leader's copy is ancient (its daemon wedged)
run a collect
eq 'stale copy → follower fetches itself'  1 "$(calls a issue)"

# --- 5. bridge listing: only when it began at/before our watermark -------------
lib b "d=\$(mktemp -d); printf '#since 2026-10-03T08:00:00Z\nrow1\n' > \$d/comments; fleet_gh_publish acme-a \$d comments; rm -rf \$d"
got=$(lib a "d=\$(mktemp -d); fleet_gh_adopt acme-a 60 \$d comments && sed -n 1p \$d/comments; rm -rf \$d")
eq 'follower reads the published listing'  '#since 2026-10-03T08:00:00Z' "$got"
# the bridge's own predicate: lexical ISO compare against the follower watermark
src=$(sed -n '/^bridge_adopt_rows()/,/^}/p' "$BIN/fleet-issue-bridge.sh")
[ -n "$src" ] || fail 'bridge_adopt_rows not found'
adopt() { lib a "$src
rows=''; if bridge_adopt_rows acme-a '$1'; then printf 'took:%s' \"\$rows\"; else printf fetch; fi"; }
eq 'watermark after the copy start → take it' 'took:row1' "$(adopt 2026-10-03T09:00:00Z)"
eq 'watermark before the copy start → fetch'  fetch       "$(adopt 2026-10-03T07:00:00Z)"
eq 'leader never adopts its own copy'         1 "$(lib b "fleet_gh_adopt acme-a 60 /tmp/nowhere comments; echo \$?")"

# --- 6. off (the default): everyone fetches, nothing shared ---------------------
reset_logs
rm -rf "$SHARED"
SHARE='' run a collect; SHARE='' run b collect
eq 'off: a fetches'                        1 "$(calls a issue)"
eq 'off: b fetches'                        1 "$(calls b issue)"
[ -e "$SHARED" ] && fail 'off: the shared dir was created'
pass=$((pass+1))

echo "gh-share selftest: $pass checks passed"
