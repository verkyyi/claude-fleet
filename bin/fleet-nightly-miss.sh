#!/bin/bash
# fleet-nightly-miss.sh [--results <dir>] [--go <dir>] [--checks <file>] --sha <rev>
#                       [--since <rev>] [--prev-checks <file>] [--repo <owner/name>]
#                       [--run <id>] [--dir <repo>] [--max <n>] [--dry-run]
#   — a nightly full run's red, each traced to the merge it went red at and asked
#   why the release train / the PR gate never ran it (issues #3871, #4816).
#
# The release train tests only what a change selects (`run-selftests.sh --changed`,
# a test is picked when its source NAMES a changed file), and the PR gate runs only
# the checks and Go blocks `bin/ci-plan.sh` says a change reaches. A test that reads
# something outside what selected it goes red without anything running it, and
# ships red. Two nightlies run everything — selftests-nightly.yml (the Linux suite,
# on stable) and ci-nightly.yml (every Go block + Postgres + each end-to-end check,
# on master, no test cache) — and this script turns each red into one issue:
#
#   --results <dir>  selftests: every `FAIL <test>` / `TIMEOUT <test>` line in any
#                    train-result.txt (selftests-shards.yml `record: true`)
#   --go <dir>       Go tests: every top-level `--- FAIL: <Test>` of each package in
#                    any go-log-*/go.log (the -race leg) or pg-log-*/pg.log (the
#                    Postgres leg) — tokenledger.yml's `go test -v` artifacts
#   --checks <file>  whole checks: `<check key> <result>` lines (ci-nightly.yml's
#                    jobs); `failure` is red. `tokenledger` is left to --go when
#                    the logs named a red test.
#
# A test (selftest or Go) is:
#   1. bisected — the window is <since>..<sha> on the first-parent line (default
#      <since>: the first-parent commit a day before <sha>'s commit time). Run again
#      at <sha> (green ⇒ `flaky`), at <since> (red ⇒ `old`), and over the merges
#      between (log2 n runs) to the FIRST one it is red at — a selftest through
#      run-selftests.sh, a Go test through `go test -race -count=1 -run '^T$'` in its
#      module (the Postgres leg with $FLEET_NM_DB_URL as CCQUOTA_DB_URL; none ⇒
#      unanalysed);
#   2. asked whether that merge M selected it — a selftest: `run-selftests.sh
#      --changed <M^> --list-only` lists it; a Go test: `bin/ci-plan.sh go <M^>`
#      selected its block and its package (`./...` or by name). Not ⇒
#      `selection-miss`; selected ⇒ `picked` (read that merge's run).
# A whole check is not re-run (an end-to-end check costs minutes a try): red last
# night too (--prev-checks) ⇒ `old`; else every merge of the window is asked
# `bin/ci-plan.sh <check> <M^>` — those that skipped it are the suspects
# (`selection-miss`, each named), none skipped ⇒ `picked`.
#
# One issue per red, through the ONE filer road (bin/fleet-issue-file.sh
# --breakage-key, never a sha — 共同约定 6): nightly-<test> · nightly-go-<pkg>.<Test>
# · nightly-pg-<pkg>.<Test> · nightly-check-<check>; a flaky one flaky-<…> (the
# train's own key for a selftest). The same red the next night is a 「同一故障」
# comment (exit 5), never a second issue. Labels: selection-miss · bug · flaky.
# Prints a Markdown table (one row per red) on stdout for the run's summary page.
# Bisects at most --max tests (default 5, FLEET_NM_MAX); the rest are listed and
# filed without a bisect.
#
# Env: FLEET_NM_FILER   the issue filer (default bin/fleet-issue-file.sh) — a selftest seam
#      FLEET_NM_RUN     runs ONE selftest in a checkout: `$FLEET_NM_RUN <checkout> <test>`,
#                       exit 0 green (default: <checkout>/bin/run-selftests.sh <test>)
#      FLEET_NM_GO_RUN  runs ONE Go test: `$FLEET_NM_GO_RUN <checkout> <go|pg> <pkg> <Test>`,
#                       exit 0 green (default: go test in <checkout>/tokenledger/<module>)
#      FLEET_NM_DB_URL  the Postgres the pg leg's tests are re-run against
# Exit: 0 analysed and filed (or nothing red) · 1 a filing failed · 2 usage.
set -uo pipefail
BIN=$(cd -- "$(dirname -- "$0")" && pwd)
ME=fleet-nightly-miss
MODPFX=github.com/verkyyi/claude-fleet/tokenledger

die() { printf '%s: %s\n' "$ME" "$*" >&2; exit 2; }
say() { printf '%s: %s\n' "$ME" "$*" >&2; }

results='' gologs='' checks='' prevchecks='' sha='' since='' repo='' run='' dir=. max=${FLEET_NM_MAX:-5} dry=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --results) results=${2:-}; shift 2 ;;
    --go)      gologs=${2:-}; shift 2 ;;
    --checks)  checks=${2:-}; shift 2 ;;
    --prev-checks) prevchecks=${2:-}; shift 2 ;;
    --sha)     sha=${2:-}; shift 2 ;;
    --since)   since=${2:-}; shift 2 ;;
    --repo)    repo=${2:-}; shift 2 ;;
    --run)     run=${2:-}; shift 2 ;;
    --dir)     dir=${2:-}; shift 2 ;;
    --max)     max=${2:-}; shift 2 ;;
    --dry-run|-n) dry=1; shift ;;
    -h|--help) sed -n '2,58p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done
[ -n "$results$gologs$checks" ] || die "one of --results <dir> (selftests), --go <dir> (Go logs), --checks <file> is required"
[ -z "$results" ] || [ -d "$results" ] || die "--results $results is not a directory (the shards' train-result-* artifacts)"
[ -z "$gologs" ] || [ -d "$gologs" ] || die "--go $gologs is not a directory (tokenledger.yml's go-log-* / pg-log-* artifacts)"
[ -z "$checks" ] || [ -f "$checks" ] || die "--checks $checks is not a file"
[ -n "$sha" ] || die "--sha <rev> is required (the commit the nightly tested)"
case "$max" in ''|*[!0-9]*) max=5 ;; esac
dir=$(cd "$dir" 2>/dev/null && pwd) || die "no such checkout: $dir"
git -C "$dir" rev-parse -q --verify "$sha^{commit}" >/dev/null || die "$sha is not a commit in $dir"
sha=$(git -C "$dir" rev-parse "$sha^{commit}")

file_issue() {
  if [ -n "${FLEET_NM_FILER:-}" ]; then "$FLEET_NM_FILER" "$@"; else bash "$BIN/fleet-issue-file.sh" "$@"; fi
}

# The reds, one unit a line: st|<test> · go|<pkg>|<Test> · pg|<pkg>|<Test> (<Test>
# `-`: the package went red with no test named — a panic, a timeout, a build) ·
# ck|<check key>. <pkg> is the import path under tokenledger/ (hub/api).
units=''
if [ -n "$results" ]; then
  units=$(find "$results" -name 'train-result*.txt' -type f -exec cat {} + 2>/dev/null \
            | awk '($1 == "FAIL" || $1 == "TIMEOUT") && $2 ~ /-selftest\.sh$/ { print "st|" $2 }' | sort -u)
fi
# go_reds <log> <leg> — `<leg>|<pkg>|<Test>` per red top-level test of each package
go_reds() {
  awk -v leg="$2" -v pfx="$MODPFX/" '
    /^--- FAIL: / { n++; t[n] = $3; next }
    /^(FAIL|ok)[ \t]+[^ \t]+/ && index($2, pfx) == 1 {
      p = substr($2, length(pfx) + 1)
      if ($1 == "FAIL") {
        if (n == 0) print leg "|" p "|-"
        for (i = 1; i <= n; i++) print leg "|" p "|" t[i]
      }
      n = 0
    }' "$1"
}
if [ -n "$gologs" ]; then
  gounits=$(find "$gologs" -type f \( -name 'go.log' -o -name 'pg.log' \) 2>/dev/null | sort | while IFS= read -r f; do
    case "$f" in (*/pg-log*|*/pg.log) go_reds "$f" pg ;; (*) go_reds "$f" go ;; esac
  done | sort -u)
  units=$(printf '%s\n%s\n' "$units" "$gounits" | grep . | sort -u)
fi
if [ -n "$checks" ]; then
  ckunits=$(awk '$2 == "failure" { print "ck|" $1 }' "$checks" | sort -u)
  # the Go check's red is its tests' when the logs named one
  if grep -Eq '^(go|pg)[|]' <<<"$units"; then
    ckunits=$(printf '%s\n' "$ckunits" | grep -vx 'ck|tokenledger')
  fi
  units=$(printf '%s\n%s\n' "$units" "$ckunits" | grep .)
fi
if [ -z "$units" ]; then
  say "nothing red in ${results:+$results }${gologs:+$gologs }${checks:+$checks} — nothing to trace"
  exit 0
fi

# The window: <since>..<sha> on the first-parent line.
if [ -z "$since" ]; then
  ct=$(git -C "$dir" log -1 --format=%ct "$sha")
  since=$(git -C "$dir" rev-list -1 --first-parent --before="$((ct - 86400))" "$sha" 2>/dev/null)
fi
if [ -n "$since" ]; then
  git -C "$dir" rev-parse -q --verify "$since^{commit}" >/dev/null || die "$since is not a commit in $dir"
  since=$(git -C "$dir" rev-parse "$since^{commit}")
  # oldest first; the window's last entry is <sha>
  merges=$(git -C "$dir" rev-list --first-parent --reverse "$since..$sha")
else
  merges=''
fi
nmerges=$(printf '%s\n' "$merges" | grep -c . || true)

# One scratch checkout, moved commit to commit: a --shared clone (the objects stay
# the checkout's, through alternates), never a worktree registered on <dir>.
wt=$(mktemp -d "${TMPDIR:-/tmp}/fleet-nightly-miss.XXXXXX") || die "no temp dir"
git clone -q --shared --no-checkout "$dir" "$wt" >/dev/null 2>&1 \
  && git -C "$wt" checkout -q --detach "$sha" >/dev/null 2>&1 \
  || { rm -rf "$wt"; die "could not check out $sha into a scratch copy"; }
cleanup() { rm -rf "$wt"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
at() { git -C "$wt" checkout -q --detach --force "$1" >/dev/null 2>&1; }

# the module and the directory of a Go package (hub/api → hub api; hub → hub .)
go_mod() { printf '%s' "${1%%/*}"; }
go_rel() { case "$1" in */*) printf '%s' "${1#*/}" ;; *) printf . ;; esac; }
# the hub embeds the client pack (go list / go test need it); harmless elsewhere
go_pack() { [ -f "$wt/bin/fleet-client-pack.sh" ] && bash "$wt/bin/fleet-client-pack.sh" >/dev/null 2>&1; return 0; }

# can_run <unit> — 1 when its red cannot be re-run here (a package-level Go red, a
# Postgres test with no database to re-run it against)
can_run() {
  case "$1" in
    go\|*\|-|pg\|*\|-) return 1 ;;
    pg\|*) [ -n "${FLEET_NM_GO_RUN:-}" ] || [ -n "${FLEET_NM_DB_URL:-}" ] ;;
    *) return 0 ;;
  esac
}

# red_at <rev> <unit> — 0 when the unit is RED at <rev>; a test not there yet is green.
red_at() {
  local k p t m rel rc
  at "$1" || { say "could not check out $1"; return 1; }
  k=${2%%|*}
  case "$k" in
    st)
      t=${2#st|}
      [ -f "$wt/bin/$t" ] || return 1
      if [ -n "${FLEET_NM_RUN:-}" ]; then
        "$FLEET_NM_RUN" "$wt" "$t" >/dev/null 2>&1 && return 1
      else
        (cd "$wt/bin" && FLEET_HEAVY=0 bash run-selftests.sh "$t") >/dev/null 2>&1 && return 1
      fi
      return 0 ;;
    go|pg)
      p=${2#*|}; t=${p#*|}; p=${p%%|*}
      m=$(go_mod "$p"); rel=$(go_rel "$p")
      [ -d "$wt/tokenledger/$m/$rel" ] || return 1
      if [ -n "${FLEET_NM_GO_RUN:-}" ]; then
        "$FLEET_NM_GO_RUN" "$wt" "$k" "$p" "$t" >/dev/null 2>&1 && return 1
        return 0
      fi
      go_pack
      if [ "$k" = pg ]; then
        (cd "$wt/tokenledger/$m" && CCQUOTA_DB_URL=${FLEET_NM_DB_URL:-} GOWORK=off GOFLAGS='' \
           go test -race -count=1 -timeout 20m -run "^${t}\$" "./$rel") >/dev/null 2>&1; rc=$?
      else
        (cd "$wt/tokenledger/$m" && unset CCQUOTA_DB_URL && GOWORK=off GOFLAGS='' \
           go test -race -count=1 -timeout 20m -run "^${t}\$" "./$rel") >/dev/null 2>&1; rc=$?
      fi
      [ "$rc" -ne 0 ] ;;
    *) return 1 ;;
  esac
}

# plan_go <rev> — `bin/ci-plan.sh go <rev>^` in the scratch checkout at <rev>;
# rc 2 when that commit has no plan (the gate ran every Go test then)
plan_go() {
  [ -f "$wt/bin/ci-plan.sh" ] || return 2
  go_pack
  (cd "$wt" && bash bin/ci-plan.sh go "$1^" 2>/dev/null) || return 2
}

# picked_at <rev> <unit> — 0 when the selection for <rev>'s own change ran the unit.
picked_at() {
  local k p m out pk
  at "$1" || return 1
  k=${2%%|*}
  case "$k" in
    st)
      out=$(cd "$wt/bin" && FLEET_HEAVY=0 bash run-selftests.sh --changed "$1^" --list-only 2>/dev/null)
      grep -qxF -- "${2#st|}" <<<"$out" ;;
    go|pg)
      p=${2#*|}; p=${p%%|*}; m=$(go_mod "$p")
      out=$(plan_go "$1") || return 0
      grep -q "^select: $m " <<<"$out" || return 1
      pk=$(printf '%s\n' "$out" | sed -n "s/^pkgs $m: //p")
      case " $pk " in *" ./... "*|*" $MODPFX/$p "*) return 0 ;; esac
      return 1 ;;
    ck)
      [ -f "$wt/bin/ci-plan.sh" ] || return 0
      go_pack
      # captured first: under pipefail a `grep -q` that stops early SIGPIPEs the plan
      out=$(cd "$wt" && bash bin/ci-plan.sh "${2#ck|}" "$1^" 2>/dev/null)
      grep -qx 'run=false' <<<"$out" && return 1
      return 0 ;;
  esac
}

# the selection's own words at <rev>, for the body
plan_words() {
  local k=${2%%|*} m
  case "$k" in
    go|pg) m=$(go_mod "$(printf '%s' "${2#*|}" | cut -d'|' -f1)")
           at "$1" && plan_go "$1" | grep -E "^(select|skip): |^pkgs $m: |^packages: " | head -8 ;;
    ck)    (at "$1" && cd "$wt" && bash bin/ci-plan.sh "${2#ck|}" "$1^" 2>/dev/null) | sed -n 2p ;;
  esac
}

# a breakage key from a free name: [A-Za-z0-9._-], at most 80 (the filer's rule)
keyof() {
  local k
  k=$(printf '%s' "$1" | tr '/' '.' | tr -c 'A-Za-z0-9._-' '-')
  if [ "${#k}" -gt 80 ]; then
    k="$(printf '%.70s' "$k")-$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
    k=$(printf '%.80s' "$k")
  fi
  printf '%s' "$k"
}

short() { printf '%.7s' "$1"; }
subject() { git -C "$dir" log -1 --format=%s "$1" 2>/dev/null; }
runurl=''; [ -n "$repo" ] && [ -n "$run" ] && runurl="https://github.com/$repo/actions/runs/$run"
s7=$(short "$sha")
sn7=$( [ -n "$since" ] && short "$since" || echo '?')

printf '| 测试 | 结论 | 从哪次合并起红 | 为什么没跑它 | 单 |\n|---|---|---|---|---|\n'
rc=0 n=0
while IFS= read -r u <&3; do
  [ -n "$u" ] || continue
  kind=${u%%|*}
  verdict='' first='' files='' why='' suspects=''
  case "$kind" in
    st) t=${u#st|}; name=${t%-selftest.sh}; disp=$t; base_key="nightly-$name"; flaky_key="flaky-$name" ;;
    go|pg)
      pkg=${u#*|}; test=${pkg#*|}; pkg=${pkg%%|*}
      disp="$kind $pkg $test"; [ "$test" != - ] || disp="$kind ${pkg}（整包）"
      kn=$pkg; [ "$test" = - ] || kn="$pkg.$test"
      base_key=$(keyof "nightly-$kind-$kn"); flaky_key=$(keyof "flaky-$kind-$kn") ;;
    ck) ck=${u#ck|}; disp="检查 $ck"; base_key=$(keyof "nightly-check-$ck") ;;
    *) continue ;;
  esac
  if [ "$kind" = ck ]; then
    if [ -n "$prevchecks" ] && [ -f "$prevchecks" ] && awk -v c="$ck" '$1 == c && $2 == "failure" { f = 1 } END { exit !f }' "$prevchecks"; then
      verdict=old
    elif [ -z "$since" ] || [ "$nmerges" -eq 0 ]; then
      verdict=old
    else
      for m in $merges; do picked_at "$m" "$u" || suspects="$suspects $m"; done
      suspects=${suspects# }
      if [ -n "$suspects" ]; then
        verdict=selection-miss
        set -- $suspects
        [ "$#" -ne 1 ] || { first=$1; files=$(git -C "$dir" diff --no-renames --name-only "$first^" "$first" 2>/dev/null); }
      else
        verdict=picked
      fi
    fi
  else
    n=$((n + 1))
    if [ "$n" -gt "$max" ] || ! can_run "$u"; then
      verdict=unanalysed
    elif ! red_at "$sha" "$u"; then
      verdict=flaky
    elif [ -z "$since" ] || [ "$nmerges" -eq 0 ]; then
      verdict=old
    elif red_at "$since" "$u"; then
      verdict=old
    else
      # bisect: index 0 = <since> (green), index n = <sha> (red)
      lo=0 hi=$nmerges
      while [ $((hi - lo)) -gt 1 ]; do
        mid=$(( (lo + hi) / 2 ))
        m=$(printf '%s\n' "$merges" | sed -n "${mid}p")
        if red_at "$m" "$u"; then hi=$mid; else lo=$mid; fi
      done
      first=$(printf '%s\n' "$merges" | sed -n "${hi}p")
      files=$(git -C "$dir" diff --no-renames --name-only "$first^" "$first" 2>/dev/null)
      if picked_at "$first" "$u"; then verdict=picked; else verdict=selection-miss; fi
    fi
  fi
  f7=''; [ -z "$first" ] || f7=$(short "$first")
  flist=$(printf '%s\n' "$files" | grep . | head -20 | sed 's/^/- `/; s/$/`/')
  label=bug key=$base_key
  case "$kind:$verdict" in
    st:selection-miss)
      label=selection-miss
      title="夜间全量红：${t} 自 ${f7} 起红，列车没选中它（漏选）"
      hint=$(printf '%s\n' "$files" | grep . | grep -v -- '-selftest\.sh$' | head -1)
      why="那次合并的改动没有一个是 ${t} 点名的文件"
      body="## ${t} 在夜间全量里红了，发布列车从没跑过它（issue #3871 的自动开单）

- 夜间全量：stable \`${s7}\`${runurl:+ · $runurl}
- **从哪次合并开始红**：\`${f7}\` $(subject "$first")（在 \`${sn7}\`..\`${s7}\` 的 ${nmerges} 次合并里二分得出：它之前绿、它起红）
- **列车为什么没选中它**：\`run-selftests.sh --changed ${f7}^ --list-only\` 在 \`${f7}\` 上没有列出 ${t}——列车只跑源里**点名**了改动文件（基名）的测试，而这次合并改的文件 ${t} 一个都没点名：

${flist:-（没有读出改动的文件）}

## 修法
1. 修好 ${t}（它现在在 stable 上是红的，只是没有列车跑它）；
2. 在 \`bin/${t}\` 里点名它读的那个文件，以后改它时列车就会选中这个测试——一行注释即可（规则 b 按基名匹配），例如：
   \`\`\`
   # reads: ${hint:-<被漏的文件>}
   \`\`\`
   修它的 PR 里写上 \`Closes #<本单>\`，这张单就是这次漏选和它的补上之间的关联。"
      ;;
    go:selection-miss|pg:selection-miss)
      label=selection-miss
      mod=$(go_mod "$pkg")
      title="夜间全量红：Go ${pkg} ${test}（${kind}）自 ${f7} 起红，PR 门没选中它（漏选）"
      why="\`ci-plan.sh go ${f7}^\` 没选 ${mod} 块 / ${pkg} 包"
      body="## Go 测试 \`${test}\`（\`${pkg}\`，$( [ "$kind" = pg ] && echo 'Postgres 腿' || echo '-race 腿')）在夜间全量里红了，改坏它的那次合并在 PR 上没跑它（issue #4816 的自动开单）

- 夜间全量：master \`${s7}\`${runurl:+ · $runurl}（\`go test -race -count=1\`，不读测试缓存）
- **从哪次合并开始红**：\`${f7}\` $(subject "$first")（在 \`${sn7}\`..\`${s7}\` 的 ${nmerges} 次合并里用 \`go test -run '^${test}\$' ./$(go_rel "$pkg")\` 二分得出：它之前绿、它起红）
- **PR 门为什么没跑它**：在 \`${f7}\` 上 \`bin/ci-plan.sh go ${f7}^\` 没有选中 \`${mod}\` 块里的 \`${pkg}\`：

\`\`\`
$(plan_words "$first" "$u")
\`\`\`

这次合并改的文件：
${flist:-（没有读出改动的文件）}

## 修法
1. 修好 \`${test}\`；
2. 让 PR 门以后选中它：测试读到了另一块的东西，而 \`bin/ci-plan.sh\` 的 \`block_of\` / \`go_plan\` 映射没把那块的改动算到 \`${mod}\`——补上映射（\`bin/ci-plan-selftest.sh\` B 腿加一行），或者让测试不再跨块读文件。修它的 PR 写 \`Closes #<本单>\`。"
      ;;
    ck:selection-miss)
      label=selection-miss
      set -- $suspects; ns=$#
      if [ "$ns" -eq 1 ]; then
        title="夜间全量红：检查 ${ck}，窗口里只有 ${f7} 在 PR 上跳过了它（漏选）"
        why="\`ci-plan.sh ${ck} ${f7}^\` 跳过了它"
      else
        title="夜间全量红：检查 ${ck}，窗口里 ${ns} 次合并在 PR 上跳过了它（漏选嫌疑）"
        why="${ns} 次合并的 PR 跳过了它"
      fi
      slist=$(for m in $suspects; do printf -- '- `%s` %s\n  - %s\n' "$(short "$m")" "$(subject "$m")" "$(plan_words "$m" "$u")"; done | head -60)
      body="## 检查 \`${ck}\` 在夜间全量里红了，它没在这些合并的 PR 上跑过（issue #4816 的自动开单）

- 夜间全量：master \`${s7}\`${runurl:+ · $runurl}
- 前一晚它不红（窗口 \`${sn7}\`..\`${s7}\`，${nmerges} 次合并）；端到端检查不逐次重跑，所以列出窗口里 **PR 门跳过了它** 的合并（\`bin/ci-plan.sh ${ck} <M^>\` 说 \`run=false\`）——改坏它的就在其中：

${slist}

## 修法
1. 在上面那几次合并里找出改坏它的（在那次合并上手动跑一次 ci-nightly.yml，或本地照它的工作流跑）并修好；
2. 让 PR 门以后选中它：在 \`bin/ci-plan.sh\` 的 \`check_rules\` 里把那次改到的路径加进 \`${ck}\` 的 \`globs\`（或它的入口文件点名那个文件）。修它的 PR 写 \`Closes #<本单>\`。"
      ;;
    st:picked|go:picked|pg:picked)
      title="夜间全量红：${disp} 自 ${f7} 起红（$( [ "$kind" = st ] && echo 列车 || echo 'PR 门')选中过它）"
      if [ "$kind" = st ]; then
        why="列车选中了它：去看 ${f7} 之后那趟列车——隔离（QUARANTINED）或重跑才过（FLAKY）"
        sel="\`run-selftests.sh --changed ${f7}^ --list-only\` 列出了 ${t}，所以这不是漏选——那趟列车跑过它：看它是不是被隔离（\`QUARANTINED\`）、或红了一次重跑才过（\`FLAKY\`）后照发。"
      else
        why="PR 门选中了它：去看 ${f7} 的 PR 上 tokenledger 那一项"
        sel="\`bin/ci-plan.sh go ${f7}^\` 选中了 \`${pkg}\`，所以这不是漏选——那次的 PR 跑过它：看它是不是在 \`tokenledger/test-quarantine.txt\` 里被隔离、或用了测试缓存（夜里一律 \`-count=1\`）。"
      fi
      body="## ${disp} 在夜间全量里红了（issue #3871 / #4816 的自动开单）

- 夜间全量：\`${s7}\`${runurl:+ · $runurl}
- **从哪次合并开始红**：\`${f7}\` $(subject "$first")（\`${sn7}\`..\`${s7}\` 的 ${nmerges} 次合并里二分得出）
- **选中过它**：${sel}

这次合并改的文件：
${flist:-（没有读出改动的文件）}"
      ;;
    ck:picked)
      title="夜间全量红：检查 ${ck}（窗口里每次合并的 PR 都跑过它）"
      why="窗口里每次合并的 PR 都选中了它"
      body="## 检查 \`${ck}\` 在夜间全量里红了（issue #4816 的自动开单）

- 夜间全量：master \`${s7}\`${runurl:+ · $runurl}
- 窗口 \`${sn7}\`..\`${s7}\` 的 ${nmerges} 次合并，PR 门每次都选中了 \`${ck}\`（\`bin/ci-plan.sh ${ck} <M^>\` 都说 \`run=true\`），所以这不是漏选：可能是外部变了（runner 镜像、依赖、时间相关），或它时好时坏。去看这晚它的日志。"
      ;;
    *:old)
      title="夜间全量红：${disp} 在 $( [ -n "$since" ] && short "$since" || echo "${s7} 之前") 就已经红了"
      if [ "$kind" = ck ]; then why="前一晚也红"; else why="窗口之前就红（\`${sn7}\` 上也红）"; fi
      body="## ${disp} 在夜间全量里红了（issue #3871 / #4816 的自动开单）

- 夜间全量：\`${s7}\`${runurl:+ · $runurl}
- 在窗口起点 \`$( [ -n "$since" ] && short "$since" || echo '（没有窗口：前一天没有提交）')\` 上它$( [ "$kind" = ck ] && echo '（前一晚）')也是红的：这不是今天的合并改坏的，往前找更早的那次。"
      ;;
    *:flaky)
      label=flaky key=$flaky_key
      title="夜间全量里 ${disp} 时好时坏：夜里红，复跑绿"
      why="不确定：在 \`${s7}\` 上复跑是绿的"
      body="${disp} 在夜间全量（\`${s7}\`${runurl:+ · $runurl}）里红了，事后在同一提交上单独复跑一次是绿的——它时好时坏（issue #3871 / #4816 的自动开单，\`${flaky_key}\`）。修好它，这张单就关。"
      ;;
    *:unanalysed)
      title="夜间全量红：${disp}"
      if [ "$n" -gt "$max" ]; then why="没分析（本晚只分析前 ${max} 个红测试）"
      elif [ "$kind" = pg ] && [ "$test" != - ]; then why="没分析（这里没有 Postgres 可以复跑：FLEET_NM_DB_URL）"
      else why="没分析（整包红、没有点名测试：panic / 超时 / 编译失败）"; fi
      body="${disp} 在夜间全量（\`${s7}\`${runurl:+ · $runurl}）里红了。${why}；看这晚的日志复现。"
      ;;
  esac
  url='-'
  if [ "$dry" = 1 ] || [ -z "$repo" ]; then
    url="(would file: $label · $key)"
  else
    url=$(file_issue --repo "$repo" --breakage-key "$key" --fault-sha "$sha" ${runurl:+--fault-link "$runurl"} --label "$label" --priority p1 \
            --title "$title" --body "$body"); frc=$?
    case "$frc" in
      0|5) url=$(printf '%s\n' "$url" | tail -1) ;;
      *)   say "could not file $disp (filer exit $frc)"; rc=1; url="(filing failed, exit $frc)" ;;
    esac
  fi
  printf '| %s | %s | %s | %s | %s |\n' "$disp" "$verdict" "${f7:--}" "${why:--}" "$url"
done 3<<EOF
$units
EOF
exit "$rc"
