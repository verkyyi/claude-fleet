#!/bin/bash
# dash-issue-close-selftest.sh — hermetic tests for bin/dash-issue-close.sh's
# non-blocking close (issue #304). No network, no tmux server: gh + tmux + the
# sibling collector are faked; the real script + fleet-lib.sh are symlinked into a
# temp bin so BIN resolves the stubs. The fake tmux both LOGS `run-shell`
# dispatches (so we can prove the slow op is backgrounded, not inline) AND executes
# them (so the backgrounded gh close still fires and its effects are observable).
#
#   A. OPTIMISTIC DROP is SYNC — the confirmed close removes #num from the issues
#      cache immediately, BEFORE (and independent of) the backgrounded gh close.
#   B. gh close is BACKGROUNDED — dispatched via `tmux run-shell -b`, never inline.
#   C. the bg job WORKS — executing the dispatched command runs `gh issue close`
#      and toasts success.
#   D. CANCEL ('n') drops nothing and dispatches nothing.
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured state).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SRC="$BIN/dash-issue-close.sh"
LIB="$BIN/fleet-lib.sh"
[ -x "$SRC" ] || { printf 'selftest: %s missing\n' "$SRC" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/close-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- state ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/bin" "$WORK/fp" "$WORK/tmp/.claude-dash/fleets/fake-repo" "$WORK/tmp/.claude-dash/global"
ln -s "$SRC" "$WORK/bin/dash-issue-close.sh"
ln -s "$LIB" "$WORK/bin/fleet-lib.sh"
printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/tmux-dash-collect.sh"; chmod +x "$WORK/bin/tmux-dash-collect.sh"

FD="$WORK/tmp/.claude-dash/fleets/fake-repo"
ISSUES="$FD/issues"
seed_issues() { printf '%s\t#101\t%s\tFirst\n%s\t#102\t%s\tSecond\n' '· no milestone' '·' '· no milestone' '·' > "$ISSUES"; : > "$ISSUES.ts"; }
printf 'fakesess\tfake-repo\tfake/repo\n' > "$WORK/tmp/.claude-dash/global/sessmap"

GHLOG="$WORK/ghlog"; RSLOG="$WORK/rslog"; TOAST="$WORK/toast"
# fake gh: log `issue close`; `command -v gh` succeeds.
cat > "$WORK/fp/gh" <<GHFAKE
#!/bin/bash
case "\${1:-} \${2:-}" in
  "issue close") printf '%s\n' "\$*" >> "$GHLOG" ;;
esac
exit 0
GHFAKE
# fake tmux: answer session_name; LOG + EXECUTE run-shell; log display-message.
cat > "$WORK/fp/tmux" <<TMUXFAKE
#!/bin/bash
if [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-S" ]; then shift 2; fi
case "\${1:-}" in
  run-shell)
    shift; [ "\${1:-}" = "-b" ] && shift
    printf '%s\n' "\$1" >> "$RSLOG"          # prove the dispatch happened
    sh -c "\$1" ;;                            # mirror real run-shell: actually run it
  display-message)
    case "\$*" in *session_name*) echo fakesess ;; *) printf '%s\n' "\$*" >> "$TOAST" ;; esac ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fp/gh" "$WORK/fp/tmux"

# phase 2 (confirm mode) with a piped answer; fresh logs + cache each run.
runc() { : > "$GHLOG"; : > "$RSLOG"; : > "$TOAST"; seed_issues
  printf '%s' "$2" | PATH="$WORK/fp:$PATH" TMPDIR="$WORK/tmp" CF_REPO=fake/repo \
    bash "$WORK/bin/dash-issue-close.sh" "$1" confirm >/dev/null 2>&1; }

# ============================ A + B + C: confirmed close ====================
runc 101 y
grep -q $'\t#101\t' "$ISSUES" && fail "A #101 row must be dropped from the issues cache SYNCHRONOUSLY" "$(cat "$ISSUES")"
grep -q $'\t#102\t' "$ISSUES" || fail "A unrelated #102 row must be kept" "$(cat "$ISSUES")"
ok "A optimistic drop is synchronous (row gone, siblings kept)"

grep -q "gh issue close '101'" "$RSLOG" || fail "B gh close must be dispatched via run-shell -b (backgrounded)" "$(cat "$RSLOG")"
ok "B gh close is backgrounded via run-shell -b, not inline"

grep -q "issue close 101" "$GHLOG" || fail "C the backgrounded job must actually run gh issue close" "$(cat "$GHLOG")"
grep -q 'closed' "$TOAST" || fail "C the bg job must toast success" "$(cat "$TOAST")"
ok "C backgrounded job runs the close + toasts success"

# ============================ D: cancel ====================================
runc 101 n
[ -s "$RSLOG" ] && fail "D cancel must dispatch NOTHING" "$(cat "$RSLOG")"
[ -s "$GHLOG" ] && fail "D cancel must not close" "$(cat "$GHLOG")"
grep -q $'\t#101\t' "$ISSUES" || fail "D cancel must leave the #101 row in place" "$(cat "$ISSUES")"
ok "D cancel drops nothing and dispatches nothing"

printf '\nselftest OK: %s assertions passed (dash-issue-close non-blocking)\n' "$pass"
exit 0
