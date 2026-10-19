#!/bin/bash
# fleet-gh-share-selftest.sh — one machine, one fetch per repo (issues #1271, #3529).
#
# Sandbox "logins" (FLEET_GH_SHARE_ID a / b / c — each its own TMPDIR cache and
# gh shim log; all of them the one OS user running the test, FLEET_GH_SHARE_OWNER_AS)
# with DIFFERENT tokens share one shared dir, and run the REAL collector,
# pr-refresh and fleet-gh-lib.sh. Pins:
#   1. a and b trust each other: whoever is due first fetches, the other takes its
#      copy — no gh at all — so the calls do not grow with the logins;
#   2. the backlog comes by increments: a second fetch is a 304, no `gh issue list`,
#      no GraphQL parents pass while the links are fresh;
#   3. trust: c names nobody → fetches itself; a pub dir another can write, or
#      that is not the login's, is never taken;
#   4. one fetcher at a time: a live trusted claim makes the other wait (bounded),
#      a dead one is ignored;
#   5. a private repo (or one this token cannot read) is never shared;
#   6. the bridge's shared listing is taken only when it began at/before our watermark;
#   7. root's fleet-shared-dirs.py sweeps a claim file planted under another
#      login's name and keeps the gh/ dirs 1777;
#   8. FLEET_GH_SHARE off (the default) → every login fetches with `gh issue list`,
#      no shared dir is created.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gh-share-selftest.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/conf/fleets/f1"
printf 'FLEET_REPO=acme/a\n' > "$WORK/conf/fleets/f1/conf"   # one "live" fleet (fake tmux answers has-session)
for f in tmux-dash-collect.sh tmux-pr-refresh.sh fleet-lib.sh fleet-client-core.sh usage-lib.sh fleet-gh-lib.sh fleet_gh_issues.py; do
  cp "$BIN/$f" "$WORK/bin/"
done
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/fleet-restore.sh"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/fleet-emit.sh"
printf '#!/bin/sh\nexit 0\n' > "$WORK/fakepath/tmux"
printf '#!/bin/sh\nexit 1\n' > "$WORK/fakepath/git"
# gh: logs one word per call — access · inc (REST increment; inc304 when it was a
# 304) · issue (gh issue list) · graphql · pr — and answers in the shape asked.
cat > "$WORK/fakepath/gh" <<'FAKE'
#!/bin/bash
args="$*"; name=''; etag=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) shift; name=${1##*/} ;;
    name=*) name=${1#name=} ;;
    'If-None-Match: '*) etag=${1#If-None-Match: } ;;
    repos/*) name=${1#repos/*/}; name=${name%%[/?]*} ;;
  esac
  shift
done
case "$args" in
  api\ -i*)
    if [ -n "$etag" ] && [ "$etag" = '"E1"' ]; then
      echo "inc304 $name" >> "$TEST_GH_LOG"; printf 'HTTP/2.0 304 Not Modified\r\n\r\n'; exit 1
    fi
    echo "inc $name" >> "$TEST_GH_LOG"
    printf 'HTTP/2.0 200 OK\r\nEtag: "E1"\r\n\r\n'
    printf '[{"number":1,"title":"Fresh %s by %s","labels":[{"name":"bug"}],"milestone":{"title":"Milestone"},"assignees":[],"state":"open","updated_at":"2026-10-01T00:00:00Z"}]\n' "$name" "$FLEET_GH_SHARE_ID" ;;
  api\ repos/*) echo "access $name" >> "$TEST_GH_LOG"
    if [ "${TEST_PRIVATE:-0}" = 1 ]; then echo 'true true'; else echo 'false true'; fi ;;
  api\ graphql*) echo "graphql $name" >> "$TEST_GH_LOG"; printf '2\t1\n' ;;
  issue\ *) echo "issue $name" >> "$TEST_GH_LOG"
    printf 'bug\tMilestone\t#1\t·\tFresh %s by %s\n' "$name" "$FLEET_GH_SHARE_ID" ;;
  pr\ *) echo "pr $name" >> "$TEST_GH_LOG"
    printf 'issue-1\t#7\tOPEN\t✓\tready\t%s\n' "$FLEET_GH_SHARE_ID" ;;
esac
FAKE
chmod +x "$WORK/fakepath/"*
SHARED="$WORK/shared"
ME=$(id -un)
pass=0
fail() { echo "gh-share FAIL: $1" >&2; for l in a b c; do echo "--- $l"; cat "$WORK/$l.gh" "$WORK/$l.err" 2>/dev/null; done >&2; exit 1; }
eq() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail "$1: expected [$2], got [$3]"; fi; }

# run <login> <collect|pr> [repos] — one daemon tick as that login
run() {
  local who="$1" what="$2" repos="${3:-acme/a}" script=tmux-dash-collect.sh
  [ "$what" = pr ] && script=tmux-pr-refresh.sh
  mkdir -p "$WORK/$who.tmp"
  env PATH="$WORK/fakepath:$PATH" HOME="$WORK/$who.tmp" TMPDIR="$WORK/$who.tmp" \
    GH_TOKEN="token-of-$who" FLEET_GH_SHARE="${SHARE-1}" FLEET_GH_SHARED_DIR="$SHARED" \
    FLEET_GH_SHARE_ID="$who" FLEET_GH_SHARE_OWNER_AS="$ME" FLEET_GH_SHARE_TRUST="${TRUST-a b}" \
    FLEET_GH_SHARE_WAIT="${WAIT:-1}" FLEET_GH_LOG="$WORK/gh-limit.log" \
    FLEET_STATE_DIR="$WORK/$who.state" FLEET_CONF_DIR="$WORK/conf" FLEET_REPO='' FLEET_REPOS="$repos" \
    FLEET_NOTIFY_CMD='' FLEET_COLLECT_QUOTAWATCH=never FLEET_DAEMON_IDLE_AFTER=0 \
    FLEET_COLLECT_QUOTAWATCH_BUDGET=0 FLEET_COLLECT_SOCKETS_BUDGET=0 \
    FLEET_COLLECT_SESSMAP_BUDGET=0 FLEET_COLLECT_GIT_BUDGET=0 \
    FLEET_COLLECT_CTX_BUDGET=0 FLEET_COLLECT_USAGE_BUDGET=0 \
    FLEET_COLLECT_SCRAPE_BUDGET=0 FLEET_COLLECT_BANNER_BUDGET=0 \
    FLEET_COLLECT_ESCALATE_BUDGET=0 FLEET_COLLECT_SNAPSHOT_BUDGET=0 \
    FLEET_COLLECT_ISSUES_BUDGET=20 GH_TTL=60 FLEET_PR_REFRESH_INTERVAL=60 \
    TEST_GH_LOG="$WORK/$who.gh" \
    bash "$WORK/bin/$script" > "$WORK/$who.out" 2> "$WORK/$who.err"
}
calls() { grep -c "^$2 " "$WORK/$1.gh" 2>/dev/null || :; }
gh_total() { cat "$WORK/$1.gh" 2>/dev/null | grep -vc '^access ' || :; }
fd() { printf '%s' "$WORK/$1.tmp/.claude-dash/fleets/$2"; }
issues() { cat "$(fd "$1" "$2")/issues" 2>/dev/null; }
prmap() { cat "$(fd "$1" "$2")/prmap" 2>/dev/null; }
due() { rm -f "$(fd "$1" acme-a)/issues.ts" "$(fd "$1" acme-a)/prmap.ts"; }   # its TTL ran out
reset_logs() { : > "$WORK/a.gh"; : > "$WORK/b.gh"; : > "$WORK/c.gh"; }
lib() {  # lib <login> <shell snippet> — the gh lib as that login
  env PATH="$WORK/fakepath:$PATH" GH_TOKEN="token-of-$1" FLEET_GH_SHARE=1 FLEET_GH_SHARED_DIR="$SHARED" \
    FLEET_GH_SHARE_ID="$1" FLEET_GH_SHARE_OWNER_AS="${OWNER_AS:-$ME}" FLEET_GH_SHARE_TRUST="${TRUST-a b}" \
    FLEET_GH_SHARE_WAIT="${WAIT:-1}" FLEET_STATE_DIR="$WORK/$1.state" FLEET_GH_LOG="$WORK/gh-limit.log" \
    TEST_GH_LOG="$WORK/$1.gh" bash -c ". '$WORK/bin/fleet-gh-lib.sh'; $2"
}

# --- 1. one fetch, the other login takes it -------------------------------------
reset_logs
run a collect; run b collect
run a pr;      run b pr
eq 'a: backlog fetched once (an increment)'  1 "$(calls a inc)"
eq 'a: no gh issue list under sharing'       0 "$(calls a issue)"
eq 'a: PR map fetched'                       1 "$(calls a pr)"
eq 'b: no GitHub read at all'                0 "$(gh_total b)"
eq 'b has the issues a fetched'              $'Milestone\t#1\t·\tFresh a by a' "$(issues b acme-a)"
eq 'b labels came along'                     $'1\tbug' "$(cat "$(fd b acme-a)/labels")"
eq 'b has the PR map a fetched'              "$(prmap a acme-a)" "$(prmap b acme-a)"
eq 'b checked its own access once'           1 "$(calls b access)"
eq 'shared dir is per repo'                  yes "$([ -d "$SHARED/acme-a/pub.a/issues" ] && echo yes)"
eq 'shared repo dir is sticky (1777)'        yes "$([ -k "$SHARED" ] && [ -k "$SHARED/acme-a" ] && echo yes)"
eq 'no claim left behind'                    '' "$(for f in "$SHARED/acme-a"/fetch.*; do [ -e "$f" ] && echo "$f"; done)"
# b's next due tick: b fetches now (a's copy too old) and a takes b's — still one fetch
reset_logs
due a; due b
touch -t 200001010000 "$SHARED/acme-a/pub.a/issues/issues.ts"
run b collect; run a collect
eq 'turn: b fetches when the copy is old'    1 "$(( $(calls b inc) + $(calls b inc304) ))"
eq 'turn: a takes b'                         0 "$(gh_total a)"

# --- 2. increments: unchanged is a 304, no list, no GraphQL ----------------------
# (b's increment above was the first after a's full listing: a 200 that fixed the
# watermark's ETag. The next one, whoever runs it, is a 304.)
reset_logs
due a; touch -t 200001010000 "$SHARED/acme-a/pub.b/issues/issues.ts"
run a collect
eq 'a continued b'"'"'s watermark: a 304'       1 "$(calls a inc304)"
eq 'a: no other GitHub read'                 1 "$(gh_total a)"
eq 'state travels with the copy'             yes "$(grep -q '"etag": "\\"E1\\""' "$(fd a acme-a)/issues.json" && echo yes)"

# --- 3. trust ---------------------------------------------------------------------
reset_logs
TRUST='' run c collect
eq 'c trusts nobody → fetches itself'        1 "$(calls c inc)"
eq 'c still publishes for others'            yes "$([ -f "$SHARED/acme-a/pub.c/issues/issues" ] && echo yes)"
due a
chmod 777 "$SHARED/acme-a/pub.b"; touch "$SHARED/acme-a/pub.b/issues/issues.ts"
TRUST=b run a collect
eq 'a world-writable pub dir is not taken'   1 "$(( $(calls a inc) + $(calls a inc304) ))"
chmod 755 "$SHARED/acme-a/pub.b"
reset_logs; due a; touch "$SHARED/acme-a/pub.b/issues/issues.ts"
OWNER_AS=nobody-here lib a "_fleet_gh_owned_by '$SHARED/acme-a/pub.b' b" && fail 'a pub dir owned by someone else was accepted'
pass=$((pass+1))
TRUST='*' run a collect
eq 'TRUST=* takes any login'                 0 "$(gh_total a)"

# --- 4. one fetcher at a time ---------------------------------------------------
reset_logs
printf '%s %s\n' "$$" "$(( $(date +%s) * 1000 - 1000 ))" > "$SHARED/acme-a/fetch.testkind.b"   # live, earlier
got=$(lib a "fleet_gh_share_get acme/a testkind 0 '$WORK/x' issues.ts issues; echo rc=\$?")
eq 'a live earlier claim → wait, then fetch' rc=1 "$got"
grep -q 'share-wait-timeout repo=acme/a kind=testkind' "$WORK/gh-limit.log" || fail 'wait timeout not logged'
pass=$((pass+1))
eq 'a holds the claim it fetches under'      yes "$([ -f "$SHARED/acme-a/fetch.testkind.a" ] && echo yes)"
lib a "fleet_gh_share_put acme/a testkind 0 '$WORK/x' issues.ts issues"
eq 'put drops the claim'                     no "$([ -f "$SHARED/acme-a/fetch.testkind.a" ] && echo yes || echo no)"
printf '%s %s\n' 999999 "$(( $(date +%s) * 1000 - 1000 ))" > "$SHARED/acme-a/fetch.testkind.b"     # dead pid
t0=$(date +%s)
got=$(WAIT=5 lib a "fleet_gh_share_get acme/a testkind 0 '$WORK/x' issues.ts issues; echo rc=\$?")
eq 'a dead claim is ignored'                 rc=1 "$got"
[ $(( $(date +%s) - t0 )) -lt 4 ] || fail 'waited on a dead claim'
pass=$((pass+1))
rm -f "$SHARED/acme-a/fetch.testkind."*

# --- 5. a private repo is never shared --------------------------------------------
reset_logs
rm -rf "$SHARED/acme-p"
TEST_PRIVATE=1 run a collect acme/p; TEST_PRIVATE=1 run b collect acme/p
eq 'private: a fetches'                      1 "$(( $(calls a inc) + $(calls a issue) ))"
eq 'private: b fetches too'                  1 "$(( $(calls b inc) + $(calls b issue) ))"
eq 'private: nothing published'              no "$([ -e "$SHARED/acme-p" ] && echo yes || echo no)"

# --- 6. bridge listing: only when it began at/before our watermark -------------
lib b "d=\$(mktemp -d); printf '#since 2026-10-03T08:00:00Z\nrow1\n' > \$d/comments; fleet_gh_share_put acme/a comments 1 \$d comments; rm -rf \$d"
src=$(sed -n '/^bridge_adopt_rows()/,/^}/p' "$BIN/fleet-issue-bridge.sh")
[ -n "$src" ] || fail 'bridge_adopt_rows not found'
adopt() { lib a "BRIDGE_INT=60; $src
rows=''; if bridge_adopt_rows acme/a '$1'; then printf 'took:%s' \"\$rows\"; else printf fetch; fi"; }
eq 'watermark after the copy start → take it' 'took:row1' "$(adopt 2026-10-03T09:00:00Z)"
eq 'watermark before the copy start → fetch'  fetch       "$(WAIT=0 adopt 2026-10-03T07:00:00Z)"
eq 'never takes its own copy'                 fetch       "$(TRUST=b WAIT=0 lib b "BRIDGE_INT=60; $src
rows=''; if bridge_adopt_rows acme/a 2026-10-03T09:00:00Z; then printf took; else printf fetch; fi")"

# --- 7. the root sweep: a claim under another login's name goes ----------------
SR="$WORK/sroot"; mkdir -p "$SR/gh/acme-a"
: > "$SR/gh/acme-a/fetch.issues.mallory"; : > "$SR/gh/acme-a/fetch.issues.$ME"
python3 "$BIN/fleet-shared-dirs.py" --root "$SR" --slots 1 >/dev/null
eq 'shared-dirs sweeps a squatted claim'     no "$([ -e "$SR/gh/acme-a/fetch.issues.mallory" ] && echo yes || echo no)"
eq 'shared-dirs keeps the owner'"'"'s claim'    yes "$([ -e "$SR/gh/acme-a/fetch.issues.$ME" ] && echo yes)"
eq 'shared-dirs keeps gh/<repo> sticky'      yes "$([ -k "$SR/gh" ] && [ -k "$SR/gh/acme-a" ] && echo yes)"

# --- 8. off (the default): everyone fetches, nothing shared ---------------------
reset_logs
rm -rf "$SHARED"; rm -rf "$WORK/a.tmp" "$WORK/b.tmp"
SHARE='' run a collect; SHARE='' run b collect
eq 'off: a lists with gh'                    1 "$(calls a issue)"
eq 'off: b lists with gh'                    1 "$(calls b issue)"
eq 'off: no increment, no access check'      0 "$(( $(calls a inc) + $(calls a access) ))"
[ -e "$SHARED" ] && fail 'off: the shared dir was created'
pass=$((pass+1))

echo "gh-share selftest: $pass checks passed"
