#!/bin/sh
# skill-tools-selftest.sh — a worker skill names TOOLS, never script paths
# (issue #1811, EPIC #1813 C9).
#
# A worker session — Claude or Codex — reaches the fleet through the one tool
# service (bin/fleet-mcp.py, docs/dev/FLEET-MCP.md). So the steps a worker runs from a
# skill say `mcp__fleet__<tool>`, and a `~/.claude/fleet/bin/…` path may appear only
# under a heading that says it is not a worker step: one containing `运营者`
# (operator) or `排障` (troubleshooting), down to the next heading of the same or
# a higher level. Operator skills (owner: hub — the fleet-epic-* family,
# fleet-history) keep their script form and are not linted.
#
# In scope: every commands/*.md marked `owner: worker`, plus the worker-run ones
# named below (owner: either — run from a worker pane too), the fleet-open, fleet-help and fleet-preview skills
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
. "$BIN/selftest-lib.sh"
ROOT=$(cd "$BIN/.." && pwd)
[ -f "$BIN/fleet-mcp.py" ] || { echo "selftest: fleet-mcp.py missing" >&2; exit 2; }

st_sandbox "${TMPDIR:-/tmp}/skill-tools.XXXXXX"
trap 'exit 130' INT TERM HUP

pass=0

# The tools each server really serves (tools/list, no hub, no tmux needed): `fleet`,
# and the dispatch group `fleet-orch` (issue #3113) — a line is `<server>__<tool>`.
# As every session launches since issue #4703: fleet-orch beside fleet (FLEET_MCP_ORCH=1),
# so `fleet` lists its core only.
: > "$WORK/tools"
for grp in core orch; do
  srv=fleet; [ "$grp" = orch ] && srv=fleet-orch
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
    | env -u TMUX -u TMUX_PANE -u FLEET_MCP_EXEC FLEET_MCP_ORCH=1 python3 "$BIN/fleet-mcp.py" --group "$grp" > "$WORK/list" 2>"$WORK/list.err" \
    || st_fail "fleet-mcp.py --group $grp tools/list failed" "$(cat "$WORK/list.err")"
  python3 -c 'import json,sys; print("\n".join(sys.argv[2] + "__" + t["name"] for t in json.load(open(sys.argv[1]))["result"]["tools"]))' \
    "$WORK/list" "$srv" >> "$WORK/tools" || st_fail "could not read the tool list" "$(cat "$WORK/list")"
done

cat > "$WORK/lint.py" <<'PY'
"""lint <tools-file> <md>... — print `file:line: why` for each violation."""
import re, sys

PATH = re.compile(r'(~|\$HOME|\$\{HOME\})/\.claude/fleet/bin/|fleet-lib\.sh')
TOOL = re.compile(r'mcp__(fleet(?:-orch)?__[A-Za-z0-9_]+)')
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
                print("%s:%d: mcp__%s is not a tool that server lists" % (path, n, t)); bad += 1
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
cat > "$WORK/fx/red-server.md" <<'MD'
# skill
Call `mcp__fleet__spawn` — the dispatch group is `fleet-orch`'s (issue #3113).
MD
cat > "$WORK/fx/red-after.md" <<'MD'
# skill
## 排障
`~/.claude/fleet/bin/fleet-heavy.sh` is the script.
### detail
still troubleshooting: `~/.claude/fleet/bin/fleet-heavy.sh --status`
## 2. Back to work
`~/.claude/fleet/bin/fleet-pr-merge.sh 5`
MD
cat > "$WORK/fx/clean.md" <<'MD'
# skill
## 1. Ship
Call `mcp__fleet__pr_merge` (`pr`), then summarize the result; independent work uses `mcp__fleet-orch__task`.
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
for f in red-path red-lib red-tool red-server red-after red-fence; do
  out=$(lint "$WORK/fx/$f.md") && st_fail "A: $f.md should be red" "$out"
done
out=$(lint "$WORK/fx/red-after.md")
case "$out" in *'red-after.md:7:'*) : ;; *) st_fail "A: the exemption must end at the next same-level heading" "$out" ;; esac
case "$out" in *'red-after.md:3:'*|*'red-after.md:5:'*) st_fail "A: a path under 排障 (and its sub-heading) must be clean" "$out" ;; esac
out=$(lint "$WORK/fx/clean.md") || st_fail "A: clean.md should be clean" "$out"
st_pass "A linter: a path in a worker step / fleet-lib.sh / an unknown tool / a tool on the wrong server are red; 排障 · 运营者 sections are exempt to the next heading; a fenced # is no heading"

# --- B: the real skills ------------------------------------------------------------
set --
for f in "$ROOT"/commands/*.md; do
  grep -q '^<!-- fleet skill · owner: worker -->$' "$f" && set -- "$@" "$f"
done
for f in commands/fleet-handoff.md commands/fleet-compact-resume.md \
         commands/fleet-context.md skills/fleet-open/SKILL.md skills/fleet-help/SKILL.md skills/handoff/SKILL.md \
         skills/fleet-preview/SKILL.md conf/codex-preamble.md; do
  [ -f "$ROOT/$f" ] || st_fail "B: $f is in scope but missing"
  case " $* " in *" $ROOT/$f "*) : ;; *) set -- "$@" "$ROOT/$f" ;; esac
done
out=$(lint "$@") || st_fail "B: a worker skill still names a script path (or an unknown tool)" "$out"
st_pass "B worker skills ($#): no ~/.claude/fleet/bin path outside 排障 / 运营者, every mcp__fleet__ tool real"

# --- C: the lifecycle skills name the tools that replaced their scripts -------------
need() { # need <file> <tool>…
  f=$1; shift
  for t in "$@"; do
    grep -Eqw "mcp__fleet(-orch)?__$t" "$ROOT/$f" || st_fail "C: $f must name mcp__fleet__$t (or the dispatch group's mcp__fleet-orch__$t)"
  done
}
need commands/fleet-handoff.md status context handoff transfer
need commands/fleet-compact-resume.md brief pr_verdict
need commands/fleet-context.md context
need skills/fleet-open/SKILL.md open where show
need skills/fleet-preview/SKILL.md preview where open
st_pass "C handoff · compact-resume · context · fleet-open · fleet-preview name the tools that replaced their scripts"

printf 'skill-tools-selftest: %d passed\n' "$pass"
