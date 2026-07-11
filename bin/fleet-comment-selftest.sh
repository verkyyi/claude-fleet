#!/bin/bash
# fleet-comment-selftest.sh — hermetic smoke test for bin/fleet-comment.sh's
# per-role sender footer (issue #224).
#
# Drives the real fleet-comment.sh + fleet-lib.sh against a FAKE gh + tmux (no
# network, no tmux server): the fake gh records the --body it would post into
# $BODYFILE, the fake tmux answers @issue / @scout / session_name from FAKE_*
# env, so every role path is deterministic. Asserts the issue's contract:
#   (a) the visible signature line carries the correct role WORD, with NO emoji /
#       glyph (only the em-dash + middle-dot separators are allowed);
#   (b) the `<!-- fleet:from role=… -->` machine marker is present + parseable;
#   (c) `<!-- fleet:no-relay -->` stays verbatim AND last for a --note comment
#       (the loop-safety rail bin/fleet-issue-bridge.sh greps as a substring);
#   (d) a --to-worker (relayed) comment gets the footer but NO no-relay marker;
#   (e) explicit --from overrides auto-detection;
#   (f) --no-footer suppresses the footer but KEEPS no-relay;
#   (g) no $(hostname) / $USER leak;
#   plus role auto-detection (worker/scout/steward/generic), idempotency, and the
#   watcher path preserving the separate `<!-- fleet:wake … -->` coalescing marker
#   + never inflating the bridge's `- ` wake-line count.
#
# Exit 0 = pass. Non-zero = fail (prints the captured body).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/fleet-comment.sh"
[ -x "$SRC" ] || { printf 'selftest: %s not found/executable\n' "$SRC" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fcs-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/wt/issue-10"
FAKEPATH="$WORK/fakepath"
FCS="$WORK/bin/fleet-comment.sh"
BODYFILE="$WORK/body.txt"; : > "$BODYFILE"
MARKER='<!-- fleet:no-relay -->'

# real fleet-comment.sh + lib, run from $WORK/bin so BIN resolves the copies and
# ../fleet.conf is absent (env FLEET_REPO wins) — fully hermetic.
cp "$SRC" "$FCS"; cp "$BIN/fleet-lib.sh" "$WORK/bin/fleet-lib.sh"
chmod +x "$FCS"

# --- fake gh: record the --body of `gh issue comment` into $BODYFILE -----------
cat > "$FAKEPATH/gh" <<'FAKE'
#!/bin/bash
if [ "$1" = issue ] && [ "$2" = comment ]; then
  body=''
  while [ "$#" -gt 0 ]; do case "$1" in --body) shift; body="$1";; esac; shift; done
  printf '%s' "$body" > "$BODYFILE"
  echo "https://example.test/issue/comment/1"
  exit 0
fi
exit 0
FAKE
chmod +x "$FAKEPATH/gh"

# --- fake tmux: answer display-message from FAKE_* env; no server needed --------
cat > "$FAKEPATH/tmux" <<'FAKE'
#!/bin/bash
if [ "${1:-}" = -L ] || [ "${1:-}" = -S ]; then shift 2; fi
case "${1:-}" in
  display-message)
    case "$*" in
      *@issue*)       printf '%s' "${FAKE_ISSUE:-}" ;;
      *@scout*)       printf '%s' "${FAKE_SCOUT:-}" ;;
      *session_name*) printf '%s' "${FAKE_SESSION:-}" ;;
    esac ;;
esac
exit 0
FAKE
chmod +x "$FAKEPATH/tmux"

fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         printf -- '--- body ---\n' >&2; cat "$BODYFILE" >&2 2>/dev/null
         printf '\n--- end ---\n' >&2; exit 1; }

# Run fleet-comment.sh in a controlled env. Per-test knobs are shell vars set by
# the caller: RUNDIR (cwd), FAKE_ISSUE/FAKE_SCOUT/FAKE_SESSION, FLEET_SEAT. The
# vars are explicitly forwarded (a prefix assignment to a function is NOT exported
# to its grandchild bash). BODYFILE goes into the env so the fake gh can find it.
fc() {
  : > "$BODYFILE"
  ( cd "${RUNDIR:-$WORK}" 2>/dev/null || exit 3
    PATH="$FAKEPATH:$PATH" \
    FLEET_REPO="test/repo" \
    TMUX_PANE="" \
    BODYFILE="$BODYFILE" \
    FAKE_ISSUE="${FAKE_ISSUE:-}" \
    FAKE_SCOUT="${FAKE_SCOUT:-}" \
    FAKE_SESSION="${FAKE_SESSION:-}" \
    FLEET_SEAT="${FLEET_SEAT:-}" \
      bash "$FCS" "$@" >/dev/null 2>&1
  )
}

# Reset the per-test knobs to a neutral baseline (no seat signals, a session name).
reset() { RUNDIR="$WORK"; FAKE_ISSUE=''; FAKE_SCOUT=''; FAKE_SESSION='fleet-testrepo'; FLEET_SEAT=''; }

# Assert the visible signature line has no emoji/glyph: strip the two ALLOWED
# separators (em-dash U+2014 = \342\200\224, middle-dot U+00B7 = \302\267) byte-wise
# under LC_ALL=C, then any remaining non-ASCII byte is an emoji/glyph → fail.
assert_no_emoji() { # $1=label
  local vis stripped
  vis=$(grep '^— ' "$BODYFILE" 2>/dev/null)
  [ -n "$vis" ] || fail "$1: no '— ' visible signature line found"
  stripped=$(printf '%s' "$vis" | LC_ALL=C tr -d '\342\200\224\302\267')
  printf '%s' "$stripped" | LC_ALL=C grep -q '[^ -~]' \
    && fail "$1: the visible signature line contains an emoji/glyph (only — and · are allowed)"
  return 0
}

# ============================== (a)+(b)+(c) worker (auto-detect) ================
# A worker window: cwd inside an issue-<N> worktree + @issue set → role 'worker'.
reset; RUNDIR="$WORK/wt/issue-10"; FAKE_ISSUE=10
fc 10 --note --body 'did the thing' || fail "worker --note exited non-zero"
grep -qxF '— fleet · worker · #10' "$BODYFILE" \
  || fail "(a) worker: visible signature line '— fleet · worker · #10' missing"
assert_no_emoji "(a) worker"
mkline=$(grep -F '<!-- fleet:from ' "$BODYFILE" | head -n1)
[ -n "$mkline" ] || fail "(b) worker: fleet:from marker missing"
mrole=$(printf '%s' "$mkline" | sed -n 's/.*role=\([^ ]*\).*/\1/p')
[ "$mrole" = worker ] || fail "(b) worker: marker role should parse to 'worker', got '$mrole'"
printf '%s' "$mkline" | grep -qF 'issue=10' || fail "(b) worker: marker should carry issue=10"
printf '%s' "$mkline" | grep -qF 'session=fleet-testrepo' || fail "(b) worker: marker should carry the session"
grep -qF "$MARKER" "$BODYFILE" || fail "(c) worker: no-relay marker missing on a --note comment"
[ "$(tail -n1 "$BODYFILE")" = "$MARKER" ] || fail "(c) worker: no-relay marker must be the LAST line"
# constraint #1 corollary: the visible line must not read as a bridge wake '- ' line
grep -q '^- ' "$BODYFILE" && fail "worker: the footer must not introduce a '- ' line (would inflate the bridge wake count)"
printf 'selftest: worker leg PASS (auto-detect, visible+marker+no-relay-last, no emoji)\n' >&2

# ============================== scout (auto-detect) ============================
# Same worktree/@issue but the window is marked @scout → role 'scout'.
reset; RUNDIR="$WORK/wt/issue-10"; FAKE_ISSUE=10; FAKE_SCOUT=1
fc 10 --note --body 'scouted' || fail "scout --note exited non-zero"
grep -qxF '— fleet · scout · #10' "$BODYFILE" \
  || fail "scout: visible signature '— fleet · scout · #10' missing (worker+@scout should resolve to scout)"
printf '%s' "$(grep -F '<!-- fleet:from ' "$BODYFILE")" | grep -qF 'role=scout' \
  || fail "scout: marker role should be scout"
assert_no_emoji "scout"
printf 'selftest: scout leg PASS (worker seat + @scout → scout)\n' >&2

# ============================== steward (auto via FLEET_SEAT) ==================
# The steward hub exports FLEET_SEAT=steward (steward-session.sh); it has no @issue,
# so the context falls to the fleet session name.
reset; FLEET_SEAT=steward
fc 30 --note --body 'triaged #30' || fail "steward --note exited non-zero"
grep -qxF '— fleet · steward · fleet-testrepo' "$BODYFILE" \
  || fail "steward: visible signature '— fleet · steward · fleet-testrepo' missing (no @issue → session context)"
printf '%s' "$(grep -F '<!-- fleet:from ' "$BODYFILE")" | grep -qF 'role=steward' \
  || fail "steward: marker role should be steward"
assert_no_emoji "steward"
printf 'selftest: steward leg PASS (FLEET_SEAT=steward → steward, session context)\n' >&2

# ============================== generic fallback ==============================
# No seat signals at all + no session name → generic 'fleet', context = repo slug.
# The brand word must NOT double ('fleet · fleet').
reset; FAKE_SESSION=''
fc 9 --note --body 'orphan note' || fail "generic --note exited non-zero"
grep -qxF '— fleet · test-repo' "$BODYFILE" \
  || fail "generic: visible signature '— fleet · test-repo' missing (slug context, deduped brand word)"
grep -qF '— fleet · fleet' "$BODYFILE" && fail "generic: the brand word must not double ('fleet · fleet')"
printf '%s' "$(grep -F '<!-- fleet:from ' "$BODYFILE")" | grep -qF 'role=fleet' \
  || fail "generic: marker role should be the generic 'fleet'"
assert_no_emoji "generic"
printf 'selftest: generic leg PASS (no signals → fleet, no doubled brand word)\n' >&2

# ============================== (e) --from overrides ==========================
# In a worker seat, --from dash must WIN over the auto-detected worker.
reset; RUNDIR="$WORK/wt/issue-10"; FAKE_ISSUE=10
fc 10 --from dash --note --body 'triage from the backlog' || fail "--from dash exited non-zero"
grep -qxF '— fleet · dash · #10' "$BODYFILE" \
  || fail "(e) --from dash must override the auto-detected worker seat"
printf '%s' "$(grep -F '<!-- fleet:from ' "$BODYFILE")" | grep -qF 'role=dash' \
  || fail "(e) marker role should be the forced 'dash'"
printf 'selftest: --from override leg PASS (explicit role beats auto-detect)\n' >&2

# ============================== (d) --to-worker (relayed) =====================
# A relayed comment gets the footer but must stay RELAYABLE → no no-relay marker.
reset; FLEET_SEAT=steward
fc 40 --to-worker --body 'the steward instructs you' || fail "--to-worker exited non-zero"
grep -qF '<!-- fleet:from ' "$BODYFILE" || fail "(d) --to-worker should still carry the footer marker"
grep -q '^— fleet · steward' "$BODYFILE" || fail "(d) --to-worker should carry the visible signature"
grep -qF "$MARKER" "$BODYFILE" && fail "(d) --to-worker must NOT carry the no-relay marker (stays relayable)"
printf 'selftest: --to-worker leg PASS (footer present, no no-relay)\n' >&2

# ============================== (f) --no-footer ==============================
# --no-footer drops the signature+marker but must KEEP the loop-safety no-relay.
reset; RUNDIR="$WORK/wt/issue-10"; FAKE_ISSUE=10
fc 10 --no-footer --note --body 'quiet record' || fail "--no-footer exited non-zero"
grep -qF '<!-- fleet:from ' "$BODYFILE" && fail "(f) --no-footer must suppress the fleet:from marker"
grep -q '^— fleet' "$BODYFILE" && fail "(f) --no-footer must suppress the visible signature line"
grep -qF "$MARKER" "$BODYFILE" || fail "(f) --no-footer must still keep the no-relay loop-safety marker"
[ "$(tail -n1 "$BODYFILE")" = "$MARKER" ] || fail "(f) --no-footer: no-relay must still be last"
printf 'selftest: --no-footer leg PASS (footer suppressed, no-relay kept + last)\n' >&2

# ============================== idempotency (re-stamp safe) ===================
# Feeding a body that ALREADY carries the footer must not duplicate it.
reset; RUNDIR="$WORK/wt/issue-10"; FAKE_ISSUE=10
already=$'shipped\n\n— fleet · worker · #10\n<!-- fleet:from role=worker session=fleet-testrepo issue=10 -->\n<!-- fleet:no-relay -->'
fc 10 --note --body "$already" || fail "idempotent re-stamp exited non-zero"
nfrom=$(grep -cF '<!-- fleet:from ' "$BODYFILE")
[ "$nfrom" = 1 ] || fail "idempotency: expected exactly ONE fleet:from marker after re-stamp, got $nfrom"
nrelay=$(grep -cF "$MARKER" "$BODYFILE")
[ "$nrelay" = 1 ] || fail "idempotency: expected exactly ONE no-relay marker after re-stamp, got $nrelay"
printf 'selftest: idempotency leg PASS (re-stamp does not duplicate the footer)\n' >&2

# ============================== (g) no identifier leak ========================
# The footer identifies role + fleet ONLY — never the host or the OS user.
reset; RUNDIR="$WORK/wt/issue-10"; FAKE_ISSUE=10
fc 10 --note --body 'leak probe' || fail "leak-probe exited non-zero"
HN=$(hostname 2>/dev/null); UN=$(id -un 2>/dev/null)
[ -n "$HN" ] && grep -qF "$HN" "$BODYFILE" && fail "(g) the footer leaked the hostname ($HN)"
[ -n "$UN" ] && grep -qF "$UN" "$BODYFILE" && fail "(g) the footer leaked the OS user ($UN)"
printf 'selftest: no-leak leg PASS (no hostname / OS-user in the footer)\n' >&2

# ============================== watcher path (coalesce-safe) ==================
# The watcher posts via --to-worker --from watcher. The footer must NOT disturb the
# body's `- ` wake-edge lines nor the separate `<!-- fleet:wake … -->` coalescing
# marker the issue-bridge greps + counts (constraint #1 / issue #198).
reset; FLEET_SEAT=''   # watcher runs headless (no seat env)
wakebody=$'- PR #196 (#181) green — /land 196?\n- #7 shipped PR #70 — review?\n<!-- fleet:wake test-repo:196 pr:test-repo:70 -->'
fc 146 --to-worker --from watcher --body "$wakebody" || fail "watcher wake exited non-zero"
grep -q '^— fleet · watcher' "$BODYFILE" || fail "watcher: visible signature missing"
grep -qF "$MARKER" "$BODYFILE" && fail "watcher: a relayed wake must not carry no-relay"
grep -qF '<!-- fleet:wake test-repo:196 pr:test-repo:70 -->' "$BODYFILE" \
  || fail "watcher: the separate fleet:wake coalescing marker must be preserved verbatim"
edges=$(grep -c '^- ' "$BODYFILE")
[ "$edges" = 2 ] || fail "watcher: expected exactly 2 '- ' wake lines (footer must not add/remove any), got $edges"
printf 'selftest: watcher leg PASS (footer preserves wake edges + fleet:wake marker)\n' >&2

printf 'selftest PASS: footer role-resolution (worker/scout/steward/generic) + --from override + --to-worker + --no-footer + idempotency + no-leak + no-emoji + watcher-coalesce-safe verified\n'
exit 0
