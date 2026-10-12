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
  # the next train holds the entry: the test is skipped, the shard green
  train --quarantine "$T/st2/list"
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

case "${TQ_LEG:-all}" in
  all)       leg_one_red; leg_two_red; leg_touched; leg_expired; leg_pr_skips; leg_fetch ;;
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
