#!/bin/bash
# site-drill-selftest.sh — the website's seconds come from the live drill
# (issue #3589, EPIC #3569 C19): a `fleet-onboard-drill.sh --runs N` run dir
# (bin/fleet-onboard-clock.sh's clock.tsv + screens/) through bin/site-drill.py
# into bin/site-build.sh, and the built page read back.
#
#   A  a drill of 3 runs, the slowest 47 s: 「60 秒」 on the page, the stopwatch
#      00:47, the slowest run's steps (9 · 6 · 32 秒) and date, its three screens
#      in the three steps' pictures (the design's mock gone), no RED:
#   B  the screens are neutral: no drill login, no sandbox computer name, no hub
#      address, no internal name (conf/oss-scan.rules), --rename applied
#   C  a 130 s drill: 「约 2 分钟」 in place of 「60 秒」, 02:10, a RED: line
#   D  the same drill 8 days later: no seconds, a RED: line
#   E  a run that never reached the first key: no drill file (exit 1), says why
#   F  a drill file without screens: seconds shown, the mock kept, a RED: line
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRILL="$ROOT/bin/site-drill.py"
BUILD="$ROOT/bin/site-build.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/site-drill-st.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

# run_dir <dir> <date> <row>…: a fake clock run — each row
# "<run> <t_cert> <t_machine> <t_key>" (ms), and four screens per run
run_dir() {
  local d=$1 day=$2 r n c m k; shift 2
  mkdir -p "$d/screens"
  printf 'run\tt_enter\tt_installed\tt_browser\tt_cert\tt_machine\tt_ready\tt_key\n' > "$d/clock.tsv"
  printf '## 60 秒上手 · https://hub.internal.example:8443 · %s 次 · %s 19:40\n' "$#" "$day" > "$d/report.md"
  for r in "$@"; do
    set -- $r; n=$1 c=$2 m=$3 k=${4:-}
    printf '%s\t0\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$((c / 3))" "$((c / 2))" "$c" "$m" "${k:+$((k - 500))}" "$k" >> "$d/clock.tsv"
    printf 'newcomer%% curl -fsSL https://hub.internal.example:8443/i/xyz | sh\n用时 3 秒\n' > "$d/screens/run$n-001-800ms.txt"
    printf '已在浏览器里打开\n✓ 已登记到入口 drill10121955 · newcomer-%s-4242\n\n\n' "$n" > "$d/screens/run$n-002-$((c + 100))ms.txt"
    printf '正在为你开机器…\n✓ 会话开在 mini2 · 销售周报-内部\n' > "$d/screens/run$n-003-$((m + 100))ms.txt"
    [ -n "$k" ] && printf '╭──────╮\n│ ❯ z  │\n╰──────╯\n  ? for shortcuts · /Users/verky/x\n' > "$d/screens/run$n-004-$((k + 100))ms.txt"
    cp "$d/screens/run$n-001-800ms.txt" "$d/screens/run$n-last.txt"
  done
}

page_text() { python3 - "$1" <<'PY'
import html, re, sys
p = open(sys.argv[1], encoding='utf-8').read()
s = p[p.index('id="start"'):]
s = s[:s.index('</section>')]
print(html.unescape(s))
PY
}

# A — the slowest of three runs is 47 s
run_dir "$T/a" 2026-10-10 "1 8000 14000 44000" "2 9000 15000 47000" "3 7000 12000 40000"
if out=$(python3 "$DRILL" "$T/a" --out "$T/a.json" --rename '销售周报-内部=活动报名页' 2>&1); then
  b=$("$BUILD" --out "$T/pa" --drill "$T/a.json" --now 2026-10-12 2>&1); rc=$?
  if [ "$rc" != 0 ]; then bad "A build failed (rc $rc): $b"
  else
    zh=$(page_text "$T/pa/index.html"); miss=''
    for s in '<em>60 秒</em>' '00:47' '>9 秒<' '>6 秒<' '>32 秒<' '2026-10-10' 'term-shot' '已登记到入口' '活动报名页' '❯ z'; do
      printf '%s' "$zh" | grep -qF -- "$s" || miss="$miss $s"
    done
    printf '%s' "$zh" | grep -qF 's-login' && miss="$miss (the design's mock still there)"
    grep -qF '>9 s<' "$T/pa/en/index.html" || miss="$miss en:9s"
    printf '%s' "$b" | grep -q '^RED: ' && miss="$miss (a RED: line: $b)"
    [ -z "$miss" ] && ok "A slowest of 3 = 47 s: 60 秒 · 00:47 · 9/6/32 秒 · its date · its three screens" || bad "A missing:$miss"
  fi
else bad "A site-drill.py: $out"; fi

# B — neutral screens
leak=$(grep -oE 'drill1012|newcomer-[0-9]|hub\.internal|mini2|/Users/verky|销售周报-内部' "$T/a.json" "$T/pa/index.html" | sort -u | tr '\n' ' ')
[ -z "$leak" ] && ok "B the screens carry no login, computer, hub address or internal name" || bad "B leaked: $leak"

# C — a 130 s drill
run_dir "$T/c" 2026-10-10 "1 20000 110000 130000"
python3 "$DRILL" "$T/c" --out "$T/c.json" >/dev/null 2>&1 || bad "C site-drill.py failed"
b=$("$BUILD" --out "$T/pc" --drill "$T/c.json" --now 2026-10-12 2>&1)
if grep -qE '60 秒|60 seconds' "$T/pc/index.html" "$T/pc/en/index.html"; then bad "C a 130 s drill still says 60"
elif ! grep -qF '约 2 分钟' "$T/pc/index.html" || ! grep -qF '02:10' "$T/pc/index.html"; then bad "C no 约 2 分钟 / 02:10"
elif ! printf '%s\n' "$b" | grep -q '^RED: .*130.0 s'; then bad "C no RED: line: $b"
else ok "C a 130 s drill: 约 2 分钟 · 02:10 · RED"; fi

# D — the same drill 8 days on
b=$("$BUILD" --out "$T/pd" --drill "$T/c.json" --now 2026-10-18 2>&1)
if grep -qE '[0-9]+ 秒|[0-9]+ seconds|class="term-shot"' "$T/pd/index.html" "$T/pd/en/index.html"; then bad "D an 8-day-old drill still shows its seconds / screens"
elif ! printf '%s\n' "$b" | grep -q '^RED: .*8 days old'; then bad "D no RED: line: $b"
else ok "D an 8-day-old drill: no seconds, RED"; fi

# E — a run that never took the first key
run_dir "$T/e" 2026-10-10 "1 8000 14000 44000" "2 9000 15000 "
out=$(python3 "$DRILL" "$T/e" --out "$T/e.json" 2>&1); rc=$?
if [ "$rc" = 1 ] && [ ! -e "$T/e.json" ] && printf '%s' "$out" | grep -q 'run 2 never reached t_key'; then ok "E an unfinished run: no drill file"
else bad "E rc $rc, file $([ -e "$T/e.json" ] && echo written || echo none): $out"; fi

# F — no screens in the file
printf '{"date":"2026-10-10","runs":[{"total":46,"steps":{"login":8,"machine":6,"first":32}}]}\n' > "$T/f.json"
b=$("$BUILD" --out "$T/pf" --drill "$T/f.json" --now 2026-10-12 2>&1)
if grep -qF '00:46' "$T/pf/index.html" && grep -qF 's-login' "$T/pf/index.html" && ! grep -qF 'term-shot"' "$T/pf/index.html" \
   && printf '%s\n' "$b" | grep -q '^RED: .*no screens'; then ok "F no screens: the seconds, the mock, RED"
else bad "F: $b"; fi

[ "$fail" = 0 ] && echo "PASS" || echo "FAIL"
exit "$fail"
