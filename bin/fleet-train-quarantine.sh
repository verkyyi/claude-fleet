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
# A sixth word is the reason, when it is not "red twice": `flaky` — a test the train
# reran green (FLAKY, issue #3866) three times in seven days is quarantined too.
#
# FLAKY (issue #3866): the train passes --retry-red 1, so a red test runs once more;
# green then is `FLAKY <test> …`, the shard stays green and the train ships. record
# files ONE issue per test (--breakage-key flaky-<test>, label flaky; the next
# sighting is a 「同一故障」 comment on it), keeps the train's FLAKY sightings for
# seven days in the state (`flaky`: `<test> <ISO time> <run> <issue#>` lines) and, at
# the third in seven days, writes a quarantine entry with the reason `flaky`.
#
# Usage:
#   active  [--now T] LIST...   the entries in force, one per test (latest expiry wins)
#   expired [--now T] LIST...   expired entries with no entry in force for that test
#   summary [--now T] [--expired FILE] [--flaky FILE] LIST...
#                               the train summary: 「重跑才过 N 个：<test>（#N）」 (FILE: record's
#                               flaky-now), 「隔离了 N 个：<test>（#N，到期 …）」, then
#                               「已过期，恢复：…」 — nothing at all when all are empty
#   heads --log LOG --out DIR   for each FLAKY line of a shard's log: DIR/train-flaky-<test>.txt,
#                               the head of its red run and of its green rerun
#   fetch --repo R --run ID --sha S --out DIR [--name N]
#                               the previous trains' state (gh): DIR/list (their list ∪
#                               conf/selftest-quarantine.list, unpruned), DIR/prev-fails
#                               (the tests red on the newest earlier train on ANOTHER
#                               sha), DIR/prev-run (that train's run id), DIR/flaky
#                               (the newest earlier train's FLAKY sightings)
#   record --results DIR --list FILE --prev-run ID --run ID --sha S --repo R --out DIR
#          [--issue N] [--now T] [--flaky-hist FILE] [--drill-flaky TEST]
#                               after the tests: every `QUARANTINE <test>` a shard printed
#                               gets its breakage issue (the filer, --breakage-key, one
#                               per test; said, not filed, by default; --issue N files nothing and
#                               uses N — the drill) and an entry; every `FLAKY <test>` its
#                               flaky issue (above; a filing that fails is said, never
#                               reds the train) and a sighting — --drill-flaky's is filed
#                               but never counted toward a quarantine;
#                               DIR/{list,fails,sha,run,flaky} is the state the next
#                               train fetches, DIR/flaky-now this train's flaky tests
#
# Env: FLEET_TQ_FILER   the filer (default bin/fleet-ci-say.sh: said in the run summary, no
#                       issue — issue #4898; an entry then names `-` for its issue) — a selftest seam
#      FLEET_TQ_HOURS   how long an entry holds (default 48 — the decision's cap)
#      FLEET_TQ_FLAKY_DAYS / FLEET_TQ_FLAKY_MAX   the flaky window (7) and the sightings
#                       in it that quarantine (3)
set -u
BIN=$(cd -- "$(dirname -- "$0")" && pwd)
ME=fleet-train-quarantine

die() { printf '%s: %s\n' "$ME" "$*" >&2; exit 2; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
file_issue() {
  if [ -n "${FLEET_TQ_FILER:-}" ]; then "$FLEET_TQ_FILER" "$@"; else bash "$BIN/fleet-ci-say.sh" "$@"; fi
}

# record_flaky <this train's verdict lines> — the FLAKY half of record (issue #3866):
# one issue per test, the seven-day sightings, a quarantine at the third. Reads the
# record's own variables; writes $out/flaky and $out/flaky-now, may add to $out/list.
record_flaky() {
  _days=${FLEET_TQ_FLAKY_DAYS:-7} _max=${FLEET_TQ_FLAKY_MAX:-3}
  case "$_days" in ''|*[!0-9]*) _days=7 ;; esac
  case "$_max" in ''|*[!0-9]*|0) _max=3 ;; esac
  _since=$(python3 -c 'import datetime, sys
n = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")
print((n - datetime.timedelta(days=int(sys.argv[2]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$now" "$_days") || _since=$now
  # the sightings still inside the window (ISO 8601 UTC compares as text)
  if [ -n "$flaky_hist" ] && [ -f "$flaky_hist" ]; then
    awk -v since="$_since" 'NF >= 3 && $1 ~ /-selftest\.sh$/ && $2 > since' "$flaky_hist" > "$out/flaky"
  else : > "$out/flaky"; fi
  : > "$out/flaky-now"
  _new=$(printf '%s\n' "$1" | awk '$1 == "FLAKY" { print $2 }' | sort -u)
  for _t in $_new; do
    _key="flaky-${_t%-selftest.sh}"
    _heads=$(cat "$results"/train-flaky-"$_t".txt "$results"/*/train-flaky-"$_t".txt 2>/dev/null | head -40)
    _num=''
    if [ -n "$repo" ]; then
      _url=$(file_issue --repo "$repo" --breakage-key "$_key" --fault-sha "$sha" --fault-link "https://github.com/$repo/actions/runs/$run" \
               --label flaky --title "列车上 ${_t} 时好时坏：红了一次，重跑才过" \
               --body "$_t 在发布列车上红了一次，同一片里单独重跑一次是绿的（\`run-selftests.sh --retry-red 1\`，issue #3866），所以这趟照发。$( [ "$_t" != "$drill_flaky" ] || printf '（这是 \`drill_flaky\` 演练：第一次的红是演练记的。）' )
它七天里在列车上重跑才过 ${_max} 次，就进隔离（最多 48 小时）。修好它，这张单就关。
TRAIN_SHA ${sha} · https://github.com/$repo/actions/runs/$run

两次输出的头几行：
\`\`\`
${_heads:-（这一片没留下输出）}
\`\`\`") ; _frc=$?
      _num=$(printf '%s\n' "$_url" | sed -n 's|.*/issues/\([0-9][0-9]*\).*|\1|p' | tail -1)
      if [ -z "$_num" ] || { [ "$_frc" -ne 0 ] && [ "$_frc" -ne 5 ]; }; then
        printf '%s: could not file the flaky issue for %s (filer exit %s) — the train still ships\n' "$ME" "$_t" "$_frc" >&2
        _num=''
      fi
    fi
    # an earlier sighting's issue stands in when this filing gave none
    [ -n "$_num" ] || _num=$(awk -v t="$_t" '$1 == t && $4 ~ /^[0-9]+$/ { n = $4 } END { print n }' "$out/flaky")
    printf '%s %s\n' "$_t" "${_num:--}" >> "$out/flaky-now"
    # a drill's sighting is filed, never counted
    [ "$_t" = "$drill_flaky" ] || printf '%s %s %s %s\n' "$_t" "$now" "$run" "${_num:--}" >> "$out/flaky"
    _seen=$(awk -v t="$_t" '$1 == t' "$out/flaky" | wc -l | tr -d ' ')
    printf 'flaky %s → #%s (%s in %s days)\n' "$_t" "${_num:--}" "$_seen" "$_days"
    if [ "$_seen" -ge "$_max" ] && [ -n "$_num" ] && ! awk -v t="$_t" '$1 == t { f = 1 } END { exit !f }' "$out/list"; then
      _exp=$(python3 -c 'import datetime, sys
n = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")
print((n + datetime.timedelta(hours=int(sys.argv[2]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$now" "$hours") || continue
      _prev=$(awk -v t="$_t" -v r="$run" '$1 == t && $3 != r { p = $3 } END { print (p ? p : 0) }' "$out/flaky")
      { cat "$out/list"; printf '%s %s %s %s %s flaky\n' "$_t" "$_num" "$_exp" "$_prev" "$run"; } | sort > "$out/list.new"
      mv "$out/list.new" "$out/list"
      printf 'quarantined %s → #%s until %s (flaky %s times in %s days)\n' "$_t" "$_num" "$_exp" "$_seen" "$_days"
    fi
  done
  sort -o "$out/flaky" "$out/flaky"
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
      l = t " " i " " e " " a " " b (NF >= 6 ? " " $6 : "")
      if (e > now) { if (!(t in on) || e > on[t]) { on[t] = e; line[t] = l } }
      else if (!(t in off) || e > offe[t]) { offe[t] = e; off[t] = l }
    }
    END {
      if (mode == "active") for (t in line) print line[t]
      else for (t in off) if (!(t in on)) print off[t]
    }' "$@" | sort
}

cmd=${1:-}; [ -n "$cmd" ] || die "usage: active|expired|summary|fetch|record … (see the header)"
shift
now='' out='' repo='' run='' sha='' name=train-quarantine results='' list='' prev_run='' issue='' expired_f=''
flaky_f='' flaky_hist='' drill_flaky='' log=''
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
    --flaky)    flaky_f=${2:-}; shift 2 ;;
    --flaky-hist) flaky_hist=${2:-}; shift 2 ;;
    --drill-flaky) drill_flaky=${2:-}; shift 2 ;;
    --log)      log=${2:-}; shift 2 ;;
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
    if [ -n "$flaky_f" ] && [ -s "$flaky_f" ]; then
      awk 'NF { s = s (n++ ? "、" : "") ($2 ~ /^[0-9]+$/ ? sprintf("%s（#%s）", $1, $2) : $1) }
        END { if (n) printf "重跑才过 %d 个：%s\n", n, s }' "$flaky_f"
    fi
    if [ -n "$on" ]; then
      printf '%s\n' "$on" | awk '{ s = s (NR > 1 ? "、" : "") sprintf("%s（#%s，%s到期 %s）", $1, $2, (NF >= 6 ? $6 "，" : ""), $3) }
        END { printf "隔离了 %d 个：%s\n", NR, s }'
    fi
    if [ -n "$off" ]; then
      printf '%s\n' "$off" | awk '{ s = s (NR > 1 ? "、" : "") sprintf("%s（#%s）", $1, $2) }
        END { printf "已过期，恢复：%s\n", s }'
    fi ;;

  heads)
    [ -n "$log" ] && [ -n "$out" ] || die "heads needs --log --out"
    [ -f "$log" ] || exit 0
    mkdir -p "$out" || exit 1
    # each FLAKY test's first run (its `=== t ===` block) and its rerun (the
    # `=== t (rerun… ===` block up to the FLAKY line), 15 lines of each
    awk -v out="$out" '
      /^=== [^ ]+ ===$/ { cur = $2; part = 1; n1[cur] = 0; buf1[cur] = ""; buf2[cur] = ""; n2[cur] = 0; next }
      /^=== [^ ]+ \(rerun/ { cur = $2; part = 2; next }
      /^FLAKY / {
        t = $2; f = out "/train-flaky-" t ".txt"
        printf "--- first run (red) ---\n%s--- rerun (green) ---\n%s", buf1[t], buf2[t] > f; close(f)
        cur = ""; next
      }
      /^(PASS  |FAIL  |TIMEOUT |QUARANTINE )/ { cur = ""; next }
      cur != "" && part == 1 && n1[cur] < 15 { buf1[cur] = buf1[cur] $0 "\n"; n1[cur]++ }
      cur != "" && part == 2 && n2[cur] < 15 { buf2[cur] = buf2[cur] $0 "\n"; n2[cur]++ }
    ' "$log" ;;

  fetch)
    [ -n "$repo" ] && [ -n "$run" ] && [ -n "$sha" ] && [ -n "$out" ] || die "fetch needs --repo --run --sha --out"
    command -v gh >/dev/null 2>&1 || die "fetch: gh not on PATH"
    mkdir -p "$out" || exit 1
    : > "$out/list"; : > "$out/prev-fails"; : > "$out/prev-run"; : > "$out/flaky"
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
      [ "$got_list" = 1 ] || { [ ! -f "$d/list" ] || cat "$d/list" >> "$out/list"
                               [ ! -f "$d/flaky" ] || cat "$d/flaky" >> "$out/flaky"; got_list=1; }
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
    # This train's verdicts, from every shard's result file (FAIL / TIMEOUT / QUARANTINE lines).
    res=$(cat "$results"/*/train-result.txt "$results"/train-result*.txt 2>/dev/null)
    printf '%s\n' "$res" | awk '$1 == "FAIL" || $1 == "TIMEOUT" || $1 == "QUARANTINE" { print $2 }' | sort -u > "$out/fails"
    newq=$(printf '%s\n' "$res" | awk '$1 == "QUARANTINE" { print $2 }' | sort -u)
    entries "$now" active "$list" > "$out/list"
    rc=0
    for t in $newq; do
      if [ -n "$issue" ]; then num=$issue
      else
        [ -n "$repo" ] || die "record: --repo is needed to file the breakage issue"
        key="selftest-quarantine.${t%-selftest.sh}"
        url=$(file_issue --repo "$repo" --breakage-key "$key" --fault-sha "$sha" --fault-link "https://github.com/$repo/actions/runs/$run" \
                --label bug --title "列车隔离了 ${t}：连红两趟" \
                --body "$t 在连续两趟发布列车上红（run ${prev_run:-?} 与 run ${run}，TRAIN_SHA ${sha}），这趟的改动没碰它，也没碰它点名的文件，所以列车隔离它最多 ${hours} 小时（issue #3243）。PR 与夜里的全量照跑它；碰到它的列车也照跑。修好它，隔离就失效；到期自动恢复。
https://github.com/$repo/actions/runs/$run") ; frc=$?
        num=$(printf '%s\n' "$url" | sed -n 's|.*/issues/\([0-9][0-9]*\).*|\1|p' | tail -1)
        # said, not filed (the default since #4898): no issue to name
        [ -z "$num" ] && [ -z "${FLEET_TQ_FILER:-}" ] && [ "$frc" -eq 0 ] && num=-
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
    record_flaky "$res" || true
    printf '%s\n' "$sha" > "$out/sha"; printf '%s\n' "$run" > "$out/run"
    exit "$rc" ;;

  *) die "unknown command $cmd (active|expired|summary|fetch|record)" ;;
esac
