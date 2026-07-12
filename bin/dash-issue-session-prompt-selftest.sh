#!/bin/bash
# dash-issue-session-prompt-selftest.sh — hermetic tests for the per-fleet
# customizable worker seed prompt (issue #234). The BODY of an implementing
# worker's one-shot seed — the clause between the /fleet-claim ritual and the
# /fleet-ship + steward-lands|self-land tail — is overridable per fleet via
# FLEET_WORKER_PROMPT / FLEET_WORKER_PROMPT_FILE, while the structural pieces
# (issue-binding head, /fleet-claim, the ship/land tail) are always kept intact.
# No network, no real repo, no tmux server — git/gh/tmux are faked on PATH (same
# shape as dash-issue-session-name-selftest.sh). We read the SEED the spawn wrote
# to its task file and assert on its contents.
#
#   A. DEFAULT (no override) is byte-identical at the seam: the body flows into
#      the steward-lands tail as "…conventions. To finish, run /fleet-ship" with a
#      SINGLE period — proving the refactor didn't change historic behavior.
#   B. FLEET_WORKER_PROMPT replaces the body; the /fleet-claim ritual + the ship
#      tail (structural) are still present.
#   C. a trailing sentence-ender in the override is stripped so the tail seam
#      stays clean (no "thing.. To finish").
#   D. {issue}/{repo} placeholders are substituted.
#   E. FLEET_WORKER_PROMPT_FILE wins over the inline value and carries multi-line
#      content verbatim; an unreadable file warns and falls back to the default.
#   F. --self-land still appends the self-land tail after a custom body (structural
#      tail intact regardless of the body override).
#   G. --scout ignores the override entirely (a scout has its own read-only seed).
#   H. FLEET_SELF_LAND=auto seeds the trigger-free AUTO tail (issue #270): flows
#      straight into /fleet-land-self, no WAIT / no /land trigger language.
#   I. FLEET_SELF_LAND=1 keeps the steward-TRIGGERED tail (waits for /land).
#   J. the --self-land=auto flag seeds auto; bare --self-land stays triggered.
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

# ===== A: default seam is byte-identical (steward-lands) =======================
run_spawn 234
[ -n "$(seedfile)" ] || fail "A no seed task file was written" "$(cat "$WORK/spawn.err")"
has 'Work GitHub issue #234 in this repo.' || fail "A default seed lost the issue-binding head" "$(seed)"
has '/fleet-claim' || fail "A default seed lost the /fleet-claim ritual" "$(seed)"
has 'Implement and verify per the repo conventions. To finish, run /fleet-ship' \
  || fail "A default body→tail seam changed (expected single-period join)" "$(seed)"
ok "A default worker seed is unchanged at the body→tail seam"

# ===== B: FLEET_WORKER_PROMPT replaces the body; structure intact ==============
FLEET_WORKER_PROMPT='Follow CONTRIBUTING and add coverage' run_spawn 234
has 'Follow CONTRIBUTING and add coverage. To finish, run /fleet-ship' \
  || fail "B override body should replace the default and flow into the tail" "$(seed)"
has 'Implement and verify per the repo conventions' \
  && fail "B override should REMOVE the default body" "$(seed)"
has '/fleet-claim' || fail "B override must keep the /fleet-claim ritual" "$(seed)"
has 'do NOT merge it yourself; the steward reviews and lands it' \
  || fail "B override must keep the steward-lands ship tail" "$(seed)"
ok "B FLEET_WORKER_PROMPT replaces the body while keeping the structural seed"

# ===== C: trailing sentence-ender stripped so the seam stays clean =============
FLEET_WORKER_PROMPT='Do the thing.' run_spawn 234
has 'Do the thing. To finish, run /fleet-ship' \
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

# ===== F: --self-land keeps the self-land tail after a custom body =============
FLEET_WORKER_PROMPT='Ship it carefully' run_spawn 234 --self-land
has 'Ship it carefully, then run /fleet-ship' \
  || fail "F self-land body should flow into the ', then run /fleet-ship' tail" "$(seed)"
has '/fleet-land-self' || fail "F self-land tail (structural) was dropped" "$(seed)"
ok "F --self-land keeps its structural tail regardless of the body override"

# ===== G: --scout ignores the override (own read-only seed) ====================
FLEET_WORKER_PROMPT='THIS-MUST-NOT-APPEAR' run_spawn 234 --scout
has 'THIS-MUST-NOT-APPEAR' && fail "G a scout must ignore FLEET_WORKER_PROMPT" "$(seed)"
has 'READ-ONLY scout' || fail "G scout seed missing its read-only framing" "$(seed)"
has 'do NOT implement' || fail "G scout seed missing its no-implement rail" "$(seed)"
ok "G --scout ignores FLEET_WORKER_PROMPT and keeps its read-only seed"

# ===== H: FLEET_SELF_LAND=auto → the AUTO tail (no trigger, no wait) ============
# Issue #270: the steward trigger becomes optional; /fleet-ship flows straight into
# /fleet-land-self. The auto tail must NOT carry the triggered-mode WAIT language.
FLEET_SELF_LAND=auto run_spawn 234
has '/fleet-land-self' || fail "H auto mode must still seed the self-land tail" "$(seed)"
has 'FLEET_SELF_LAND=auto' || fail "H auto tail should name the auto mode" "$(seed)"
has 'No /land comment is required' \
  || fail "H auto tail must say no /land trigger is required" "$(seed)"
has 'run /fleet-land-self IMMEDIATELY' \
  || fail "H auto tail must flow straight into /fleet-land-self" "$(seed)"
case "$(seed)" in
  *'do NOT merge — WAIT'*) fail "H auto tail must NOT carry the triggered-mode WAIT" "$(seed)" ;;
  *'triggers the land by commenting'*) fail "H auto tail must NOT mention the /land trigger" "$(seed)" ;;
esac
ok "H FLEET_SELF_LAND=auto seeds the trigger-free auto self-land tail"

# ===== I: FLEET_SELF_LAND=1 → the TRIGGERED tail (waits for /land) ==============
FLEET_SELF_LAND=1 run_spawn 234
has 'do NOT merge — WAIT' || fail "I =1 must seed the triggered wait-for-/land tail" "$(seed)"
has 'triggers the land by commenting' || fail "I =1 tail must mention the /land trigger" "$(seed)"
has 'FLEET_SELF_LAND=auto' && fail "I =1 must NOT emit the auto-mode tail" "$(seed)"
ok "I FLEET_SELF_LAND=1 seeds the steward-triggered self-land tail"

# ===== J: --self-land=auto flag matches the =auto conf (flag wins) =============
run_spawn 234 --self-land=auto
has 'run /fleet-land-self IMMEDIATELY' \
  || fail "J --self-land=auto flag should seed the auto tail" "$(seed)"
case "$(seed)" in *'do NOT merge — WAIT'*) fail "J --self-land=auto must not carry the WAIT" "$(seed)" ;; esac
# ...and the bare --self-land flag stays TRIGGERED (back-compat).
run_spawn 234 --self-land
has 'do NOT merge — WAIT' || fail "J bare --self-land must stay steward-triggered" "$(seed)"
ok "J --self-land=auto seeds auto; bare --self-land stays triggered"

printf '\nselftest OK: %s assertions passed (per-fleet worker seed prompt)\n' "$pass"
exit 0
