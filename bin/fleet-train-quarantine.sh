#!/bin/sh
# fleet-train-quarantine.sh — the release train's selftest quarantine, ONE reader
# (issue #3243, EPIC #3139 C10; 发起人拍板 10).
#
# A test red on TWO trains in a row — different TRAIN_SHAs, the second train's diff
# touching neither the test nor a file it names — stops holding every release back:
# it is quarantined for at most 48 hours, against the breakage issue that fixes it.
# Only the train skips it. A PR (selftests.yml), the nightly full suite
# (selftests-macos.yml) and any train whose change touches it run it as always: the
# skip is an option of bin/run-selftests.sh (--quarantine) that only the train passes.
# One red train never quarantines anything, and a cut-short shard has no FAIL line
# to count (that is C9's rerun, issue #3241).
#
# A LIST is lines of
#     <test> <issue#> <expires ISO 8601 UTC> <run id> <run id>
#     portability-selftest.sh 3250 2026-10-13T08:00:00Z 18324412 18325077
# — the issue that fixes it, when the entry stops counting, and the two train runs
# that were red on it. `#` starts a comment; a malformed line is said on stderr and
# ignored; an expired entry does not exist (the summary says it came back).
# conf/selftest-quarantine.list is the hand-written list (normally empty); what the
# train adds lives in the `train-quarantine` artifact each train uploads and the next
# one fetches — the train never pushes master.
#
# Usage:
#   active  [--now T] LIST...   the entries in force, one per test (latest expiry wins)
#   expired [--now T] LIST...   expired entries with no entry in force for that test
#   summary [--now T] [--expired FILE] LIST...
#                               the train summary: 「隔离了 N 个：<test>（#N，到期 …）」,
#                               then 「已过期，恢复：…」 — nothing at all when both are empty
#   fetch --repo R --run ID --sha S --out DIR [--name N]
#                               the previous trains' state (gh): DIR/list (their list ∪
#                               conf/selftest-quarantine.list, unpruned), DIR/prev-fails
#                               (the tests red on the newest earlier train on ANOTHER
#                               sha), DIR/prev-run (that train's run id)
#   record --results DIR --list FILE --prev-run ID --run ID --sha S --repo R --out DIR
#          [--issue N] [--now T]
#                               after the tests: every `QUARANTINE <test>` a shard printed
#                               gets its breakage issue (fleet-issue-file.sh
#                               --breakage-key, one per test; --issue N files nothing and
#                               uses N — the drill) and an entry; DIR/{list,fails,sha,run}
#                               is the state the next train fetches
#
# Env: FLEET_TQ_FILER   the issue filer (default bin/fleet-issue-file.sh) — a selftest seam
#      FLEET_TQ_HOURS   how long an entry holds (default 48 — the decision's cap)
set -u
BIN=$(cd -- "$(dirname -- "$0")" && pwd)
ME=fleet-train-quarantine

die() { printf '%s: %s\n' "$ME" "$*" >&2; exit 2; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
file_issue() {
  if [ -n "${FLEET_TQ_FILER:-}" ]; then "$FLEET_TQ_FILER" "$@"; else bash "$BIN/fleet-issue-file.sh" "$@"; fi
}

# entries <now> <mode: active|expired> LIST... — the one parse of the format.
entries() {
  _now=$1 _mode=$2; shift 2
  for _f in "$@"; do [ -e "$_f" ] || die "no list $_f"; done
  awk -v now="$_now" -v mode="$_mode" -v me="$ME" '
    /^[[:space:]]*(#|$)/ { next }
    {
      t = $1; i = $2; e = $3; a = $4; b = $5; sub(/^#/, "", i)
      if (NF < 5 || t !~ /^[A-Za-z0-9._-]+-selftest\.sh$/ || i !~ /^[0-9]+$/ ||
          e !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ ||
          a !~ /^[0-9]+$/ || b !~ /^[0-9]+$/) {
        printf "%s: ignoring malformed line %s:%d: %s\n", me, FILENAME, FNR, $0 > "/dev/stderr"; next
      }
      if (e > now) { if (!(t in on) || e > on[t]) { on[t] = e; line[t] = t " " i " " e " " a " " b } }
      else if (!(t in off) || e > offe[t]) { offe[t] = e; off[t] = t " " i " " e " " a " " b }
    }
    END {
      if (mode == "active") for (t in line) print line[t]
      else for (t in off) if (!(t in on)) print off[t]
    }' "$@" | sort
}

cmd=${1:-}; [ -n "$cmd" ] || die "usage: active|expired|summary|fetch|record … (see the header)"
shift
now='' out='' repo='' run='' sha='' name=train-quarantine results='' list='' prev_run='' issue='' expired_f=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --now)      now=${2:-}; shift 2 ;;
    --out)      out=${2:-}; shift 2 ;;
    --repo)     repo=${2:-}; shift 2 ;;
    --run)      run=${2:-}; shift 2 ;;
    --sha)      sha=${2:-}; shift 2 ;;
    --name)     name=${2:-}; shift 2 ;;
    --results)  results=${2:-}; shift 2 ;;
    --list)     list=${2:-}; shift 2 ;;
    --prev-run) prev_run=${2:-}; shift 2 ;;
    --issue)    issue=${2:-}; shift 2 ;;
    --expired)  expired_f=${2:-}; shift 2 ;;
    --)         shift; break ;;
    -*)         die "unknown option $1" ;;
    *)          break ;;
  esac
done
[ -n "$now" ] || now=$(now_iso)

case "$cmd" in
  active|expired)
    [ "$#" -gt 0 ] || die "$cmd: name a list"
    entries "$now" "$cmd" "$@" ;;

  summary)
    [ "$#" -gt 0 ] || die "summary: name a list"
    on=$(entries "$now" active "$@")
    off=''
    # an expired entry with a newer one in force for the same test is not a return
    [ -z "$expired_f" ] || off=$(entries "$now" expired "$expired_f" "$@")
    if [ -n "$on" ]; then
      printf '%s\n' "$on" | awk '{ s = s (NR > 1 ? "、" : "") sprintf("%s（#%s，到期 %s）", $1, $2, $3) }
        END { printf "隔离了 %d 个：%s\n", NR, s }'
    fi
    if [ -n "$off" ]; then
      printf '%s\n' "$off" | awk '{ s = s (NR > 1 ? "、" : "") sprintf("%s（#%s）", $1, $2) }
        END { printf "已过期，恢复：%s\n", s }'
    fi ;;

  fetch)
    [ -n "$repo" ] && [ -n "$run" ] && [ -n "$sha" ] && [ -n "$out" ] || die "fetch needs --repo --run --sha --out"
    command -v gh >/dev/null 2>&1 || die "fetch: gh not on PATH"
    mkdir -p "$out" || exit 1
    : > "$out/list"; : > "$out/prev-fails"; : > "$out/prev-run"
    # The hand-written list rides along with whatever the trains carried.
    [ ! -f "$BIN/../conf/selftest-quarantine.list" ] || cat "$BIN/../conf/selftest-quarantine.list" >> "$out/list"
    # Newest first; this run's own artifact (a re-run) is not a previous train.
    ids=$(gh api "repos/$repo/actions/artifacts?name=$name&per_page=30" \
            --jq '.artifacts | sort_by(.created_at) | reverse | .[] | select(.expired | not) | "\(.id) \(.workflow_run.id)"' 2>/dev/null) \
      || { printf '%s: fetch: could not list the %s artifacts — no previous state (nothing quarantined from it)\n' "$ME" "$name" >&2; exit 0; }
    got_list=0 n=0
    printf '%s\n' "$ids" | while read -r aid wrun; do
      [ -n "$aid" ] || continue
      [ "$wrun" != "$run" ] || continue
      n=$((n + 1)); [ "$n" -le 8 ] || break
      d="$out/a.$aid"; mkdir -p "$d"
      gh api "repos/$repo/actions/artifacts/$aid/zip" > "$d.zip" 2>/dev/null && (cd "$d" && unzip -qo "../a.$aid.zip") 2>/dev/null \
        || { printf '%s: fetch: could not download artifact %s (run %s)\n' "$ME" "$aid" "$wrun" >&2; continue; }
      # the newest previous train's list is the state in force
      [ "$got_list" = 1 ] || { [ ! -f "$d/list" ] || cat "$d/list" >> "$out/list"; got_list=1; }
      # the fails that count are the newest earlier train's on ANOTHER sha
      s=$(cat "$d/sha" 2>/dev/null)
      if [ -n "$s" ] && [ "$s" != "$sha" ]; then
        [ ! -f "$d/fails" ] || cp "$d/fails" "$out/prev-fails"
        cat "$d/run" 2>/dev/null > "$out/prev-run"
        break
      fi
    done
    rm -rf "$out"/a.* ;;

  record)
    [ -n "$results" ] && [ -n "$list" ] && [ -n "$run" ] && [ -n "$sha" ] && [ -n "$out" ] \
      || die "record needs --results --list --run --sha --out"
    mkdir -p "$out" || exit 1
    hours=${FLEET_TQ_HOURS:-48}
    case "$hours" in ''|*[!0-9]*) hours=48 ;; esac
    [ "$hours" -le 48 ] || hours=48
    # This train's verdicts, from every shard's result file (FAIL / QUARANTINE lines).
    res=$(cat "$results"/*/train-result.txt "$results"/train-result*.txt 2>/dev/null)
    printf '%s\n' "$res" | awk '$1 == "FAIL" || $1 == "QUARANTINE" { print $2 }' | sort -u > "$out/fails"
    newq=$(printf '%s\n' "$res" | awk '$1 == "QUARANTINE" { print $2 }' | sort -u)
    entries "$now" active "$list" > "$out/list"
    rc=0
    for t in $newq; do
      if [ -n "$issue" ]; then num=$issue
      else
        [ -n "$repo" ] || die "record: --repo is needed to file the breakage issue"
        key="selftest-quarantine.${t%-selftest.sh}"
        url=$(file_issue --repo "$repo" --breakage-key "$key" \
                --label bug --title "列车隔离了 ${t}：连红两趟" \
                --body "$t 在连续两趟发布列车上红（run ${prev_run:-?} 与 run ${run}，TRAIN_SHA ${sha}），这趟的改动没碰它，也没碰它点名的文件，所以列车隔离它最多 ${hours} 小时（issue #3243）。PR 与夜里的全量照跑它；碰到它的列车也照跑。修好它，隔离就失效；到期自动恢复。
https://github.com/$repo/actions/runs/$run") ; frc=$?
        num=$(printf '%s\n' "$url" | sed -n 's|.*/issues/\([0-9][0-9]*\).*|\1|p' | tail -1)
        if [ -z "$num" ] || { [ "$frc" -ne 0 ] && [ "$frc" -ne 5 ]; }; then
          printf '%s: could not file the breakage issue for %s (filer exit %s) — not quarantined\n' "$ME" "$t" "$frc" >&2
          rc=1; continue
        fi
      fi
      exp=$(python3 -c 'import datetime, sys
n = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")
print((n + datetime.timedelta(hours=int(sys.argv[2]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$now" "$hours") \
        || { printf '%s: no python3 to date the entry for %s\n' "$ME" "$t" >&2; rc=1; continue; }
      { grep -v "^$t " "$out/list"; printf '%s %s %s %s %s\n' "$t" "$num" "$exp" "${prev_run:-0}" "$run"; } | sort > "$out/list.new"
      mv "$out/list.new" "$out/list"
      printf 'quarantined %s → #%s until %s (red on runs %s and %s)\n' "$t" "$num" "$exp" "${prev_run:-?}" "$run"
    done
    printf '%s\n' "$sha" > "$out/sha"; printf '%s\n' "$run" > "$out/run"
    exit "$rc" ;;

  *) die "unknown command $cmd (active|expired|summary|fetch|record)" ;;
esac
