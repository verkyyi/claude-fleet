#!/bin/bash
# bash-guard-selftest.sh — the allow/deny matrix for the two bypass-permissions
# last-line-of-defense PreToolUse hooks shipped in hooks/ (issue #355):
#
#   hooks/bash-guard.py         — a GENERIC Bash deny-list (rm -rf on / ~ .git;
#                                 a force-push onto the base branch), with a
#                                 personal overlay it runs if present.
#   hooks/base-readonly-guard.py — deny Edit/Write/NotebookEdit into the fleet's
#                                 base checkout (FLEET_MAIN); worktree siblings
#                                 (<repo>-issue-N) sit next to it and stay writable.
#
# Both hooks read a Claude Code PreToolUse JSON payload on stdin and signal via
# exit code: 0 = allow, 2 = BLOCK, and (contract) fail OPEN on any internal
# error so a guard bug never bricks a session. This test drives the REAL hooks
# with crafted payloads and asserts each verdict — it proves the false-positive
# discipline (statement-segment splitting, git-subcommand matching) AND that the
# rails actually fire.
#
# Hermetic: no network, no tmux, no live fleet. base-readonly resolution is
# pinned via the FLEET_MAIN env override so fleet-lib is never consulted. HOME is
# redirected to a temp dir so the overlay path (~/.claude/hooks/bash-guard-local.py)
# resolves under our control.
#
# python3 absent → SKIP cleanly (exit 0), per the run-selftests convention.
# Exit 0 = pass. Non-zero = fail (prints which case diverged).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
GUARD="$BIN/../hooks/bash-guard.py"
BASEGUARD="$BIN/../hooks/base-readonly-guard.py"
[ -f "$GUARD" ]     || { printf 'selftest: %s not found\n' "$GUARD" >&2; exit 2; }
[ -f "$BASEGUARD" ] || { printf 'selftest: %s not found\n' "$BASEGUARD" >&2; exit 2; }

PY="$(command -v python3 2>/dev/null)"
[ -n "$PY" ] || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/bash-guard-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$TMP"' EXIT INT TERM

fails=0
# assert_exit <expected-code> <label> <hook> <json>   [env passed via caller]
assert_exit() {
  local want="$1" label="$2" hook="$3" json="$4" got
  printf '%s' "$json" | "$PY" "$hook" >/dev/null 2>&1
  got=$?
  if [ "$got" != "$want" ]; then
    printf 'FAIL: %s — expected exit %s, got %s\n' "$label" "$want" "$got" >&2
    fails=$((fails + 1))
  fi
}

bash_json() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$1"; }
# jq-free JSON string encode of "$1" (handles the quoting/escaping we need here).
jstr() { "$PY" -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1"; }

# ---------------------------------------------------------------------------
# bash-guard.py — GENERIC Bash deny-list
# ---------------------------------------------------------------------------

# BLOCK: rm -rf on filesystem root / home / a .git dir
assert_exit 2 "rm -rf /"            "$GUARD" "$(bash_json "$(jstr 'rm -rf /')")"
assert_exit 2 "rm -rf ~"            "$GUARD" "$(bash_json "$(jstr 'rm -rf ~')")"
assert_exit 2 "rm -rf \$HOME"       "$GUARD" "$(bash_json "$(jstr 'rm -rf $HOME')")"
assert_exit 2 "rm -fr /"            "$GUARD" "$(bash_json "$(jstr 'rm -fr /')")"
assert_exit 2 "rm -rf .git"         "$GUARD" "$(bash_json "$(jstr 'rm -rf .git')")"
assert_exit 2 "rm -rf path/.git"    "$GUARD" "$(bash_json "$(jstr 'rm -rf worktree/.git')")"

# ALLOW: rm -rf on a real subpath, and a non-recursive rm
assert_exit 0 "rm -rf subpath"      "$GUARD" "$(bash_json "$(jstr 'rm -rf /usr/local/tmp/build')")"
assert_exit 0 "rm -rf ./build"      "$GUARD" "$(bash_json "$(jstr 'rm -rf ./build')")"
assert_exit 0 "rm file (no -r)"     "$GUARD" "$(bash_json "$(jstr 'rm -f /tmp/x')")"
# ALLOW: `git rm` is not the `rm` command
assert_exit 0 "git rm -rf"          "$GUARD" "$(bash_json "$(jstr 'git rm -rf .git-old')")"

# BLOCK: force-push onto the base branch (several forced forms)
assert_exit 2 "push --force master" "$GUARD" "$(bash_json "$(jstr 'git push --force origin master')")"
assert_exit 2 "push -f main"        "$GUARD" "$(bash_json "$(jstr 'git push -f origin main')")"
assert_exit 2 "push +master"        "$GUARD" "$(bash_json "$(jstr 'git push origin +master')")"
assert_exit 2 "push -fwl main"      "$GUARD" "$(bash_json "$(jstr 'git push --force-with-lease origin main')")"

# ALLOW: a plain push to the base branch, and a force-push to a feature branch
assert_exit 0 "push master (plain)" "$GUARD" "$(bash_json "$(jstr 'git push origin master')")"
assert_exit 0 "push -f feature"     "$GUARD" "$(bash_json "$(jstr 'git push --force origin issue-355')")"

# FALSE-POSITIVE discipline: dangerous tokens in a message / another segment
assert_exit 0 "rm in commit msg"    "$GUARD" "$(bash_json "$(jstr 'git commit -m "rm -rf cleanup on master"')")"
assert_exit 0 "master in echo seg"  "$GUARD" "$(bash_json "$(jstr 'echo "protect master" && rm -rf ./build')")"
assert_exit 0 "cross-segment split" "$GUARD" "$(bash_json "$(jstr 'git commit -m "wip -rf" ; git push origin master')")"
# but a REAL dangerous statement AFTER a harmless one still fires
assert_exit 2 "block in 2nd segment" "$GUARD" "$(bash_json "$(jstr 'echo hi && rm -rf /')")"

# fail OPEN on malformed input, and no-op on a non-Bash tool
assert_exit 0 "malformed json"      "$GUARD" 'not json at all'
assert_exit 0 "non-Bash tool"       "$GUARD" '{"tool_name":"Read","tool_input":{}}'

# FLEET_BASE_BRANCH extends the protected set (subshell keeps the export local;
# reset fails=0 so `exit $fails` reports only THIS subshell's count).
( fails=0; export FLEET_BASE_BRANCH=develop
  assert_exit 2 "push -f develop"   "$GUARD" "$(bash_json "$(jstr 'git push -f origin develop')")"
  exit $fails ); rc=$?; fails=$((fails + rc))

# Local overlay: a present overlay's block() denies; a broken overlay fails OPEN.
mkdir -p "$TMP/home/.claude/hooks"
cat > "$TMP/home/.claude/hooks/bash-guard-local.py" <<'PYEOF'
def check_segment(seg, ctx):
    if ctx.cmd_is(seg, "frobnicate"):
        ctx.block("operator rule: frobnicate is forbidden")
PYEOF
( fails=0; export HOME="$TMP/home"
  assert_exit 2 "overlay blocks"    "$GUARD" "$(bash_json "$(jstr 'frobnicate --now')")"
  assert_exit 0 "overlay passes"    "$GUARD" "$(bash_json "$(jstr 'ls -la')")"
  exit $fails ); rc=$?; fails=$((fails + rc))

printf 'def check_segment(seg, ctx):\n    raise RuntimeError("boom")\n' \
  > "$TMP/home/.claude/hooks/bash-guard-local.py"
( fails=0; export HOME="$TMP/home"
  assert_exit 0 "broken overlay → open" "$GUARD" "$(bash_json "$(jstr 'ls -la')")"
  exit $fails ); rc=$?; fails=$((fails + rc))

# ---------------------------------------------------------------------------
# base-readonly-guard.py — deny writes into the fleet base checkout
# ---------------------------------------------------------------------------
BASE="$TMP/repo"; mkdir -p "$BASE" "$TMP/repo-issue-5" "$TMP/elsewhere"
edit_json() { printf '{"tool_name":"%s","tool_input":{"%s":%s}}' "$1" "$2" "$(jstr "$3")"; }

( fails=0; export FLEET_MAIN="$BASE"; unset TMUX
  # BLOCK: any write into the base checkout
  assert_exit 2 "edit base file"    "$BASEGUARD" "$(edit_json Edit   file_path "$BASE/bin/x.sh")"
  assert_exit 2 "write base file"   "$BASEGUARD" "$(edit_json Write  file_path "$BASE/README.md")"
  assert_exit 2 "notebook in base"  "$BASEGUARD" "$(edit_json NotebookEdit notebook_path "$BASE/nb.ipynb")"
  # ALLOW: the issue-<N> worktree sibling (sits NEXT TO the base, not under it)
  assert_exit 0 "edit worktree"     "$BASEGUARD" "$(edit_json Edit file_path "$TMP/repo-issue-5/bin/x.sh")"
  # ALLOW: an unrelated path, and a non-write tool
  assert_exit 0 "edit elsewhere"    "$BASEGUARD" "$(edit_json Write file_path "$TMP/elsewhere/y.txt")"
  assert_exit 0 "read tool no-op"   "$BASEGUARD" '{"tool_name":"Read","tool_input":{"file_path":"'"$BASE/x"'"}}'
  # fail OPEN on malformed input
  assert_exit 0 "baseguard bad json" "$BASEGUARD" 'nope'
  exit $fails ); rc=$?; fails=$((fails + rc))

# Not in a fleet (no FLEET_MAIN, no $TMUX) → nothing to protect → allow
( fails=0; unset FLEET_MAIN; unset TMUX
  assert_exit 0 "no fleet → allow"  "$BASEGUARD" "$(edit_json Edit file_path "$BASE/bin/x.sh")"
  exit $fails ); rc=$?; fails=$((fails + rc))

if [ "$fails" -ne 0 ]; then
  printf '\nbash-guard-selftest: %s case(s) FAILED\n' "$fails" >&2
  exit 1
fi
printf 'bash-guard-selftest: all cases passed\n'
exit 0
