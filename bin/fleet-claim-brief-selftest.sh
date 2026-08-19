#!/bin/bash
# fleet-claim-brief-selftest.sh — hermetic tests for the issue #458 preamble
# collapse: bin/fleet-claim-brief.sh, the ONE call that replaces /fleet-claim
# steps 0–3 (resolve fleet → guard seat → resolve+read the issue → load the
# charter + per-fleet directive).
#
# What is actually load-bearing here, and therefore what is pinned:
#   RAILS   the three refusals the skill states, one exit code each — no fleet ⇒
#           ABORT(2), wrong seat ⇒ REFUSE(3), no issue bound ⇒ FAIL(4). A brief
#           that printed a plausible-looking block from the hub pane, or guessed a
#           repo, would be worse than the four-step preamble it replaces.
#   BINDING @issue WINS over the issue-<N> worktree in cwd; the worktree is the
#           FALLBACK for a window that lost its binding (and that window is still
#           a worker — fleet_seat alone would refuse it).
#   ONE GH  exactly ONE `gh` invocation for the whole preamble (the old steps 1+2
#           cost 3–4 reads: the --comments dump, the --json assignees check, and
#           the re-fetch every real session then did anyway). The assignee comes
#           out of that same read — the claim is a READ here, never a write.
#   ATOMIC  the charter layers + the per-fleet implementation directive are
#           printed on EVERY successful run, and even when the gh read fails —
#           they were separate steps a worker could skip, and #454 did skip them.
#
# `gh` and `tmux` are faked on PATH; the conf dir, cache (TMPDIR) and cwd are all
# private temp trees. No network, no real tmux server, no git.
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + detail).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
CLI="$BIN/fleet-claim-brief.sh"
[ -x "$CLI" ] || { echo "selftest: $CLI missing/not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claimbrief-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
has()  { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

SESS=testfleet
REPO=acme/widgets
CONF="$WORK/conf"
mkdir -p "$CONF/fleets/$SESS" "$WORK/hub" "$WORK/widgets-issue-12" "$WORK/fakebin"
cat > "$CONF/fleets/$SESS/conf" <<CONF_EOF
FLEET_REPO=$REPO
FLEET_MAIN=$WORK/widgets
FLEET_BASE_BRANCH=trunk
FLEET_MERGE_METHOD=rebase
FLEET_WORKER_PROMPT='DIRECTIVE-MARKER for {issue}'
CONF_EOF

# ---- fake tmux: answers the two formats the brief reads, nothing else ---------
cat > "$WORK/fakebin/tmux" <<'TMUX_EOF'
#!/bin/bash
case " $* " in
  *'#{session_name}'*) printf '%s\n' "${FAKE_SESSION-}" ;;
  *'#{@issue}'*)       printf '%s\n' "${FAKE_AT_ISSUE-}" ;;
  *)                   : ;;   # list-panes (hub lookup) → no hub pane
esac
exit 0
TMUX_EOF

# ---- fake gh: COUNTS its invocations, emits the shape the real --jq produces --
# GH_ASSIGNEES '' ⇒ an unclaimed issue; GH_RC!=0 ⇒ the read fails.
cat > "$WORK/fakebin/gh" <<'GH_EOF'
#!/bin/bash
# ONE line per invocation (newlines in the --jq program squashed) so the caller
# can count calls with `wc -l` and still grep the fields off the same line.
printf '%s\n' "$(printf '%s ' "$@" | tr '\n' ' ')" >> "${GH_CALLS:-/dev/null}"
[ "${GH_RC:-0}" != 0 ] && { echo 'gh: fake failure' >&2; exit "${GH_RC}"; }
cat <<ROW
title: FAKE-TITLE the collapsed preamble
state: OPEN   labels: enhancement
assignees: ${GH_ASSIGNEES-}
url: https://github.com/acme/widgets/issues/77

----- issue body -----
BODY-MARKER
ROW
# Comments only when the --jq program the caller passed actually asks for them,
# so --no-comments is tested for real and not just for its call count.
case "$*" in
  *'----- comments'*) cat <<'ROW2'

----- comments (1) -----
--- @someone · 2026-01-01T00:00:00Z ---
COMMENT-MARKER
ROW2
  ;;
esac
exit 0
GH_EOF
chmod +x "$WORK/fakebin/tmux" "$WORK/fakebin/gh"

# run <cwd> <args…> → OUT/ERR/RC. Everything the brief reads is redirected into
# the temp tree: conf dir, runtime cache (TMPDIR) and cwd.
run() {
  local dir="$1"; shift
  OUT=$(cd "$dir" && env PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK" \
          FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$CONF" TMUX_PANE='%9' \
          FAKE_SESSION="${FAKE_SESSION-$SESS}" FAKE_AT_ISSUE="${FAKE_AT_ISSUE-}" \
          GH_CALLS="${GH_CALLS:-/dev/null}" GH_RC="${GH_RC:-0}" \
          GH_ASSIGNEES="${GH_ASSIGNEES-}" \
          bash "$CLI" "$@" 2>"$WORK/err"); RC=$?
  ERR=$(cat "$WORK/err")
}

# ===== RAIL 1: no fleet ⇒ ABORT(2), and never a guessed repo ====================
# An unknown session has no conf and (private TMPDIR) no cached repo either.
FAKE_SESSION=nosuchfleet FAKE_AT_ISSUE=77 run "$WORK/widgets-issue-12"
[ "$RC" = 2 ] || fail "no fleet must exit 2 (got $RC)" "$OUT$ERR"
case "$ERR" in *ABORT*) : ;; *) fail "no fleet must say ABORT on stderr" "$ERR" ;; esac
[ -z "$OUT" ] || fail "no fleet must print no brief on stdout" "$OUT"
ok "RAIL no fleet → ABORT, exit 2, empty stdout (never guesses a repo)"

# ===== RAIL 2: wrong seat ⇒ REFUSE(3) ==========================================
# @issue IS set (so an issue resolves) but cwd is not an issue-<N> worktree — the
# hub pane / a stray shell. Worker-only, so it must refuse rather than proceed.
FAKE_AT_ISSUE=77 run "$WORK/hub"
[ "$RC" = 3 ] || fail "wrong seat must exit 3 (got $RC)" "$OUT$ERR"
case "$ERR" in *REFUSE*worker-only*) : ;; *) fail "wrong seat must REFUSE as worker-only" "$ERR" ;; esac
[ -z "$OUT" ] || fail "wrong seat must print no brief" "$OUT"
ok "RAIL wrong seat → REFUSE (worker-only), exit 3, empty stdout"

# ===== RAIL 3: no @issue AND cwd isn't a worktree ⇒ FAIL(4) =====================
FAKE_AT_ISSUE='' run "$WORK/hub"
[ "$RC" = 4 ] || fail "no issue bound must exit 4 (got $RC)" "$OUT$ERR"
case "$ERR" in *'no issue bound'*) : ;; *) fail "must fail loudly with 'no issue bound'" "$ERR" ;; esac
[ -z "$OUT" ] || fail "no issue bound must print no brief" "$OUT"
ok "RAIL no @issue + non-worktree cwd → FAIL 'no issue bound', exit 4"

# ===== BINDING: @issue WINS over the issue-<N> worktree in cwd ==================
GH_ASSIGNEES=verkyyi FAKE_AT_ISSUE=77 run "$WORK/widgets-issue-12"
[ "$RC" = 0 ] || fail "the happy path must exit 0 (got $RC)" "$OUT$ERR"
has 'issue=77' || fail "@issue (77) must win over the worktree (12)" "$OUT"
has '@issue=77 worktree=12' || fail "the brief should show BOTH candidates it resolved from" "$OUT"
has 'seat=worker' || fail "a bound worker window must read seat=worker" "$OUT"
ok "BINDING @issue wins over the issue-<N> worktree, and both are shown"

# ...and the worktree is the FALLBACK when the window lost its @issue binding.
# fleet_seat alone returns '' there, so this also pins the widened seat.
FAKE_AT_ISSUE='' run "$WORK/widgets-issue-12"
[ "$RC" = 0 ] || fail "a window with no @issue but an issue-<N> cwd must still work (got $RC)" "$OUT$ERR"
has 'issue=12' || fail "the worktree fallback must resolve issue 12" "$OUT"
has 'seat=worker' || fail "an @issue-less worker worktree is still the worker seat" "$OUT"
ok "BINDING worktree fallback resolves the issue and keeps the worker seat"

# An explicit --issue overrides both.
FAKE_AT_ISSUE=77 run "$WORK/widgets-issue-12" --issue 999
has 'issue=999' || fail "--issue must override @issue and the worktree" "$OUT"
ok "BINDING an explicit --issue overrides @issue and the worktree"

# ===== ONE GH: the whole preamble costs exactly one gh invocation ===============
: > "$WORK/gh.calls"
GH_CALLS="$WORK/gh.calls" GH_ASSIGNEES=verkyyi FAKE_AT_ISSUE=77 run "$WORK/widgets-issue-12"
n=$(wc -l < "$WORK/gh.calls" | tr -d ' ')
[ "$n" = 1 ] || fail "the brief must make exactly ONE gh call (made $n)" "$(cat "$WORK/gh.calls")"
grep -q -- '--json' "$WORK/gh.calls" || fail "the one read must be the structured --json read" "$(cat "$WORK/gh.calls")"
for f in title state url body labels assignees comments; do
  grep -q -- "$f" "$WORK/gh.calls" || fail "the single read must include the '$f' field" "$(cat "$WORK/gh.calls")"
done
ok "ONE GH exactly one gh call, carrying every field the old 3 reads fetched"

# The issue thread itself lands in the brief (body + comments, not a bare header).
has BODY-MARKER    || fail "the issue body must be in the brief" "$OUT"
has COMMENT-MARKER || fail "the issue comments must be in the brief" "$OUT"
has 'FAKE-TITLE'   || fail "the issue title must be in the brief" "$OUT"
ok "ONE GH the brief carries title + body + comments (no re-fetch needed)"

# --no-comments still costs one call and keeps the body.
: > "$WORK/gh.calls"
GH_CALLS="$WORK/gh.calls" GH_ASSIGNEES=verkyyi FAKE_AT_ISSUE=77 run "$WORK/widgets-issue-12" --no-comments
[ "$(wc -l < "$WORK/gh.calls" | tr -d ' ')" = 1 ] || fail "--no-comments must still be one gh call"
has BODY-MARKER    || fail "--no-comments must keep the issue body" "$OUT"
has COMMENT-MARKER && fail "--no-comments must drop the comment thread" "$OUT"
ok "ONE GH --no-comments is still a single read, body kept, thread dropped"

# ===== CLAIM: read-only — held vs unclaimed, and the exact assign on the miss ===
GH_ASSIGNEES=verkyyi FAKE_AT_ISSUE=77 run "$WORK/widgets-issue-12"
has 'claim: HELD by verkyyi' || fail "an assigned issue must read as already claimed" "$OUT"
has 'Do NOT re-assign'       || fail "a held claim must tell the worker not to re-assign" "$OUT"
has '--add-assignee'         && fail "a held claim must NOT offer the assign command" "$OUT"
ok "CLAIM an assigned issue reads HELD (the spawn pre-claim) — no write, no re-assign"

GH_ASSIGNEES='' FAKE_AT_ISSUE=77 run "$WORK/widgets-issue-12"
has 'claim: UNCLAIMED' || fail "an unassigned issue must read as UNCLAIMED" "$OUT"
has "gh issue edit 77 --repo $REPO --add-assignee @me" \
  || fail "the miss must print the exact assign command (the brief never writes)" "$OUT"
ok "CLAIM an unassigned issue reads UNCLAIMED + prints the assign the caller runs"

# ===== ATOMIC: charter layers + per-fleet directive on EVERY run ================
# No file layers and the tap-first flag off ⇒ the brief still says so explicitly,
# so "charter missing" can never be confused with "step skipped" (the #454 gap).
GH_ASSIGNEES=verkyyi FAKE_AT_ISSUE=77 run "$WORK/widgets-issue-12"
has '===== charter'   || fail "the charter section must always be printed" "$OUT"
has 'built-in contract' || fail "no file layers must be stated, not silently omitted" "$OUT"
has 'DIRECTIVE-MARKER for 77' \
  || fail "the per-fleet implementation directive (#234) must be printed, with {issue} substituted" "$OUT"
has "repo=$REPO"    || fail "the brief must state the resolved repo" "$OUT"
has 'base=trunk'    || fail "the brief must state the fleet's base branch" "$OUT"
has 'merge=rebase'  || fail "the brief must state how this fleet lands" "$OUT"
ok "ATOMIC charter + directive + fleet facts are printed on the happy path"

# With an overlay charter present it is printed, in the charter section.
printf 'OVERLAY-ORDERS: keep PRs small\n' > "$CONF/fleets/$SESS/worker.md"
GH_ASSIGNEES=verkyyi FAKE_AT_ISSUE=77 run "$WORK/widgets-issue-12"
has 'OVERLAY-ORDERS' || fail "the fleet overlay charter layer must reach the worker" "$OUT"
ch_at=$(printf '%s\n' "$OUT" | grep -n '===== charter'  | head -1 | cut -d: -f1)
ov_at=$(printf '%s\n' "$OUT" | grep -n 'OVERLAY-ORDERS' | head -1 | cut -d: -f1)
[ -n "$ch_at" ] && [ -n "$ov_at" ] && [ "$ch_at" -lt "$ov_at" ] \
  || fail "the overlay must be printed inside the charter section" "$OUT"
ok "ATOMIC the fleet overlay charter layer is printed under the charter heading"

# ===== gh unhappy: exit 5, but the non-gh half of the brief still prints ========
GH_RC=1 FAKE_AT_ISSUE=77 run "$WORK/widgets-issue-12"
[ "$RC" = 5 ] || fail "a failed gh read must exit 5 (got $RC)" "$OUT$ERR"
has 'could not read issue' || fail "a failed gh read must say so" "$OUT"
has 'OVERLAY-ORDERS'       || fail "a failed gh read must NOT swallow the charter" "$OUT"
has 'DIRECTIVE-MARKER'     || fail "a failed gh read must NOT swallow the directive" "$OUT"
has "repo=$REPO"           || fail "a failed gh read must NOT swallow the fleet facts" "$OUT"
ok "gh read failure → exit 5, fleet + charter + directive still printed"

# gh absent entirely: same contract, no invented issue text. PATH holds ONLY the
# fake tmux plus the handful of externals fleet-lib needs — no gh anywhere on it.
mkdir -p "$WORK/nogh"
cp "$WORK/fakebin/tmux" "$WORK/nogh/tmux"
for t in dirname grep cat awk sed head tr; do
  p=$(command -v "$t") && ln -sf "$p" "$WORK/nogh/$t"
done
OUT=$(cd "$WORK/widgets-issue-12" && env PATH="$WORK/nogh" TMPDIR="$WORK" \
        FLEET_SKIP_GLOBAL_CONF=1 FLEET_CONF_DIR="$CONF" TMUX_PANE='%9' \
        FAKE_SESSION="$SESS" FAKE_AT_ISSUE=77 \
        "$(command -v bash)" "$CLI" 2>"$WORK/err"); RC=$?
[ "$RC" = 5 ] || fail "gh missing must exit 5 (got $RC)" "$OUT$(cat "$WORK/err")"
has 'gh: NOT ON PATH' || fail "gh missing must be stated plainly" "$OUT"
has 'FAKE-TITLE'      && fail "gh missing must not invent issue content" "$OUT"
has 'DIRECTIVE-MARKER' || fail "gh missing must still print the directive" "$OUT"
ok "gh missing → exit 5, says so, invents nothing, still prints the charter half"

# ===== arg handling ============================================================
FAKE_AT_ISSUE=77 run "$WORK/widgets-issue-12" --bogus
[ "$RC" = 2 ] || fail "an unknown flag must exit 2 (got $RC)" "$ERR"
FAKE_AT_ISSUE=77 run "$WORK/widgets-issue-12" -h
[ "$RC" = 0 ] || fail "--help must exit 0 (got $RC)" "$ERR"
case "$OUT" in *'fleet-claim-brief.sh'*) : ;; *) fail "--help must print the usage header" "$OUT" ;; esac
ok "args unknown flag → exit 2; --help prints the header and exits 0"

printf '\nfleet-claim-brief-selftest: %d checks passed (issue #458 preamble collapse)\n' "$pass"
exit 0
