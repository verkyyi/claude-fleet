#!/bin/bash
# tokenledger-split-agent.sh — the mechanical half of claude-fleet#4812 (EPIC
# #4810 C2): the node program becomes its own module, tokenledger/agent.
#
#   bin/tokenledger-split-agent.sh [--check]
#
#   internal/agent/*            → agent/          (package agent, the module root)
#   cmd/ccquota/<node file>.go  → agent/cli/      (package cli; FILES below)
#
# and every import of tokenledger/internal/agent becomes tokenledger/agent.
# Idempotent like bin/tokenledger-split-shared.sh: a file already moved is left
# alone, so a Go PR that raced this move is merged by re-running the script on
# top of it (EPIC #4810 共同约定 8), never by hand. --check exits 1 (and lists
# them) when something still names the old place.
#
# The hand-made half (cli.Run, runAgent out of hub.go, the exported helpers the
# combined cmd/ccquota still uses) was written once in the same commit; a raced
# edit to one of those spots is a normal merge.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TL="$ROOT/tokenledger"
MOD=github.com/verkyyi/claude-fleet/tokenledger
# the node's subcommands' files (agent/cmd/ccquota/commands.txt is the list of names)
FILES="agent_machine.go agent_machine_other.go agent_machine_unix.go agent_machine_test.go
agent_machine_hubdial_test.go agent_machine_script_test.go chat_pipe.go term_pty.go
report.go report_test.go stamp.go budget.go budget_test.go budget_json_test.go
budget_codex_test.go codex.go codex_test.go credproxy.go lease.go lease_test.go place.go place_test.go
move.go move_test.go release.go install.go secretflag_test.go"

if [ "${1:-}" = --check ]; then
  left=$(grep -rlE "\"$MOD/internal/agent\"" --include='*.go' "$TL" || true)
  for f in $FILES; do [ -f "$TL/cmd/ccquota/$f" ] && left="$left
$TL/cmd/ccquota/$f"; done
  [ -d "$TL/internal/agent" ] && left="$left
$TL/internal/agent/"
  left=$(printf '%s\n' "$left" | sed '/^$/d')
  [ -z "$left" ] && { echo "tokenledger-split-agent: everything is on agent/"; exit 0; }
  echo "tokenledger-split-agent: still in the old place — rerun bin/tokenledger-split-agent.sh:"
  printf '%s\n' "$left" | sed "s#^$ROOT/#  #"
  exit 1
fi

cd "$ROOT"
mkdir -p "$TL/agent/cli"
if [ -d "$TL/internal/agent" ]; then
  (cd "$TL/internal/agent" && find . -type f) | while read -r f; do
    mkdir -p "$(dirname "$TL/agent/$f")"
    git mv -f "$TL/internal/agent/$f" "$TL/agent/$f"
  done
  rmdir "$TL/internal/agent" 2>/dev/null || true
fi
for f in $FILES; do
  [ -f "$TL/cmd/ccquota/$f" ] || continue
  git mv -f "$TL/cmd/ccquota/$f" "$TL/agent/cli/$f"
  perl -pi -e 's/^package main$/package cli/' "$TL/agent/cli/$f"
done

# imports (and the comments that cite the package by its path)
find "$TL" -name '*.go' -type f -print0 | xargs -0 perl -pi -e \
  "s#\\b(tokenledger/)?internal/agent\\b#\${1}agent#g"
grep -rlE "\"$MOD/agent(/[^\"]*)?\"" --include='*.go' "$TL" | xargs gofmt -w
echo "tokenledger-split-agent: internal/agent → agent/, $(printf '%s' "$FILES" | wc -w | tr -d ' ') files → agent/cli"
