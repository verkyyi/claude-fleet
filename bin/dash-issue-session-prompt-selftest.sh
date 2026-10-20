#!/bin/bash
# dash-issue-session-prompt-selftest.sh — hermetic tests for a worker's seed
# (issues #234, #299, #3331, #4898). The spawn writes the issue's words (the
# person's, else the title) as the first turn and stamps `@seed_words 1`; the
# SessionStart hook brings the flow. With no words, a Codex worker or
# FLEET_SEED_WORDS=0 the flow rides the first turn as plain words (there is no
# claim command any more — issue #4898).
#
# Two layers, tested where they live:
#   SEED — drive the real spawn (git/gh/tmux faked on PATH, temp dirs, no network)
#          and assert the task file it writes, stable under a FLEET_WORKER_PROMPT
#          override (the directive rides the brief, not the seed), with none of the
#          retired paragraph pieces or skills.
#   BODY — the per-fleet implementation directive (FLEET_WORKER_PROMPT / _FILE),
#          printed by the brief via fleet_worker_prompt_body, tested directly.
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
SPAWN="$BIN/dash-issue-session.sh"
[ -x "$SPAWN" ] || { echo "selftest: $SPAWN missing/not executable" >&2; exit 2; }

st_sandbox "${TMPDIR:-/tmp}/wprompt-selftest.XXXXXX"

pass=0

mkdir -p "$WORK/main/.git" "$WORK/fakebin" "$WORK/conf" "$WORK/dash"
. "$BIN/selftest-repo-fixture.sh"
fx_repo "$WORK/conf" testsess acme/widgets FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH=master

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
  "issue view") printf '%s\n' "${GH_TITLE-Some Issue Title}" ;;
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
  new-window)        [ -n "${NEWWIN_LOG:-}" ] && printf '%s\n' "$*" >> "$NEWWIN_LOG"; echo "${TMUX_WIN:-@9}" ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/git" "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

# Run the spawn in a clean per-fleet dir so nothing carries over, then echo the
# path to the seed task file it wrote. Extra FLEET_* overrides come in via env.
run_spawn() { # $@ = args to dash-issue-session.sh
  rm -rf "$WORK/dash/.claude-dash/fleets"
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/dash" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" FLEET_BASE_BRANCH="master" \
  NEWWIN_LOG="$WORK/newwin" FLEET_CODEX_READY_CHECK=0 \
    "$SPAWN" "$@" >"$WORK/spawn.out" 2>"$WORK/spawn.err"
}
# The seed is written to $TMPDIR/.claude-dash/fleets/<slug>/task_issue-<N>.txt.
seedfile() { ls "$WORK"/dash/.claude-dash/fleets/*/task_issue-234.txt 2>/dev/null | head -1; }
seed()     { local f; f=$(seedfile); [ -n "$f" ] && cat "$f"; }
has()      { case "$(seed)" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# ===== SEED A: the first turn is the issue's own words, the flow rides a stamp ==
# Since issue #3331 (EPIC #3178 ⑧) a Claude worker's first turn is the person's
# words — none typed for a plain issue spawn, so the issue's title — and the
# window is stamped `@seed_words 1` before its agent starts: the SessionStart hook
# (fleet-worker-start-hook.sh) brings the flow. FLEET_SEED_WORDS=0 / no words ⇒
# the flow rides the first turn as words (issue #4898: no claim command).
FLOW='Issue #234 of acme/widgets: call the fleet tool `brief`'
stamped() { grep -qF -- "@seed_words '1'" "$WORK/newwin"; }
: > "$WORK/newwin"; run_spawn 234
[ -n "$(seedfile)" ] || st_fail "A no seed task file was written" "$(cat "$WORK/spawn.err")"
[ "$(seed)" = "Some Issue Title" ] \
  || st_fail "A with no words the first turn must be the issue's title" "$(seed)"
stamped || st_fail "A a words seed must stamp @seed_words before the agent starts" "$(cat "$WORK/newwin")"
: > "$WORK/newwin"; FLEET_SEED_WORDS=0 run_spawn 234
case "$(seed)" in "Some Issue Title"*"$FLOW"*'Closes #234'*) ;; *) st_fail "A FLEET_SEED_WORDS=0: the title, then the flow as words" "$(seed)" ;; esac
stamped && st_fail "A FLEET_SEED_WORDS=0 must stamp no @seed_words" "$(cat "$WORK/newwin")"
: > "$WORK/newwin"; GH_TITLE='' run_spawn 234
case "$(seed)" in "$FLOW"*) ;; *) st_fail "A no words and no title: the flow alone" "$(seed)" ;; esac
stamped && st_fail "A no words: no @seed_words" "$(cat "$WORK/newwin")"
has '/fleet-' && st_fail "A no claim command anywhere (#4898)" "$(seed)"
st_pass "A the first turn is the issue's words + @seed_words; off / no words = the flow as words"

# ===== SEED W: --words-file — the person's words, verbatim (issue #3331) =======
printf '给 hub 加一个 /healthz\n\n要返回 "ok"，别用 $HOME' > "$WORK/words.txt"
: > "$WORK/newwin"; run_spawn 234 --words-file "$WORK/words.txt"
[ "$(seed)" = "$(cat "$WORK/words.txt")" ] || st_fail "W the words file must be the first turn, byte for byte" "$(seed)"
stamped || st_fail "W words ⇒ @seed_words" "$(cat "$WORK/newwin")"
grep -qF 'healthz' "$WORK/newwin" && st_fail "W the words must never ride the new-window command" "$(cat "$WORK/newwin")"
: > "$WORK/words.txt"; run_spawn 234 --words-file "$WORK/words.txt"
[ "$(seed)" = "Some Issue Title" ] || st_fail "W an empty words file falls back to the title" "$(seed)"
printf 'do it' > "$WORK/words.txt"
: > "$WORK/newwin"; run_spawn 234 --words-file "$WORK/words.txt" --agent codex
case "$(seed)" in "do it"*"$FLOW"*) ;; *) st_fail "W a Codex worker: the words, then the flow as words" "$(seed)" ;; esac
stamped && st_fail "W a Codex worker gets no @seed_words" "$(cat "$WORK/newwin")"
st_pass "W --words-file is the first turn verbatim; Codex gets the words + the flow"

# ===== SEED B: the seed is STABLE under FLEET_WORKER_PROMPT (body left the seed) =
FLEET_WORKER_PROMPT='Follow CONTRIBUTING and add coverage' run_spawn 234
[ "$(seed)" = "Some Issue Title" ] \
  || st_fail "B FLEET_WORKER_PROMPT must NOT change the seed — the directive rides the brief" "$(seed)"
FLEET_WORKER_PROMPT_FILE="$WORK/whatever.txt" FLEET_SEED_WORDS=0 run_spawn 234
has 'Follow CONTRIBUTING' && st_fail "B FLEET_WORKER_PROMPT_FILE must NOT change the seed either" "$(seed)"
st_pass "B the seed is stable regardless of the per-fleet body override"

# ===== SEED C: the collapsed seed drops the retired paragraph + retired skills ==
run_spawn 234
# The old assembly (issue-binding head, claim line, per-fleet body, ship tail) and
# the retired self-land/ship/blocked text must NOT reappear in the seed.
for _sw in 1 0; do FLEET_SEED_WORDS=$_sw run_spawn 234
for gone in 'Work GitHub issue' 'To finish:' 'arm GitHub auto-merge' \
            'do NOT merge it yourself' 'com.claude-fleet.cleanup' \
            'Implement and verify per the repo conventions' \
            '/fleet-ship' '/fleet-blocked' '/fleet-land-self' 'FLEET_SELF_LAND'; do
  ! has "$gone" || st_fail "C retired seed text '$gone' leaked back into the collapsed seed" "$(seed)"
done
done
st_pass "C the collapsed seed carries none of the retired paragraph pieces or skills"

# ===== SEED D: --agent rides the launch command, never the seed (issue #547) ====
# A worker launch names the agent file it starts as (`--as fleet-worker`, issue
# #3122) only when that file is there — none in this sandbox, so none here. A per-spawn `--agent codex` reaches bin/fleet-claude.sh as its own flag INSIDE
# the new-window command (the launcher consumes it and execs fleet-codex.sh); the
# seed file is the words + the flow. A default spawn freezes its default
# provider. An unknown token is refused before work.
: > "$WORK/newwin"; run_spawn 234 --agent codex
case "$(seed)" in *"$FLOW"*) ;; *) st_fail "D a Codex seed carries the flow as words" "$(seed)" ;; esac
sed 's/ --as fleet-worker//g' "$WORK/newwin" | grep -qF -- "fleet-session-wrap.sh' --agent codex \"\$(cat '" \
  || st_fail "D --agent codex must sit between the launcher and the seed in the new-window command" "$(cat "$WORK/newwin")"
: > "$WORK/newwin"; run_spawn 234
grep -q -- '--agent claude' "$WORK/newwin" || st_fail "D a default spawn freezes Claude" "$(cat "$WORK/newwin")"
: > "$WORK/newwin"; run_spawn 234 --agent=gemini
[ ! -s "$WORK/newwin" ] || st_fail "D an unknown --agent must open nothing" "$(cat "$WORK/newwin")"
grep -q 'unknown --agent' "$WORK/spawn.err" || st_fail "D an unknown --agent should be reported on stderr" "$(cat "$WORK/spawn.err")"
st_pass "D --agent codex rides the launch command; default is frozen; unknown is refused (#4392)"

# ===== SEED R: a PARKED session's return (--resume + --seed-file, issue #2671) ===
# The same conversation (`--resume <sid>` between the launcher and the seed) and
# the seed file's text as its first turn — only while the transcript is still in
# the worktree's project dir; without it the plain seed, no --resume.
SID=0f0e0d0c-1111-2222-3333-444455556666
printf '[fleet park] read the handoff' > "$WORK/park.seed"
: > "$WORK/newwin"
CLAUDE_PROJECTS_DIR="$WORK/projects" run_spawn 234 --resume "$SID" --seed-file "$WORK/park.seed"
[ "$(seed)" = "Some Issue Title" ] || st_fail "R no transcript: the plain spawn's seed (the title)" "$(seed)"
grep -q -- '--resume' "$WORK/newwin" && st_fail "R no transcript: no --resume" "$(cat "$WORK/newwin")"
WT=$(sed -n 's/.* -c \([^ ]*\) .*/\1/p' "$WORK/newwin" | head -1)
[ -n "$WT" ] || st_fail "R the new-window carried no -c <worktree>" "$(cat "$WORK/newwin")"
mkdir -p "$WORK/projects/$(printf '%s' "$WT" | LC_ALL=C tr -c 'A-Za-z0-9' '-')"
: > "$WORK/projects/$(printf '%s' "$WT" | LC_ALL=C tr -c 'A-Za-z0-9' '-')/$SID.jsonl"
: > "$WORK/newwin"
CLAUDE_PROJECTS_DIR="$WORK/projects" run_spawn 234 --resume "$SID" --seed-file "$WORK/park.seed"
[ "$(seed)" = "[fleet park] read the handoff" ] || st_fail "R the seed file must be the first turn" "$(seed)"
grep -qF -- '@seed_words' "$WORK/newwin" && st_fail "R a parked return is no words seed: no @seed_words" "$(cat "$WORK/newwin")"
sed 's/ --as fleet-worker//g' "$WORK/newwin" | grep -qF -- "fleet-session-wrap.sh' --agent claude --resume $SID \"\$(cat '" \
  || st_fail "R --resume <sid> must sit between the launcher and the seed" "$(cat "$WORK/newwin")"
: > "$WORK/newwin"
CLAUDE_PROJECTS_DIR="$WORK/projects" run_spawn 234 --resume "$SID" --seed-file "$WORK/park.seed" --agent codex
grep -q -- '--resume' "$WORK/newwin" && st_fail "R a Codex return carries no Claude --resume" "$(cat "$WORK/newwin")"
st_pass "R a parked session comes back on the same conversation with its own first turn (#2671)"

# ===== BODY: fleet_worker_prompt_body (the per-fleet directive the brief prints)
# bin/fleet-brief.sh calls this at runtime instead of the spawn baking it into
# the seed — so its behaviour is tested directly here.
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"
unset FLEET_WORKER_PROMPT FLEET_WORKER_PROMPT_FILE

# D: default (no override) is the built-in instruction, verbatim.
[ "$(fleet_worker_prompt_body 234 acme/widgets)" = 'Implement and verify per the repo conventions' ] \
  || st_fail "D default body should be the built-in instruction" "$(fleet_worker_prompt_body 234 acme/widgets)"
st_pass "D fleet_worker_prompt_body default is the built-in instruction"

# E: FLEET_WORKER_PROMPT replaces the body.
got=$(FLEET_WORKER_PROMPT='Follow CONTRIBUTING and add coverage' fleet_worker_prompt_body 234 acme/widgets)
[ "$got" = 'Follow CONTRIBUTING and add coverage' ] \
  || st_fail "E FLEET_WORKER_PROMPT should replace the default body" "$got"
st_pass "E FLEET_WORKER_PROMPT replaces the default body"

# F: a trailing sentence-ender is stripped (so it flows cleanly wherever it's woven).
got=$(FLEET_WORKER_PROMPT='Do the thing.' fleet_worker_prompt_body 234 acme/widgets)
[ "$got" = 'Do the thing' ] || st_fail "F a trailing period should be stripped" "$got"
st_pass "F a trailing sentence-ender in the override is stripped"

# G: {issue}/{repo} placeholders are substituted.
got=$(FLEET_WORKER_PROMPT='Handle {issue} in {repo}' fleet_worker_prompt_body 234 acme/widgets)
[ "$got" = 'Handle 234 in acme/widgets' ] || st_fail "G {issue}/{repo} were not substituted" "$got"
st_pass "G {issue}/{repo} placeholders are substituted"

# H: FLEET_WORKER_PROMPT_FILE wins over the inline value and carries multi-line
#    content; an unreadable file warns on stderr and falls back to the default.
printf 'First custom line for {issue}.\nSecond line for {repo}.\n' > "$WORK/tmpl.txt"
got=$(FLEET_WORKER_PROMPT='inline-should-lose' FLEET_WORKER_PROMPT_FILE="$WORK/tmpl.txt" \
        fleet_worker_prompt_body 234 acme/widgets)
case "$got" in *inline-should-lose*) st_fail "H a readable prompt FILE must win over the inline value" "$got" ;; esac
case "$got" in *'First custom line for 234.'*) : ;; *) st_fail "H prompt file line 1 missing (subst)" "$got" ;; esac
case "$got" in *'Second line for acme/widgets'*) : ;; *) st_fail "H prompt file line 2 missing (multi-line lost)" "$got" ;; esac
got=$(FLEET_WORKER_PROMPT_FILE="$WORK/nope.txt" fleet_worker_prompt_body 234 acme/widgets 2>"$WORK/body.err")
[ "$got" = 'Implement and verify per the repo conventions' ] \
  || st_fail "H an unreadable prompt file should fall back to the default body" "$got"
grep -q 'worker prompt file not readable' "$WORK/body.err" \
  || st_fail "H an unreadable prompt file should warn on stderr" "$(cat "$WORK/body.err")"
st_pass "H prompt FILE wins + is multi-line; an unreadable file warns and falls back"

# I: FLEET_WORKER_PROMPT="@<path>" is the one-key form of the retired _FILE twin
#    (issue #1101): same file read, same subst; an unreadable @path warns and
#    falls back to the DEFAULT (never to the literal "@…" string); and the old
#    _FILE key, when an old conf still sets it, keeps winning.
got=$(FLEET_WORKER_PROMPT="@$WORK/tmpl.txt" fleet_worker_prompt_body 234 acme/widgets)
case "$got" in *'First custom line for 234.'*'Second line for acme/widgets'*) : ;;
  *) st_fail "I @path should read the file (multi-line + subst)" "$got" ;; esac
got=$(FLEET_WORKER_PROMPT="@$WORK/nope.txt" fleet_worker_prompt_body 234 acme/widgets 2>"$WORK/body.err")
[ "$got" = 'Implement and verify per the repo conventions' ] \
  || st_fail "I an unreadable @path should fall back to the default body" "$got"
grep -q 'worker prompt file not readable' "$WORK/body.err" \
  || st_fail "I an unreadable @path should warn on stderr" "$(cat "$WORK/body.err")"
printf 'legacy file body\n' > "$WORK/legacy.txt"
got=$(FLEET_WORKER_PROMPT="@$WORK/tmpl.txt" FLEET_WORKER_PROMPT_FILE="$WORK/legacy.txt" \
        fleet_worker_prompt_body 234 acme/widgets)
[ "$got" = 'legacy file body' ] || st_fail "I the retired _FILE key must still win when set" "$got"
st_pass "I @path form reads the file; unreadable → default; retired _FILE still honored"

printf '\nselftest OK: %s assertions passed (the words seed + per-fleet body)\n' "$pass"
exit 0
