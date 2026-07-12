#!/bin/bash
# dash-issue-session-prompt-selftest.sh — hermetic tests for the per-fleet
# customizable worker seed prompt (issues #234, #283). Since issue #283 the seed
# COLLAPSES to essentially "run /fleet-claim" (the skill carries the whole
# lifecycle). The BODY of an implementing worker's one-shot seed — the clause
# between the /fleet-claim ritual and the "open the PR + arm auto-merge, then STOP"
# tail — is overridable per fleet via FLEET_WORKER_PROMPT / FLEET_WORKER_PROMPT_FILE,
# while the structural pieces (issue-binding head, /fleet-claim ritual, the ship+stop
# tail) are always kept intact. No network, no real repo, no tmux server — git/gh/tmux
# are faked on PATH. We read the SEED the spawn wrote to its task file and assert.
#
#   A. DEFAULT (no override) joins the body into the tail with a SINGLE period:
#      "…conventions. To finish: verify, push…" — proving a clean seam.
#   B. FLEET_WORKER_PROMPT replaces the body; the /fleet-claim ritual + the ship
#      tail (structural, "do NOT merge it yourself") are still present.
#   C. a trailing sentence-ender in the override is stripped so the tail seam
#      stays clean (no "thing.. To finish").
#   D. {issue}/{repo} placeholders are substituted.
#   E. FLEET_WORKER_PROMPT_FILE wins over the inline value and carries multi-line
#      content verbatim; an unreadable file warns and falls back to the default.
#   F. every worker seed arms auto-merge (the tail names it) and carries NEITHER a
#      retired self-land instruction NOR a reference to the retired /fleet-ship or
#      /fleet-blocked skills (issue #283 folded them into /fleet-claim).
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SPAWN="$BIN/dash-issue-session.sh"
[ -x "$SPAWN" ] || { echo "selftest: $SPAWN missing/not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wprompt-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/main/.git" "$WORK/fakebin" "$WORK/conf" "$WORK/dash"

# --- fake git: worktree/fetch/branch succeed; report a branch + toplevel ---------
cat > "$WORK/fakebin/git" <<'GITFAKE'
#!/bin/bash
if [ "${1:-}" = "-C" ]; then shift 2; fi
case "${1:-}" in
  rev-parse)
    case "$*" in
      *--abbrev-ref*)    printf '%s\n' "${GIT_BRANCH:-issue-234}" ;;
      *--show-toplevel*) pwd -P ;;
      *) printf 'deadbeef\n' ;;
    esac ;;
  *) : ;;   # fetch / worktree / branch → succeed silently
esac
exit 0
GITFAKE

# --- fake gh: issue view returns a title (used for the window name only) ---------
cat > "$WORK/fakebin/gh" <<'GHFAKE'
#!/bin/bash
case "${1:-} ${2:-}" in
  "issue view") printf '%s\n' "${GH_TITLE:-Some Issue Title}" ;;
  *) : ;;
esac
exit 0
GHFAKE

# --- fake tmux: query via -p; everything else is a no-op (we don't inspect it) ---
cat > "$WORK/fakebin/tmux" <<'TMUXFAKE'
#!/bin/bash
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then shift 2; fi
case "${1:-}" in
  display-message)
    case "$*" in
      *-p*)
        case "$*" in
          *window_id*)    echo "${TMUX_WIN:-@9}" ;;
          *session_name*) echo 'testsess' ;;
          *) echo '' ;;
        esac ;;
      *) : ;;
    esac ;;
  list-windows)      : ;;
  show-options)      echo '' ;;
  new-window)        echo "${TMUX_WIN:-@9}" ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/git" "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

# Run the spawn in a clean per-fleet dir so nothing carries over, then echo the
# path to the seed task file it wrote. Extra FLEET_* overrides come in via env.
run_spawn() { # $@ = args to dash-issue-session.sh
  rm -rf "$WORK/dash/.claude-dash/fleets"
  # This test is about the SEED PROMPT, not the cross-machine claim dedup (issue
  # #258, on by default) — opt out so the fake gh (which returns a title for any
  # `issue view`) isn't parsed as a claim ledger and the spawn refuses. Its own
  # selftest covers the dedup.
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/dash" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH="master" \
  FLEET_PRESPAWN_DEDUP=0 \
    "$SPAWN" "$@" >"$WORK/spawn.out" 2>"$WORK/spawn.err"
}
# The seed is written to $TMPDIR/.claude-dash/fleets/<slug>/task_issue-<N>.txt.
seedfile() { ls "$WORK"/dash/.claude-dash/fleets/*/task_issue-234.txt 2>/dev/null | head -1; }
seed()     { local f; f=$(seedfile); [ -n "$f" ] && cat "$f"; }
has()      { case "$(seed)" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# ===== A: default seam is a clean single-period join ==========================
run_spawn 234
[ -n "$(seedfile)" ] || fail "A no seed task file was written" "$(cat "$WORK/spawn.err")"
has 'Work GitHub issue #234 in this repo.' || fail "A default seed lost the issue-binding head" "$(seed)"
has '/fleet-claim' || fail "A default seed lost the /fleet-claim ritual" "$(seed)"
has 'Implement and verify per the repo conventions. To finish: verify, push' \
  || fail "A default body→tail seam changed (expected single-period join)" "$(seed)"
ok "A default worker seed joins body→tail cleanly (single period)"

# ===== B: FLEET_WORKER_PROMPT replaces the body; structure intact ==============
FLEET_WORKER_PROMPT='Follow CONTRIBUTING and add coverage' run_spawn 234
has 'Follow CONTRIBUTING and add coverage. To finish: verify, push' \
  || fail "B override body should replace the default and flow into the tail" "$(seed)"
has 'Implement and verify per the repo conventions' \
  && fail "B override should REMOVE the default body" "$(seed)"
has '/fleet-claim' || fail "B override must keep the /fleet-claim ritual" "$(seed)"
has 'do NOT merge it yourself' \
  || fail "B override must keep the 'do NOT merge it yourself' ship tail" "$(seed)"
ok "B FLEET_WORKER_PROMPT replaces the body while keeping the structural seed"

# ===== C: trailing sentence-ender stripped so the seam stays clean =============
FLEET_WORKER_PROMPT='Do the thing.' run_spawn 234
has 'Do the thing. To finish: verify, push' \
  || fail "C a trailing period should be stripped before the tail" "$(seed)"
has 'Do the thing.. To finish' && fail "C double-period seam not de-duplicated" "$(seed)"
ok "C a trailing sentence-ender in the override is stripped at the seam"

# ===== D: {issue}/{repo} placeholders substituted =============================
FLEET_WORKER_PROMPT='Handle {issue} in {repo}' run_spawn 234
has 'Handle 234 in acme/widgets. To finish' \
  || fail "D {issue}/{repo} placeholders were not substituted" "$(seed)"
ok "D {issue}/{repo} placeholders are substituted in the body"

# ===== E: FLEET_WORKER_PROMPT_FILE wins + multi-line; bad file falls back ======
printf 'First custom line for {issue}.\nSecond line for {repo}.\n' > "$WORK/tmpl.txt"
FLEET_WORKER_PROMPT='inline-should-lose' FLEET_WORKER_PROMPT_FILE="$WORK/tmpl.txt" run_spawn 234
has 'inline-should-lose' && fail "E a readable prompt FILE must win over the inline value" "$(seed)"
has 'First custom line for 234.' || fail "E prompt file line 1 missing (subst)" "$(seed)"
has 'Second line for acme/widgets' || fail "E prompt file line 2 missing (multi-line lost)" "$(seed)"
# unreadable file → warn on stderr, fall back to default body
FLEET_WORKER_PROMPT_FILE="$WORK/nope.txt" run_spawn 234
has 'Implement and verify per the repo conventions. To finish' \
  || fail "E an unreadable prompt file should fall back to the default body" "$(seed)"
grep -q 'FLEET_WORKER_PROMPT_FILE not readable' "$WORK/spawn.err" \
  || fail "E an unreadable prompt file should warn on stderr" "$(cat "$WORK/spawn.err")"
ok "E prompt FILE wins + is multi-line; an unreadable file warns and falls back"

# ===== F: the collapsed seed arms auto-merge, drops retired skills + self-land ==
run_spawn 234
has 'arm GitHub auto-merge' || fail "F default seed must arm auto-merge" "$(seed)"
has 'com.claude-fleet.cleanup' || fail "F seed should name the cleanup daemon" "$(seed)"
# Retired skills (issue #283 folded them into /fleet-claim) must not be named.
for gone in '/fleet-ship' '/fleet-blocked' \
            '/fleet-land-self' 'FLEET_SELF_LAND' 'do NOT merge — WAIT' \
            'triggers the land by commenting' 'the steward reviews and lands'; do
  case "$(seed)" in *"$gone"*) fail "F retired text '$gone' leaked into the collapsed seed" "$(seed)" ;; esac
done
ok "F the worker seed arms auto-merge and drops the retired /fleet-ship, /fleet-blocked + self-land text"

printf '\nselftest OK: %s assertions passed (per-fleet worker seed prompt)\n' "$pass"
exit 0
