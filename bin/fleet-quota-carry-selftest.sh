#!/bin/bash
# fleet-quota-carry-selftest.sh — a refused or silent hub does not blind the
# account pick (issue #2465, EPIC #2463 C8).
#
# On 2026-10-08 the hub answered 401 for six hours. Every quota fetch came back
# empty, fleet-account.sh overwrote the cache with nothing, 341 reads in a row
# had no rows, pick_score had "no opinion" about every account and the pool never
# rotated — six sessions burned one subscription to its weekly wall. The fix: an
# empty fetch KEEPS the last good reading while it is younger than
# FLEET_QUOTA_STALE_OK (1800 s) and says why the reads are empty
# (refused · unreachable · empty); only past that is it cleared and the #684
# blind alarm fires. A 401 that lasts FLEET_QUOTA_REFUSED_ALARM (300 s) is an
# alarm of its own — a credential to fix, never a green board.
#
# Pinned end to end, the same four surfaces fleet-quota-blind-selftest.sh pins:
# the cache (fleet-account.sh), the predicate (usage-lib.sh fleet_quota_carry),
# the word `fleet-quotawatch.sh --status` answers with, and the doctor's qwatch
# line — plus the alerts row and the pick (`_claude-inventory`'s score column).
#
#   A  rows, then 401 for 10 minutes → the rows stay, the pick still scores,
#      --status `carry 600 … refused`, doctor 「沿用 10 分钟前」, alarm ✖ refused,
#      quota-verdict unknown (a banner still benches)
#   B  401 for 35 minutes → the rows are cleared, --status blind (refused),
#      doctor FAIL 拒 + FRESH BUT EMPTY, alarm ✖ unreadable
#   C  a 1-minute silence (no answer) → carried, doctor WARN 失联, no alarm row
#   D  a cache from before #2465 (no read_at) → its stamp is the reading's age
#   E  rows again → the why is gone, fresh, green
#   F  the node token (issue #2630): ccquota runs with node.env's CCQUOTA_TOKEN
#      in ITS environment (the summary door's credential), never the caller's;
#      a refusal is on record in global/hub_auth_fail (`quota`) and the doctor's
#      qwatch line names the fix; rows clear the record
#
# Hermetic: a FAKE ccquota on PATH (switchable payload), scratch pool, conf,
# TMPDIR and HOME. No network, no tmux server. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
NEED="fleet-doctor.sh fleet-account.sh fleet_iso.py fleet-lib.sh usage-lib.sh fleet-quotawatch.sh fleet-alerts.sh fleet-daemon-lib.sh"
for f in $NEED; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/quota-carry-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/accounts" "$WORK/conf/fleets/sessA" "$WORK/.claude-dash/global"
for f in $NEED fleet-config-lib.sh; do [ -f "$BIN/$f" ] && cp "$BIN/$f" "$WORK/bin/"; done
chmod +x "$WORK/bin/"*.sh
printf 'tok-a\n' > "$WORK/accounts/a"; printf 'tok-b\n' > "$WORK/accounts/b"
chmod 600 "$WORK/accounts/a" "$WORK/accounts/b"
printf 'FLEET_REPO="acme/widgets"\n' > "$WORK/conf/fleets/sessA/conf"
G="$WORK/.claude-dash/global"
MODE="$WORK/mode"

# rows    — a clean two-account payload
# refused — what ccquota prints when the hub answers 401 (cmd/ccquota/budget.go:
#           "hub unreachable: HTTP 401: …", verdict unknown, no accounts)
# down    — no answer at all (ccquota killed / crashed)
cat > "$WORK/fakepath/ccquota" <<'FAKE'
#!/bin/bash
[ "${1:-}" = version ] && { printf 'ccquota 9.9.9-testbuild\n'; exit 0; }
printf '%s\n' "${CCQUOTA_TOKEN:-none}" > "${FAKE_MODE_FILE%/*}/ccquota.token"
case "$(cat "$FAKE_MODE_FILE" 2>/dev/null)" in
  refused) printf '{"verdict":"unknown","reason":"hub unreachable: HTTP 401: {\\"error\\":\\"unauthorized\\"}","accounts":null}\n' ;;
  down)    exit 1 ;;
  *) printf '{"verdict":"go","accounts":[{"account_uuid":"u-a","label":"a","headroom_pct":70,"five_hour":{"utilization":30,"resets_at":"2030-09-16T05:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2030-09-16T05:00:00Z"}},{"account_uuid":"u-b","label":"b","headroom_pct":80,"five_hour":{"utilization":20,"resets_at":"2030-09-16T05:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2030-09-16T05:00:00Z"}}]}\n' ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/ccquota"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf -- '--- got ---\n%s\n' "$2" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS+1)); }
run() {
  env PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
    FLEET_CONF_DIR="$WORK/conf" FLEET_ACCOUNTS_DIR="$WORK/accounts" FLEET_C="$WORK/.claude-dash" \
    CCQUOTA_HUB_URL="http://hub.test:8787" FAKE_MODE_FILE="$MODE" "$@"
}
fetch()  { run bash "$WORK/bin/fleet-account.sh" quota --refresh >/dev/null 2>&1; }
cached() { run bash "$WORK/bin/fleet-account.sh" quota --cached 2>/dev/null; }
status() { run bash "$WORK/bin/fleet-quotawatch.sh" --status 2>/dev/null; }
score()  { run bash "$WORK/bin/fleet-account.sh" _claude-inventory 2>/dev/null | awk -F'\t' -v l="$1" '$1==l{print $4}'; }
verdict(){ run bash "$WORK/bin/fleet-account.sh" quota-verdict "$1" 2>/dev/null; }
qwatch() { run bash "$WORK/bin/fleet-doctor.sh" 2>/dev/null \
             | grep -E '^[[:space:]]+(PASS|WARN|FAIL)[[:space:]]+qwatch([[:space:]]|$)' | head -1; }
alerts() { run bash "$WORK/bin/fleet-alerts.sh" write >/dev/null 2>&1; run bash "$WORK/bin/fleet-alerts.sh" list --plain 2>/dev/null; }
col()    { printf '%s' "$1" | cut -f"$2"; }
# back <secs> — the reading (and the reason's since) were that long ago.
back() {
  local t=$(( $(date +%s) - $1 ))
  printf '%s\n' "$t" > "$G/account.quota.read_at"
  [ -f "$G/account.quota.why" ] && awk -F'\t' -v t="$t" 'BEGIN{OFS="\t"} NR==1{$2=t} {print}' "$G/account.quota.why" > "$G/w.tmp" && mv "$G/w.tmp" "$G/account.quota.why"
}

# --- A: rows, then 401 for ten minutes ---------------------------------------
printf 'rows' > "$MODE"; fetch
[ "$(cached | grep -c .)" = 2 ] || fail "A: the fixture must cache two rows" "$(cached)"
[ -f "$G/account.quota.read_at" ] || fail "A: a fetch with rows must write read_at"
[ ! -f "$G/account.quota.why" ] || fail "A: a fetch with rows leaves no why" "$(cat "$G/account.quota.why")"
s0=$(score a); [ -n "$s0" ] || fail "A: precondition — the pick scores account a" "$(run bash "$WORK/bin/fleet-account.sh" _claude-inventory 2>&1)"
ok
printf 'refused' > "$MODE"; fetch; fetch; fetch
[ "$(cached | grep -c .)" = 2 ] || fail "A: a 401 must NOT wipe the last reading" "$(cached)"
[ "$(col "$(cat "$G/account.quota.why")" 1)" = refused ] || fail "A: a 401 is told apart as refused" "$(cat "$G/account.quota.why")"
case "$(cat "$G/account.quota.why")" in *"HTTP 401"*) ;; *) fail "A: the why carries the hub's words" "$(cat "$G/account.quota.why")" ;; esac
back 600
[ "$(cached | grep -c .)" = 2 ] || fail "A: a 10-minute-old reading still answers quota" "$(cached)"
fetch                                                  # one more 401 at the 10-minute mark
[ "$(cached | grep -c .)" = 2 ] || fail "A: …and survives a fetch at 10 minutes" "$(cached)"
[ "$(score a)" = "$s0" ] || fail "A: the pick must still score on the carried reading" "$(score a) (was $s0)"
ok
s=$(status)
[ "$(col "$s" 1)" = carry ] || fail "A: --status must answer carry, not blind or fresh" "$s"
case "$(col "$s" 2)" in 59[0-9]|60[0-9]|61[0-9]) ;; *) fail "A: --status column 2 is the reading's age" "$s" ;; esac
[ "$(col "$s" 4)" = refused ] || fail "A: --status column 4 is the why" "$s"
case "$(col "$s" 5)" in 59[0-9]|6[0-9][0-9]) ;; *) fail "A: --status column 5 is how long the 401 has held" "$s" ;; esac
[ "$(verdict a)" = unknown ] || fail "A: a carried reading never overrules a banner — quota-verdict says unknown" "$(verdict a)"
ok
l=$(qwatch)
case "$l" in *FAIL*qwatch*"拒（401"*"沿用 10 分钟前的读数"*) ;; *) fail "A: doctor — 401 past 5 minutes FAILs and says 沿用 10 分钟前的读数" "$l" ;; esac
case "$l" in *"FRESH BUT EMPTY"*) fail "A: a carried reading is not FRESH BUT EMPTY" "$l" ;; esac
a=$(alerts)
case "$a" in *"✖  quota · refused"*) ;; *) fail "A: a 401 held 10 minutes raises ✖ quota · refused" "$a" ;; esac
case "$a" in *"✖  quota · unreadable"*) fail "A: no unreadable alarm while the reading is carried" "$a" ;; esac
ok

# --- B: 401 for 35 minutes → cleared, blind, alarmed --------------------------
back 2100
fetch
[ -z "$(cached)" ] || fail "B: past FLEET_QUOTA_STALE_OK the reading is cleared" "$(cached)"
[ -z "$(score a)" ] || fail "B: …and the pick has no opinion again" "$(score a)"
s=$(status)
[ "$(col "$s" 1)" = blind ] || fail "B: --status must answer blind past the carry" "$s"
[ "$(col "$s" 4)" = refused ] || fail "B: blind keeps the why" "$s"
l=$(qwatch)
case "$l" in *FAIL*qwatch*"拒（401"*"FRESH BUT EMPTY"*) ;; *) fail "B: doctor FAILs blind with the 401 named" "$l" ;; esac
a=$(alerts)
case "$a" in *"✖  quota · unreadable"*) ;; *) fail "B: ✖ quota · unreadable after the carry ends" "$a" ;; esac
ok

# --- C: a one-minute silence is carried quietly -------------------------------
printf 'rows' > "$MODE"; fetch
printf 'down' > "$MODE"; fetch; fetch; fetch
back 60
[ "$(cached | grep -c .)" = 2 ] || fail "C: no answer keeps the reading too" "$(cached)"
s=$(status); [ "$(col "$s" 1)" = carry ] && [ "$(col "$s" 4)" = unreachable ] || fail "C: --status carry/unreachable" "$s"
l=$(qwatch)
case "$l" in *WARN*qwatch*"失联"*"沿用 1 分钟前的读数"*) ;; *) fail "C: doctor WARNs 失联 + 沿用 1 分钟前" "$l" ;; esac
a=$(alerts)
case "$a" in *"✖  quota · "*) fail "C: a short silence raises no quota alarm" "$a" ;; esac
ok

# --- D: a cache from before #2465 (no read_at) -------------------------------
printf 'rows' > "$MODE"; fetch
rm -f "$G/account.quota.read_at"
[ "$(cached | grep -c .)" = 2 ] || fail "D: an old cache with a fresh stamp still answers" "$(cached)"
printf 'refused' > "$MODE"; fetch
[ "$(cached | grep -c .)" = 2 ] || fail "D: …and is carried, its stamp read as the reading's age" "$(cached)"
ok

# --- E: the hub answers again -------------------------------------------------
printf 'rows' > "$MODE"; fetch
[ ! -f "$G/account.quota.why" ] || fail "E: rows clear the why" "$(cat "$G/account.quota.why")"
[ "$(col "$(status)" 1)" = fresh ] || fail "E: --status fresh again" "$(status)"
case "$(qwatch)" in *PASS*qwatch*) ;; *) fail "E: doctor green again" "$(qwatch)" ;; esac
case "$(alerts)" in *"✖  quota · "*) fail "E: no quota alarm once the hub answers" "$(alerts)" ;; esac
ok

# --- F: the node token, and a refusal on record ------------------------------
printf 'CCQUOTA_HUB_URL=http://hub.test:8787\nCCQUOTA_TOKEN=node-tok-2630\n' > "$WORK/conf/node.env"; chmod 600 "$WORK/conf/node.env"
printf 'refused' > "$MODE"; fetch
[ "$(cat "$WORK/ccquota.token")" = node-tok-2630 ] || fail "F: ccquota must run with node.env's CCQUOTA_TOKEN" "$(cat "$WORK/ccquota.token")"
case "$(cat "$G/hub_auth_fail" 2>/dev/null)" in quota$'\t'[0-9]*$'\t'[0-9]*$'\t'*"HTTP 401"*) ;; *) fail "F: a refused quota read must be recorded in global/hub_auth_fail" "$(cat "$G/hub_auth_fail" 2>/dev/null)" ;; esac
fetch; fetch; back 2100; fetch
l=$(qwatch)
case "$l" in *FAIL*qwatch*"node token is here"*) ;; *) fail "F: doctor qwatch must name the fix for a refused node token" "$l" ;; esac
printf 'rows' > "$MODE"; fetch
[ ! -s "$G/hub_auth_fail" ] || fail "F: rows must clear quota from hub_auth_fail" "$(cat "$G/hub_auth_fail")"
ok

printf 'selftest PASS: %s checks (carry under 401 · pick · verdict · doctor · alarm · expiry · silence · old cache · recovery)\n' "$CHECKS"
exit 0
