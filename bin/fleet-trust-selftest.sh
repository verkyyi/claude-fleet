#!/bin/bash
# fleet-trust-selftest.sh — the pre-trust helper's contract (issue #563).
#
# bin/fleet-trust.sh writes `projects[<path>].hasTrustDialogAccepted = true` into
# Claude Code's ~/.claude.json so an unattended worker pane never parks on the
# "trust this folder?" dialog. Because that file is ALSO written by every running
# claude process, and because trust is a security boundary, the helper has to hold
# four things at once — pinned here:
#
#   * SCOPE   — only the fleet's base checkout and worktrees OF it; anything else
#               is refused and the file is not touched.
#   * LOSSLESS — every other top-level key and every other key of the project
#               entry survive; a writer that lands BETWEEN our read and our rename
#               (the race the atomic write exists for) loses nothing either.
#   * SAFE    — invalid JSON is left alone; a missing file is created 0600; the
#               original mode is preserved; the result is valid JSON.
#   * QUIET   — an already-trusted path is a no-op: no write, no output.
#
# Hermetic: HOME points at a temp dir holding a fake ~/.claude.json; a real
# throwaway git repo + worktree stands in for FLEET_MAIN / issue-<N>. No tmux, no
# network, no real config touched. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
SUT="$BIN/fleet-trust.sh"
[ -f "$SUT" ] || { printf 'selftest: %s missing\n' "$SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 missing — SKIP (the helper needs it)\n' >&2; exit 0; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git missing — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-trust.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

export HOME="$WORK/home"; mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR FLEET_TRUST_RACE_HOOK
CFG="$HOME/.claude.json"

# a realistic fake: unrelated top-level keys, one trusted project with many keys,
# one UNtrusted project (the macmini shape: FLEET_MAIN present but false).
MAIN="$WORK/proj/repo"; mkdir -p "$WORK/proj"
git init -q "$MAIN" && git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
MAIN_P=$(cd "$MAIN" && pwd -P)
git -C "$MAIN" worktree add -q "$WORK/proj/repo-issue-7" -b issue-7 >/dev/null 2>&1 || fail "fixture: worktree add"
WT_P=$(cd "$WORK/proj/repo-issue-7" && pwd -P)
OTHER="$WORK/elsewhere"; mkdir -p "$OTHER"; git init -q "$OTHER"
OTHER_P=$(cd "$OTHER" && pwd -P)

write_cfg() {
  cat > "$CFG" <<JSON
{
  "numStartups": 42,
  "theme": "dark",
  "oauthAccount": {"emailAddress": "x@y"},
  "projects": {
    "/Users/someone/old": {"allowedTools": ["Bash"], "hasTrustDialogAccepted": true, "lastCost": 1.5},
    "$MAIN_P": {"allowedTools": ["Read"], "hasTrustDialogAccepted": false, "mcpServers": {"a": {"x": 1}}, "lastSessionId": "s1"}
  }
}
JSON
  chmod 600 "$CFG"
}
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2:]:
    d = d[k] if isinstance(d, dict) and k in d else None
    if d is None: break
print(json.dumps(d))' "$CFG" "$@"; }
valid_json() { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null; }
# portable: BSD `stat -f` is a FORMAT flag, GNU `stat -f` means "file system" and
# succeeds with the wrong answer — so neither shape can be the other's fallback.
mode_of() { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }

# --- A. check verdicts + exit codes --------------------------------------------
write_cfg
out=$(sh "$SUT" check "$MAIN"); rc=$?
[ "$out" = untrusted ] && [ "$rc" = 1 ] || fail "A check on an untrusted main must say untrusted/exit 1" "got '$out' rc=$rc"
out=$(sh "$SUT" check /Users/someone/old 2>/dev/null); rc=$?   # not a dir here → unknown
[ "$out" = unknown ] && [ "$rc" = 2 ] || fail "A check on a nonexistent dir must say unknown/exit 2" "got '$out' rc=$rc"
rm -f "$CFG"
out=$(sh "$SUT" check "$MAIN"); rc=$?
[ "$out" = unknown ] && [ "$rc" = 2 ] || fail "A check with no config file must say unknown/exit 2" "got '$out' rc=$rc"
[ "$(sh "$SUT" file)" = "$CFG" ] || fail "A file must print \$HOME/.claude.json" "$(sh "$SUT" file)"
ok "A check: untrusted→1, unknown→2 (missing dir / missing file), file names ~/.claude.json"

# --- B. grant on the base checkout: key flipped, everything else preserved ------
write_cfg
before_mode=$(mode_of "$CFG")
out=$(sh "$SUT" grant --main "$MAIN" 2>"$WORK/err"); rc=$?
[ "$rc" = 0 ] || fail "B grant exited $rc" "$(cat "$WORK/err")"
[ "$out" = "$MAIN_P" ] || fail "B grant must print the newly trusted path (physical)" "got '$out'"
valid_json "$CFG" || fail "B result is not valid JSON" "$(cat "$CFG")"
[ "$(jget projects "$MAIN_P" hasTrustDialogAccepted)" = true ] || fail "B hasTrustDialogAccepted not set on main" "$(cat "$CFG")"
[ "$(jget projects "$MAIN_P" allowedTools)" = '["Read"]' ] || fail "B other keys of the project entry were lost" "$(cat "$CFG")"
[ "$(jget projects "$MAIN_P" mcpServers)" = '{"a": {"x": 1}}' ] || fail "B nested project key lost" "$(cat "$CFG")"
[ "$(jget projects "$MAIN_P" lastSessionId)" = '"s1"' ] || fail "B lastSessionId lost" "$(cat "$CFG")"
[ "$(jget numStartups)" = 42 ] || fail "B top-level numStartups lost" "$(cat "$CFG")"
[ "$(jget oauthAccount emailAddress)" = '"x@y"' ] || fail "B top-level nested key lost" "$(cat "$CFG")"
[ "$(jget projects /Users/someone/old hasTrustDialogAccepted)" = true ] || fail "B the other project entry was lost" "$(cat "$CFG")"
[ "$(jget projects /Users/someone/old lastCost)" = 1.5 ] || fail "B the other project's keys were lost" "$(cat "$CFG")"
[ "$(mode_of "$CFG")" = "$before_mode" ] || fail "B file mode changed" "was $before_mode now $(mode_of "$CFG")"
ls "$HOME"/.claude.json.fleet-trust.* >/dev/null 2>&1 && fail "B temp file left behind" "$(ls "$HOME")"
[ "$(sh "$SUT" check "$MAIN")" = trusted ] || fail "B check must now say trusted"
ok "B grant flips main's key; every other top-level + project key preserved; mode kept; valid JSON; no temp litter"

# --- C. idempotent: a second grant is a no-op (no output, file untouched) ------
cp "$CFG" "$WORK/snap"
out=$(sh "$SUT" grant --main "$MAIN" 2>"$WORK/err"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] || fail "C re-grant must be silent + exit 0" "rc=$rc out='$out' $(cat "$WORK/err")"
cmp -s "$CFG" "$WORK/snap" || fail "C re-grant rewrote an already-trusted file" "$(diff "$WORK/snap" "$CFG")"
ok "C an already-trusted main is a no-op — no write, no output"

# --- D. scope: a worktree OF main is trusted alongside it; anything else refused --
write_cfg
out=$(sh "$SUT" grant --main "$MAIN" "$WORK/proj/repo-issue-7" 2>"$WORK/err"); rc=$?
[ "$rc" = 0 ] || fail "D grant main+worktree exited $rc" "$(cat "$WORK/err")"
printf '%s\n' "$out" | grep -qxF "$MAIN_P" || fail "D main not reported" "$out"
printf '%s\n' "$out" | grep -qxF "$WT_P"   || fail "D worktree not reported" "$out"
[ "$(jget projects "$WT_P" hasTrustDialogAccepted)" = true ] || fail "D worktree entry not written" "$(cat "$CFG")"
[ "$(jget projects "$MAIN_P" hasTrustDialogAccepted)" = true ] || fail "D main entry not written" "$(cat "$CFG")"
# a stranger checkout: refused (exit 3), never written — main still handled
write_cfg
out=$(sh "$SUT" grant --main "$MAIN" "$OTHER" 2>"$WORK/err"); rc=$?
[ "$rc" = 3 ] || fail "D a non-worktree dir must be refused with exit 3" "rc=$rc $(cat "$WORK/err")"
grep -q "refusing $OTHER_P" "$WORK/err" || fail "D refusal must name the dir on stderr" "$(cat "$WORK/err")"
[ "$(jget projects "$OTHER_P")" = null ] || fail "D the stranger dir was written anyway" "$(cat "$CFG")"
[ "$(jget projects "$MAIN_P" hasTrustDialogAccepted)" = true ] || fail "D main must still be granted when a sibling arg is refused"
# a main that is not a git checkout: refused outright, file untouched
write_cfg; cp "$CFG" "$WORK/snap"
sh "$SUT" grant --main "$WORK/proj" >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" = 3 ] || fail "D --main on a non-checkout must exit 3" "rc=$rc $(cat "$WORK/err")"
cmp -s "$CFG" "$WORK/snap" || fail "D a refused --main must not touch the file"
sh "$SUT" grant >/dev/null 2>&1; [ $? = 2 ] || fail "D grant without --main must be a usage error (2)"
ok "D scope: main + its worktree written; a stranger checkout / non-checkout main refused (3), never written"

# --- E. concurrent writer between read and rename loses nothing -------------------
# The race hook runs inside the helper after it has READ the file and before it
# WRITES — a claude process saving its own state at that instant. Its key must
# survive, and ours must still land.
write_cfg
cat > "$WORK/racer.sh" <<RACER
#!/bin/sh
python3 - "$CFG" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["numStartups"] = 43
d["projects"]["/Users/someone/new"] = {"hasTrustDialogAccepted": True, "lastCost": 9}
d["projects"]["$MAIN_P"]["lastSessionId"] = "s2"
json.dump(d, open(p, "w"), indent=2)
PY
RACER
chmod +x "$WORK/racer.sh"
out=$(FLEET_TRUST_RACE_HOOK="$WORK/racer.sh" sh "$SUT" grant --main "$MAIN" 2>"$WORK/err"); rc=$?
[ "$rc" = 0 ] || fail "E grant under a race exited $rc" "$(cat "$WORK/err")"
[ "$out" = "$MAIN_P" ] || fail "E grant under a race must still report main" "got '$out'"
valid_json "$CFG" || fail "E result is not valid JSON" "$(cat "$CFG")"
[ "$(jget projects "$MAIN_P" hasTrustDialogAccepted)" = true ] || fail "E our key did not land" "$(cat "$CFG")"
[ "$(jget numStartups)" = 43 ] || fail "E the concurrent writer's top-level change was LOST (stale write won)" "$(cat "$CFG")"
[ "$(jget projects /Users/someone/new lastCost)" = 9 ] || fail "E the concurrent writer's new project entry was LOST" "$(cat "$CFG")"
[ "$(jget projects "$MAIN_P" lastSessionId)" = '"s2"' ] || fail "E the concurrent writer's change to OUR entry was LOST" "$(cat "$CFG")"
ok "E a writer landing between read and rename keeps every one of its keys; ours lands too"

# --- F. invalid JSON is left alone; a missing file is created 0600 ---------------
printf '{ this is not json' > "$CFG"; cp "$CFG" "$WORK/snap"
sh "$SUT" grant --main "$MAIN" >/dev/null 2>"$WORK/err"; rc=$?
[ "$rc" = 5 ] || fail "F invalid JSON must exit 5" "rc=$rc $(cat "$WORK/err")"
cmp -s "$CFG" "$WORK/snap" || fail "F invalid JSON was rewritten"
grep -q "not valid JSON" "$WORK/err" || fail "F must say why on stderr" "$(cat "$WORK/err")"
rm -f "$CFG"
out=$(sh "$SUT" grant --main "$MAIN" 2>"$WORK/err"); rc=$?
[ "$rc" = 0 ] && [ -f "$CFG" ] || fail "F a missing config must be created" "rc=$rc $(cat "$WORK/err")"
valid_json "$CFG" || fail "F created file is not valid JSON" "$(cat "$CFG")"
[ "$(jget projects "$MAIN_P" hasTrustDialogAccepted)" = true ] || fail "F created file lacks our entry" "$(cat "$CFG")"
[ "$(mode_of "$CFG")" = 600 ] || fail "F created file must be 0600" "mode $(mode_of "$CFG")"
ok "F invalid JSON untouched (5); a missing file is created 0600 with just our entry"

# --- G. CLAUDE_CONFIG_DIR relocates the file ---------------------------------------
mkdir -p "$WORK/ccd"
out=$(CLAUDE_CONFIG_DIR="$WORK/ccd" sh "$SUT" grant --main "$MAIN" 2>"$WORK/err"); rc=$?
[ "$rc" = 0 ] && [ -f "$WORK/ccd/.claude.json" ] || fail "G CLAUDE_CONFIG_DIR not honoured" "rc=$rc $(ls -a "$WORK/ccd") $(cat "$WORK/err")"
[ "$(CLAUDE_CONFIG_DIR="$WORK/ccd" sh "$SUT" file)" = "$WORK/ccd/.claude.json" ] || fail "G file must follow CLAUDE_CONFIG_DIR"
[ "$(CLAUDE_CONFIG_DIR="$WORK/ccd" sh "$SUT" check "$MAIN")" = trusted ] || fail "G check must read the relocated file"
ok "G CLAUDE_CONFIG_DIR/.claude.json is used when set"

printf 'selftest PASS: %d checks — fleet-trust.sh is scoped, lossless under a concurrent writer, atomic, idempotent\n' "$pass"
exit 0
