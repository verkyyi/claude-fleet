#!/bin/bash
# poll-backoff-selftest.sh — the 15s GitHub pollers slow down while nothing
# changes (issue #892).
#
#   • LIB       fleet_poll_backoff_{read,due,note,reset}: unchanged polls grow the
#               interval 15 → 30 → 60 and stop at the knob; a change resets to 15;
#               reset removes the state; the due gate sits 3s under the interval.
#   • OFF       FLEET_POLL_MAX_BACKOFF unset / 15 / below the base / garbled ⇒ off:
#               always due, and NO state file is ever written (a stale one is
#               removed) — the degenerate path is the pre-#892 poller.
#   • PR-REFRESH the real bin/tmux-pr-refresh.sh on a fake clock + fake gh/tmux:
#               default → a `gh pr list` every tick; knob 60 → calls at 15/30/60/60
#               spacing on an unchanged prmap; a changed prmap resets to 15; the
#               webhook's `--repo` kick resets too.
#   • BRIDGE    the real bin/fleet-issue-bridge.sh --poll: same growth on empty
#               comment listings, a listed comment resets, default polls every
#               tick; a signed --deliver (needs python3) resets the backoff.
#
# Hermetic: TMPDIR / FLEET_CONF_DIR under a temp dir, fake gh / tmux / date on
# PATH. No network, no tmux server. Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIB="$BIN/fleet-lib.sh"
REFRESH="$BIN/tmux-pr-refresh.sh"
BRIDGE="$BIN/fleet-issue-bridge.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/poll-backoff-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK"
export FLEET_SKIP_GLOBAL_CONF=1
export FLEET_CONF_DIR="$WORK/conf"
export FLEET_ISSUE_BRIDGE_STATE_DIR="$WORK/bridge-state"
export FLEET_DISPATCH_LEASE_DIR="$WORK/leases"
unset FLEET_REPO FLEET_SESSION FLEET_POLL_MAX_BACKOFF FLEET_DEPLOY_REF FLEET_DEPLOY_CHECK 2>/dev/null || true
mkdir -p "$WORK/bin" "$WORK/conf/fleets/s1" "$WORK/leases"

CHECKS=0
fail() { printf 'poll-backoff-selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }
eq()   { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 (want '$2', got '$3')" "${4:-}"; }

# ============================================================ LIB
# shellcheck source=/dev/null
. "$LIB"
F="$WORK/bo"
st() { cat "$F" 2>/dev/null || printf 'none'; }

export FLEET_POLL_MAX_BACKOFF=60
fleet_poll_backoff_due "$F" 15 1000; eq "lib: no state → due" 0 "$?"
fleet_poll_backoff_note "$F" 15 1 1000;  eq "lib: changed → base"          "15 1000" "$(st)"
fleet_poll_backoff_note "$F" 15 0 1015;  eq "lib: unchanged → 30"          "30 1015" "$(st)"
fleet_poll_backoff_note "$F" 15 0 1045;  eq "lib: unchanged → 60"          "60 1045" "$(st)"
fleet_poll_backoff_note "$F" 15 0 1105;  eq "lib: unchanged → capped at 60" "60 1105" "$(st)"
fleet_poll_backoff_due "$F" 15 1161; eq "lib: 56s into a 60s wait → not due" 1 "$?"
fleet_poll_backoff_due "$F" 15 1162; eq "lib: 57s into a 60s wait → due (3s jitter floor)" 0 "$?"
fleet_poll_backoff_note "$F" 15 1 1162;  eq "lib: a change → straight back to 15" "15 1162" "$(st)"
fleet_poll_backoff_reset "$F";           eq "lib: reset removes the state" none "$(st)"
printf 'garbage here\n' > "$F"
fleet_poll_backoff_due "$F" 15 1000; eq "lib: garbled state → due (fail open)" 0 "$?"
printf '9999 1000\n' > "$F"; fleet_poll_backoff_read "$F" 15
eq "lib: an interval above the knob clamps to it" 60 "$FLEET_PB_INT"
FLEET_POLL_MAX_BACKOFF=120; fleet_poll_backoff_note "$F" 15 0 2000
eq "lib: a raised knob lets it grow past 60" "120 2000" "$(st)"

for v in '' 15 10 abc; do
  if [ -z "$v" ]; then unset FLEET_POLL_MAX_BACKOFF; else export FLEET_POLL_MAX_BACKOFF="$v"; fi
  rm -f "$F"
  fleet_poll_backoff_read "$F" 15; eq "off[$v]: read reports off" 1 "$?"
  fleet_poll_backoff_note "$F" 15 0 1000; eq "off[$v]: note writes no state" none "$(st)"
  printf '60 1000\n' > "$F"
  fleet_poll_backoff_due "$F" 15 1001; eq "off[$v]: always due, even over a stale file" 0 "$?"
  fleet_poll_backoff_note "$F" 15 0 1001; eq "off[$v]: a stale file is removed" none "$(st)"
done
unset FLEET_POLL_MAX_BACKOFF

# ============================================================ fakes
# date: `+%s` answers the fake clock (FAKE_NOW); anything else is the real date.
REAL_DATE=$(command -v date)
cat > "$WORK/bin/date" <<SHIM
#!/bin/bash
[ "\${1:-}" = +%s ] && [ -n "\${FAKE_NOW:-}" ] && { printf '%s\n' "\$FAKE_NOW"; exit 0; }
exec "$REAL_DATE" "\$@"
SHIM
# gh: log each call; `pr list` → prmap.tsv, `api` → comments.tsv (the --jq is gh's
# own; the shim answers as gh would after it).
cat > "$WORK/bin/gh" <<SHIM
#!/bin/bash
case "\${1:-} \${2:-}" in
  "pr list") printf 'pr\n' >> "$WORK/gh.log"; cat "$WORK/prmap.tsv"; exit 0 ;;
  "api "*)   printf 'api\n' >> "$WORK/gh.log"; cat "$WORK/comments.tsv" 2>/dev/null; exit 0 ;;
esac
exit 0
SHIM
# tmux: fleet s1 is live (has-session / info succeed); no windows listed.
cat > "$WORK/bin/tmux" <<'SHIM'
#!/bin/sh
for a in "$@"; do [ "$a" = has-session ] && exit 0; done
exit 0
SHIM
chmod +x "$WORK/bin/date" "$WORK/bin/gh" "$WORK/bin/tmux"
PATH="$WORK/bin:$PATH"; export PATH

printf 'FLEET_REPO="fake/repo"\nFLEET_ISSUE_BRIDGE=1\n' > "$WORK/conf/fleets/s1/conf"
mkdir -p "$WORK/.claude-dash/global"
printf 's1\tfake-repo\tfake/repo\n' > "$WORK/.claude-dash/global/sessmap"

calls() { local n; n=$(grep -c "^$1\$" "$WORK/gh.log" 2>/dev/null); printf '%s' "${n:-0}"; }
# tick <script-and-args…> over FAKE_NOW = T0, T0+15, … for N ticks; prints the
# tick offsets (seconds from T0) at which gh was actually called.
ticks() {  # $1=kind(pr|api) $2=T0 $3=N $4…=command
  local kind="$1" t0="$2" n="$3" k=0 before out=''
  shift 3
  while [ "$k" -lt "$n" ]; do
    before=$(calls "$kind")
    FAKE_NOW=$(( t0 + k * 15 )) "$@" >>"$WORK/run.out" 2>&1
    [ "$(calls "$kind")" -gt "$before" ] && out="$out$(( k * 15 )) "
    k=$((k + 1))
  done
  printf '%s' "${out% }"
}

# ============================================================ PR-REFRESH
PRF="$WORK/.claude-dash/fleets/fake-repo"
printf 'issue-1\t#1\tOPEN\t…\t\t\n' > "$WORK/prmap.tsv"
: > "$WORK/gh.log"
got=$(ticks pr 10000 8 bash "$REFRESH")
eq "pr-refresh default: gh every tick" "0 15 30 45 60 75 90 105" "$got" "$(cat "$WORK/run.out")"
eq "pr-refresh default: no backoff state" no "$([ -e "$PRF/prmap.backoff" ] && echo yes || echo no)"

export FLEET_POLL_MAX_BACKOFF=60
rm -f "$PRF/prmap" "$PRF/prmap.ts"
got=$(ticks pr 20000 10 bash "$REFRESH")
# cold (changed) → 15 → 30 → 60 → 60
eq "pr-refresh knob 60: 15/30/60/60 spacing on no change" "0 15 45 105" "$got" "$(cat "$WORK/run.out")"
eq "pr-refresh knob 60: state at the ceiling" 60 "$(cut -d' ' -f1 "$PRF/prmap.backoff")"

printf 'issue-1\t#1\tOPEN\t✓\tready\t\n' > "$WORK/prmap.tsv"          # CI went green
got=$(ticks pr 20165 3 bash "$REFRESH")
eq "pr-refresh: a changed prmap resets to 15" "0 15" "$got" "$(cat "$WORK/run.out")"
eq "pr-refresh: … and the state reads the base after one quiet poll" 30 "$(cut -d' ' -f1 "$PRF/prmap.backoff")"

before=$(calls pr)
FAKE_NOW=20200 bash "$REFRESH" --repo fake/repo >>"$WORK/run.out" 2>&1
eq "pr-refresh: webhook --repo kick fetches" $((before + 1)) "$(calls pr)"
eq "pr-refresh: … and resets to 15" 15 "$(cut -d' ' -f1 "$PRF/prmap.backoff")"
unset FLEET_POLL_MAX_BACKOFF

# ============================================================ BRIDGE
BOF="$WORK/conf/fleets/s1/bridge/backoff"
: > "$WORK/comments.tsv"
FAKE_NOW=30000 bash "$BRIDGE" --poll >>"$WORK/run.out" 2>&1          # first run seeds the watermark
: > "$WORK/gh.log"
got=$(ticks api 30000 6 bash "$BRIDGE" --poll)
eq "bridge default: gh api every tick" "0 15 30 45 60 75" "$got" "$(cat "$WORK/run.out")"
eq "bridge default: no backoff state" no "$([ -e "$BOF" ] && echo yes || echo no)"

export FLEET_POLL_MAX_BACKOFF=60
got=$(ticks api 40000 10 bash "$BRIDGE" --poll)
eq "bridge knob 60: 15→30→60 on empty listings" "0 30 90" "$got" "$(cat "$WORK/run.out")"

b64=$(printf 'hello' | base64 | tr -d '\n')
printf '555\tNONE\tsomeone\t7\t2026-09-24T00:00:00Z\t%s\n' "$b64" > "$WORK/comments.tsv"
got=$(ticks api 40150 1 bash "$BRIDGE" --poll)
eq "bridge: a listed comment polls on schedule" "0" "$got" "$(cat "$WORK/run.out")"
eq "bridge: … and resets to 15" 15 "$(cut -d' ' -f1 "$BOF")"
: > "$WORK/comments.tsv"

if command -v python3 >/dev/null 2>&1; then
  printf '30 40150\n' > "$BOF"
  export FLEET_ISSUE_BRIDGE_SECRET=s3cret
  payload='{"action":"created","comment":{"id":556,"author_association":"NONE","user":{"login":"x"},"body":"hi"},"issue":{"number":7},"repository":{"full_name":"fake/repo"}}'
  sig="sha256=$(printf '%s' "$payload" | python3 -c 'import sys,hmac,hashlib;print(hmac.new(b"s3cret",sys.stdin.buffer.read(),hashlib.sha256).hexdigest())')"
  printf '%s' "$payload" | FAKE_NOW=40160 FLEET_DELIVERY_SIG="$sig" bash "$BRIDGE" --deliver >>"$WORK/run.out" 2>&1
  eq "bridge: a --deliver resets the backoff" no "$([ -e "$BOF" ] && echo yes || echo no)" "$(cat "$WORK/run.out")"
  unset FLEET_ISSUE_BRIDGE_SECRET
else
  printf 'poll-backoff-selftest: python3 absent — --deliver leg skipped\n'
fi
unset FLEET_POLL_MAX_BACKOFF

printf 'poll-backoff-selftest: PASS (%s checks)\n' "$CHECKS"
