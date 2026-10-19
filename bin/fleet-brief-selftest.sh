#!/bin/bash
# fleet-brief-selftest.sh — hermetic tests for bin/fleet-brief.sh, the opening read
# of a development session (the `brief` tool; issue #4898, EPIC #4895 批 1).
#
#   RAILS   no fleet ⇒ ABORT(2), nothing bound ⇒ FAIL(4): never a guessed repo.
#   TASK    @task T<n>: the record off the hub (the FLEET_TASK_RECORD seam), the
#           flow ending in `report merged`, the directive; an unreadable record ⇒ 5.
#   ISSUE   @issue N (or an issue-<N> worktree): the words are already the first
#           turn — no claim line, `Closes #N` in the flow.
#   NO GH   neither shape ever runs gh.
#   ORIGIN  the `origin:` line in every shape, "none" included.
#
# tmux and gh are faked on PATH; conf dir, TMPDIR and cwd are private temp trees.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-repo-fixture.sh"
CLI="$BIN/fleet-brief.sh"
[ -x "$CLI" ] || { echo "selftest: $CLI missing/not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleetbrief-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
has()  { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

SESS=testfleet
REPO=acme/widgets
CONF="$WORK/conf"
mkdir -p "$CONF/fleets/$SESS" "$WORK/plain" "$WORK/widgets-issue-12" "$WORK/widgets-scratch-3" "$WORK/fakebin"
fx_repo "$CONF" "$SESS" "$REPO" FLEET_MAIN="$WORK/widgets" FLEET_BASE_BRANCH=trunk
cat > "$CONF/fleets/$SESS/conf" <<CONF_EOF
FLEET_MERGE_METHOD=rebase
FLEET_WORKER_PROMPT='DIRECTIVE-MARKER for {issue}'
CONF_EOF

cat > "$WORK/fakebin/tmux" <<'TMUX_EOF'
#!/bin/bash
case " $* " in
  *'#{session_name}'*) printf '%s\n' "${FAKE_SESSION-}" ;;
  *'#{@issue}'*)       printf '%s\n' "${FAKE_AT_ISSUE-}" ;;
  *'#{@origin}'*)      printf '%s\n' "${FAKE_AT_ORIGIN-}" ;;
  *'#{@origin_wid}'*)  printf '%s\n' "${FAKE_AT_OWID-}" ;;
  *'#{@task}'*)        printf '%s\n' "${FAKE_AT_TASK-}" ;;
  *'#{@repo}'*)        printf '%s\n' "${FAKE_AT_REPO-}" ;;
  *)                   : ;;
esac
exit 0
TMUX_EOF
cat > "$WORK/fakebin/gh" <<'GH_EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${GH_CALLS:-/dev/null}"
exit 1
GH_EOF
cat > "$WORK/taskrec" <<'TR_EOF'
#!/bin/bash
[ "${1:-}" = get ] && [ "${2:-}" = T42 ] || exit 1
[ "${TR_RC:-0}" = 0 ] || exit 1
printf '%s\n' '{"task":{"id":"T42","title":"RECORD-TITLE 修风扇","state":"open","repo":"acme/widgets","parent_task":"T7","request_payload":"{\"body\":\"RECORD-WORDS 为什么一直转\"}"}}'
TR_EOF
chmod +x "$WORK/fakebin/tmux" "$WORK/fakebin/gh" "$WORK/taskrec"

run() {
  local dir="$1"; shift
  OUT=$(cd "$dir" && env PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK" \
          FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$CONF" TMUX=/tmp/fake,1,0 TMUX_PANE='%9' \
          FAKE_SESSION="${FAKE_SESSION-$SESS}" FAKE_AT_ISSUE="${FAKE_AT_ISSUE-}" \
          FAKE_AT_ORIGIN="${FAKE_AT_ORIGIN-}" FAKE_AT_OWID="${FAKE_AT_OWID-}" \
          FAKE_AT_TASK="${FAKE_AT_TASK-}" FAKE_AT_REPO="${FAKE_AT_REPO-}" \
          GH_CALLS="$WORK/gh.calls" TR_RC="${TR_RC:-0}" FLEET_TASK_RECORD="$WORK/taskrec" \
          bash "$CLI" "$@" 2>"$WORK/err"); RC=$?
  ERR=$(cat "$WORK/err")
}

# ===== RAILS ===================================================================
FAKE_SESSION=nosuchfleet FAKE_AT_TASK=T42 run "$WORK/plain"
[ "$RC" = 2 ] || [ "$RC" = 0 ] || fail "RAIL an unknown fleet must exit 2 or find its one repo (got $RC)" "$OUT$ERR"
run "$WORK/plain"
[ "$RC" = 4 ] || fail "RAIL nothing bound must exit 4 (got $RC)" "$OUT$ERR"
case "$ERR" in *FAIL*) : ;; *) fail "RAIL nothing bound must say FAIL" "$ERR" ;; esac
[ -z "$OUT" ] || fail "RAIL nothing bound prints no brief" "$OUT"
ok "RAIL nothing bound → FAIL, exit 4, empty stdout"

# ===== TASK ====================================================================
: > "$WORK/gh.calls"
FAKE_AT_TASK=T42 FAKE_AT_REPO=$REPO run "$WORK/widgets-scratch-3"
[ "$RC" = 0 ] || fail "TASK must exit 0 (got $RC)" "$OUT$ERR"
has 'task=T42'                 || fail "TASK the fleet block names the record" "$OUT"
has 'RECORD-TITLE 修风扇'       || fail "TASK the record's title" "$OUT"
has 'RECORD-WORDS 为什么一直转'  || fail "TASK the record's words" "$OUT"
has 'dispatched by: T7'        || fail "TASK the dispatcher" "$OUT"
has 'report (state: merged'    || fail "TASK the flow ends with report merged" "$OUT"
has 'merge=rebase'             || fail "TASK the merge method" "$OUT"
has 'DIRECTIVE-MARKER for T42' || fail "TASK the directive" "$OUT"
has 'origin: none'             || fail "TASK the origin line, none included" "$OUT"
has 'claim'                    && fail "TASK no claim anywhere" "$OUT"
FAKE_AT_TASK=T42 FAKE_AT_REPO=$REPO TR_RC=1 run "$WORK/widgets-scratch-3"
[ "$RC" = 5 ] || fail "TASK an unreadable record exits 5 (got $RC)" "$OUT$ERR"
has 'DIRECTIVE-MARKER' || fail "TASK an unreadable record still prints the rest" "$OUT"
ok "TASK the record, the flow, the directive; unreadable → 5"

# ===== ISSUE ===================================================================
FAKE_AT_ISSUE=77 FAKE_AT_ORIGIN=scratch-4 run "$WORK/widgets-issue-12"
[ "$RC" = 0 ] || fail "ISSUE must exit 0 (got $RC)" "$OUT$ERR"
has 'issue=77'          || fail "ISSUE @issue wins over the worktree's number" "$OUT"
has 'Closes #77'        || fail "ISSUE the flow carries Closes #N" "$OUT"
has 'origin: scratch-4' || fail "ISSUE the origin" "$OUT"
FAKE_AT_ISSUE='' run "$WORK/widgets-issue-12"
has 'issue=12' || fail "ISSUE the issue-<N> worktree is the fallback" "$OUT"
ok "ISSUE words-only: Closes #N, @issue first, worktree fallback"

[ -s "$WORK/gh.calls" ] && fail "NO GH the brief never runs gh" "$(cat "$WORK/gh.calls")"
ok "NO GH no shape runs gh"

FAKE_AT_ISSUE=77 run "$WORK/widgets-issue-12" --bogus
[ "$RC" = 2 ] || fail "an unknown argument exits 2 (got $RC)" "$ERR"
run "$WORK/plain" -h
[ "$RC" = 0 ] || fail "--help exits 0 (got $RC)" "$ERR"
ok "args"

printf '\nfleet-brief-selftest: %d checks passed\n' "$pass"
exit 0
