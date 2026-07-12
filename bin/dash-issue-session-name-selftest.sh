#!/bin/bash
# dash-issue-session-name-selftest.sh — hermetic tests for how a spawned worker's
# tmux window is NAMED (issue #216). A create-then-spawn caller (/fleet-new-issue,
# the prefix+n quick-dispatch, the dash new-session box) now passes the title it
# just wrote as --title, so the window is named after the WORK — reliably, without
# depending on the brand-new issue being in the collector cache yet or on a
# post-create `gh issue view` succeeding. No network, no real repo, no tmux server
# — git/gh/tmux are faked on PATH.
#
#   A. --title is AUTHORITATIVE + needs NO network: the window is named from the
#      passed title even when `gh issue view` would return something else, and
#      `gh issue view` is NOT called at all.
#   B. no --title, cache miss → falls back to `gh issue view` and names the window
#      from that title (the pre-#216 behavior still works).
#   C. no --title, cache miss, gh returns an empty title → falls back to the bare
#      issue-<N> slug (the last-resort behavior still works).
#   D. a --title that slugifies to empty (symbol-only/non-latin) degrades to the
#      issue-<N> slug without a network call (graceful, predictable).
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion + captured output).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SPAWN="$BIN/dash-issue-session.sh"
[ -x "$SPAWN" ] || { echo "selftest: $SPAWN missing/not executable" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/issname-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

mkdir -p "$WORK/main/.git" "$WORK/fakebin" "$WORK/conf" "$WORK/dash"
NEWWIN_LOG="$WORK/newwins"; GHVIEW_LOG="$WORK/ghviews"; DISPLAY_LOG="$WORK/display"

# --- fake git: worktree/fetch/branch succeed; report a branch + toplevel --------
cat > "$WORK/fakebin/git" <<GITFAKE
#!/bin/bash
if [ "\${1:-}" = "-C" ]; then shift 2; fi
case "\${1:-}" in
  rev-parse)
    case "\$*" in
      *--abbrev-ref*)    printf '%s\n' "\${GIT_BRANCH:-issue-216}" ;;
      *--show-toplevel*) pwd -P ;;
      *) printf 'deadbeef\n' ;;
    esac ;;
  *) : ;;   # fetch / worktree / branch → succeed silently
esac
exit 0
GITFAKE

# --- fake gh: `issue view` returns \$GH_TITLE and LOGS that it was called, so a
# test can assert the network path was (or was NOT) taken.
cat > "$WORK/fakebin/gh" <<GHFAKE
#!/bin/bash
case "\${1:-} \${2:-}" in
  "issue view") printf 'view\n' >> "$GHVIEW_LOG"; printf '%s\n' "\${GH_TITLE-}" ;;
  *) : ;;
esac
exit 0
GHFAKE

# --- fake tmux: query via -p; new-window logs its args (so we can read -n <name>).
cat > "$WORK/fakebin/tmux" <<TMUXFAKE
#!/bin/bash
if [ "\${1:-}" = "-L" ] || [ "\${1:-}" = "-S" ]; then shift 2; fi
case "\${1:-}" in
  display-message)
    case "\$*" in
      *-p*)
        case "\$*" in
          *window_id*)    echo "\${TMUX_WIN:-@9}" ;;
          *session_name*) echo 'testsess' ;;
          *) echo '' ;;
        esac ;;
      *) shift; printf '%s\n' "\$*" >> "$DISPLAY_LOG" ;;
    esac ;;
  list-windows)      [ -n "\${TMUX_LW:-}" ] && printf '%s\n' "\${TMUX_LW}" || : ;;
  show-options)      echo '' ;;
  new-window)        printf '%s\n' "\$*" >> "$NEWWIN_LOG"; echo "\${TMUX_WIN:-@9}" ;;
  set-window-option) : ;;
  select-window)     : ;;
  *) : ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/fakebin/git" "$WORK/fakebin/gh" "$WORK/fakebin/tmux"

run_spawn() { # $@ = args to dash-issue-session.sh ; env GH_TITLE controls gh view
  : > "$NEWWIN_LOG"; : > "$GHVIEW_LOG"; : > "$DISPLAY_LOG"
  # This test is about the WINDOW NAME, not the cross-machine claim dedup (issue
  # #258, on by default) — opt out so the simplistic fake gh isn't parsed as a
  # claim ledger and the spawn proceeds. The dedup has its own selftest.
  PATH="$WORK/fakebin:$PATH" TMPDIR="$WORK/dash" FLEET_CONF_DIR="$WORK/conf" \
  FLEET_C="$WORK/dash" FLEET_REPO="acme/widgets" FLEET_MAIN="$WORK/main" \
  FLEET_BASE_BRANCH="master" FLEET_PRESPAWN_DEDUP=0 \
    "$SPAWN" "$@" >"$WORK/spawn.out" 2>"$WORK/spawn.err"
}

# The window name is passed to `tmux new-window ... -n <name> -c <wt> ...`; pull the
# token right after -n out of the logged args.
winname() { awk '{for(i=1;i<=NF;i++) if($i=="-n"){print $(i+1); exit}}' "$NEWWIN_LOG"; }

# ===== A: --title is authoritative and needs no network =======================
GH_TITLE="do-not-use-this-from-gh" run_spawn 216 --title "Fix The Widget Cache"
[ -s "$NEWWIN_LOG" ] || fail "A no window was created" "$(cat "$WORK/spawn.err")"
[ "$(winname)" = "fix-the-widget-cache" ] \
  || fail "A window should be named from --title (got '$(winname)')" "$(cat "$NEWWIN_LOG")"
[ -s "$GHVIEW_LOG" ] && fail "A --title must NOT trigger a gh issue view network call" "$(cat "$GHVIEW_LOG")"
ok "A --title names the window after the work — no cache/network dependency"

# ===== B: no --title → gh issue view fallback still names the window ===========
GH_TITLE="Cached Widget Title" run_spawn 216
[ "$(winname)" = "cached-widget-title" ] \
  || fail "B window should be named from the gh title (got '$(winname)')" "$(cat "$NEWWIN_LOG")"
[ -s "$GHVIEW_LOG" ] || fail "B a cache miss should fall back to gh issue view" "$(cat "$WORK/spawn.err")"
ok "B without --title, the gh issue view fallback still names the window"

# ===== C: no --title, gh returns empty → bare issue-<N> slug ===================
GH_TITLE="" run_spawn 216
[ "$(winname)" = "issue-216" ] \
  || fail "C an unresolvable title should fall back to issue-216 (got '$(winname)')" "$(cat "$NEWWIN_LOG")"
ok "C unresolvable title falls back to the issue-<N> slug"

# ===== D: --title that slugifies to empty → issue-<N> slug, no network =========
GH_TITLE="latin fallback title" run_spawn 216 --title "★★★"
[ "$(winname)" = "issue-216" ] \
  || fail "D a symbol-only --title should degrade to issue-216 (got '$(winname)')" "$(cat "$NEWWIN_LOG")"
[ -s "$GHVIEW_LOG" ] && fail "D a provided --title must not fall through to a gh network call" "$(cat "$GHVIEW_LOG")"
ok "D a non-latin --title degrades to the issue-<N> slug, predictably + offline"

printf '\nselftest OK: %s assertions passed (issue-window naming / --title)\n' "$pass"
exit 0
