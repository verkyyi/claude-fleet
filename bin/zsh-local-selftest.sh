#!/bin/bash
# zsh-local-selftest.sh — the regression net for issue #1633: a `local` named like
# one of zsh's SPECIAL parameters silently breaks the function when a zsh sources
# the file.
#
# Claude Code's Bash tool runs the login shell, and on the operator's machine that
# is zsh. Every skill that does `source ~/.claude/fleet/bin/fleet-lib.sh` and then
# calls a function runs that function IN ZSH. There `path` is the array tied to
# $PATH, so `local o iss owt path k pre` (fleet_origin_key) emptied PATH for the
# rest of the function: the next `tmux display-message` was "command not found",
# the key came back empty, and /fleet-epic-run's four members were stamped with
# the EPIC's key instead of the scratch that started them — every one of them at
# the top of the sidebar instead of nested under its parent. bash has no such
# parameter, so every selftest (all bash) passed.
#
# The rule, repo-wide over bin/*.sh: a `local` / `typeset` / `declare` /
# `readonly` never declares a name zsh treats as special (`path`, `argv`,
# `status`, `pipestatus`, `options`, `fpath`, `commands`, `aliases`, …). Rename
# it (`pth`, `cmdline`, `stfile`). A deliberate exception marks its line
# `# zsh-ok: <why>`.
#
#   PART 1 — the RULE: no such declaration anywhere in bin/*.sh.
#   PART 2 — the LINT: fixtures prove it flags each unsafe shape, clears each safe
#            one, and honours the escape hatch. Always runs.
#   PART 3 — the CLAIM: on a real zsh, `local path` loses PATH and `local pth`
#            does not. SKIPs (still exit 0) where no zsh exists. The end-to-end
#            leg — `zsh -c 'source fleet-lib.sh; fleet_origin_key'` in a scratch
#            pane on an isolated socket — lives in origin-selftest.sh part A.
#
# Hermetic: reads files, runs zsh on a one-liner. No network, no tmux, no gh.
# Exit 0 = pass, non-zero = fail (prints every offending site).
set -uo pipefail

BIN=$(cd -- "$(dirname -- "$0")" && pwd)
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/zsh-local-selftest.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

# --- the lint ------------------------------------------------------------------
# zsh_local_lint <file>… → `file:line: name` for every declaration of a zsh
# special parameter. A declaration is the keyword at the start of a statement up
# to the first unquoted ; & | ) or #; quoted strings and $(…) are blanked first,
# so `local x="path status"` and `local d; d=$(git status)` stay clean.
zsh_local_lint() {
  python3 - "$@" <<'PY'
import re, sys
SPECIAL = set("""
path fpath cdpath manpath mailpath module_path psvar fignore watch
argv status pipestatus options prompt histchars signals
commands functions aliases galiases saliases dis_aliases dis_functions
builtins reswords parameters modules history historywords
jobstates jobtexts jobdirs dirstack userdirs nameddirs mapfile sysparams
errnos termcap terminfo widgets keymaps patchars
funcstack functrace funcfiletrace funcsourcetrace zsh_eval_context
""".split())
DECL = re.compile(r'(?:^|[;&|{(]|\bthen|\bdo|\belse)\s*(local|typeset|declare|readonly)\s+(.*)')
def blank(s):
    # $(…) and quoted strings → spaces, one level of nesting is plenty here
    s = re.sub(r'\$\([^()]*\)', ' ', s)
    s = re.sub(r"'[^']*'", "''", s)
    s = re.sub(r'"(?:[^"\\]|\\.)*"', '""', s)
    return s
bad = 0
for f in sys.argv[1:]:
    try:
        lines = open(f, encoding='utf-8', errors='replace').read().split('\n')
    except OSError:
        continue
    for n, raw in enumerate(lines, 1):
        if 'zsh-ok:' in raw or raw.lstrip().startswith('#'):
            continue
        line = blank(raw)
        for m in DECL.finditer(line):
            tail = re.split(r'[;&|)#]', m.group(2), 1)[0]
            for tok in tail.split():
                if tok.startswith('-'):
                    continue
                name = re.match(r'[A-Za-z_][A-Za-z0-9_]*', tok)
                if name and name.group(0) in SPECIAL:
                    print('%s:%d: %s' % (f, n, name.group(0)))
                    bad = 1
sys.exit(bad)
PY
}

command -v python3 >/dev/null 2>&1 || { printf 'zsh-local-selftest: python3 missing — SKIPPED\n'; exit 0; }

# --- PART 1: the rule ----------------------------------------------------------
if ! hits=$(zsh_local_lint "$BIN"/*.sh); then
  printf '%s\n' "$hits" >&2
  fail "a local declares a zsh special parameter (rename it, or mark the line '# zsh-ok: <why>') — issue #1633"
fi
ok

# --- PART 2: the lint, on fixtures ---------------------------------------------
flags() { # <label> <snippet> — the lint MUST flag it
  printf '%s\n' "$2" > "$WORK/f.sh"
  zsh_local_lint "$WORK/f.sh" >/dev/null && fail "lint missed: $1"; ok
}
clears() { # <label> <snippet> — the lint must NOT flag it
  printf '%s\n' "$2" > "$WORK/f.sh"
  out=$(zsh_local_lint "$WORK/f.sh") || fail "lint false positive: $1 → $out"; ok
}
flags  'local path'                 '  local o iss owt path k pre'
flags  'local path=value'           '  local sess="$1" conf repo path="$x"'
flags  'local argv after a value'   '  local rule="$1" argv="$7" action="$8"'
flags  'local status'               '  local status="$1" limit="$2" waited=0'
flags  'typeset -a path'            '  typeset -a path'
flags  'declare after a ;'          '  x=1; declare options=()'
flags  'local after then'           '  if :; then local aliases=x; fi'
clears 'renamed'                    '  local o iss owt pth k pre'
clears 'name inside a quoted value' '  local msg="path status argv"'
clears 'status in a later command'  '  local dirty; dirty=$(git -C "$wt" status --porcelain)'
clears 'status in $(…) of a value'  '  local out=$(git status --short)'
clears 'a comment'                  '  # local path is what broke #1633'
clears 'a trailing comment'         '  local pth  # not path'
clears 'escape hatch'               '  local path  # zsh-ok: fixture'
clears 'similar names'              '  local paths path_x my_path statuses argv0'
clears 'python local[…]'            '                local[m.group(1)] = 1'

# --- PART 3: the claim, on a real zsh ------------------------------------------
if command -v zsh >/dev/null 2>&1; then
  got=$(zsh -fc 'f() { local path; command -v ls >/dev/null && echo found || echo lost; }; f' 2>/dev/null)
  [ "$got" = lost ] || fail "claim: zsh 'local path' was expected to lose PATH, got [$got]"; ok
  got=$(zsh -fc 'f() { local pth; command -v ls >/dev/null && echo found || echo lost; }; f' 2>/dev/null)
  [ "$got" = found ] || fail "claim: zsh 'local pth' should keep PATH, got [$got]"; ok
  # Sourcing fleet-lib.sh under zsh prints nothing (fleet-lang.sh's direct-run
  # guard read zsh's $0 — the SOURCED file — as a direct run, issue #1633).
  got=$(cd "$WORK" && zsh -fc ". '$BIN/fleet-lib.sh'" 2>/dev/null)
  [ -z "$got" ] || fail "claim: sourcing fleet-lib.sh under zsh printed [$got]"; ok
else
  printf 'zsh-local-selftest: zsh not installed — part 3 SKIPPED\n'
fi

printf 'zsh-local-selftest: %d checks passed\n' "$CHECKS"
