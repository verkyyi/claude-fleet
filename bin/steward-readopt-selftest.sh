#!/bin/bash
# steward-readopt-selftest.sh — the SessionStart re-adopt hook's gate matrix
# (issue #155, rewired for the layered charter in issue #286).
#
# bin/steward-readopt-hook.sh re-injects the STEWARD charter into the model's
# context after a /clear, so the steward doesn't go amnesiac (and drift off its
# first-mate charter onto the reloaded cwd CLAUDE.md). Since issue #286 it no
# longer cats a flat ~/.claude/steward.md — it runs the SHARED resolver
# bin/steward-charter.sh (built-in skill charter + gated repo/operator overrides),
# the same path /fleet-steward uses at spawn, so a /clear re-adopt can't drift. It
# must fire in EXACTLY one case and stay silent in every other. This test drives
# the REAL hook against a REAL, isolated tmux server (its own -S socket, torn down
# at exit — never the user's live server) and a throwaway $HOME:
#
#   • @steward pane + source=clear  + charter present → INJECTS (charter + framing
#                                     + newest-handoff pointer on stdout).
#   • @steward pane + source=startup                  → SILENT (scoped to clear).
#   • @steward pane + source=resume                   → SILENT (crash path #143).
#   • NON-steward pane + source=clear                 → SILENT (hard @steward gate).
#   • @steward pane + source=clear  + charter EMPTY   → SILENT (nothing to adopt).
#   • real stdin JSON {"source":"clear"} (no override)→ INJECTS (parser works).
#
# The built-in charter tier is fixtured via FLEET_STEWARD_SKILL (a temp skill file
# carrying a sentinel between the begin/end markers) so the test doesn't ride the
# real charter's prose; the resolver reads that env in the subprocess the hook
# spawns. The hook calls bare `tmux`; a PATH shim routes it onto the private socket
# (the same trick as tmux-guard-selftest.sh). $HOME is redirected to a temp dir so
# the test owns the handoff pointer and never touches the user's real files.
#
# tmux absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which assertion diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
HOOK="$BIN/steward-readopt-hook.sh"
[ -f "$HOOK" ] || { printf 'selftest: %s not found\n' "$HOOK" >&2; exit 2; }

REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/stre-selftest.XXXXXX")" || exit 2
SOCK="$WORK/tmux.sock"
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/.claude/handoff"

# PATH shim: the plain `tmux` the hook calls routes onto our private socket, but
# a -L/-S call passes straight through (matches tmux-guard-selftest.sh).
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
case " \$* " in
  *" -L "*|*" -S "*) exec "$REAL_TMUX" "\$@" ;;
  *)                 exec "$REAL_TMUX" -S "$SOCK" "\$@" ;;
esac
EOF
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"

cleanup() { "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
# A bare EXIT trap does NOT fire on a signal — turn INT/TERM/HUP into a normal exit
# so the isolated server is still reaped (issue #152; fleet-selftest-reap.sh backstops).
trap 'exit 1' INT TERM HUP

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- fixture: an isolated server with two panes in one window -----------------
"$REAL_TMUX" -S "$SOCK" new-session -d -s t -x 80 -y 24 || fail "could not start isolated tmux"
# pane %A = steward (marked), pane %B = plain worker (unmarked).
STEW_PANE=$("$REAL_TMUX" -S "$SOCK" display-message -p -t t '#{pane_id}')
WORK_PANE=$("$REAL_TMUX" -S "$SOCK" split-window -P -F '#{pane_id}' -t t)
"$REAL_TMUX" -S "$SOCK" set-option -p -t "$STEW_PANE" @steward 1
[ -n "$STEW_PANE" ] && [ -n "$WORK_PANE" ] || fail "fixture panes not created"

# The built-in charter fixture (a sentinel between the begin/end markers the
# resolver extracts) + a handoff, in the throwaway HOME.
MARKER='STEWARD_IDENTITY_SENTINEL_9F3A'
SKILL="$WORK/fleet-steward.md"
{
  printf '# /fleet-steward — procedure (excluded)\n\n'
  printf '<!-- fleet:charter-begin -->\n'
  printf '%s\nyou are the fleet steward.\n' "$MARKER"
  printf '<!-- fleet:charter-end -->\n'
} > "$SKILL"
export FLEET_STEWARD_SKILL="$SKILL"
printf 'handoff body\n' > "$FAKE_HOME/.claude/handoff/steward-2026-07-07.md"

# Run the hook with a given pane / source / stdin, capture stdout.
# Usage: run_hook <pane> <source-or-'-'> [stdin]   ('-' => drive via real stdin JSON)
run_hook() {
  _pane="$1"; _src="$2"; _stdin="${3:-}"
  if [ "$_src" = "-" ]; then
    TMUX="$SOCK,0,0" TMUX_PANE="$_pane" HOME="$FAKE_HOME" \
      sh "$HOOK" <<< "$_stdin"
  else
    TMUX="$SOCK,0,0" TMUX_PANE="$_pane" HOME="$FAKE_HOME" FLEET_READOPT_SOURCE="$_src" \
      sh "$HOOK" < /dev/null
  fi
}

# --- 1. steward + clear + charter present → INJECTS --------------------------
out=$(run_hook "$STEW_PANE" clear)
printf '%s' "$out" | grep -q "$MARKER"            || fail "clear/steward: charter not injected"
printf '%s' "$out" | grep -q 'steward re-adopt'   || fail "clear/steward: framing preamble missing"
printf '%s' "$out" | grep -q 'steward-2026-07-07' || fail "clear/steward: handoff pointer missing"

# --- 2. steward + startup → SILENT (scoped to clear) -------------------------
out=$(run_hook "$STEW_PANE" startup)
[ -z "$out" ] || fail "startup/steward: expected no output, got: $out"

# --- 3. steward + resume → SILENT (crash-resume path owns this, #143) --------
out=$(run_hook "$STEW_PANE" resume)
[ -z "$out" ] || fail "resume/steward: expected no output, got: $out"

# --- 4. NON-steward pane + clear → SILENT (hard @steward gate) ----------------
out=$(run_hook "$WORK_PANE" clear)
[ -z "$out" ] || fail "clear/worker: a non-steward pane must NOT get steward identity, got: $out"

# --- 5. steward + clear but charter EMPTY → SILENT (nothing to adopt) ---------
# Point the resolver at a markerless file: its built-in tier extracts nothing and,
# with no repo/overlay layer, the resolver emits nothing → the hook stays silent.
EMPTY_SKILL="$WORK/empty.md"; printf 'no markers here\n' > "$EMPTY_SKILL"
out=$(FLEET_STEWARD_SKILL="$EMPTY_SKILL" run_hook "$STEW_PANE" clear)
[ -z "$out" ] || fail "clear/empty-charter: expected no output when the resolver emits nothing, got: $out"

# --- 6. real stdin JSON parse (no override) → INJECTS ------------------------
out=$(run_hook "$STEW_PANE" - '{"hook_event_name":"SessionStart","source":"clear","cwd":"/x"}')
printf '%s' "$out" | grep -q "$MARKER" || fail "stdin-json/clear: source parser failed to detect clear"
# ...and a startup JSON stays SILENT through the same parser.
out=$(run_hook "$STEW_PANE" - '{"hook_event_name":"SessionStart","source":"startup"}')
[ -z "$out" ] || fail "stdin-json/startup: parser should not fire on startup, got: $out"

printf 'PASS: steward re-adopt hook fires only on @steward + /clear (via steward-charter.sh)\n'
exit 0
