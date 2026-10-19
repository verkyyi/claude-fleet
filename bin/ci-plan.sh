#!/bin/bash
# ci-plan.sh — which PR checks does this change reach? (issues #4794, #4815)
#
#   ci-plan.sh <check> <base>        one check: run=true|false + one line of why
#   ci-plan.sh all <base> [--out F]  every PR check, one `<key>=true|false` per check
#                                    plus the Go blocks — what .github/workflows/ci.yml's
#                                    plan job turns into its callers' `if:`s; --out
#                                    writes the record (the `ci-plan` artifact)
#   ci-plan.sh go <base> [--no-pkgs] the Go blocks (EPIC #4810): `select: <block> ← <why>`
#                                    / `skip: <block> ← <why>`, then each block's packages
#   ci-plan.sh checks                the check keys, one per line
#
# ONE place decides what a PR runs (docs/dev/CI.md): every check used to carry its
# own `paths:`, and nearly every PR touches bin/. Here each check has
#   globs — the paths it builds or serves wholesale (its old `paths:`, its own
#           workflow file): a match runs it;
#   among — (task-acceptance, client-e2e, fleet-hub-mcp) its entry files: when only
#           those globs matched loosely, the selftest selector says whether a
#           changed file is actually named (`run-selftests.sh --changed <base>
#           --list-only --among <files>` — the rules the selftest gate trusts).
# Go (`tokenledger`) is four modules, so four blocks: shared/** ⇒ all four,
# agent/** ⇒ agent + e2e, hub/** ⇒ hub + e2e, e2e/** ⇒ e2e; go.work, the
# Dockerfile, the quarantine list, this file, the Go workflow ⇒ all four; a bin/
# script a Go test runs (go_driven) ⇒ that test's block and package. Inside a
# selected block `go list -test` keeps only the packages whose test binary depends
# on a changed package — none left ⇒ the block is skipped too.
#
# Anything it cannot answer — an unknown base, a git or `go list` error, a path
# under tokenledger/ it has no rule for — runs (unsure ⇒ run: EPIC #4810 共同约定 7).
# A change to this file or ci.yml runs every check. A skipped check reads green in
# `CI 结论`; the nightly runs each of them whole.
set -uo pipefail

bin=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$bin/.." && pwd)
# every check key; ci.yml calls each, and its `CI 结论` job needs each
CHECKS='selftests shellcheck tokenledger task_acceptance client_e2e fleet_hub_mcp browser_attachment hub_rolling hub_deploy_check cluster_perms native_claude_worktree native_managed_hooks node_join oss_scan web_chat_ui web_console'
# a change to the plan itself (or the workflow that runs it) runs everything
SELF='bin/ci-plan.sh .github/workflows/ci.yml'
MODPFX=github.com/verkyyi/claude-fleet/tokenledger
# set by go_plan (eval'd per block)
GO_PKGS_hub=''   # read by name below; it and its siblings are eval'd by go_plan

usage() { sed -n '2,13p' "$0" >&2; exit 2; }

# check → entry files (from bin/; ../x outside it) | globs that run it whole.
# `*` crosses / here (shell case). Keep each glob list the check's old `paths:`.
check_rules() {
  among='' globs='' paths=''
  case "$1" in
    selftests)
      globs='bin/* hooks/* conf/* launchd/* systemd/* .claude-plugin/* commands/* skills/* shell/* extras/* mod/* fleet.conf.example .github/workflows/selftests.yml .github/workflows/selftests-shards.yml' ;;
    shellcheck)
      globs='bin/* hooks/* shell/* extras/* .shellcheckrc .shellcheck-version .github/workflows/shellcheck.yml' ;;
    task_acceptance|task-acceptance)
      among='nogh-task-acceptance.py nogh-live-selftest.sh nogh_live_kernel_test.py nogh_live_http_test.py fleet-client-pack.sh'
      paths='bin/* tokenledger/* extras/web-console/* .github/workflows/task-acceptance.yml'
      globs='tokenledger/* extras/web-console/* .github/workflows/task-acceptance.yml' ;;
    client_e2e|client-e2e)
      # the installer fetches every file the client manifest lists
      among='client-e2e.sh nogh-e2e-selftest.sh fleet-client-pack.sh ../tokenledger/hub/api/fleetclient/manifest'
      paths='bin/* shell/* conf/* tokenledger/* .github/workflows/client-e2e.yml'
      globs='tokenledger/* .github/workflows/client-e2e.yml' ;;
    fleet_hub_mcp|fleet-hub-mcp)
      # run-selftests.sh fleet-hub 'fleet-hub-[0-9]*', with the MCP SDK installed
      among=$(cd "$bin" && printf '%s ' fleet-hub-selftest.sh fleet-hub-selftest.py fleet-hub-[0-9]*-selftest.sh)
      paths='bin/fleet* requirements-mcp.txt .github/workflows/fleet-hub.yml'
      globs='requirements-mcp.txt .github/workflows/fleet-hub.yml' ;;
    browser_attachment)
      globs='tokenledger/* bin/fleet-webterm.py bin/fleet-term-attach.sh bin/fleet_view.py extras/browser-transport/* extras/web-console/* extras/web-chat/ui/* .github/workflows/browser-attachment.yml' ;;
    hub_rolling)
      globs='deploy/k8s/* .github/actions/hub-release/* .github/workflows/hub-rolling.yml tokenledger/*' ;;
    hub_deploy_check)
      globs='deploy/k8s/* .github/actions/hub-* .github/workflows/hub-deploy.yml .github/workflows/hub-deploy-check.yml' ;;
    cluster_perms)
      globs='deploy/k8s/fleet-workers/* deploy/k8s/provisioner/* deploy/k8s/credproxy/* deploy/k8s/egress/* deploy/k8s/caches/* extras/managed-node/render.py bin/fleet-provisioner.py bin/fleet-node-linux.py bin/fleet_cluster_ticket.py bin/fleet_admin_ticket.py bin/fleet_ed25519.py bin/fleet-job-runner.sh .github/workflows/cluster-perms.yml' ;;
    native_claude_worktree)
      globs='bin/fleet-native-claude-worktree-selftest.py bin/fleet-native-claude-tui-selftest.py bin/fleet-native-create-claude-selftest.py bin/fleet-claude.sh bin/fleet-agent-team.py hooks/settings-hooks.json conf/mcp-worker.json bin/.fleet-restore-resolve.py bin/fleet-restore.sh bin/dash-raw-session.sh bin/fleet_launch.py bin/fleet_repo_authority.py bin/fleet-lib.sh bin/fleet-client-core.sh bin/fleet-worktree-drop.sh hooks/base-readonly-guard.py .github/workflows/native-claude-worktree.yml' ;;  # wrap-ok: path globs, not a launch
    native_managed_hooks)
      globs='bin/fleet-native-hook-cli-selftest.py bin/fleet-native-local-runtime-selftest.py bin/fleet-native-session-env-selftest.py bin/fleet-mcp.py bin/fleet_launch.py bin/fleet-agent-defaults.py conf/agent-defaults/codex/config.default.toml bin/fleet-native-usage-cli-selftest.py bin/fleet-native-guard-install-selftest.py extras/managed-node/image-stage.py bin/fleet-codex-runtime.py bin/fleet-codex-rpc.py bin/fleet-codex-attention.py bin/fleet-codex-session.py conf/statusline.sh bin/fleet-hooks-emit.sh hooks/settings-hooks.json hooks/codex-map.json hooks/bash-guard.py hooks/base-readonly-guard.py .github/workflows/native-managed-hooks.yml' ;;
    node_join)
      globs='bin/fleet-node-join.sh tokenledger/hub/api/fleet_join.go tokenledger/hub/store/fleet_join.go .github/workflows/node-join.yml' ;;
    oss_scan)
      globs='*' ;;   # every PR: nothing of ours may leak, whatever changed
    web_chat_ui)
      globs='extras/web-chat/ui/* extras/fleet-theme/* extras/browser-transport/* .github/workflows/web-chat-ui.yml' ;;
    web_console)
      globs='extras/web-console/* extras/browser-transport/* extras/fleet-theme/* bin/web-console-pack.sh .github/workflows/web-console.yml' ;;
    tokenledger)
      globs='' ;;    # the Go blocks decide (go_plan)
    *) return 1 ;;
  esac
  return 0
}

# changed_files <base> → sets $files (newline list); returns 1 when it cannot tell
changed_files() {
  local mb
  local head=${CI_PLAN_HEAD:-HEAD}   # a replay names the commit (CI_PLAN_HEAD)
  mb=$(git -C "$root" merge-base "$1" "$head" 2>/dev/null) || { why="base '$1' does not resolve"; return 1; }
  files=$(git -C "$root" diff --no-renames --name-only "$mb" "$head" 2>/dev/null) || { why="git diff failed"; return 1; }
  MB=$mb
  return 0
}

# --- one check ------------------------------------------------------------
# plan_check <check> → sets $run (true|false) and $why. Needs $files / $MB / $unsure.
plan_check() {
  local c=$1 f g picks
  run=true
  [ -z "$unsure" ] || { why="$unsure — unsure, so it runs"; return; }
  check_rules "$c" || { run=true why="no rule for '$c' — unsure, so it runs"; return; }
  set -f
  for f in $files; do
    for g in $SELF; do [ "$f" = "$g" ] && { set +f; why="$f changed (the plan itself)"; return; }; done
  done
  if [ "$c" = tokenledger ]; then
    set +f
    go_plan
    if [ -n "$GO_SELECTED" ]; then why="Go blocks: $GO_SELECTED"; else run=false why="no Go block is reached"; fi
    return
  fi
  for f in $files; do
    for g in $globs; do
      # shellcheck disable=SC2254  # intentional: $g is a glob ( * crosses / in case )
      case "$f" in $g) set +f; why="$f changed (${g})"; return ;; esac
    done
  done
  if [ -n "$paths" ]; then
    # the selector is asked only about a change inside the check's old `paths:`
    local inside=''
    for f in $files; do
      for g in $paths; do
        # shellcheck disable=SC2254
        case "$f" in $g) inside=1; break 2 ;; esac
      done
    done
    [ -n "$inside" ] || { set +f; run=false why="no changed file is inside its paths"; return; }
  fi
  set +f
  if [ -z "$among" ]; then run=false why="no changed file matches its paths"; return; fi
  picks=$(cd "$bin" && FLEET_HEAVY=0 bash run-selftests.sh --changed "$MB" --list-only --among "$among" 2>/dev/null) \
    || { why="the selector failed — unsure, so it runs"; return; }
  [ -z "$picks" ] || { why="related: $(printf '%s' "$picks" | tr '\n' ' ')"; return; }
  run=false why="no changed file is named by its entry files ($among)"
}

# --- the Go blocks ----------------------------------------------------------
# block_of <file> → shared|agent|hub|e2e|all|none|unknown (not under tokenledger: empty)
block_of() {
  case "$1" in
    tokenledger/shared/*) echo shared ;;
    tokenledger/agent/*)  echo agent ;;
    tokenledger/hub/*)    echo hub ;;
    tokenledger/e2e/*)    echo e2e ;;
    tokenledger/go.work|tokenledger/go.work.sum|tokenledger/Dockerfile|tokenledger/Makefile|tokenledger/test-quarantine.txt|tokenledger/.gitignore)
      echo all ;;
    # the cost tables only deal the shards (issue #4817): the tests are the same
    tokenledger/README.md|tokenledger/LICENSE|tokenledger/docs/*|tokenledger/notify/*|tokenledger/test-durations*.txt) echo none ;;
    tokenledger/*) echo unknown ;;
    # what builds or gates the Go tests from outside tokenledger/
    .github/workflows/tokenledger.yml|bin/tokenledger-quarantine.sh|bin/tokenledger-modules-selftest.sh|bin/go-test-shard.sh)
      echo all ;;
    bin/fleet-client-pack.sh) echo hub ;;   # packs the client the hub embeds
    *) echo '' ;;
  esac
}

# go_driven <file> → the Go test files that run a bin/ script (issue #4944:
# #4937 changed bin/fleet-task-record.sh, which hub/api's tests execute, and no
# block was picked). Run = named inside a filepath.Join — `"bin/<name>"` or
# `"bin", "<name>"` — or on a `// drives: bin/<name> …` line (a script the test
# reaches through another one). A path merely listed as data is not a run.
go_driven() {
  case "$1" in bin/*/*) return 0 ;; bin/?*) ;; *) return 0 ;; esac
  local q
  q=$(printf '%s' "${1#bin/}" | sed 's/[].[\*^$+?(){}|]/\\&/g')
  (cd "$root" && grep -rlE --include='*_test.go' \
    -e "filepath\.Join\([^;]*(\"bin/$q\"|\"bin\", *\"$q\")" -e "// drives:.* bin/$q( |\$)" \
    tokenledger/shared tokenledger/agent tokenledger/hub tokenledger/e2e 2>/dev/null) | sort
}

# go_plan → GO_SELECTED (blocks, space-separated), GO_WHY_<block>, GO_PKGS_<block>
# (import paths, or `./...` = the whole module), GO_PKGNOTE. Needs $files.
go_plan() {
  [ -z "${GO_DONE:-}" ] || return 0
  GO_DONE=1 GO_SELECTED='' GO_PKGNOTE='' GO_WHOLE='' GO_DRIVEN=''
  local f b bs='' k t
  for k in shared agent hub e2e; do eval "GO_WHY_$k=''; GO_PKGS_$k=''"; done
  pick() {  # pick <block> <why>
    case " $bs " in *" $1 "*) return ;; esac
    bs="$bs $1"; eval "GO_WHY_$1=\$2"
  }
  if [ -n "$unsure" ]; then
    for k in shared agent hub e2e; do pick "$k" "$unsure — unsure, so it runs"; done
    GO_WHOLE="$unsure"
  fi
  for f in $files; do
    case " $SELF " in *" $f "*) for k in shared agent hub e2e; do pick "$k" "$f changed (the plan itself)"; done; GO_WHOLE=$f; continue ;; esac
    b=$(block_of "$f")
    case "$b" in
      '')
        for t in $(go_driven "$f"); do
          k=${t#tokenledger/}; k=${k%%/*}
          pick "$k" "$f is run by $t"
          GO_DRIVEN="$GO_DRIVEN $t"
        done ;;
      none) ;;
      all) for k in shared agent hub e2e; do pick "$k" "$f changed (all four blocks)"; done; GO_WHOLE=$f ;;
      unknown) for k in shared agent hub e2e; do pick "$k" "$f has no block rule — unsure, so it runs"; done; GO_WHOLE=$f ;;
      shared) for k in shared agent hub e2e; do pick "$k" "$f changed (shared ⇒ $k)"; done ;;
      agent|hub)
        pick "$b" "$f changed"
        pick e2e "$f changed ($b ⇒ e2e)" ;;
      e2e) pick e2e "$f changed" ;;
    esac
  done
  # stable order
  for k in shared agent hub e2e; do case " $bs " in *" $k "*) GO_SELECTED="$GO_SELECTED $k" ;; esac; done
  GO_SELECTED=${GO_SELECTED# }
  for k in $GO_SELECTED; do eval "GO_PKGS_$k=./..."; done
  [ -n "$GO_SELECTED" ] || return 0
  [ "${NO_PKGS:-0}" = 1 ] && { GO_PKGNOTE='packages: not narrowed (--no-pkgs)'; return 0; }
  [ -z "$GO_WHOLE" ] || { GO_PKGNOTE="packages: whole blocks ($GO_WHOLE)"; return 0; }
  go_narrow
}

# go_narrow — inside each selected block, only the packages whose test binary
# depends on a changed package. Any doubt keeps the whole block.
go_narrow() {
  local tl="$root/tokenledger" k m f d rel p changed='' allwhole='' lst kept dep
  command -v go >/dev/null 2>&1 || { GO_PKGNOTE='packages: not narrowed (no go here)'; return 0; }
  for m in shared agent hub e2e; do
    [ -f "$tl/$m/go.mod" ] || { GO_PKGNOTE="packages: not narrowed (no tokenledger/$m/go.mod)"; return 0; }
  done
  # changed packages: a changed file's directory, or the nearest package above it
  # (testdata/, an embedded asset); a go.mod / go.sum ⇒ every package of its module;
  # a bin/ script a Go test runs ⇒ that test's package (go_driven)
  for f in $files $GO_DRIVEN; do
    case "$f" in tokenledger/shared/*|tokenledger/agent/*|tokenledger/hub/*|tokenledger/e2e/*) ;; *) continue ;; esac
    rel=${f#tokenledger/}; m=${rel%%/*}; rel=${rel#*/}
    case "$rel" in
      go.mod|go.sum) allwhole="$allwhole $m"; continue ;;
    esac
    eval "lst=\${GO_LIST_$m:-}"
    if [ -z "$lst" ]; then
      lst=$(cd "$tl/$m" && GOWORK=off go list ./... 2>/dev/null) \
        || { GO_PKGNOTE="packages: not narrowed (go list failed in $m)"; return 0; }
      eval "GO_LIST_$m=\$lst"
    fi
    d=$(dirname "$rel")
    p=''
    while :; do
      if [ "$d" = . ]; then cand="$MODPFX/$m"; else cand="$MODPFX/$m/$d"; fi
      printf '%s\n' "$lst" | grep -qxF -- "$cand" && { p=$cand; break; }
      [ "$d" = . ] && break
      d=$(dirname "$d")
    done
    [ -n "$p" ] || { GO_PKGNOTE="packages: not narrowed ($f belongs to no package of $m)"; return 0; }
    changed="$changed $p"
  done
  for m in $allwhole; do
    eval "lst=\${GO_LIST_$m:-}"
    [ -n "$lst" ] || lst=$(cd "$tl/$m" && GOWORK=off go list ./... 2>/dev/null) \
      || { GO_PKGNOTE="packages: not narrowed (go list failed in $m)"; return 0; }
    changed="$changed $(printf '%s' "$lst" | tr '\n' ' ')"
  done
  [ -n "$(printf '%s' "$changed" | tr -d ' ')" ] || { GO_PKGNOTE='packages: not narrowed (no changed package)'; return 0; }
  # shellcheck disable=SC2086  # a word list on purpose
  printf '%s\n' $changed | sort -u > "${TMPDIR:-/tmp}/ci-plan-changed.$$"
  local sel=''
  for k in $GO_SELECTED; do
    # each test binary (`<pkg>.test`) and what it is built from
    dep=$(cd "$tl/$k" && GOWORK=off go list -test -f '{{if .ForTest}}{{else}}{{.ImportPath}}{{range .Deps}} {{.}}{{end}}{{end}}' ./... 2>/dev/null) \
      || { rm -f "${TMPDIR:-/tmp}/ci-plan-changed.$$"; GO_PKGNOTE="packages: not narrowed (go list -test failed in $k)"; return 0; }
    kept=$(printf '%s\n' "$dep" | awk -v cf="${TMPDIR:-/tmp}/ci-plan-changed.$$" '
      BEGIN { while ((getline l < cf) > 0) ch[l] = 1 }
      $1 ~ /\.test$/ {
        p = substr($1, 1, length($1) - 5); hit = (p in ch)
        for (i = 2; i <= NF && !hit; i++) { d = $i; sub(/ \[.*$/, "", d); if (d in ch) hit = 1 }
        if (hit) print p
      }' | sort -u | tr '\n' ' ')
    kept=${kept% }
    if [ -z "$kept" ]; then
      eval "GO_WHY_$k=\"\${GO_WHY_$k} — but none of its packages depends on a changed one\""
      eval "GO_PKGS_$k=''"
    else
      eval "GO_PKGS_$k=\$kept"
      sel="$sel $k"
    fi
  done
  rm -f "${TMPDIR:-/tmp}/ci-plan-changed.$$"
  GO_SELECTED=${sel# }
  GO_PKGNOTE='packages: narrowed by go list -test'
}

# api_shards <table> → how many shards hub/api's tests take on that leg: its
# recorded seconds ÷ GO_SHARD_SECS (240 — four minutes a shard), 1..GO_SHARD_MAX
# (8, the runners' headroom), 3 (the old fixed count) with no row (issue #4817)
api_shards() {
  bash "$bin/go-test-shard.sh" count --table "$root/tokenledger/$1" --pkg hub/api \
    --per "${GO_SHARD_SECS:-240}" --max "${GO_SHARD_MAX:-8}" --default 3 2>/dev/null || echo 3
}

# api_parts <n> → `"api-1", …, "api-<n>",`
api_parts() {
  local i=1 out=''
  while [ "$i" -le "$1" ]; do out="$out \"api-$i\","; i=$((i + 1)); done
  printf '%s' "$out"
}

# go_outputs — the matrices tokenledger.yml takes
go_outputs() {
  local k parts='' pg='' build='' pk ap=0 st=0 rest=0 sr=0 an pn
  an=$(api_shards test-durations.txt) pn=$(api_shards test-durations-pg.txt)
  case " $GO_SELECTED " in *" hub "*)
    if [ "$GO_PKGS_hub" = ./... ]; then ap=1 st=1 rest=1 sr=1
    else
      for pk in $GO_PKGS_hub; do
        case "$pk" in
          "$MODPFX/hub/api") ap=1 ;;
          # hub/store is its own -race part (claude-fleet#4817): ~300s alone, it
          # was the `rest` part's long pole
          "$MODPFX/hub/store"|"$MODPFX/hub/store/"*) st=1 sr=1 ;;
          "$MODPFX/hub/leader"|"$MODPFX/hub/leader/"*) st=1 rest=1 ;;
          *) rest=1 ;;
        esac
      done
    fi
    build="$build hub"
    [ "$rest" = 1 ] && parts="$parts \"rest\","
    [ "$sr" = 1 ] && parts="$parts \"store\","
    [ "$ap" = 1 ] && { parts="$parts$(api_parts "$an")"; pg="$pg$(api_parts "$pn")"; }
    [ "$st" = 1 ] && pg="\"store\",$pg" ;;
  esac
  for k in shared agent e2e; do
    case " $GO_SELECTED " in *" $k "*) parts="$parts \"$k\"," ;; esac
  done
  case " $GO_SELECTED " in *" agent "*) build="$build agent" ;; esac
  case " $GO_SELECTED " in *" e2e "*) pg="$pg \"e2e\"," ;; esac
  parts=${parts%,} pg=${pg%,}
  printf 'go_parts=[%s]\n' "${parts# }"
  printf 'go_pg_parts=[%s]\n' "${pg# }"
  printf 'go_build=%s\n' "${build# }"
  printf 'go_modules=%s\n' "$GO_SELECTED"
  printf 'go_api_shards=%s\n' "$an"
  printf 'go_pg_api_shards=%s\n' "$pn"
  for k in shared agent hub e2e; do eval "printf 'go_pkgs_%s=%s\n' \"$k\" \"\$GO_PKGS_$k\""; done
}

go_report() {
  local k w
  for k in shared agent hub e2e; do
    eval "w=\$GO_WHY_$k"
    case " $GO_SELECTED " in
      *" $k "*) printf 'select: %s ← %s\n' "$k" "$w" ;;
      *) printf 'skip: %s ← %s\n' "$k" "${w:-no changed file reaches it}" ;;
    esac
  done
  [ -z "$GO_PKGNOTE" ] || printf '%s\n' "$GO_PKGNOTE"
  for k in $GO_SELECTED; do eval "printf 'pkgs %s: %s\n' \"$k\" \"\$GO_PKGS_$k\""; done
}

# --- main ---------------------------------------------------------------------
cmd=${1:-}
# shellcheck disable=SC2086  # $CHECKS is a word list on purpose
case "$cmd" in
  ''|-h|--help) usage ;;
  checks) printf '%s\n' $CHECKS; exit 0 ;;
esac
base=${2:-}
[ -n "$base" ] || usage
shift 2
out='' NO_PKGS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) out=${2:-}; shift ;;
    --no-pkgs) NO_PKGS=1 ;;
    *) echo "ci-plan: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done
files='' MB='' unsure='' why=''
changed_files "$base" || unsure=$why

case "$cmd" in
  go)
    go_plan; go_report; go_outputs
    [ -z "${GITHUB_OUTPUT:-}" ] || go_outputs >> "$GITHUB_OUTPUT"
    exit 0 ;;
  all)
    rec=$(mktemp "${TMPDIR:-/tmp}/ci-plan.XXXXXX")
    {
      echo "base $base"
      echo "merge-base ${MB:-?}"
      echo "head $(git -C "$root" rev-parse HEAD 2>/dev/null)"
    } > "$rec"
    summary="| 检查 | 结果 | 为什么 |
|---|---|---|"
    for c in $CHECKS; do
      plan_check "$c"
      printf '%s=%s\n' "$c" "$run"
      printf 'check %s %s %s\n' "$c" "$run" "$why" >> "$rec"
      summary="$summary
| $c | $([ "$run" = true ] && echo 跑 || echo 跳过) | $why |"
      [ -z "${GITHUB_OUTPUT:-}" ] || printf '%s=%s\n' "$c" "$run" >> "$GITHUB_OUTPUT"
    done
    go_plan
    go_report | sed 's/^/go /' >> "$rec"
    go_outputs | sed 's/^/out /' >> "$rec"
    go_report
    go_outputs
    [ -z "${GITHUB_OUTPUT:-}" ] || go_outputs >> "$GITHUB_OUTPUT"
    # shellcheck disable=SC2016  # the backticks are Markdown
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '### CI 计划（相对 %s）\n%s\n\n```\n%s\n```\n' "$base" "$summary" "$(go_report)" >> "$GITHUB_STEP_SUMMARY"
    if [ -n "$out" ]; then cp "$rec" "$out"; fi
    rm -f "$rec"
    exit 0 ;;
esac

# one check (the old form)
c=$cmd
check_rules "$c" || { echo "ci-plan: no entry for check '$c'" >&2; exit 2; }
plan_check "$c"
printf 'run=%s\n' "$run"
printf '%s: %s — %s\n' "$c" "$([ "$run" = true ] && echo runs || echo skipped)" "$why"
[ -z "${GITHUB_OUTPUT:-}" ] || printf 'run=%s\n' "$run" >> "$GITHUB_OUTPUT"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '### %s: %s\n%s\n' "$c" "$([ "$run" = true ] && echo 跑 || echo 跳过（与本次改动无关）)" "$why" >> "$GITHUB_STEP_SUMMARY"
exit 0
