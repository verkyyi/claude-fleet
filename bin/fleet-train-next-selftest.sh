#!/bin/bash
# fleet-train-next-selftest.sh — bin/fleet-train-next.py (issue #4913): judge a
# train's jobs + results into shipped / held / flaky / red / superseded /
# cancelled, decide whether the lane needs another train (≤ 2 re-sends a sha, a
# real red waits, a release-hold waits), count re-sends off the run names, and say
# the one line. Also pins the wiring: release-train.yml's `next` job and
# `release-hold?` step, release-train-next.yml's 10-minute backstop, the ledger's
# `post --to notice`.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
ROOT="$BIN/.."
PY="$BIN/fleet-train-next.py"
D=$(mktemp -d "${TMPDIR:-/tmp}/train-next.XXXXXX")
trap 'rm -rf "${D:?}"' EXIT
st_tally
SHA=$(printf 'a%.0s' $(seq 40)); NEW=$(printf 'b%.0s' $(seq 40)); STB=$(printf 'c%.0s' $(seq 40))

jobs() { : > "$D/jobs"; while [ "$#" -gt 0 ]; do printf '{"name":"%s","conclusion":"%s"}\n' "$1" "$2" >> "$D/jobs"; shift 2; done; }
result() { mkdir -p "$D/res/train-result-Linux-$1"; printf '%s\n' "$2" >> "$D/res/train-result-Linux-$1/train-result.txt"; }
judge() { python3 "$PY" judge --sha "$SHA" --jobs "$D/jobs" --results "$D/res" --flaky-issues "$D/flaky.tsv" "$@" > "$D/v.json"; \
          python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); print(v["verdict"], ",".join(v["tests"]))' "$D/v.json"; }
want() { [ "$2" = "$3" ] && st_ok "$1" || st_miss "$1: got '$2', want '$3'"; }

# --- judge ---
printf '4101\t列车上 wobbly-selftest.sh 时好时坏：红了一次，重跑才过\n' > "$D/flaky.tsv"
rm -rf "$D/res"; mkdir -p "$D/res"
jobs board success "Linux / shard 1" success "Linux / shard 2" failure 红灯即停 success train failure release skipped
result 2 'FAIL  wobbly-selftest.sh  (exit 1)'
want "a red test with an open flaky issue ⇒ flaky" "$(judge)" "flaky wobbly-selftest.sh"
result 2 'FAIL  solid-selftest.sh  (exit 1)'
want "a red test without one ⇒ red" "$(judge)" "red wobbly-selftest.sh,solid-selftest.sh"
rm -rf "$D/res"; mkdir -p "$D/res"
want "a shard cut short with no test red ⇒ flaky" "$(judge)" "flaky "
result 2 'FAIL  solid-selftest.sh  (exit 1)'
want "a lost runner's shard ⇒ flaky, whatever its log" "$(judge --lost '2')" "flaky "
jobs "Linux / shard 2" failure "Linux rescue / shard 2" success release success
want "a rescue green ⇒ the shard is green" "$(judge --moved true)" "shipped "
jobs "Linux / shard 1" success precheck failure train failure
want "precheck red ⇒ red, whatever the shards" "$(judge)" "red "
jobs "Linux / shard 1" success release success
want "green, a hold ⇒ held" "$(judge --held '77')" "held "
want "green, stable ahead ⇒ superseded" "$(judge --superseded true)" "superseded "
jobs "Linux / shard 1" cancelled
want "nothing red, nothing shipped ⇒ cancelled" "$(judge)" "cancelled "

# --- decide ---
verdict() { printf '{"sha":"%s","verdict":"%s","tests":["wobbly-selftest.sh"],"why":"x"}\n' "$1" "$2" > "$D/v.json"; }
decide() { python3 "$PY" decide --verdict "$D/v.json" --stable "$STB" "$@" | sed -n 's/^action=//p'; }
verdict "$SHA" flaky
want "flaky, idle lane ⇒ dispatch"        "$(decide --head "$SHA" --active 0 --retries 0)" dispatch
want "flaky, re-sent twice ⇒ wait"        "$(decide --head "$SHA" --active 0 --retries 2)" wait
want "flaky, a train queued ⇒ wait"       "$(decide --head "$SHA" --active 1 --retries 0)" wait
want "flaky, release-hold open ⇒ wait"    "$(decide --head "$SHA" --active 0 --retries 0 --holds 77)" wait
want "head on stable ⇒ wait"              "$(python3 "$PY" decide --verdict "$D/v.json" --stable "$SHA" --head "$SHA" --active 0 --retries 0 | sed -n 's/^action=//p')" wait
verdict "$SHA" red
want "real red ⇒ wait"                    "$(decide --head "$SHA" --active 0 --retries 0)" wait
want "real red, but the head moved ⇒ dispatch" "$(decide --head "$NEW" --active 0 --retries 0)" dispatch
verdict "$SHA" held
want "held, the hold closed ⇒ dispatch"   "$(decide --head "$SHA" --active 0 --retries 0)" dispatch
: > "$D/v.json"
want "no verdict ⇒ dispatch"              "$(decide --head "$SHA" --active 0 --retries 0)" dispatch
out=$(GITHUB_OUTPUT="$D/gho" python3 "$PY" decide --verdict "$D/v.json" --stable "$STB" --head "$SHA" --active 0 --retries 0)
grep -q '^action=dispatch$' "$D/gho" && grep -q '^reason=' "$D/gho" && st_ok "decide writes \$GITHUB_OUTPUT" || st_miss "decide's GITHUB_OUTPUT: $(cat "$D/gho" 2>/dev/null) / $out"

# --- retries / resend ---
rs=$(python3 "$PY" resend --sha "$SHA" --n 1 --max 2 --why 不稳)
want "resend input" "$rs" "${SHA:0:7} · 1/2 · 不稳"
printf '{"workflow_runs":[{"display_title":"release train (补发 %s)"},{"display_title":"release train (补发 %s · 2/2 · 不稳)"},{"display_title":"release train"},{"display_title":"release train (补发 %s · 1/2 · 新头)"}]}\n' \
  "$rs" "${SHA:0:7}" "${NEW:0:7}" > "$D/runs.json"
want "retries counts this sha's re-sends only" "$(python3 "$PY" retries --runs "$D/runs.json" --sha "$SHA")" 2

# --- notice ---
note() { python3 "$PY" notice --verdict "$D/v.json" --run-url U "$@"; }
verdict "$SHA" flaky
case "$(note --action dispatch --retries 0)" in "红：wobbly-selftest.sh · 不稳，已补发（第 1/2 次） · U") st_ok "flaky notice" ;; *) st_miss "flaky notice: $(note --action dispatch --retries 0)" ;; esac
verdict "$SHA" red
case "$(note --action wait)" in "红：wobbly-selftest.sh · 真红，等修复 · U") st_ok "red notice" ;; *) st_miss "red notice: $(note --action wait)" ;; esac
verdict "$SHA" held
case "$(note --action wait --holds 77)" in "${SHA:0:7} 测完未发布：#77 挡着 · U") st_ok "held notice" ;; *) st_miss "held notice: $(note --action wait --holds 77)" ;; esac
verdict "$SHA" shipped
printf '[{"sha":"%s","subject":"a (#12) (#4913)","committed":"2026-10-19T10:00:00Z"},{"sha":"%s","subject":"b (#13)","committed":"2026-10-19T10:05:00Z"}]\n' "$SHA" "$NEW" > "$D/m.json"
case "$(note --action wait --merges "$D/m.json" --now 2026-10-19T10:17:00Z)" in
  "已上线 ${SHA:0:7} · 含 PR #12 #4913 #13 · 合并→生效 17 分钟 · U") st_ok "shipped notice" ;;
  *) st_miss "shipped notice: $(note --action wait --merges "$D/m.json" --now 2026-10-19T10:17:00Z)" ;; esac

# --run-id: the whole body, with what the hub words its push with (T893)
verdict "$SHA" held
body=$(note --action wait --holds 77 --run-id 42)
python3 -c 'import json,sys; b=json.loads(sys.argv[1]); assert b["run_id"]=="42" and b["verdict"]=="held" and b["holds"]=="#77" and b["url"]=="U" and b["text"].endswith("挡着 · U"), b' "$body" \
  && st_ok "notice --run-id prints the body with holds/url" || st_miss "notice --run-id: $body"
grep -q -- '--run-id "$GITHUB_RUN_ID"' "$ROOT/.github/workflows/release-train.yml" \
  && st_ok "the train posts the structured body" || st_miss "release-train.yml does not pass --run-id"

# --- wiring ---
wf="$ROOT/.github/workflows/release-train.yml"; bk="$ROOT/.github/workflows/release-train-next.yml"
grep -q 'fleet-train-next.py judge' "$wf" && grep -q 'gh workflow run release-train.yml' "$wf" && grep -q 'name: train-next' "$wf" \
  && st_ok "the train's next job judges, re-sends and leaves its verdict" || st_miss "release-train.yml's next job is not wired"
grep -q 'labels=release-hold' "$wf" && grep -q "steps.hold.outputs.held == '' && steps.pub.outputs.superseded" "$wf" \
  && st_ok "release-hold holds the move" || st_miss "release-train.yml's move is not held by release-hold"
grep -q "inputs.resend != ''" "$wf" && st_ok "a re-send names itself 补发" || st_miss "run-name does not carry the re-send"
grep -q -- "--ignore-check next" "$wf" && st_ok "the move ignores the next job" || st_miss "the move would wait on next"
# (no hourly cron re-runs a real red, #4913: conf/gone.list)
grep -q "cron: '3-59/10" "$bk" && grep -q 'fleet-train-next.py decide' "$bk" && grep -q 'workflows: \[release train\]' "$bk" \
  && st_ok "the 10-minute backstop decides by the same rule" || st_miss "release-train-next.yml is not wired"
grep -q '"release-train-next.yml"' "$ROOT/tokenledger/hub/api/fleet_release_notice.go" && st_ok "the hub takes the backstop's notice" || st_miss "the hub refuses the backstop"
grep -q '"--to"' "$BIN/fleet-train-ledger.py" && st_ok "the ledger posts a notice" || st_miss "fleet-train-ledger.py has no --to notice"

st_done
