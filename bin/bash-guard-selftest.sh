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

# assert_rewrite <label> <hook> <json> <substring>  — the messaging rails REPAIR
# rather than deny (#528): exit 0 PLUS a PreToolUse updatedInput payload on
# stdout. Asserts the payload is well-formed, carries the substring, and that the
# ORIGINAL command is gone (a rewrite that leaves the raw call in place is a
# silent no-op).
assert_rewrite() {
  local label="$1" hook="$2" json="$3" want="$4" out got
  out=$(printf '%s' "$json" | "$PY" "$hook" 2>/dev/null); got=$?
  if [ "$got" != 0 ]; then
    printf 'FAIL: %s — expected exit 0 with a rewrite, got %s\n' "$label" "$got" >&2
    fails=$((fails + 1)); return
  fi
  printf '%s' "$out" | "$PY" -c '
import json,sys
d=json.load(sys.stdin)["hookSpecificOutput"]
assert d["hookEventName"]=="PreToolUse", "wrong hookEventName"
assert d["permissionDecision"]=="allow", "rewrite must decide allow"
cmd=d["updatedInput"]["command"]
assert sys.argv[1] in cmd, "rewrite missing %r" % sys.argv[1]
' "$want" 2>/dev/null || {
    printf 'FAIL: %s — malformed/incomplete rewrite payload\n' "$label" >&2
    fails=$((fails + 1)); }
}

# assert_no_rewrite <label> <hook> <json> — allowed AND left verbatim (no payload).
assert_no_rewrite() {
  local label="$1" hook="$2" json="$3" out
  out=$(printf '%s' "$json" | "$PY" "$hook" 2>/dev/null)
  if [ -n "$out" ]; then
    printf 'FAIL: %s — expected a verbatim allow, got a rewrite\n' "$label" >&2
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

# MASKING (#528): quoted and heredoc text is DATA. A runbook, a report or a
# test fixture whose line merely BEGINS with a guarded command used to segment
# like code and get denied though nothing would ever run — the guard blocked its
# own documentation. The rails still fire on the real thing in the same command.
assert_exit 0 "rm -rf in a heredoc doc" "$GUARD" "$(bash_json "$(jstr 'cat > /tmp/d.md <<EOF
Never run this:
rm -rf /
EOF
echo wrote')")"
assert_exit 0 "rm -rf in a quoted arg"  "$GUARD" "$(bash_json "$(jstr 'printf "%s" "rm -rf /"')")"
assert_exit 0 "push -f doc line"        "$GUARD" "$(bash_json "$(jstr 'cat <<EOF > /tmp/r.md
git push --force origin master
EOF')")"
# ...but a REAL statement after a masked lookalike still fires
assert_exit 2 "real rm after doc text"  "$GUARD" "$(bash_json "$(jstr 'cat > /tmp/d.md <<EOF
rm -rf /
EOF
rm -rf /')")"
# A live $(...) inside a quoted body is code again, not data — masking blanks the
# surrounding string but leaves the substitution scannable, so it cannot become a
# bypass for the irreversible rails.
assert_exit 2 "rm -rf in a subst"       "$GUARD" "$(bash_json "$(jstr 'echo "$(cd /tmp && rm -rf / )"')")"

# BLOCK: a raw tmux send-keys into a live FLEET pane — inter-agent messaging must
# go through the issue-bridge (issue #437). Scoped to fleet SERVERS since #528:
# the rail protects a worker's Claude TUI, and a server hosting no fleet has no
# TUI to corrupt. FLEET_CONF_DIR is pinned so "which labels are fleets" stays
# hermetic — `fleet-x` owns a conf here, `scratch` deliberately does not.
export FLEET_CONF_DIR="$TMP/conf"
mkdir -p "$FLEET_CONF_DIR/fleets/fleet-x" && : > "$FLEET_CONF_DIR/fleets/fleet-x/conf"
( fails=0; export FLEET_MAIN="$TMP/repo"; unset TMUX
  assert_exit 2 "send-keys ambient fleet"   "$GUARD" "$(bash_json "$(jstr 'tmux send-keys -t win Enter')")"
  assert_exit 2 "send-keys -L a fleet"      "$GUARD" "$(bash_json "$(jstr 'tmux -L fleet-x send-keys -t win C-c')")"
  # ALLOW: the isolated-socket test idiom CLAUDE.md prescribes ("test tmux
  # tooling on an isolated socket") — 12 of the 13 blocks this rail produced were
  # exactly this, never a live pane.
  assert_exit 0 "send-keys -S custom sock"  "$GUARD" "$(bash_json "$(jstr 'tmux -S /tmp/probe.sock send-keys -t t -l hi')")"
  assert_exit 0 "send-keys -L non-fleet"    "$GUARD" "$(bash_json "$(jstr 'tmux -L scratch send-keys -t t C-u')")"
  # ALLOW: the FLEET_ALLOW_SENDKEYS=1 hatch — COMMAND-WIDE since #528, not
  # segment-local: an inline assignment anywhere in the command counts, and so
  # does the process env. Read off one segment the hatch was useless on exactly
  # the compound commands that needed it.
  assert_exit 0 "send-keys + inline hatch"  "$GUARD" "$(bash_json "$(jstr 'FLEET_ALLOW_SENDKEYS=1 tmux send-keys -t win Enter')")"
  assert_exit 0 "hatch on an earlier stmt"  "$GUARD" "$(bash_json "$(jstr 'FLEET_ALLOW_SENDKEYS=1 ; tmux send-keys -t win Enter')")"
  # FALSE-POSITIVE: a script FIXTURE that merely contains the call is data, not a
  # call. Before #528 the heredoc body segmented and its line posed as a command.
  assert_exit 0 "send-keys in a heredoc"    "$GUARD" "$(bash_json "$(jstr 'cat > /tmp/s.sh <<EOF
tmux send-keys -t x Enter
EOF
chmod +x /tmp/s.sh')")"
  exit $fails ); rc=$?; fails=$((fails + rc))
( fails=0; export FLEET_MAIN="$TMP/repo" FLEET_ALLOW_SENDKEYS=1; unset TMUX
  assert_exit 0 "send-keys + env hatch"     "$GUARD" "$(bash_json "$(jstr 'tmux send-keys -t win Enter')")"
  exit $fails ); rc=$?; fails=$((fails + rc))
# ALLOW: a script wrapping send-keys — the hook never sees the subprocess
assert_exit 0 "bash cycle script"   "$GUARD" "$(bash_json "$(jstr 'bash ~/.claude/fleet/bin/fleet-handoff-cycle.sh')")"
# ALLOW: unrelated tmux (a read/list is not send-keys)
assert_exit 0 "tmux list-windows"   "$GUARD" "$(bash_json "$(jstr 'tmux list-windows')")"
# ALLOW: send-keys as a quoted literal to another subcommand isn't the subcommand
assert_exit 0 "send-keys quoted lit" "$GUARD" "$(bash_json "$(jstr 'tmux set-buffer -- "send-keys demo"')")"

# REWRITE (not deny, since #528): a raw gh issue-comment from a FLEET pane is
# repaired onto fleet-comment.sh so the issue-bridge's markers are stamped at the
# source (issue #483) WITHOUT throwing the rest of the command away. Every block
# this rail ever produced hit a compound command (median 1.2 KB, up to 34
# statements), so a deny cost the whole batch to fix one statement.
#
# Fleet context is pinned hermetically via FLEET_MAIN (env is authoritative, no
# tmux consulted). FLEET_LIB points at nothing, so the "does this issue have a
# live bound worker" probe cannot resolve and takes its conservative branch
# (assume yes → rewrite); the rewrite is lossless, so guessing wrong costs
# nothing. The narrow case — a resolvable fleet that reports NO bound worker —
# is covered by the stub-lib block further down.
( fails=0; export FLEET_MAIN="$TMP/repo" FLEET_LIB="$TMP/nope/fleet-lib.sh"; unset TMUX
  assert_rewrite "gh comment -> wrapper"    "$GUARD" "$(bash_json "$(jstr 'gh issue comment 483 --body "done"')")" \
    'fleet-comment.sh --note 483 --body "done"'
  assert_rewrite "gh --repo= comment"       "$GUARD" "$(bash_json "$(jstr 'gh --repo=o/r issue comment 483 -F body.md')")" \
    'fleet-comment.sh --note 483 -F body.md'
  assert_rewrite "gh comment in 2nd stmt"   "$GUARD" "$(bash_json "$(jstr 'echo hi && gh issue comment 12 --body x')")" \
    'echo hi && ~/.claude/fleet/bin/fleet-comment.sh --note 12 --body x'
  # The whole point: the OTHER statements survive untouched, including a body
  # that must not be re-typed and must not be case-folded.
  assert_rewrite "batch keeps its work"     "$GUARD" "$(bash_json "$(jstr 'git commit -m WIP ; gh issue comment 7 --body "Done: See PR" ; echo TAIL')")" \
    'git commit -m WIP ; ~/.claude/fleet/bin/fleet-comment.sh --note 7 --body "Done: See PR" ; echo TAIL'
  # ALLOW verbatim: the FLEET_ALLOW_RAW_COMMENT=1 hatch, inline or in the env,
  # anywhere in the command (command-wide since #528).
  assert_no_rewrite "gh comment + hatch"    "$GUARD" "$(bash_json "$(jstr 'FLEET_ALLOW_RAW_COMMENT=1 gh issue comment 483 --body x')")"
  assert_no_rewrite "hatch on stmt 1 of 2"  "$GUARD" "$(bash_json "$(jstr 'FLEET_ALLOW_RAW_COMMENT=1 echo go ; gh issue comment 483 --body x')")"
  # BLOCK: an issue the wrapper cannot address (its digit-strip would mangle a
  # URL into a different issue number) — refuse rather than post to the wrong one.
  assert_exit 2 "gh comment by URL"         "$GUARD" "$(bash_json "$(jstr 'gh issue comment https://github.com/o/r/issues/483 --body x')")"
  # ALLOW: the sanctioned wrapper (its internal gh runs in a subprocess this
  # layer never sees), and non-comment gh issue verbs
  # shellcheck disable=SC2088  # the tilde is a literal test payload, as typed in a pane
  assert_exit 0 "fleet-comment wrapper"     "$GUARD" "$(bash_json "$(jstr '~/.claude/fleet/bin/fleet-comment.sh 483 --note --body "progress"')")"
  assert_exit 0 "gh issue view"             "$GUARD" "$(bash_json "$(jstr 'gh issue view 483 --json state')")"
  assert_exit 0 "gh pr comment"             "$GUARD" "$(bash_json "$(jstr 'gh pr comment 484 --body "verified"')")"
  # FALSE-POSITIVE discipline: `issue comment` inside a quoted body / another
  # command's args must not trip the anchored rule
  assert_exit 0 "issue comment in body"     "$GUARD" "$(bash_json "$(jstr 'gh issue create --title x --body "never run gh issue comment raw"')")"
  assert_exit 0 "issue comment in echo"     "$GUARD" "$(bash_json "$(jstr 'echo gh issue comment')")"
  exit $fails ); rc=$?; fails=$((fails + rc))

# ALLOW verbatim: a fleet whose bridge reports NO live worker bound to that issue.
# This is the scope fix (#528) — the rail exists so an unmarked comment cannot be
# relayed back into a bound worker as a spurious self-turn, and with nothing bound
# the comment is inert. It was denying overwhelmingly inert commands: of the 43
# blocks it produced, 36 came from scratch panes with no binding at all, and
# exactly ONE was the pane's own issue. Stub lib + bridge so the probe resolves
# without a live fleet.
mkdir -p "$TMP/stub"
cat > "$TMP/stub/fleet-lib.sh" <<'STUB'
fleet_current_session() { printf 'fleet-x'; }
fleet_repo_cached()     { printf 'o/r'; }
STUB
cat > "$TMP/stub/fleet-issue-bridge.sh" <<'STUB'
#!/bin/bash
# --find-window <issue> <repo>: issue 999 is bound to a live worker, nothing else is.
[ "${1:-}" = "--find-window" ] || exit 2
[ "${2:-}" = "999" ] && printf 'fleet-x\t@9\tdone'
exit 0
STUB
( fails=0; export FLEET_MAIN="$TMP/repo" FLEET_LIB="$TMP/stub/fleet-lib.sh"; unset TMUX
  assert_no_rewrite "unbound issue verbatim" "$GUARD" "$(bash_json "$(jstr 'gh issue comment 483 --body x')")"
  assert_rewrite "bound issue rewritten"     "$GUARD" "$(bash_json "$(jstr 'gh issue comment 999 --body x')")" \
    'fleet-comment.sh --note 999 --body x'
  exit $fails ); rc=$?; fails=$((fails + rc))

# ALLOW: the same raw comment OUTSIDE a fleet (no FLEET_MAIN, no TMUX)
( fails=0; unset FLEET_MAIN; unset TMUX
  assert_exit 0 "gh comment (no fleet)"     "$GUARD" "$(bash_json "$(jstr 'gh issue comment 483 --body "done"')")"
  exit $fails ); rc=$?; fails=$((fails + rc))

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

# ---------------------------------------------------------------------------
# artifact-guard.py — a fleet session never PUBLISHES an Artifact (issue #526)
# ---------------------------------------------------------------------------
# An Artifact page is scoped to the claude.ai account that published it; with the
# multi-account pool rotating tokens under sessions (#513/#515/#524) the operator
# cannot tell which account a session used, so the page is invisible from the
# wrong login. The fleet ships doc-preview (a fixed tailnet URL, any device, no
# login) — the guard turns every publish into a pointer at it, and leaves reading /
# listing / commenting on artifacts others shared alone.
ARTGUARD="$BIN/../hooks/artifact-guard.py"
if [ ! -f "$ARTGUARD" ]; then printf 'FAIL: %s not found\n' "$ARTGUARD" >&2; fails=$((fails + 1)); fi
art_json() { printf '{"tool_name":"Artifact","tool_input":%s}' "$1"; }
( fails=0; unset FLEET_ALLOW_ARTIFACT
  # BLOCK: a publish — the default action, spelled out, or a redeploy to an existing url
  assert_exit 2 "artifact publish (default action)"   "$ARTGUARD" "$(art_json '{"file_path":"/tmp/report.html","favicon":"📊"}')"
  assert_exit 2 "artifact publish (explicit)"         "$ARTGUARD" "$(art_json '{"action":"publish","file_path":"/tmp/report.html"}')"
  assert_exit 2 "artifact publish (redeploy to url)"  "$ARTGUARD" "$(art_json '{"file_path":"/tmp/r.html","url":"https://claude.ai/artifacts/x"}')"
  # the refusal must TELL the model what to do instead — the doc-preview share line
  msg=$(printf '%s' "$(art_json '{"action":"publish","file_path":"/tmp/r.html"}')" | "$PY" "$ARTGUARD" 2>&1 >/dev/null)
  case "$msg" in *doc-preview/share.sh*) ;; *) printf 'FAIL: refusal must point at doc-preview/share.sh (got: %s)\n' "$msg" >&2; fails=$((fails + 1)) ;; esac
  # ALLOW: reading / listing / commenting on artifacts others shared
  for a in read list comments reply resolve status watch unwatch read_db list_assets read_asset; do
    assert_exit 0 "artifact $a allowed" "$ARTGUARD" "$(art_json "{\"action\":\"$a\",\"url\":\"https://claude.ai/artifacts/x\"}")"
  done
  # ALLOW: other tools, malformed input (fail open)
  assert_exit 0 "non-artifact tool"  "$ARTGUARD" '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x.html"}}'
  assert_exit 0 "artguard bad json"  "$ARTGUARD" 'nope'
  exit $fails ); rc=$?; fails=$((fails + rc))
# the operator's escape hatch
( fails=0; export FLEET_ALLOW_ARTIFACT=1
  assert_exit 0 "FLEET_ALLOW_ARTIFACT=1 → publish allowed" "$ARTGUARD" "$(art_json '{"action":"publish","file_path":"/tmp/r.html"}')"
  exit $fails ); rc=$?; fails=$((fails + rc))

if [ "$fails" -ne 0 ]; then
  printf '\nbash-guard-selftest: %s case(s) FAILED\n' "$fails" >&2
  exit 1
fi
printf 'bash-guard-selftest: all cases passed\n'
exit 0
