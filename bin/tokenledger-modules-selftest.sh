#!/bin/bash
# tokenledger-modules-selftest.sh — the Go blocks under tokenledger/ and the
# direction their dependencies run (claude-fleet#4811, EPIC #4810 共同约定 3).
#
#   shared/  — what the hub and the node both build in; names NO other block
#   agent/   — the node (claude-fleet#4812): the agent package, agent/cli (every
#              node subcommand) and agent/cmd/ccquota (the node's own build);
#              names shared/ only
#   (root)   — tokenledger/go.mod, the hub plus the combined cmd/ccquota (which
#              runs agent/cli first); requires shared and agent, replaces them
#              with ./shared and ./agent
#
# Later members add their own edges here (hub → shared, hub's non-test code
# never names agent, e2e → all). Static: reads go.mod / go.work and the import
# lines, so it needs no Go toolchain and runs on every shard; with Go on PATH it
# also asks `go list -deps` the same question.
#
#   1. tokenledger/shared/go.mod is the module …/tokenledger/shared
#   2. no .go file under shared/ imports another tokenledger package
#   3. the root go.mod requires shared and replaces it with ./shared; go.work
#      lists both (a person's editor; CI builds each GOWORK=off)
#   4. no moved package is back under internal/, and no import still names one
#      there (bin/tokenledger-split-shared.sh --check — a Go PR that raced the
#      move is merged by rerunning that script)
#   5. the node's developer road builds from a checkout: `go install
#      …/cmd/ccquota@<v>` refuses a module with a replace
#   6. tokenledger/agent/go.mod is …/agent and replaces shared with ../shared;
#      the root requires + replaces it, go.work uses it
#   7. no .go file under agent/ imports a tokenledger package outside agent/ and
#      shared/ (go list -deps of the node's build: no hub package), and no
#      non-test file under internal/ imports agent
#   8. nothing is left in internal/agent or the moved cmd/ccquota files
#      (bin/tokenledger-split-agent.sh --check)
#   9. agent/cmd/ccquota/commands.txt is agent/cli.Run's names; the combined
#      cmd/ccquota handles none of them itself; every `ccquota <cmd>` bin/,
#      hooks/ and conf/ name is a node command or a hub one listed below
#  10. tokenledger.yml still tests the agent module: `go list ./...` from
#      tokenledger/ stops at agent/, so without its own step the node's tests
#      would quietly stop running
set -u
BIN=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(cd -- "$BIN/.." && pwd)
TL="$ROOT/tokenledger"
MOD=github.com/verkyyi/claude-fleet/tokenledger
FAILS=0
fail() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
ok()   { printf 'ok   %s\n' "$*"; }

# --- 1. the shared module ---------------------------------------------------
if [ "$(sed -n 's/^module //p' "$TL/shared/go.mod" 2>/dev/null)" = "$MOD/shared" ]; then
  ok "tokenledger/shared/go.mod is $MOD/shared"
else
  fail "tokenledger/shared/go.mod missing or not module $MOD/shared"
fi

# --- 2. shared names no other block -----------------------------------------
# every quoted tokenledger import path in a .go file under shared/ (an import
# block line or a single import), less those inside shared itself
hits=$(find "$TL/shared" -name '*.go' -type f -exec grep -HnE "^[[:space:]]*(import[[:space:]]+)?([A-Za-z_.]+[[:space:]]+)?\"$MOD/" {} + 2>/dev/null \
         | grep -vE "\"$MOD/shared(/[^\"]*)?\"" | sed "s#^$ROOT/##")
[ -z "$hits" ] && ok "no file under shared/ imports another tokenledger block" \
  || { fail "shared/ imports outside itself:"; printf '%s\n' "$hits" | sed 's/^/     /'; }
if command -v go >/dev/null 2>&1; then
  out=$(cd "$TL/shared" && GOWORK=off GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
        go list -deps -test -f '{{.ImportPath}}' ./... 2>&1); rc=$?
  if [ "$rc" = 0 ]; then
    bad=$(printf '%s\n' "$out" | grep "^$MOD/" | grep -v "^$MOD/shared\(/\|$\)")
    [ -z "$bad" ] && ok "go list -deps: shared/ reaches no other tokenledger package" \
      || { fail "go list -deps: shared/ reaches:"; printf '%s\n' "$bad" | sed 's/^/     /'; }
  else
    case "$out" in   # no module cache / an older toolchain here: the static check above stands
      *GOPROXY=off*|*'module lookup disabled'*|*'missing go.sum entry'*|*'requires go >= '*|*'toolchain'*)
        echo "SKIP go list -deps (no module cache or toolchain here)" ;;
      *) fail "go list -deps in shared/ failed: $(printf '%s' "$out" | head -3 | tr '\n' '|')" ;;
    esac
  fi
fi

# --- 3. the root module points at it ----------------------------------------
grep -qE "^(require)?[[:space:]]*$MOD/shared v" "$TL/go.mod" \
  && ok "tokenledger/go.mod requires $MOD/shared" || fail "tokenledger/go.mod does not require $MOD/shared"
grep -qE "^replace $MOD/shared => \./shared$" "$TL/go.mod" \
  && ok "tokenledger/go.mod replaces shared with ./shared" || fail "tokenledger/go.mod has no 'replace $MOD/shared => ./shared'"
if [ -f "$TL/go.work" ] && grep -qE '^[[:space:]]*\.$|use \.$' "$TL/go.work" && grep -qE '\./shared' "$TL/go.work"; then
  ok "tokenledger/go.work uses . and ./shared"
else
  fail "tokenledger/go.work missing or does not use both . and ./shared"
fi

# --- 4. nothing moved back --------------------------------------------------
pkgs=$(sed -n 's/^PKGS="\(.*\)"$/\1/p' "$BIN/tokenledger-split-shared.sh")
[ -n "$pkgs" ] || fail "no PKGS= line in bin/tokenledger-split-shared.sh"
back=''
for p in $pkgs; do
  [ -d "$TL/internal/$p" ] && back="$back internal/$p"
  [ -d "$TL/shared/$p" ] || fail "shared/$p is missing"
done
[ -z "$back" ] && ok "no shared package is back under internal/" \
  || fail "back under internal/ (rerun bin/tokenledger-split-shared.sh):$back"
[ -d "$TL/cmd/ccquota-srcdigest" ] && fail "cmd/ccquota-srcdigest is back outside shared/"
out=$(bash "$BIN/tokenledger-split-shared.sh" --check 2>&1) \
  && ok "every import of a shared package names shared/" \
  || { fail "imports still name internal/:"; printf '%s\n' "$out" | sed 's/^/     /'; }

# --- 5. no `go install …@<v>` of a module with a replace ---------------------
hits=$(grep -rnE "go[[:space:]]+install[[:space:]]+[^ ]*$MOD/[^ ]*@" "$BIN" 2>/dev/null \
         | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v "$(basename "$0"):")
[ -z "$hits" ] && ok "no bin/ script runs go install …tokenledger…@<version>" \
  || { fail "go install <pkg>@<v> refuses tokenledger's replace — build from a checkout:"; printf '%s\n' "$hits" | sed 's/^/     /'; }

# --- 6. the agent module ----------------------------------------------------
if [ "$(sed -n 's/^module //p' "$TL/agent/go.mod" 2>/dev/null)" = "$MOD/agent" ]; then
  ok "tokenledger/agent/go.mod is $MOD/agent"
else
  fail "tokenledger/agent/go.mod missing or not module $MOD/agent"
fi
grep -qE "^replace $MOD/shared => \.\./shared$" "$TL/agent/go.mod" 2>/dev/null \
  && ok "agent/go.mod replaces shared with ../shared" || fail "agent/go.mod has no 'replace $MOD/shared => ../shared'"
grep -qE "^(require)?[[:space:]]*$MOD/agent v" "$TL/go.mod" \
  && ok "tokenledger/go.mod requires $MOD/agent" || fail "tokenledger/go.mod does not require $MOD/agent"
grep -qE "^replace $MOD/agent => \./agent$" "$TL/go.mod" \
  && ok "tokenledger/go.mod replaces agent with ./agent" || fail "tokenledger/go.mod has no 'replace $MOD/agent => ./agent'"
grep -qE '\./agent' "$TL/go.work" 2>/dev/null && ok "tokenledger/go.work uses ./agent" || fail "tokenledger/go.work does not use ./agent"

# --- 7. agent names shared/ only; the hub's code does not name agent ---------
hits=$(find "$TL/agent" -name '*.go' -type f -exec grep -HnE "^[[:space:]]*(import[[:space:]]+)?([A-Za-z_.]+[[:space:]]+)?\"$MOD/" {} + 2>/dev/null \
         | grep -vE "\"$MOD/(agent|shared)(/[^\"]*)?\"" | sed "s#^$ROOT/##")
[ -z "$hits" ] && ok "no file under agent/ imports a tokenledger package outside agent/ and shared/" \
  || { fail "agent/ imports outside agent/ and shared/:"; printf '%s\n' "$hits" | sed 's/^/     /'; }
hits=$(find "$TL/internal" -name '*.go' ! -name '*_test.go' -type f -exec grep -HnE "\"$MOD/agent(/[^\"]*)?\"" {} + 2>/dev/null | sed "s#^$ROOT/##")
[ -z "$hits" ] && ok "no non-test file under internal/ imports agent" \
  || { fail "the hub's code imports the node:"; printf '%s\n' "$hits" | sed 's/^/     /'; }
if command -v go >/dev/null 2>&1; then
  out=$(cd "$TL/agent" && GOWORK=off GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
        go list -deps -test -f '{{.ImportPath}}' ./... 2>&1); rc=$?
  if [ "$rc" = 0 ]; then
    bad=$(printf '%s\n' "$out" | grep "^$MOD/" | grep -vE "^$MOD/(agent|shared)(/| |\$|\.test)" | grep -vE "^$MOD/(agent|shared)\$")
    [ -z "$bad" ] && ok "go list -deps: agent/ (and the node's build) reaches no hub package" \
      || { fail "go list -deps: agent/ reaches:"; printf '%s\n' "$bad" | sed 's/^/     /'; }
  else
    case "$out" in
      *GOPROXY=off*|*'module lookup disabled'*|*'missing go.sum entry'*|*'requires go >= '*|*'toolchain'*)
        echo "SKIP go list -deps agent/ (no module cache or toolchain here)" ;;
      *) fail "go list -deps in agent/ failed: $(printf '%s' "$out" | head -3 | tr '\n' '|')" ;;
    esac
  fi
fi

# --- 8. nothing left behind -------------------------------------------------
out=$(bash "$BIN/tokenledger-split-agent.sh" --check 2>&1) \
  && ok "internal/agent and the node's cmd/ccquota files are on agent/" \
  || { fail "left in the old place:"; printf '%s\n' "$out" | sed 's/^/     /'; }

# --- 9. the node's subcommands ----------------------------------------------
CMDS="$TL/agent/cmd/ccquota/commands.txt"
listed=$(grep -vE '^[[:space:]]*(#|$)' "$CMDS" 2>/dev/null | sort -u)
[ -n "$listed" ] || fail "no agent/cmd/ccquota/commands.txt"
# a switch's case names: `case "a", "b":` lines, the first name of each
cases() { sed -n 's/^[[:space:]]*case "\([a-z][a-z-]*\)".*/\1/p' "$1" | sort -u; }
ran=$(cases "$TL/agent/cli/run.go")
[ "$ran" = "$listed" ] && ok "commands.txt is agent/cli.Run's names ($(printf '%s\n' "$listed" | wc -l | tr -d ' '))" \
  || { fail "commands.txt and agent/cli/run.go differ:"; diff <(printf '%s\n' "$listed") <(printf '%s\n' "$ran") | sed 's/^/     /'; }
hubcmds=$(cases "$TL/cmd/ccquota/main.go" | grep -vx help)
both=$(comm -12 <(printf '%s\n' "$listed") <(printf '%s\n' "$hubcmds"))
[ -z "$both" ] && ok "the combined cmd/ccquota leaves every node command to agent/cli" \
  || fail "the combined cmd/ccquota handles a node command itself (agent/cli.Run runs first): $both"
# Hub commands bin/ may name: run on (or against) the hub, never on a node.
#   hub    — e2e / drills start a hub        enroll — "on the hub: ccquota enroll"
#   name   — "ccquota name must equal …"     notify — the hub's FLEET_NOTIFY_CMD
HUB_NAMED="enroll hub name notify"
CALL_RE="(ccquota|\\\$\{?[A-Za-z_]*(CCQ|ccq)[A-Za-z_]*\}?)[\"'}]*[[:space:]]+[a-z][a-z-]*"
named=$(grep -rnE "$CALL_RE" "$ROOT/bin" "$ROOT/hooks" "$ROOT/conf" 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v "$(basename "$0"):" \
        | grep -oE "$CALL_RE" | awk '{print $NF}' | sort -u)
unknown=''
for w in $named; do
  printf '%s\n' "$listed" | grep -qx "$w" && continue
  printf '%s\n' "$hubcmds" | grep -qx "$w" || continue   # prose, not a subcommand
  case " $HUB_NAMED " in *" $w "*) continue ;; esac
  unknown="$unknown $w"
done
[ -z "$unknown" ] && ok "every ccquota <cmd> bin/ names is the node's, or a hub command listed here" \
  || fail "bin/ names a hub-only ccquota command the node's build lacks (move it to agent/cli, or list it in HUB_NAMED with why):$unknown"

# --- 10. CI runs the node's tests --------------------------------------------
WF="$ROOT/.github/workflows/tokenledger.yml"
if awk '/working-directory: tokenledger\/agent[[:space:]]*$/ { on = 1; next }
        on && /^[[:space:]]*run:.*go test/ { found = 1 }
        on && /^[[:space:]]*- / { on = 0 }
        END { exit !found }' "$WF" 2>/dev/null; then
  ok "tokenledger.yml runs go test in tokenledger/agent"
else
  fail "tokenledger.yml has no go test step in tokenledger/agent — the node's tests would not run"
fi

[ "$FAILS" = 0 ] && echo "tokenledger-modules selftest: OK" || { echo "tokenledger-modules selftest: $FAILS FAILED"; exit 1; }
