#!/bin/bash
# refocus-hook-selftest.sh — hermetic tests for bin/refocus-hook.sh, the
# SessionStart(source=compact) hook that re-states a worker's task charter after
# a context compaction (issue #1266, EPIC #1262 C6).
#
# What is pinned:
#   WIRED    hooks/settings-hooks.json runs it under SessionStart, matcher `compact`.
#   COMPACT  a fake SessionStart payload with source=compact from a worker pane
#            yields ONE JSON object whose hookSpecificOutput.additionalContext
#            opens `[fleet charter] #<N>` with the right issue, repo, title,
#            branch, base and PR (from the dash's prmap — zero gh calls).
#   SOURCE   startup / resume / clear ⇒ zero output (matcher-independent).
#   SEATS    hub / scratch (no @issue), a non-worktree cwd, a headless child and
#            a non-tmux shell ⇒ zero output.
#   REPO     a 2-repo fleet window with no @repo ⇒ zero output (never guessed);
#            the degenerate one-repo fleet resolves without @repo.
#   OFF      FLEET_REFOCUS=0 in the fleet conf ⇒ zero output.
#   SIZE     the context stays ≤ 1.5 KB however long the paths/title are.
#
# `tmux` and `gh` are faked on PATH (gh fails loudly if called at all); conf dir,
# cache (TMPDIR) and cwd are private temp trees. No network, no real tmux server.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
HOOK="$BIN/refocus-hook.sh"
[ -x "$HOOK" ] || { echo "selftest: $HOOK missing/not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/refocus-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

SESS=testfleet
REPO=acme/widgets
CONF="$WORK/conf"
mkdir -p "$CONF/fleets/$SESS" "$WORK/hub" "$WORK/widgets-issue-12" "$WORK/fakebin" \
         "$WORK/.claude-dash/fleets/acme-widgets"
cat > "$CONF/fleets/$SESS/conf" <<CONF_EOF
FLEET_REPO=$REPO
FLEET_MAIN=$WORK/widgets
FLEET_BASE_BRANCH=trunk
FLEET_MERGE_METHOD=rebase
CONF_EOF
printf 'issue-12\t#345\tOPEN\t✓\tready\t\nissue-99\t#400\tMERGED\t✓\t\tabc\n' \
  > "$WORK/.claude-dash/fleets/acme-widgets/prmap"
printf '· no milestone\t#12\t·\tRESTATE-TITLE after compaction\n' \
  > "$WORK/.claude-dash/fleets/acme-widgets/issues"

cat > "$WORK/fakebin/tmux" <<'TMUX_EOF'
#!/bin/bash
case " $* " in
  *'#{session_name}'*) printf '%s\n' "${FAKE_SESSION-}" ;;
  *'#{@repo}'*)        printf '%s||\n' "${FAKE_AT_REPO-}" ;;
  *'#{@issue}'*)       printf '%s\n' "${FAKE_AT_ISSUE-}" ;;
  *'#{@origin}'*)      printf '%s\n' "${FAKE_AT_ORIGIN-}" ;;
  *)                   : ;;
esac
exit 0
TMUX_EOF
cat > "$WORK/fakebin/gh" <<'GH_EOF'
#!/bin/bash
echo "gh called: $*" >> "${GH_CALLS:-/dev/null}"; exit 1
GH_EOF
chmod +x "$WORK/fakebin/tmux" "$WORK/fakebin/gh"

# run <cwd> <source> → OUT/RC. Extra env is passed via the caller's env.
run() {
  local dir="$1" src="$2"
  OUT=$(cd "$dir" && printf '{"session_id":"s","hook_event_name":"SessionStart","source":"%s"}' "$src" \
        | env PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK" \
            FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$CONF" \
            TMUX="${FAKE_TMUX-/tmp/fake,1,0}" TMUX_PANE='%9' \
            CLAUDE_CODE_ENTRYPOINT="${FAKE_ENTRY-cli}" \
            FAKE_SESSION="$SESS" FAKE_AT_ISSUE="${FAKE_AT_ISSUE-}" \
            FAKE_AT_REPO="${FAKE_AT_REPO-}" FAKE_AT_ORIGIN="${FAKE_AT_ORIGIN-}" \
            GH_CALLS="$WORK/gh.calls" \
            bash "$HOOK" 2>"$WORK/err"); RC=$?
}
ctx() { printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin)["hookSpecificOutput"]; assert d["hookEventName"]=="SessionStart"; sys.stdout.write(d["additionalContext"])'; }

# ===== WIRED ====================================================================
python3 - "$BIN/../hooks/settings-hooks.json" <<'PY' || fail "settings-hooks.json has no SessionStart group matcher=compact running refocus-hook.sh"
import json, sys
groups = json.load(open(sys.argv[1]))["hooks"]["SessionStart"]
sys.exit(0 if any(g.get("matcher") == "compact" and
                  any("refocus-hook.sh" in h.get("command", "") for h in g.get("hooks", []))
                  for g in groups) else 1)
PY
ok "WIRED SessionStart[compact] runs refocus-hook.sh"

# ===== COMPACT: the charter, from a worker pane =================================
FAKE_AT_ISSUE=12 FAKE_AT_ORIGIN=issue-7 run "$WORK/widgets-issue-12" compact
[ "$RC" = 0 ] || fail "compact must exit 0 (got $RC)" "$OUT$(cat "$WORK/err")"
C=$(ctx) || fail "output must be a SessionStart hookSpecificOutput JSON object" "$OUT"
case "$C" in '[fleet charter] #12 · acme/widgets — RESTATE-TITLE after compaction'*) : ;;
  *) fail "context must open with the [fleet charter] #12 line" "$C" ;; esac
for want in 'branch issue-12 → base trunk' 'PR: #345 OPEN ci✓' 'work ONLY on #12' \
            'Closes #12' 'gh pr merge --rebase' 'spawned by issue-7' 'fleet-claim-brief.sh' \
            "Base checkout $WORK/widgets is read-only"; do
  case "$C" in *"$want"*) : ;; *) fail "context must carry: $want" "$C" ;; esac
done
[ ! -s "$WORK/gh.calls" ] || fail "the hook must make ZERO gh calls" "$(cat "$WORK/gh.calls")"
ok "COMPACT worker → [fleet charter] #12 with repo/title/branch/base/PR/origin, 0 gh calls"

# ===== SOURCE: anything but compact is silent ===================================
for s in startup resume clear ''; do
  FAKE_AT_ISSUE=12 run "$WORK/widgets-issue-12" "$s"
  [ "$RC" = 0 ] && [ -z "$OUT" ] || fail "source='$s' must be silent (rc=$RC)" "$OUT"
done
ok "SOURCE startup/resume/clear/empty → zero output"

# ===== SEATS =====================================================================
FAKE_AT_ISSUE='' run "$WORK/hub" compact
[ -z "$OUT" ] || fail "hub/scratch (no @issue) must be silent" "$OUT"
FAKE_AT_ISSUE=12 run "$WORK/hub" compact
[ -z "$OUT" ] || fail "a bound issue in a non-worktree cwd must be silent" "$OUT"
FAKE_AT_ISSUE=12 FAKE_ENTRY=sdk-cli run "$WORK/widgets-issue-12" compact
[ -z "$OUT" ] || fail "a headless child must be silent" "$OUT"
FAKE_AT_ISSUE=12 FAKE_TMUX='' run "$WORK/widgets-issue-12" compact
[ -z "$OUT" ] || fail "outside tmux must be silent" "$OUT"
ok "SEATS hub/scratch, non-worktree, headless, non-tmux → zero output"

# ===== OFF: FLEET_REFOCUS=0 in the fleet conf silences it =========================
printf 'FLEET_REFOCUS=0\n' >> "$CONF/fleets/$SESS/conf"
FAKE_AT_ISSUE=12 run "$WORK/widgets-issue-12" compact
[ -z "$OUT" ] || fail "FLEET_REFOCUS=0 in the conf must silence the hook" "$OUT"
sed -i.bak '/^FLEET_REFOCUS=/d' "$CONF/fleets/$SESS/conf"
ok "OFF FLEET_REFOCUS=0 in the fleet conf → zero output"

# ===== PR fallback: no prmap row ⇒ 'none yet' ===================================
: > "$WORK/.claude-dash/fleets/acme-widgets/prmap"
FAKE_AT_ISSUE=12 run "$WORK/widgets-issue-12" compact
C=$(ctx) || fail "compact without a PR must still emit" "$OUT"
case "$C" in *'PR: none yet'*) : ;; *) fail "no prmap row must read 'PR: none yet'" "$C" ;; esac
case "$C" in *'no live parent'*) : ;; *) fail "no @origin must say no live parent" "$C" ;; esac
ok "PR none yet + no parent when the caches know nothing"

# ===== REPO: a 2-repo fleet never guesses ========================================
mkdir -p "$CONF/fleets/$SESS/repos"
printf 'FLEET_REPO=acme/gadgets\nFLEET_MAIN=%s/gadgets\n' "$WORK" > "$CONF/fleets/$SESS/repos/acme-gadgets.conf"
FAKE_AT_ISSUE=12 FAKE_AT_REPO='' run "$WORK/widgets-issue-12" compact
[ -z "$OUT" ] || fail "a multi-repo window with no @repo must be silent" "$OUT"
FAKE_AT_ISSUE=12 FAKE_AT_REPO=acme/gadgets run "$WORK/widgets-issue-12" compact
C=$(ctx) || fail "a multi-repo window with @repo must emit" "$OUT"
case "$C" in '[fleet charter] #12 · acme/gadgets'*) : ;; *) fail "must name the window's @repo" "$C" ;; esac
rm -rf "$CONF/fleets/$SESS/repos"
ok "REPO 2-repo fleet: no @repo → silent, @repo → that repo"

# ===== SIZE: ≤ 1.5 KB whatever the paths ========================================
long=$(printf 'x%.0s' $(seq 1 1800))
sed -i.bak "s|^FLEET_MAIN=.*|FLEET_MAIN=$WORK/$long|" "$CONF/fleets/$SESS/conf"
FAKE_AT_ISSUE=12 run "$WORK/widgets-issue-12" compact
C=$(ctx) || fail "a huge path must still emit valid JSON" "$OUT"
n=$(printf '%s' "$C" | wc -c | tr -d ' ')
[ "$n" -le 1536 ] || fail "context must be ≤ 1536 bytes (got $n)" "$C"
case "$C" in '[fleet charter] #12'*) : ;; *) fail "truncation must keep the header" "$C" ;; esac
ok "SIZE context capped at ≤ 1536 bytes ($n), header intact"

printf 'refocus-hook-selftest: %d passed\n' "$pass"
