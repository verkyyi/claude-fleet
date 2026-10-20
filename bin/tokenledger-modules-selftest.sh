#!/bin/bash
# tokenledger-modules-selftest.sh — the Go blocks under tokenledger/, the direction
# their dependencies run (claude-fleet#4811, EPIC #4810 共同约定 3), and the subtree
# being inert to the fleet (issue #1391; was tokenledger-isolation-selftest.sh).
#
#   shared/ names NO other block · agent/ (the node, #4812) and hub/ (#4814, not
#   even a test) name shared/ only · e2e/ (a real node against a real hub) any of
#   the three. No go.mod at tokenledger/; go.work joins the four for an editor.
# Static (go.mod / go.work / import lines); with Go on PATH it also asks
# `go list -deps` the same question.
#
#   1. shared/go.mod is …/tokenledger/shared    2. shared/ imports no other block
#   3. hub/go.mod: …/hub, requires + replaces shared, names neither agent nor e2e;
#      no tokenledger/go.mod; go.work uses all four
#   4. no moved package is back under internal/ (tokenledger-split-shared.sh --check)
#   5. no `go install …/cmd/ccquota@<v>` (Go refuses a module with a replace)
#   6. agent/go.mod and e2e/go.mod, with their replaces
#   7. agent/ imports outside agent/+shared/ none, hub/ (tests too) outside hub/+shared/ none
#   8. nothing left in internal/, the old cmd/ccquota or web/ (split-agent / split-hub --check)
#   9. agent/cmd/ccquota/commands.txt is agent/cli.Run's names; the hub's build runs
#      only credproxy and version of them and names the rest in nodeCommands; every
#      `ccquota <cmd>` bin/, hooks/, conf/ name is a node command or a listed hub one
#  10. tokenledger.yml tests every module
# The isolation rails (skipped with --modules: the BREAK-IT drills' sandbox repo):
#  11. install sync never builds Go — fleet-install-apply.sh / fleet-sync-logins.sh
#      run no go/npm/docker and never name tokenledger/
#  12. no hook, daemon unit or conf names tokenledger/
#  13. CI split both ways: ci-plan.sh's selftests rule never matches tokenledger/**,
#      only tokenledger/** reaches a Go block; tokenledger.yml runs only when the
#      gate calls it; selftests-macos.yml has no push / PR trigger
#  14. run-selftests.sh --changed, for real in a throwaway repo: a change confined
#      to tokenledger/ runs the lint group alone
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

# --- 3. the hub module ------------------------------------------------------
[ "$(sed -n 's/^module //p' "$TL/hub/go.mod" 2>/dev/null)" = "$MOD/hub" ] \
  && ok "tokenledger/hub/go.mod is $MOD/hub" || fail "tokenledger/hub/go.mod missing or not module $MOD/hub"
grep -qE "^(require)?[[:space:]]*$MOD/shared v" "$TL/hub/go.mod" 2>/dev/null \
  && ok "hub/go.mod requires $MOD/shared" || fail "hub/go.mod does not require $MOD/shared"
grep -qE "^replace $MOD/shared => \.\./shared$" "$TL/hub/go.mod" 2>/dev/null \
  && ok "hub/go.mod replaces shared with ../shared" || fail "hub/go.mod has no 'replace $MOD/shared => ../shared'"
grep -qE "$MOD/(agent|e2e)[[:space:]]" "$TL/hub/go.mod" 2>/dev/null \
  && fail "hub/go.mod names the node or e2e (the hub never builds them, not even a test)" \
  || ok "hub/go.mod names neither agent nor e2e"
[ -e "$TL/go.mod" ] && fail "tokenledger/go.mod is back (the four blocks are each their own module)" \
  || ok "no module at tokenledger/ itself"
miss=''
for m in hub agent shared e2e; do
  grep -qE "^[[:space:]]*(use[[:space:]]+)?\./${m}[[:space:]]*\)?$" "$TL/go.work" 2>/dev/null || miss="$miss ./$m"
done
grep -qE '^[[:space:]]*(use[[:space:]]+)?\.[[:space:]]*$' "$TL/go.work" 2>/dev/null && miss="$miss (uses . — no module there)"
[ -z "$miss" ] && ok "tokenledger/go.work uses ./hub ./agent ./shared ./e2e" \
  || fail "tokenledger/go.work:$miss"

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
[ "$(sed -n 's/^module //p' "$TL/e2e/go.mod" 2>/dev/null)" = "$MOD/e2e" ] \
  && ok "tokenledger/e2e/go.mod is $MOD/e2e" || fail "tokenledger/e2e/go.mod missing or not module $MOD/e2e"
for m in hub agent shared; do
  grep -qE "^replace $MOD/$m => \.\./$m$" "$TL/e2e/go.mod" 2>/dev/null \
    || fail "e2e/go.mod has no 'replace $MOD/$m => ../$m'"
done

# --- 7. agent names shared/ only; the hub's code does not name agent ---------
hits=$(find "$TL/agent" -name '*.go' -type f -exec grep -HnE "^[[:space:]]*(import[[:space:]]+)?([A-Za-z_.]+[[:space:]]+)?\"$MOD/" {} + 2>/dev/null \
         | grep -vE "\"$MOD/(agent|shared)(/[^\"]*)?\"" | sed "s#^$ROOT/##")
[ -z "$hits" ] && ok "no file under agent/ imports a tokenledger package outside agent/ and shared/" \
  || { fail "agent/ imports outside agent/ and shared/:"; printf '%s\n' "$hits" | sed 's/^/     /'; }
hits=$(find "$TL/hub" -name '*.go' -type f -exec grep -HnE "^[[:space:]]*(import[[:space:]]+)?([A-Za-z_.]+[[:space:]]+)?\"$MOD/" {} + 2>/dev/null \
         | grep -vE "\"$MOD/(hub|shared)(/[^\"]*)?\"" | sed "s#^$ROOT/##")
[ -z "$hits" ] && ok "no file under hub/ (tests too) imports a tokenledger package outside hub/ and shared/" \
  || { fail "hub/ imports outside hub/ and shared/ (a test that starts a node goes to e2e/, through hub/apitest):"; printf '%s\n' "$hits" | sed 's/^/     /'; }
# go list -deps -test of a module: no other block's package (the node's build has
# no hub package; the hub's — tests too — no node package)
deps_only() { # <module dir> <allowed blocks, a|b>
  local out rc bad
  [ -d "$TL/$1" ] || return 0
  out=$(cd "$TL/$1" && GOWORK=off GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local \
        go list -deps -test -f '{{.ImportPath}}' ./... 2>&1); rc=$?
  if [ "$rc" = 0 ]; then
    bad=$(printf '%s\n' "$out" | grep "^$MOD/" | grep -vE "^$MOD/($2)(/| |\$|\.test)" | grep -vE "^$MOD/($2)\$")
    [ -z "$bad" ] && ok "go list -deps -test: $1/ reaches no package outside $(printf '%s' "$2" | tr '|' '/')" \
      || { fail "go list -deps -test: $1/ reaches:"; printf '%s\n' "$bad" | sed 's/^/     /'; }
  else
    case "$out" in
      *GOPROXY=off*|*'module lookup disabled'*|*'missing go.sum entry'*|*'requires go >= '*|*'toolchain'*)
        echo "SKIP go list -deps $1/ (no module cache or toolchain here)" ;;
      *) fail "go list -deps in $1/ failed: $(printf '%s' "$out" | head -3 | tr '\n' '|')" ;;
    esac
  fi
}
if command -v go >/dev/null 2>&1; then
  deps_only agent 'agent|shared'
  deps_only hub 'hub|shared'
fi

# --- 8. nothing left behind -------------------------------------------------
out=$(bash "$BIN/tokenledger-split-agent.sh" --check 2>&1) \
  && ok "internal/agent and the node's cmd/ccquota files are on agent/" \
  || { fail "left in the old place:"; printf '%s\n' "$out" | sed 's/^/     /'; }
out=$(bash "$BIN/tokenledger-split-hub.sh" --check 2>&1) \
  && ok "internal/, cmd/ccquota and web/ are on hub/, and nothing names the old paths" \
  || { fail "left in (or naming) the old place:"; printf '%s\n' "$out" | sed 's/^/     /'; }

# --- 9. the node's subcommands ----------------------------------------------
CMDS="$TL/agent/cmd/ccquota/commands.txt"
listed=$(grep -vE '^[[:space:]]*(#|$)' "$CMDS" 2>/dev/null | sort -u)
[ -n "$listed" ] || fail "no agent/cmd/ccquota/commands.txt"
# a switch's case names: `case "a", "b":` lines, the first name of each
cases() { sed -n 's/^[[:space:]]*case "\([a-z][a-z-]*\)".*/\1/p' "$1" | sort -u; }
ran=$(cases "$TL/agent/cli/run.go")
[ "$ran" = "$listed" ] && ok "commands.txt is agent/cli.Run's names ($(printf '%s\n' "$listed" | wc -l | tr -d ' '))" \
  || { fail "commands.txt and agent/cli/run.go differ:"; diff <(printf '%s\n' "$listed") <(printf '%s\n' "$ran") | sed 's/^/     /'; }
HUBMAIN="$TL/hub/cmd/ccquota/main.go"
hubcmds=$(cases "$HUBMAIN" | grep -vx help)
# credproxy and version: the hub's image runs them too (the credproxy Deployment,
# `ccquota version`'s src line) — shared/credproxy.Main, one implementation
BOTH_BUILDS="credproxy version"
both=$(comm -12 <(printf '%s\n' "$listed") <(printf '%s\n' "$hubcmds") | grep -vxE "$(printf '%s' "$BOTH_BUILDS" | tr ' ' '|')")
[ -z "$both" ] && ok "the hub's build runs no node command but $BOTH_BUILDS" \
  || fail "the hub's build runs a node command itself (it belongs to agent/cli): $both"
# the rest it names in nodeCommands: answered «the node's command», exit 2
refused=$(awk '/^var nodeCommands = map\[string\]bool\{/,/^}/' "$HUBMAIN" 2>/dev/null | grep -oE '"[a-z][a-z-]*"' | tr -d '"' | sort -u)
want=$(printf '%s\n' "$listed" | grep -vxE "$(printf '%s' "$BOTH_BUILDS" | tr ' ' '|')")
[ "$refused" = "$want" ] && ok "the hub's nodeCommands is commands.txt less $BOTH_BUILDS" \
  || { fail "hub/cmd/ccquota nodeCommands and commands.txt differ:"; diff <(printf '%s\n' "$want") <(printf '%s\n' "$refused") | sed 's/^/     /'; }
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

# --- 10. CI runs every module's tests ----------------------------------------
# the test job's parts: rest + api-K are the hub's; shared, agent and e2e each
# their own module (`cd "$MOD" && go test`). The PR gate hands the parts in
# (bin/ci-plan.sh go, issue #4815); the default — a dispatch — is every part.
WF="$ROOT/.github/workflows/tokenledger.yml"
parts=$(awk '/^  test:/ { on = 1 } on && /part: / { print; exit }' "$WF" 2>/dev/null)
for m in rest api-1 shared agent e2e; do
  case "$parts" in
    *"[$m,"*|*" $m,"*|*" $m]"*|*"\"$m\""*) ok "tokenledger.yml's test job has the part $m" ;;
    *) fail "tokenledger.yml's test job has no part $m — $( [ "$m" = rest ] || [ "$m" = api-1 ] && echo "the hub's" || echo "the $m module's") tests would not run" ;;
  esac
done
grep -qE 'cd "\$MOD" && go test' "$WF" 2>/dev/null \
  && ok "tokenledger.yml runs each part's go test in its module" \
  || fail "tokenledger.yml has no go test step run in the part's module (cd \"\$MOD\")"

[ "${1:-}" = --modules ] || {
# --- 11. install sync never builds Go ----------------------------------------
for s in fleet-install-apply.sh fleet-sync-logins.sh; do
  f="$BIN/$s"
  [ -f "$f" ] || { fail "$s missing"; continue; }
  # Code lines only: a comment may explain this very rule.
  hits=$(grep -nE '(^|[^A-Za-z0-9_./-])(go[[:space:]]+(build|install|test|run|generate|mod)|npm[[:space:]]|docker[[:space:]]|make[[:space:]]+-C)' "$f" \
           | grep -vE '^[0-9]+:[[:space:]]*#')
  [ -z "$hits" ] && ok "$s runs no go/npm/docker build" \
    || { fail "$s invokes a build:"; printf '%s\n' "$hits" | sed 's/^/     /'; }
  hits=$(grep -n 'tokenledger' "$f" | grep -vE '^[0-9]+:[[:space:]]*#')
  [ -z "$hits" ] && ok "$s never names tokenledger/" \
    || { fail "$s acts on tokenledger:"; printf '%s\n' "$hits" | sed 's/^/     /'; }
done

# --- 12. no hook / daemon / conf names it ------------------------------------
hits=''
for d in hooks launchd systemd conf; do
  [ -d "$ROOT/$d" ] || continue
  # a line that only keeps it OUT (conf/release-tree.list's `!tokenledger/`,
  # #2771) or a comment is not acting on it
  h=$(grep -rlE '^[^#!]*tokenledger/' "$ROOT/$d" 2>/dev/null)
  [ -n "$h" ] && hits="$hits$h
"
done
[ -z "$hits" ] && ok "no hook / daemon unit / conf names tokenledger/" \
  || { fail "a hook/daemon/conf names tokenledger/:"; printf '%s' "$hits" | sed 's/^/     /'; }

# --- 13. CI split both ways --------------------------------------------------
WFD="$ROOT/.github/workflows"
# paths_of <file> — every `- '<glob>'` entry of the file's `paths:` lists.
paths_of() {
  awk '/^[[:space:]]*paths:[[:space:]]*$/ { inp = 1; next }
       inp && /^[[:space:]]*-[[:space:]]/ { s = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", s); gsub(/["'\'']/, "", s); print s; next }
       { inp = 0 }' "$1"
}
w=selftests-macos.yml
if [ -f "$WFD/$w" ]; then
  # no push / pull_request trigger at all (since #3141: nightly + dispatch only)
  grep -qE '^[[:space:]]*(push|pull_request):' "$WFD/$w" \
    && fail "$w runs on a push or PR" || ok "$w is never triggered by a push or PR"
else
  fail "$w missing"
fi
# the PR gate (issue #4815): ONE plan, bin/ci-plan.sh, says what a PR runs
eval "$(sed -n '/^check_rules()/,/^}/p; /^block_of()/,/^}/p' "$BIN/ci-plan.sh")"
globs=""
if command -v check_rules >/dev/null 2>&1 && check_rules selftests; then
  bad=''
  for g in $globs; do case "$g" in tokenledger*|'*'|'**'*) bad="$bad $g" ;; esac; done
  [ -z "$bad" ] && ok "the selftests' plan rule never matches tokenledger/**" \
    || fail "the selftests' plan rule matches tokenledger/**:$bad"
else
  fail "bin/ci-plan.sh has no selftests rule"
fi
if command -v block_of >/dev/null 2>&1; then
  out=''
  for f in bin/fleet-lib.sh hooks/bash-guard.py conf/x.conf docs/README.md; do out="$out$(block_of "$f")"; done
  [ -z "$out" ] && ok "the Go tests run for no change outside tokenledger/ (shell, hooks, conf, docs)" \
    || fail "a shell / hook / conf / docs change reaches a Go block: [$out]"
  [ "$(block_of tokenledger/hub/api/x.go)" = hub ] && ok "a tokenledger/ change reaches its Go block" \
    || fail "tokenledger/hub/api/x.go reaches no Go block"
else
  fail "bin/ci-plan.sh has no block_of"
fi
T_WF="$WFD/tokenledger.yml"
if [ -f "$T_WF" ]; then
  grep -qE '^[[:space:]]*(push|pull_request):' "$T_WF" \
    && fail "tokenledger.yml runs on a push or PR by itself (ci.yml calls it)" \
    || ok "tokenledger.yml runs only when the PR gate calls it (or by hand)"
  grep -qE '^[[:space:]]*working-directory:[[:space:]]*tokenledger$' "$T_WF" \
    && ok "tokenledger.yml runs inside tokenledger/" || fail "tokenledger.yml has no working-directory: tokenledger"
else
  fail "tokenledger.yml missing"
fi

# --- 14. run-selftests.sh --changed ignores tokenledger/ ---------------------
if command -v git >/dev/null 2>&1; then
  T=$(mktemp -d "${TMPDIR:-/tmp}/fleet-selftest-tokenledger.XXXXXX") || exit 1
  trap 'rm -rf "$T"' EXIT
  R="$T/repo"
  mkdir -p "$R/bin" "$R/tokenledger/hub/cmd/ccquota"
  cp "$BIN/run-selftests.sh" "$BIN/selftest-shadow-root.sh" "$R/bin/"
  mk_test() { printf '#!/bin/sh\n# %s\nexit 0\n' "$2" > "$R/bin/$1-selftest.sh"; }
  mk_test portability 'lint: scans the whole tree'
  mk_test alpha       'reads hub.go and README.md and Makefile'
  mk_test beta        'drives tool-b.sh'
  printf '#!/bin/sh\n' > "$R/bin/tool-b.sh"
  echo 'package main' > "$R/tokenledger/hub/cmd/ccquota/hub.go"
  echo '# tl' > "$R/tokenledger/README.md"
  echo 'all:' > "$R/tokenledger/Makefile"
  g() { git -C "$R" -c user.name=t -c user.email=t@example.invalid "$@"; }
  g init -q && g add -A && g commit -qm base && g tag base
  echo '// edit' >> "$R/tokenledger/hub/cmd/ccquota/hub.go"
  echo more >> "$R/tokenledger/README.md"
  echo '	true' >> "$R/tokenledger/Makefile"
  g add -A && g commit -qm tl
  out=$(env -u FLEET_SELFTEST_ROOT -u FLEET_SELFTEST_NO_SHADOW FLEET_HEAVY=0 \
        sh "$R/bin/run-selftests.sh" --changed base </dev/null 2>&1); rc=$?
  ran=$(printf '%s\n' "$out" | awk '/^PASS /{print $2}' | sort | tr '\n' ' ')
  [ "$rc" -eq 0 ] && [ "$ran" = 'portability-selftest.sh ' ] \
    && ok "--changed: a tokenledger/-only change runs the lint group alone" \
    || { fail "--changed on tokenledger/: rc=$rc ran=[$ran]"; printf '%s\n' "$out" | grep '^select' | sed 's/^/     /'; }
else
  echo "SKIP: git not installed (rail 4)"
fi

}

[ "$FAILS" = 0 ] && echo "tokenledger-modules selftest: OK" || { echo "tokenledger-modules selftest: $FAILS FAILED"; exit 1; }
