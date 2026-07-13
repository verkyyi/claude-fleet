#!/bin/bash
# dash-issue-session-prompt-selftest.sh — hermetic tests for the COLLAPSED worker
# seed (issues #234, #283, #299). Since issue #299 the seed the spawn writes is a
# BARE `/fleet-claim`: claude expands the slash command on the initial prompt and
# the skill carries the WHOLE lifecycle (claim → charter → ground → implement →
# open PR + arm auto-merge → STOP), self-discovering its issue from @issue. So the
# seed no longer embeds the issue-binding head, a claim line, the per-fleet body,
# or a ship tail — all of that moved INTO /fleet-claim.
#
# Two layers, tested where they now live:
#   SEED — drive the real spawn (git/gh/tmux faked on PATH, temp dirs, no network)
#          and assert the task file it writes is EXACTLY `/fleet-claim`, is STABLE
#          under a FLEET_WORKER_PROMPT override (the body no longer rides the seed),
#          and carries NONE of the retired paragraph pieces or retired skills.
#   BODY — the per-fleet customizable implementation directive (FLEET_WORKER_PROMPT
#          / _FILE) is now woven in by the skill at runtime via
#          fleet_worker_prompt_body, so we test that FUNCTION directly: default,
#          override, trailing-ender strip, {issue}/{repo} substitution, a prompt
#          FILE winning + carrying multi-line content, and an unreadable file
#          warning + falling back to the default.
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
  # This test is about the SEED, not the cross-machine claim dedup (issue #258, on
  # by default) — opt out so the fake gh (which returns a title for any `issue
  # view`) isn't parsed as a claim ledger and the spawn refuses. Its own selftest
  # covers the dedup.
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/dash" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH="master" \
  FLEET_PRESPAWN_DEDUP=0 \
    "$SPAWN" "$@" >"$WORK/spawn.out" 2>"$WORK/spawn.err"
}
# The seed is written to $TMPDIR/.claude-dash/fleets/<slug>/task_issue-<N>.txt.
seedfile() { ls "$WORK"/dash/.claude-dash/fleets/*/task_issue-234.txt 2>/dev/null | head -1; }
seed()     { local f; f=$(seedfile); [ -n "$f" ] && cat "$f"; }
has()      { case "$(seed)" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# ===== SEED A: the collapsed seed is EXACTLY a bare /fleet-claim ================
run_spawn 234
[ -n "$(seedfile)" ] || fail "A no seed task file was written" "$(cat "$WORK/spawn.err")"
[ "$(seed)" = "/fleet-claim" ] \
  || fail "A the collapsed seed must be exactly the bare slash command /fleet-claim" "$(seed)"
ok "A the worker seed collapsed to a bare /fleet-claim"

# ===== SEED B: the seed is STABLE under FLEET_WORKER_PROMPT (body left the seed) =
FLEET_WORKER_PROMPT='Follow CONTRIBUTING and add coverage' run_spawn 234
[ "$(seed)" = "/fleet-claim" ] \
  || fail "B FLEET_WORKER_PROMPT must NOT change the seed — the body moved into the skill" "$(seed)"
FLEET_WORKER_PROMPT_FILE="$WORK/whatever.txt" run_spawn 234
[ "$(seed)" = "/fleet-claim" ] \
  || fail "B FLEET_WORKER_PROMPT_FILE must NOT change the seed either" "$(seed)"
ok "B the seed is stable regardless of the per-fleet body override"

# ===== SEED C: the collapsed seed drops the retired paragraph + retired skills ==
run_spawn 234
# The old assembly (issue-binding head, claim line, per-fleet body, ship tail) and
# the retired self-land/ship/blocked text must NOT reappear in the seed.
for gone in 'Work GitHub issue' 'To finish:' 'arm GitHub auto-merge' \
            'do NOT merge it yourself' 'com.claude-fleet.cleanup' \
            'Implement and verify per the repo conventions' \
            '/fleet-ship' '/fleet-blocked' '/fleet-land-self' 'FLEET_SELF_LAND'; do
  ! has "$gone" || fail "C retired seed text '$gone' leaked back into the collapsed seed" "$(seed)"
done
ok "C the collapsed seed carries none of the retired paragraph pieces or skills"

# ===== BODY: fleet_worker_prompt_body (the per-fleet directive the skill weaves in)
# The skill (/fleet-claim step 4) now calls this at runtime instead of the spawn
# baking it into the seed — so its behaviour is tested directly here.
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
unset FLEET_WORKER_PROMPT FLEET_WORKER_PROMPT_FILE

# D: default (no override) is the built-in instruction, verbatim.
[ "$(fleet_worker_prompt_body 234 acme/widgets)" = 'Implement and verify per the repo conventions' ] \
  || fail "D default body should be the built-in instruction" "$(fleet_worker_prompt_body 234 acme/widgets)"
ok "D fleet_worker_prompt_body default is the built-in instruction"

# E: FLEET_WORKER_PROMPT replaces the body.
got=$(FLEET_WORKER_PROMPT='Follow CONTRIBUTING and add coverage' fleet_worker_prompt_body 234 acme/widgets)
[ "$got" = 'Follow CONTRIBUTING and add coverage' ] \
  || fail "E FLEET_WORKER_PROMPT should replace the default body" "$got"
ok "E FLEET_WORKER_PROMPT replaces the default body"

# F: a trailing sentence-ender is stripped (so it flows cleanly wherever it's woven).
got=$(FLEET_WORKER_PROMPT='Do the thing.' fleet_worker_prompt_body 234 acme/widgets)
[ "$got" = 'Do the thing' ] || fail "F a trailing period should be stripped" "$got"
ok "F a trailing sentence-ender in the override is stripped"

# G: {issue}/{repo} placeholders are substituted.
got=$(FLEET_WORKER_PROMPT='Handle {issue} in {repo}' fleet_worker_prompt_body 234 acme/widgets)
[ "$got" = 'Handle 234 in acme/widgets' ] || fail "G {issue}/{repo} were not substituted" "$got"
ok "G {issue}/{repo} placeholders are substituted"

# H: FLEET_WORKER_PROMPT_FILE wins over the inline value and carries multi-line
#    content; an unreadable file warns on stderr and falls back to the default.
printf 'First custom line for {issue}.\nSecond line for {repo}.\n' > "$WORK/tmpl.txt"
got=$(FLEET_WORKER_PROMPT='inline-should-lose' FLEET_WORKER_PROMPT_FILE="$WORK/tmpl.txt" \
        fleet_worker_prompt_body 234 acme/widgets)
case "$got" in *inline-should-lose*) fail "H a readable prompt FILE must win over the inline value" "$got" ;; esac
case "$got" in *'First custom line for 234.'*) : ;; *) fail "H prompt file line 1 missing (subst)" "$got" ;; esac
case "$got" in *'Second line for acme/widgets'*) : ;; *) fail "H prompt file line 2 missing (multi-line lost)" "$got" ;; esac
got=$(FLEET_WORKER_PROMPT_FILE="$WORK/nope.txt" fleet_worker_prompt_body 234 acme/widgets 2>"$WORK/body.err")
[ "$got" = 'Implement and verify per the repo conventions' ] \
  || fail "H an unreadable prompt file should fall back to the default body" "$got"
grep -q 'FLEET_WORKER_PROMPT_FILE not readable' "$WORK/body.err" \
  || fail "H an unreadable prompt file should warn on stderr" "$(cat "$WORK/body.err")"
ok "H prompt FILE wins + is multi-line; an unreadable file warns and falls back"

printf '\nselftest OK: %s assertions passed (collapsed /fleet-claim seed + per-fleet body)\n' "$pass"
exit 0
