#!/bin/sh
# skill-tools-selftest.sh — a worker skill names TOOLS, never script paths
# (issue #1811, EPIC #1813 C9).
#
# A worker session — Claude or Codex — reaches the fleet through the one tool
# service (bin/fleet-mcp.py, docs/FLEET-MCP.md). So the steps a worker runs from a
# skill say `mcp__fleet__<tool>`, and a `~/.claude/fleet/bin/…` path may appear only
# under a heading that says it is not a worker step: one containing `运营者`
# (operator) or `排障` (troubleshooting), down to the next heading of the same or
# a higher level. Operator skills (owner: hub — the fleet-epic-* family,
# fleet-history) keep their script form and are not linted.
#
# In scope: every commands/*.md marked `owner: worker`, plus the worker-run ones
# named below (owner: either — run from a worker pane too), the fleet-open skill
# and the Codex seed preamble.
#   A  the linter itself, on fixtures: a path in a worker step is red; the same
#      path under 排障 / 运营者 is clean, and the exemption ends at the next
#      heading; a `#` line inside a code fence is not a heading; a
#      `source …/fleet-lib.sh` is red too; an unknown mcp__fleet__ tool is red
#   B  the real skills: no path outside an exempt section, and every
#      mcp__fleet__<tool> they name is a tool fleet-mcp.py serves
#   C  the worker lifecycle skills name the tools that replaced their scripts
set -u

BIN=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$BIN/.." && pwd)
[ -f "$BIN/fleet-mcp.py" ] || { echo "selftest: fleet-mcp.py missing" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/skill-tools.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

pass=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# The tools the server really serves (tools/list, no hub, no tmux needed).
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  | env -u TMUX -u TMUX_PANE python3 "$BIN/fleet-mcp.py" > "$WORK/list" 2>"$WORK/list.err" \
  || fail "fleet-mcp.py tools/list failed" "$(cat "$WORK/list.err")"
python3 -c 'import json,sys; print("\n".join(t["name"] for t in json.load(open(sys.argv[1]))["result"]["tools"]))' \
  "$WORK/list" > "$WORK/tools" || fail "could not read the tool list" "$(cat "$WORK/list")"

cat > "$WORK/lint.py" <<'PY'
"""lint <tools-file> <md>... — print `file:line: why` for each violation."""
import re, sys

PATH = re.compile(r'(~|\$HOME|\$\{HOME\})/\.claude/fleet/bin/|fleet-lib\.sh')
TOOL = re.compile(r'mcp__fleet__([A-Za-z0-9_]+)')
EXEMPT = re.compile(r'运营者|排障')
tools = set(open(sys.argv[1]).read().split())
bad = 0
for path in sys.argv[2:]:
    exempt_at = None                  # heading level that opened the exempt section
    fence = False
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        if re.match(r'^\s*(```|~~~)', line):
            fence = not fence
        elif not fence:
            m = re.match(r'^(#{1,6})\s', line)
            if m:
                level = len(m.group(1))
                if exempt_at is not None and level <= exempt_at:
                    exempt_at = None
                if exempt_at is None and EXEMPT.search(line):
                    exempt_at = level
        for t in TOOL.findall(line):
            if t not in tools:
                print("%s:%d: mcp__fleet__%s is not a fleet tool" % (path, n, t)); bad += 1
        if exempt_at is None and PATH.search(line):
            print("%s:%d: a script path in a worker step — name the tool (or move it under 排障)" % (path, n))
            bad += 1
sys.exit(1 if bad else 0)
PY
lint() { python3 "$WORK/lint.py" "$WORK/tools" "$@"; }

# --- A: the linter on fixtures ---------------------------------------------------
mkdir -p "$WORK/fx"
cat > "$WORK/fx/red-path.md" <<'MD'
# skill
## 1. Ship
Run `~/.claude/fleet/bin/fleet-pr-merge.sh 5`.
MD
cat > "$WORK/fx/red-lib.md" <<'MD'
# skill
```sh
source "$HOME/.claude/fleet/bin/fleet-lib.sh"
```
MD
cat > "$WORK/fx/red-tool.md" <<'MD'
# skill
Call `mcp__fleet__merge_now`.
MD
cat > "$WORK/fx/red-after.md" <<'MD'
# skill
## 排障
`~/.claude/fleet/bin/fleet-gh.sh` is the script.
### detail
still troubleshooting: `~/.claude/fleet/bin/fleet-gh.sh issue view 5`
## 2. Back to work
`~/.claude/fleet/bin/fleet-comment.sh 5`
MD
cat > "$WORK/fx/clean.md" <<'MD'
# skill
## 1. Ship
Call `mcp__fleet__pr_merge` (`pr`), then `mcp__fleet__report`.
```sh
# 排障 — a comment inside a fence is not a heading
echo hi
```
## 运营者 / 排障
`~/.claude/fleet/bin/fleet-pr-merge.sh 5` by hand when the session has no tool.
MD
cat > "$WORK/fx/red-fence.md" <<'MD'
# skill
```sh
# 排障
~/.claude/fleet/bin/fleet-pr-merge.sh 5
```
MD
for f in red-path red-lib red-tool red-after red-fence; do
  out=$(lint "$WORK/fx/$f.md") && fail "A: $f.md should be red" "$out"
done
out=$(lint "$WORK/fx/red-after.md")
case "$out" in *'red-after.md:7:'*) : ;; *) fail "A: the exemption must end at the next same-level heading" "$out" ;; esac
case "$out" in *'red-after.md:3:'*|*'red-after.md:5:'*) fail "A: a path under 排障 (and its sub-heading) must be clean" "$out" ;; esac
out=$(lint "$WORK/fx/clean.md") || fail "A: clean.md should be clean" "$out"
ok "A linter: a path in a worker step / fleet-lib.sh / an unknown tool are red; 排障 · 运营者 sections are exempt to the next heading; a fenced # is no heading"

# --- B: the real skills ------------------------------------------------------------
set --
for f in "$ROOT"/commands/*.md; do
  grep -q '^<!-- fleet skill · owner: worker -->$' "$f" && set -- "$@" "$f"
done
for f in commands/fleet-claim.md commands/fleet-handoff.md commands/fleet-compact-resume.md \
         commands/fleet-context.md skills/fleet-open/SKILL.md skills/handoff/SKILL.md conf/codex-preamble.md; do
  [ -f "$ROOT/$f" ] || fail "B: $f is in scope but missing"
  case " $* " in *" $ROOT/$f "*) : ;; *) set -- "$@" "$ROOT/$f" ;; esac
done
out=$(lint "$@") || fail "B: a worker skill still names a script path (or an unknown tool)" "$out"
ok "B worker skills ($#): no ~/.claude/fleet/bin path outside 排障 / 运营者, every mcp__fleet__ tool real"

# --- C: the lifecycle skills name the tools that replaced their scripts -------------
need() { # need <file> <tool>…
  f=$1; shift
  for t in "$@"; do
    grep -qw "mcp__fleet__$t" "$ROOT/$f" || fail "C: $f must name mcp__fleet__$t"
  done
}
need commands/fleet-claim.md brief comment send ask report evidence pr_verdict pr_merge \
  file_issue gh children await context show open
need commands/fleet-handoff.md status context handoff comment transfer gh
need commands/fleet-compact-resume.md brief gh pr_verdict
need commands/fleet-context.md context
need skills/fleet-open/SKILL.md open where show
ok "C claim · handoff · compact-resume · context · fleet-open name the tools that replaced their scripts"

printf 'skill-tools-selftest: %d passed\n' "$pass"
