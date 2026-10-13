#!/bin/bash
# fleet-train-quarantine-selftest.sh — the release train's selftest quarantine
# (issue #3243, EPIC #3139 C10): a test red on two trains in a row, untouched by the
# second train's change, is quarantined ≤ 48 h against its breakage issue; only the
# train skips it.
#
# A throwaway git repo whose bin/ holds the REAL bin/run-selftests.sh and
# bin/fleet-train-quarantine.sh plus fake tests whose colour a file sets:
#   portability  the lint group — selected on every --changed run, touched by none
#   alpha        names tool-a.sh — touched when tool-a.sh changes
# Legs (TQ_LEG=<leg> runs one — docs/dev/BREAK-IT.md's quarantine-* drills do):
#   one-red    red on ONE train only: a FAIL, the shard red, nothing quarantined
#   two-red    red on the previous train (another sha) and again, untouched: QUARANTINE,
#              the shard green; record files ONE issue and writes the entry (≤ 48 h,
#              both run ids); the next train skips it; the summary says 「隔离了 1 个」
#   touched    an entry in force, but this change touches the test: it runs (and a red
#              there is a FAIL, never a second quarantine)
#   expired    an expired entry is no entry: the test runs, the summary says
#              「已过期，恢复」 and no 「隔离了」 line
#   pr-skips   without --quarantine nothing is ever skipped; the options refuse
#              without --changed; only release-train.yml passes them to the shards —
#              never selftests.yml (the PR gate) nor selftests-macos.yml (the nightly)
#   fetch      the state comes from the previous train's artifact; the fails that
#              count are the newest earlier train's on ANOTHER sha
#   flaky      (issue #3866) --retry-red 1: red then green on its one rerun is FLAKY,
#              the shard green; record files ONE flaky issue (--breakage-key
#              flaky-<test>, label flaky) with both runs' heads, keeps the sighting
#              seven days, quarantines at the third (reason flaky); a drill's sighting
#              is filed, never counted; the summary says 「重跑才过 1 个」
#   retry-red  (BREAK-IT train-flaky-retry-hides-red) a test red on its rerun too is
#              a FAIL and the shard red; --drill-red stays red on the rerun; a TIMEOUT
#              is never rerun; more than one rerun is refused; only the train passes
#              retry_red — never the PR gate nor the nightly
set -u
BIN=$(cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(cd -- "$BIN/.." && pwd)
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

T=$(mktemp -d "${TMPDIR:-/tmp}/fleet-selftest-tq.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
R="$T/repo"
mkdir -p "$R/bin" "$R/docs" "$R/conf"
cp "$BIN/run-selftests.sh" "$BIN/selftest-shadow-root.sh" "$BIN/fleet-train-quarantine.sh" "$R/bin/"

FAILS=0
fail() { printf 'FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }
ok()   { printf 'ok   %s\n' "$*"; }

mk_test() {   # mk_test <name> <comment> — red when $T/red.<name> exists
  printf '#!/bin/sh\n# %s\n[ ! -f "%s/red.%s" ]\n' "$2" "$T" "$1" > "$R/bin/$1-selftest.sh"
}
mk_test portability 'lint: scans the whole tree'
# beta: red on its next run only when $T/flip.beta exists (that run removes it)
printf '#!/bin/sh\n# flips\necho "beta says hello"\nif [ -f "%s/flip.beta" ]; then rm -f "%s/flip.beta"; echo "beta went red"; exit 3; fi\n' "$T" "$T" > "$R/bin/beta-selftest.sh"
mk_test alpha       'drives tool-a.sh'
printf '#!/bin/sh\necho a\n' > "$R/bin/tool-a.sh"
echo '# docs' > "$R/docs/guide.md"

g() { git -C "$R" -c user.name=t -c user.email=t@example.invalid "$@"; }
g init -q
g add -A && g commit -qm base && g tag base
change() {   # change <name> <edit> — a commit on top of base: this train's diff
  g checkout -q -B "c-$1" base
  (cd "$R" && eval "$2")
  g add -A && g commit -qm "$1"
}
red()   { : > "$T/red.$1"; }
green() { rm -f "$T/red.$1"; }
NOW=2026-10-11T08:00:00Z
# FUTURE is read against the real clock too (a train run has no --now): far out,
# never a date the suite outlives (2026-10-12T08:00Z went red the day it passed).
FUTURE=2099-01-01T00:00:00Z PAST=2026-10-10T08:00:00Z

# train <args…> — one shard of a train: --changed base + the given options
train() {
  out=$(env -u FLEET_SELFTEST_ROOT FLEET_SELFTEST_NO_SHADOW=1 FLEET_HEAVY=0 \
        sh "$R/bin/run-selftests.sh" --changed base "$@" </dev/null 2>&1)
  rc=$?
}
has()  { printf '%s\n' "$out" | grep -qE -- "$1"; }
show() { printf '%s\n' "$out" | sed 's/^/     /'; }

# a stub filer: the issue number it hands out, and how often it was asked
FILER="$T/filer"
cat > "$FILER" <<EOF
#!/bin/sh
printf '%s\n' "\$*" | tr '\n' ' ' >> "$T/filed"; echo >> "$T/filed"
echo "https://github.com/o/r/issues/4242"
EOF
chmod +x "$FILER"

leg_one_red() {
  change docs 'echo more >> docs/guide.md'
  red portability; : > "$T/prev"
  train --prev-fails "$T/prev"
  if [ "$rc" -ne 0 ] && has '^FAIL  portability-selftest.sh' && ! has '^QUARANTINE '; then
    ok "one-red: red on one train is a FAIL — the shard is red, nothing quarantined"
  else fail "one-red: rc=$rc"; show; fi
  # another sha's train was green on it (not in its fails): still one red
  echo 'alpha-selftest.sh' > "$T/prev"
  train --prev-fails "$T/prev"
  [ "$rc" -ne 0 ] && ! has '^QUARANTINE ' && ok "one-red: a previous red on ANOTHER test does not count" \
    || { fail "one-red: quarantined on someone else's red (rc=$rc)"; show; }
  mkdir -p "$T/res1"; printf '%s\n' "$out" > "$T/res1/train-result.txt"
  rm -f "$T/filed"
  FLEET_TQ_FILER=$FILER sh "$R/bin/fleet-train-quarantine.sh" record --results "$T/res1" --list /dev/null \
    --prev-run 11 --run 12 --sha abc --repo o/r --out "$T/st1" --now "$NOW" >/dev/null 2>&1
  [ ! -s "$T/st1/list" ] && [ ! -f "$T/filed" ] && grep -qx portability-selftest.sh "$T/st1/fails" \
    && ok "one-red: record files nothing, writes no entry, remembers the red for the next train" \
    || fail "one-red: record wrote [$(cat "$T/st1/list" 2>/dev/null)] filed [$(cat "$T/filed" 2>/dev/null)]"
  green portability
}

leg_two_red() {
  change docs2 'echo again >> docs/guide.md'
  red portability; echo portability-selftest.sh > "$T/prev"
  train --prev-fails "$T/prev"
  if [ "$rc" -eq 0 ] && has '^QUARANTINE portability-selftest.sh' && ! has '^FAIL '; then
    ok "two-red: red on two trains in a row, untouched — QUARANTINE, the shard stays green"
  else fail "two-red: rc=$rc"; show; fi
  mkdir -p "$T/res2/macOS-1"; printf '%s\n' "$out" | grep -E '^(FAIL|QUARANTINE) ' > "$T/res2/macOS-1/train-result.txt"
  cp "$T/res2/macOS-1/train-result.txt" "$T/res2/train-result-linux.txt"   # both halves say it: ONE issue
  rm -f "$T/filed"
  rec=$(FLEET_TQ_FILER=$FILER sh "$R/bin/fleet-train-quarantine.sh" record --results "$T/res2" --list /dev/null \
          --prev-run 11 --run 12 --sha abc --repo o/r --out "$T/st2" --now "$NOW" 2>&1); rrc=$?
  want='portability-selftest.sh 4242 2026-10-13T08:00:00Z 11 12'
  if [ "$rrc" -eq 0 ] && [ "$(cat "$T/st2/list")" = "$want" ] && [ "$(wc -l < "$T/filed" | tr -d ' ')" = 1 ] \
     && grep -q -- '--breakage-key selftest-quarantine.portability' "$T/filed"; then
    ok "two-red: record filed ONE breakage issue and wrote '$want' (48 h, both runs)"
  else fail "two-red: record rc=$rrc list=[$(cat "$T/st2/list" 2>/dev/null)] filed=[$(cat "$T/filed" 2>/dev/null)] $rec"; fi
  [ "$(cat "$T/st2/sha")" = abc ] && [ "$(cat "$T/st2/run")" = 12 ] || fail "two-red: the state does not carry sha/run"
  sum=$(sh "$R/bin/fleet-train-quarantine.sh" summary --now "$NOW" "$T/st2/list")
  [ "$sum" = '隔离了 1 个：portability-selftest.sh（#4242，到期 2026-10-13T08:00:00Z）' ] \
    && ok "two-red: summary — $sum" || fail "two-red: summary [$sum]"
  # the next train holds the entry: the test is skipped, the shard green. A train
  # run reads the real clock (no --now), so it gets the entry with a FUTURE expiry —
  # the recorded one (NOW + 48 h) went red the moment the wall clock passed it.
  sed "s/ 2026-10-13T08:00:00Z / $FUTURE /" "$T/st2/list" > "$T/st2/list.live"
  train --quarantine "$T/st2/list.live"
  if [ "$rc" -eq 0 ] && has '^QUARANTINED portability-selftest.sh skipped — #4242' && ! has '=== portability'; then
    ok "two-red: the next train skips it"
  else fail "two-red: next train rc=$rc"; show; fi
  # a hand cap: no entry holds longer than 48 h whatever the knob says
  FLEET_TQ_HOURS=500 FLEET_TQ_FILER=$FILER sh "$R/bin/fleet-train-quarantine.sh" record --results "$T/res2" --list /dev/null \
    --prev-run 11 --run 12 --sha abc --repo o/r --out "$T/st2b" --now "$NOW" >/dev/null 2>&1
  awk '{print $3}' "$T/st2b/list" | grep -qx 2026-10-13T08:00:00Z && ok "two-red: never longer than 48 h" \
    || fail "two-red: FLEET_TQ_HOURS=500 gave [$(cat "$T/st2b/list")]"
  # the filer said no: nothing quarantined, record red (the train with it)
  printf '#!/bin/sh\nexit 1\n' > "$T/badfiler"; chmod +x "$T/badfiler"
  FLEET_TQ_FILER=$T/badfiler sh "$R/bin/fleet-train-quarantine.sh" record --results "$T/res2" --list /dev/null \
    --prev-run 11 --run 12 --sha abc --repo o/r --out "$T/st2c" --now "$NOW" >/dev/null 2>&1 \
    && fail "two-red: record green with no issue filed" \
    || { [ ! -s "$T/st2c/list" ] && ok "two-red: no issue, no entry — record is red"; }
  green portability
}

leg_touched() {
  change tool 'echo b >> bin/tool-a.sh'
  printf 'alpha-selftest.sh 77 %s 1 2\n' "$FUTURE" > "$T/q"
  train --quarantine "$T/q"
  if [ "$rc" -eq 0 ] && has '^quarantine: alpha-selftest.sh runs — this change touches it' && has '^PASS  alpha-selftest.sh'; then
    ok "touched: an entry in force, but the change touches a file the test names — it runs"
  else fail "touched: rc=$rc"; show; fi
  red alpha; echo alpha-selftest.sh > "$T/prev"
  train --quarantine "$T/q" --prev-fails "$T/prev"
  [ "$rc" -ne 0 ] && has '^FAIL  alpha-selftest.sh' && ! has '^QUARANTINE ' \
    && ok "touched: red again there is a FAIL — a touched test is never quarantined" \
    || { fail "touched: rc=$rc"; show; }
  green alpha
  # the test file itself changed: touched too
  change self 'echo "# more" >> bin/portability-selftest.sh'
  printf 'portability-selftest.sh 78 %s 1 2\n' "$FUTURE" > "$T/q"
  train --quarantine "$T/q"
  has '^quarantine: portability-selftest.sh runs' && has '^PASS  portability-selftest.sh' \
    && ok "touched: a test whose own file changed runs" || { fail "touched: self-change skipped"; show; }
}

leg_expired() {
  change docs3 'echo x >> docs/guide.md'
  printf 'portability-selftest.sh 79 %s 1 2\n' "$PAST" > "$T/q"
  train --quarantine "$T/q"
  if [ "$rc" -eq 0 ] && has '^PASS  portability-selftest.sh' && ! has '^QUARANTINED '; then
    ok "expired: an expired entry is no entry — the test runs"
  else fail "expired: rc=$rc"; show; fi
  sum=$(sh "$R/bin/fleet-train-quarantine.sh" summary --now "$NOW" --expired "$T/q" /dev/null)
  [ "$sum" = '已过期，恢复：portability-selftest.sh（#79）' ] \
    && ok "expired: summary — $sum (no 隔离了 line)" || fail "expired: summary [$sum]"
  sum=$(sh "$R/bin/fleet-train-quarantine.sh" summary --now "$NOW" /dev/null)
  [ -z "$sum" ] && ok "expired: nothing quarantined, nothing said" || fail "expired: empty list said [$sum]"
  # malformed lines are ignored, said on stderr
  printf 'garbage\nalpha-selftest.sh x %s 1 2\n' "$FUTURE" > "$T/qbad"
  a=$(sh "$R/bin/fleet-train-quarantine.sh" active --now "$NOW" "$T/qbad" 2>"$T/err")
  [ -z "$a" ] && grep -q malformed "$T/err" && ok "expired: a malformed line is no entry" || fail "expired: malformed read as [$a]"
}

leg_pr_skips() {
  change docs4 'echo y >> docs/guide.md'
  printf 'portability-selftest.sh 80 %s 1 2\n' "$FUTURE" > "$T/q"
  train
  has '^PASS  portability-selftest.sh' && ! has 'QUARANTIN' \
    && ok "pr-skips: no --quarantine (the PR gate, the nightly) — nothing skipped" || { fail "pr-skips: skipped without the option"; show; }
  out=$(env -u FLEET_SELFTEST_ROOT FLEET_SELFTEST_NO_SHADOW=1 sh "$R/bin/run-selftests.sh" --quarantine "$T/q" portability 2>&1); rc=$?
  [ "$rc" = 2 ] && ok "pr-skips: --quarantine without --changed refuses (exit 2)" || { fail "pr-skips: rc=$rc"; show; }
  # the workflows: only the train hands the shards a quarantine
  wf="$ROOT/.github/workflows"
  for f in selftests.yml selftests-macos.yml; do
    grep -nE '^[[:space:]]+(quarantine|prev_fails|drill_red|record):' "$wf/$f" \
      && fail "pr-skips: $f passes a quarantine input to the shards" || ok "pr-skips: $f passes no quarantine"
  done
  grep -qE '^[[:space:]]+quarantine:' "$wf/release-train.yml" && ok "pr-skips: release-train.yml passes it" \
    || fail "pr-skips: release-train.yml does not pass the quarantine"
  # the shards add the options only from those inputs, never by default
  sh_=$(awk '/name: Run this shard/,/name: Per-test timings/' "$wf/selftests-shards.yml")
  printf '%s\n' "$sh_" | grep -q -- '--quarantine' && printf '%s\n' "$sh_" | grep -q 'QUARANTINE: \${{ inputs.quarantine }}' \
    && ok "pr-skips: the shard passes --quarantine from inputs.quarantine only" \
    || fail "pr-skips: selftests-shards.yml's run step does not gate --quarantine on its input"
  awk '/^on:/,/^jobs:/' "$wf/selftests-shards.yml" | grep -A4 '^      quarantine:' | grep -q "default: ''" \
    && ok "pr-skips: the input defaults to empty" || fail "pr-skips: inputs.quarantine has no empty default"
}

leg_fetch() {
  # three earlier trains: newest on the SAME sha (a re-run, red on nothing), then one
  # on another sha red on portability, then an older one red on alpha
  mk_art() {   # mk_art <id> <sha> <run> <fails> <list>
    python3 - "$T/art.$1.zip" "$2" "$3" "$4" "$5" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
z.writestr("sha", sys.argv[2] + "\n"); z.writestr("run", sys.argv[3] + "\n")
z.writestr("fails", sys.argv[4]); z.writestr("list", sys.argv[5]); z.close()
PY
  }
  mk_art 3 SAME 30 '' "alpha-selftest.sh 5 $FUTURE 1 2
"
  mk_art 2 OTHER 20 'portability-selftest.sh
' ''
  mk_art 1 OLD 10 'alpha-selftest.sh
' ''
  mkdir -p "$T/ghbin"
  cat > "$T/ghbin/gh" <<EOF
#!/bin/sh
case "\$2" in
  *'artifacts?name='*) printf '3 31\n9 99\n2 21\n1 11\n' ;;
  */artifacts/*/zip) id=\${2%/zip}; id=\${id##*/}; cat "$T/art.\$id.zip" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$T/ghbin/gh"
  PATH="$T/ghbin:$PATH" sh "$R/bin/fleet-train-quarantine.sh" fetch --repo o/r --run 99 --sha SAME --out "$T/f" 2>"$T/ferr"
  [ "$(cat "$T/f/prev-fails")" = portability-selftest.sh ] && [ "$(cat "$T/f/prev-run")" = 20 ] \
    && ok "fetch: the fails that count are the newest earlier train's on another sha (run 20)" \
    || fail "fetch: prev-fails [$(cat "$T/f/prev-fails" 2>/dev/null)] prev-run [$(cat "$T/f/prev-run" 2>/dev/null)] $(cat "$T/ferr")"
  grep -q '^alpha-selftest.sh 5 ' "$T/f/list" && ok "fetch: the newest earlier train's list is the state in force" \
    || fail "fetch: list [$(cat "$T/f/list" 2>/dev/null)]"
  # no gh answer at all: no state, nothing from it — never an error
  printf '#!/bin/sh\nexit 1\n' > "$T/ghbin/gh"
  PATH="$T/ghbin:$PATH" sh "$R/bin/fleet-train-quarantine.sh" fetch --repo o/r --run 99 --sha SAME --out "$T/f2" 2>/dev/null \
    && [ ! -s "$T/f2/prev-fails" ] && ok "fetch: no artifacts list — no previous state, exit 0" || fail "fetch: a gh failure broke the train"
}

leg_flaky() {
  change docs5 'echo f >> docs/guide.md'
  # beta is touched by nothing; run it by name, --changed still given (the train's shape)
  : > "$T/flip.beta"
  out=$(env -u FLEET_SELFTEST_ROOT FLEET_SELFTEST_NO_SHADOW=1 FLEET_HEAVY=0 \
        sh "$R/bin/run-selftests.sh" beta </dev/null 2>&1); rc=$?
  [ "$rc" -ne 0 ] && has '^FAIL  beta-selftest.sh' && ! has '^FLAKY ' \
    && ok "flaky: without --retry-red (the PR gate, the nightly) a red is a FAIL — nothing reruns" \
    || { fail "flaky: no-retry rc=$rc"; show; }
  : > "$T/flip.beta"
  out=$(env -u FLEET_SELFTEST_ROOT FLEET_SELFTEST_NO_SHADOW=1 FLEET_HEAVY=0 \
        sh "$R/bin/run-selftests.sh" --retry-red 1 beta </dev/null 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && has '^FLAKY beta-selftest.sh ' && has '^=== beta-selftest.sh \(rerun' && ! has '^FAIL ' \
     && has '^flaky \(red, then green'; then
    ok "flaky: red then green on its one rerun — FLAKY, the shard green"
  else fail "flaky: retry rc=$rc"; show; fi
  printf '%s\n' "$out" > "$T/flaky.log"
  rm -rf "$T/resf"; mkdir -p "$T/resf/Linux-1"
  printf '%s\n' "$out" | grep -E '^(FAIL|TIMEOUT|QUARANTINE|FLAKY) ' > "$T/resf/Linux-1/train-result.txt"
  sh "$R/bin/fleet-train-quarantine.sh" heads --log "$T/flaky.log" --out "$T/resf/Linux-1"
  hf="$T/resf/Linux-1/train-flaky-beta-selftest.sh.txt"
  [ -f "$hf" ] && grep -q 'beta went red' "$hf" && grep -q '^--- rerun (green) ---' "$hf" \
    && ok "flaky: heads — the head of the red run and of the green rerun" || fail "flaky: heads [$(cat "$hf" 2>/dev/null)]"
  # the drill: a green test whose first run is counted red
  out=$(env -u FLEET_SELFTEST_ROOT FLEET_SELFTEST_NO_SHADOW=1 FLEET_HEAVY=0 \
        sh "$R/bin/run-selftests.sh" --retry-red 1 --drill-flaky alpha-selftest.sh alpha </dev/null 2>&1); rc=$?
  [ "$rc" -eq 0 ] && has '^FLAKY alpha-selftest.sh ' && ok "flaky: --drill-flaky — the first run red, the rerun its own: FLAKY" \
    || { fail "flaky: drill rc=$rc"; show; }
  # record: ONE issue, a sighting, nothing quarantined yet, not a fail for the next train
  rm -f "$T/filed"
  rec=$(FLEET_TQ_FILER=$FILER sh "$R/bin/fleet-train-quarantine.sh" record --results "$T/resf" --list /dev/null \
          --prev-run 11 --run 12 --sha abc --repo o/r --out "$T/stf" --now "$NOW" 2>&1); rrc=$?
  if [ "$rrc" -eq 0 ] && [ "$(wc -l < "$T/filed" | tr -d ' ')" = 1 ] && grep -q -- '--breakage-key flaky-beta ' "$T/filed" \
     && grep -q -- '--label flaky' "$T/filed" && grep -q 'beta went red' "$T/filed" \
     && [ "$(cat "$T/stf/flaky")" = "beta-selftest.sh $NOW 12 4242" ] && [ ! -s "$T/stf/list" ] && [ ! -s "$T/stf/fails" ]; then
    ok "flaky: record filed ONE issue (flaky-beta, label flaky, both heads), kept the sighting, quarantined nothing"
  else fail "flaky: record rc=$rrc filed=[$(cat "$T/filed" 2>/dev/null)] flaky=[$(cat "$T/stf/flaky" 2>/dev/null)] list=[$(cat "$T/stf/list")] fails=[$(cat "$T/stf/fails")] $rec"; fi
  sum=$(sh "$R/bin/fleet-train-quarantine.sh" summary --now "$NOW" --flaky "$T/stf/flaky-now" "$T/stf/list")
  [ "$sum" = '重跑才过 1 个：beta-selftest.sh（#4242）' ] && ok "flaky: summary — $sum" || fail "flaky: summary [$sum]"
  # the third sighting in seven days quarantines (one older than seven days does not count)
  printf 'beta-selftest.sh 2026-10-01T00:00:00Z 5 4242\nbeta-selftest.sh 2026-10-10T00:00:00Z 9 4242\nbeta-selftest.sh 2026-10-10T09:00:00Z 10 4242\n' > "$T/fh"
  FLEET_TQ_FILER=$FILER sh "$R/bin/fleet-train-quarantine.sh" record --results "$T/resf" --list /dev/null \
    --prev-run 11 --run 12 --sha abc --repo o/r --out "$T/stf3" --now "$NOW" --flaky-hist "$T/fh" >/dev/null 2>&1
  want='beta-selftest.sh 4242 2026-10-13T08:00:00Z 10 12 flaky'
  [ "$(cat "$T/stf3/list")" = "$want" ] && [ "$(wc -l < "$T/stf3/flaky" | tr -d ' ')" = 3 ] \
    && ok "flaky: the third sighting in seven days quarantines — '$want'" \
    || fail "flaky: third sighting list=[$(cat "$T/stf3/list")] flaky=[$(cat "$T/stf3/flaky")]"
  sum=$(sh "$R/bin/fleet-train-quarantine.sh" summary --now "$NOW" "$T/stf3/list")
  [ "$sum" = '隔离了 1 个：beta-selftest.sh（#4242，flaky，到期 2026-10-13T08:00:00Z）' ] \
    && ok "flaky: the quarantine says why — $sum" || fail "flaky: quarantine summary [$sum]"
  # (the lint group is what every --changed run selects untouched: stand it in)
  printf 'portability-selftest.sh 4242 %s 10 12 flaky\n' "$FUTURE" > "$T/qf"
  train --quarantine "$T/qf"
  has "^QUARANTINED portability-selftest.sh skipped — #4242, until $FUTURE \\(flaky" \
    && ok "flaky: the next train skips it, saying flaky" || { fail "flaky: next train"; show; }
  # a drill's sighting is filed, never counted
  FLEET_TQ_FILER=$FILER sh "$R/bin/fleet-train-quarantine.sh" record --results "$T/resf" --list /dev/null \
    --prev-run 11 --run 12 --sha abc --repo o/r --out "$T/stfd" --now "$NOW" --flaky-hist "$T/fh" \
    --drill-flaky beta-selftest.sh >/dev/null 2>&1
  [ ! -s "$T/stfd/list" ] && [ "$(wc -l < "$T/stfd/flaky" | tr -d ' ')" = 2 ] && grep -q 'beta-selftest.sh 4242' "$T/stfd/flaky-now" \
    && ok "flaky: a drill's sighting is filed and said, never counted toward a quarantine" \
    || fail "flaky: drill counted list=[$(cat "$T/stfd/list")] flaky=[$(cat "$T/stfd/flaky")]"
  # a filer that says no: the train still ships (record green), the sighting kept
  printf '#!/bin/sh\nexit 1\n' > "$T/badfiler"; chmod +x "$T/badfiler"
  FLEET_TQ_FILER=$T/badfiler sh "$R/bin/fleet-train-quarantine.sh" record --results "$T/resf" --list /dev/null \
    --prev-run 11 --run 12 --sha abc --repo o/r --out "$T/stfb" --now "$NOW" >/dev/null 2>&1 \
    && [ -s "$T/stfb/flaky" ] && ok "flaky: a flaky filing that fails never reds the train" \
    || fail "flaky: a failed flaky filing redded record"
  # fetch carries the newest earlier train's sightings
  python3 - "$T/art.7.zip" <<'PY2'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
z.writestr("sha", "OTHER\n"); z.writestr("run", "70\n"); z.writestr("fails", ""); z.writestr("list", "")
z.writestr("flaky", "beta-selftest.sh 2026-10-10T00:00:00Z 70 4242\n"); z.close()
PY2
  mkdir -p "$T/ghbin"
  cat > "$T/ghbin/gh" <<EOF
#!/bin/sh
case "\$2" in
  *'artifacts?name='*) printf '7 71\n' ;;
  */artifacts/*/zip) cat "$T/art.7.zip" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$T/ghbin/gh"
  PATH="$T/ghbin:$PATH" sh "$R/bin/fleet-train-quarantine.sh" fetch --repo o/r --run 99 --sha SAME --out "$T/ff" 2>/dev/null
  grep -q '^beta-selftest.sh 2026-10-10T00:00:00Z 70 4242$' "$T/ff/flaky" \
    && ok "flaky: fetch carries the previous train's sightings" || fail "flaky: fetch flaky [$(cat "$T/ff/flaky" 2>/dev/null)]"
}

leg_retry_red() {
  change docs6 'echo r >> docs/guide.md'
  red alpha
  out=$(env -u FLEET_SELFTEST_ROOT FLEET_SELFTEST_NO_SHADOW=1 FLEET_HEAVY=0 \
        sh "$R/bin/run-selftests.sh" --retry-red 1 alpha </dev/null 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && has '^=== alpha-selftest.sh \(rerun' && has '^FAIL  alpha-selftest.sh' && ! has '^FLAKY '; then
    ok "retry-red: red on its rerun too — a FAIL, the shard red; a rerun never ships a real red"
  else fail "retry-red: rc=$rc"; show; fi
  green alpha
  out=$(env -u FLEET_SELFTEST_ROOT FLEET_SELFTEST_NO_SHADOW=1 FLEET_HEAVY=0 \
        sh "$R/bin/run-selftests.sh" --retry-red 1 --drill-red alpha-selftest.sh alpha </dev/null 2>&1); rc=$?
  [ "$rc" -ne 0 ] && has '^FAIL  alpha-selftest.sh' && ! has '^FLAKY ' \
    && ok "retry-red: --drill-red stays red on the rerun (the old drill, as before)" || { fail "retry-red: drill-red rc=$rc"; show; }
  # a red twice in a row on two trains still quarantines through the rerun
  red portability; echo portability-selftest.sh > "$T/prev"
  train --prev-fails "$T/prev" --retry-red 1
  [ "$rc" -eq 0 ] && has '^QUARANTINE portability-selftest.sh' && ok "retry-red: red twice (rerun too) on the second train in a row — QUARANTINE as before" \
    || { fail "retry-red: quarantine through the rerun rc=$rc"; show; }
  green portability
  # a TIMEOUT is never rerun
  printf '#!/bin/sh\nsleep 30\n' > "$R/bin/slow-selftest.sh"
  out=$(env -u FLEET_SELFTEST_ROOT FLEET_SELFTEST_NO_SHADOW=1 FLEET_HEAVY=0 FLEET_SELFTEST_TEST_TIMEOUT=1 \
        sh "$R/bin/run-selftests.sh" --retry-red 1 slow </dev/null 2>&1); rc=$?
  rm -f "$R/bin/slow-selftest.sh"
  if command -v perl >/dev/null 2>&1; then
    [ "$rc" -ne 0 ] && has '^TIMEOUT slow-selftest.sh' && ! has '\(rerun' \
      && ok "retry-red: a TIMEOUT is never rerun" || { fail "retry-red: timeout rc=$rc"; show; }
  fi
  out=$(env -u FLEET_SELFTEST_ROOT FLEET_SELFTEST_NO_SHADOW=1 sh "$R/bin/run-selftests.sh" --retry-red 2 alpha 2>&1); rc=$?
  [ "$rc" = 2 ] && ok "retry-red: more than one rerun is refused (exit 2)" || { fail "retry-red: --retry-red 2 rc=$rc"; show; }
  wf="$ROOT/.github/workflows"
  for f in selftests.yml selftests-macos.yml; do
    grep -nE '^[[:space:]]+(retry_red|drill_flaky):' "$wf/$f" \
      && fail "retry-red: $f passes retry_red to the shards" || ok "retry-red: $f reruns nothing"
  done
  # the Linux half on the train, the macOS half after it (mac-follow.yml, issue #3869)
  [ "$(grep -cE "^[[:space:]]+retry_red: '1'" "$wf/release-train.yml")" = 1 ] && grep -qE "^[[:space:]]+retry_red: '1'" "$wf/mac-follow.yml" \
    && ok "retry-red: release-train.yml + mac-follow.yml pass retry_red to both halves" || fail "retry-red: the train / mac-follow do not pass retry_red"
  awk '/^on:/,/^jobs:/' "$wf/selftests-shards.yml" | grep -A4 '^      retry_red:' | grep -q "default: ''" \
    && ok "retry-red: the shards' input defaults to empty" || fail "retry-red: inputs.retry_red has no empty default"
}

case "${TQ_LEG:-all}" in
  all)       leg_one_red; leg_two_red; leg_touched; leg_expired; leg_pr_skips; leg_fetch; leg_flaky; leg_retry_red ;;
  flaky)     leg_flaky ;;
  retry-red) leg_retry_red ;;
  one-red)   leg_one_red ;;
  two-red)   leg_two_red ;;
  touched)   leg_touched ;;
  expired)   leg_expired ;;
  pr-skips)  leg_pr_skips ;;
  fetch)     leg_fetch ;;
  *) echo "fleet-train-quarantine-selftest: unknown TQ_LEG=$TQ_LEG" >&2; exit 2 ;;
esac

if [ "$FAILS" -ne 0 ]; then echo "fleet-train-quarantine-selftest: $FAILS failure(s)"; exit 1; fi
echo "fleet-train-quarantine-selftest: all green"
