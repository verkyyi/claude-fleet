#!/bin/bash
# fleet-quotawatch-selftest.sh — the ccquota pre-emptive rotation as its OWN tick
# (issue #551): policy, once-per-window markers, overlap lock, heartbeat, and the
# staleness alarm. Drives the REAL bin/fleet-quotawatch.sh + fleet-account.sh
# against a FAKE ccquota / tmux / notifier on PATH (no network, no tmux server).
#
#   1. off      — no hub URL ⇒ exit 0, ccquota never called, no heartbeat.
#   2. status   — `never` before a tick; `fresh` after one.
#   3. policy   — 50%: nothing; 72%: warn marker = reset epoch + notify + toast, no
#                 bench; 72% again: no second notify (same window); 90%: ceiling
#                 marker + bench (account.limited row) + `migrate --account a` per
#                 fleet socket + notify; 90% again: no second migrate.
#   4. dry-run  — a NEW reset window at 90% with --dry-run prints `would: bench`
#                 and touches no marker / no migrate.
#   5. lock     — a live holder (command line matches) younger than the deadline
#                 ⇒ skip (no fetch); past the deadline ⇒ TERMed + superseded; a
#                 dead holder ⇒ taken over. Lock released at exit.
#   6. stale    — a stamp older than FLEET_ACCOUNT_QUOTA_STALE ⇒ `--status` says
#                 stale, the status-bar helper prints the age, and the next tick
#                 notifies once that the watch was blind.
#   7. human    — fleet_usage_human_secs coarsest-unit rendering.
# Needs python3 (quota_parse). Exit 0 = pass, non-zero = fail.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
for f in fleet-quotawatch.sh fleet-account.sh fleet-lib.sh usage-lib.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/quotawatch-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"     # physical path: the scripts resolve $BIN via pwd, and macOS $TMPDIR is a symlink
HOLDER=''
trap '[ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/accounts" "$WORK/conf/fleets/sessA" "$WORK/.claude-dash/global"
for f in fleet-quotawatch.sh fleet-account.sh fleet-lib.sh usage-lib.sh; do cp "$BIN/$f" "$WORK/bin/"; done
chmod +x "$WORK/bin/"*.sh
printf 'tok-a\n' > "$WORK/accounts/a"; printf 'tok-b\n' > "$WORK/accounts/b"
printf 'FLEET_REPO="acme/widgets"\n' > "$WORK/conf/fleets/sessA/conf"
G="$WORK/.claude-dash/global"

# --- fake ccquota: `budget --account all --json …` → two pool accounts; a's 5h %
# comes from $FAKE_PCT_FILE, its 5h reset from $FAKE_RESET_FILE (ISO). Logs calls.
cat > "$WORK/fakepath/ccquota" <<'FAKE'
#!/bin/bash
echo "$*" >> "$FAKE_LOG"
p=$(cat "$FAKE_PCT_FILE" 2>/dev/null || echo 10); r5=$(cat "$FAKE_RESET_FILE")
printf '{"verdict":"ok","accounts":[{"account_uuid":"u-a","label":"a","headroom_pct":%d,"five_hour":{"utilization":%d,"resets_at":"%s","percent_per_hour":30},"seven_day":{"utilization":10,"resets_at":"2026-09-16T05:00:00Z"}},{"account_uuid":"u-b","label":"b","headroom_pct":80,"five_hour":{"utilization":20,"resets_at":"%s"},"seven_day":{"utilization":10,"resets_at":"2026-09-16T05:00:00Z"}}]}' "$((100-p))" "$p" "$r5" "$r5"
FAKE
# --- fake tmux: strips -L; one live fleet `sessA`; two windows (@1 on a, @2 on b);
# display-message -p answers a pane pid (ours — no claude under it, so the peer
# send is skipped, which is fine: fleet-peer-send-selftest covers that channel).
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
label=""
if [ "${1:-}" = "-L" ] || [ "${1:-}" = "-S" ]; then label="$2"; shift 2; fi
printf '%s %s\n' "$label" "$*" >> "$FAKE_TMUX_LOG"
case "${1:-}" in
  has-session)     exit 0 ;;
  list-sessions)   [ -n "$label" ] && printf '%s\n' "$label"; exit 0 ;;
  list-windows)    printf '@1 a\n@2 b\n'; exit 0 ;;
  display-message) [ "${2:-}" = "-p" ] && printf '%s\n' "$PPID"; exit 0 ;;
  *) exit 0 ;;
esac
FAKE
cat > "$WORK/fakepath/notify" <<'FAKE'
#!/bin/bash
printf '%s\n---\n' "$1" >> "$FAKE_NOTIFY_LOG"
FAKE
printf '#!/bin/bash\nsleep 300\n' > "$WORK/fakepath/fleet-quotawatch-holder"
chmod +x "$WORK/fakepath/"*

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
NOW=$(date +%s)
RESET1=$(( NOW + 10800 )); RESET2=$(( NOW + 10800 + 14400 ))   # two windows, 4h apart (> the 15-min tolerance)
iso "$RESET1" > "$WORK/reset"
HUB="http://hub.test:8787"
run_watch() {
  PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
  FLEET_CONF_DIR="$WORK/conf" FLEET_ACCOUNTS_DIR="$WORK/accounts" CCQUOTA_HUB_URL="$HUB" \
  FLEET_ACCOUNT_QUOTA_TTL=0 FLEET_NOTIFY_CMD="$WORK/fakepath/notify" \
  FAKE_LOG="$WORK/ccquota.calls" FAKE_TMUX_LOG="$WORK/tmux.calls" FAKE_NOTIFY_LOG="$WORK/notify.log" \
  FAKE_PCT_FILE="$WORK/pct" FAKE_RESET_FILE="$WORK/reset" \
    bash "$WORK/bin/fleet-quotawatch.sh" "$@" >"$WORK/stdout" 2>"$WORK/stderr"
}
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2
         printf -- '--- stderr ---\n' >&2; cat "$WORK/stderr" >&2 2>/dev/null
         printf -- '--- tmux.calls ---\n' >&2; tail -8 "$WORK/tmux.calls" >&2 2>/dev/null; exit 1; }
ok()   { CHECKS=$((CHECKS+1)); }
ccq_calls() { grep -c . "$WORK/ccquota.calls" 2>/dev/null || echo 0; }
notifies()  { grep -c '^---$' "$WORK/notify.log" 2>/dev/null || echo 0; }
migrates()  { grep -c "migrate --account 'a'" "$WORK/tmux.calls" 2>/dev/null || echo 0; }
hbget()     { sed -n "s/^$2=//p" "$1" | head -1; }

# 1. off ---------------------------------------------------------------------
echo 50 > "$WORK/pct"
HUB="" run_watch || fail "1: unconfigured tick must exit 0"
[ "$(ccq_calls)" = 0 ]          || fail "1: no hub URL ⇒ ccquota must not be called"
[ ! -f "$G/quotawatch.heartbeat" ] || fail "1: no hub URL ⇒ no heartbeat"
HUB="" run_watch --status; [ "$(cat "$WORK/stdout")" = "$(printf 'off\t0')" ] || fail "1: --status must say off (got: $(cat "$WORK/stdout"))"
ok

# 2. status never → fresh ----------------------------------------------------
run_watch --status; [ "$(cat "$WORK/stdout")" = "$(printf 'never\t0')" ] || fail "2: --status before any tick must say never (got: $(cat "$WORK/stdout"))"
run_watch || fail "2: 50% tick must exit 0"
[ "$(ccq_calls)" = 1 ] || fail "2: one tick ⇒ one ccquota call (got $(ccq_calls))"
[ "$(hbget "$G/quotawatch.heartbeat" phase)" = "done" ]   || fail "2: heartbeat phase=done after a tick"
[ "$(hbget "$G/quotawatch.heartbeat" rows)" = 2 ]       || fail "2: heartbeat rows=2 (got $(hbget "$G/quotawatch.heartbeat" rows))"
[ "$(hbget "$G/quotawatch.heartbeat" fetched)" = 1 ]    || fail "2: heartbeat fetched=1"
[ "$(hbget "$G/quotawatch.heartbeat" caller)" = daemon ] || fail "2: default caller=daemon"
[ -n "$(hbget "$G/quotawatch.heartbeat" end)" ]         || fail "2: heartbeat end= written"
run_watch --status; case "$(cat "$WORK/stdout")" in fresh*) : ;; *) fail "2: --status after a tick must say fresh (got: $(cat "$WORK/stdout"))";; esac
[ ! -e "$G/quota.warn.a" ] && [ ! -e "$G/quota.ceiling.a" ] || fail "2: 50% ⇒ no markers"
[ "$(notifies)" = 0 ] || fail "2: 50% ⇒ no notify"
[ ! -d "$G/quotawatch.lock" ] || fail "2: lock must be released after the tick"
ok

# 3. policy -------------------------------------------------------------------
echo 72 > "$WORK/pct"; run_watch || fail "3: 72% tick must exit 0"
[ "$(cat "$G/quota.warn.a" 2>/dev/null)" = "$RESET1" ] || fail "3: 72% ⇒ quota.warn.a = reset epoch $RESET1 (got: $(cat "$G/quota.warn.a" 2>/dev/null))"
[ ! -e "$G/quota.ceiling.a" ] || fail "3: 72% ⇒ no ceiling marker"
grep -q 'approaching its limit' "$WORK/notify.log" || fail "3: 72% ⇒ 'approaching' notify"
grep -q '\*\*a\*\* is at 72% of its 5-hour window' "$WORK/notify.log" || fail "3: notify names the account + %"
grep -q '(~56 min to 100% at the current rate)' "$WORK/notify.log" || fail "3: notify carries the ETA from percent_per_hour"
grep -q 'sessA display-message fleet: a at 72%.*sessions warned' "$WORK/tmux.calls" || fail "3: 72% ⇒ toast on the fleet socket"
grep -q '^a	' "$G/account.limited" 2>/dev/null && fail "3: 72% must NOT bench"
[ "$(notifies)" = 1 ] || fail "3: exactly one notify at 72%"
run_watch || fail "3b: second 72% tick must exit 0"
[ "$(notifies)" = 1 ] || fail "3b: same reset window ⇒ no second warn notify (got $(notifies))"
echo 90 > "$WORK/pct"; run_watch || fail "3c: 90% tick must exit 0"
[ "$(cat "$G/quota.ceiling.a" 2>/dev/null)" = "$RESET1" ] || fail "3c: 90% ⇒ quota.ceiling.a = reset epoch"
[ "$(awk -F'\t' '$1=="a"{print $3}' "$G/account.limited" 2>/dev/null)" = "ccquota: 5-hour window at 90%" ] || fail "3c: 90% ⇒ benched with the ccquota note (account.limited: $(cat "$G/account.limited" 2>/dev/null))"
[ "$(migrates)" = 1 ] || fail "3c: 90% ⇒ one 'migrate --account a' run-shell (got $(migrates))"
grep -q "run-shell -b bash '$WORK/bin/fleet-account.sh' migrate --account 'a' --session 'sessA' --toast" "$WORK/tmux.calls" || fail "3c: migrate goes through run-shell -b on the fleet socket with --session sessA"
grep -q 'rotated early' "$WORK/notify.log" || fail "3c: 90% ⇒ 'rotated early' notify"
grep -q 'new sessions now use \*\*b\*\*' "$WORK/notify.log" || fail "3c: active pointer rotated to b (notify: $(grep 'new sessions' "$WORK/notify.log"))"
[ "$(notifies)" = 2 ] || fail "3c: two notifies so far (got $(notifies))"
run_watch || fail "3d: second 90% tick must exit 0"
[ "$(migrates)" = 1 ] || fail "3d: same window ⇒ no second migrate (got $(migrates))"
[ "$(notifies)" = 2 ] || fail "3d: same window ⇒ no third notify"
ok

# 4. dry-run in a NEW window ---------------------------------------------------
iso "$RESET2" > "$WORK/reset"
run_watch --dry-run || fail "4: --dry-run must exit 0"
grep -q "^would: bench a (90% of 5-hour" "$WORK/stdout" || fail "4: --dry-run prints the would-bench line (stdout: $(cat "$WORK/stdout"))"
grep -q "^ok: b at 20%" "$WORK/stdout" || fail "4: --dry-run prints the ok line for b"
[ "$(cat "$G/quota.ceiling.a")" = "$RESET1" ] || fail "4: --dry-run must not touch the ceiling marker"
[ "$(migrates)" = 1 ] || fail "4: --dry-run must not migrate"
[ "$(notifies)" = 2 ] || fail "4: --dry-run must not notify"
ok

# 5. lock ---------------------------------------------------------------------
bash "$WORK/fakepath/fleet-quotawatch-holder" >/dev/null 2>&1 </dev/null & HOLDER=$!; disown "$HOLDER"   # no inherited fds: a capturing caller must not wait on it
sleep 0.2
mkdir -p "$G/quotawatch.lock"; printf '%s' "$HOLDER" > "$G/quotawatch.lock/pid"; date +%s > "$G/quotawatch.lock/ts"
before=$(ccq_calls)
run_watch || fail "5: a skipped tick must still exit 0"
grep -q 'skip — tick' "$WORK/stderr" || fail "5: live holder younger than the deadline ⇒ skip on stderr"
[ "$(ccq_calls)" = "$before" ] || fail "5: skipped tick must not fetch"
[ "$(cat "$G/quotawatch.lock/pid")" = "$HOLDER" ] || fail "5: skip must leave the holder's lock alone"
kill -0 "$HOLDER" 2>/dev/null || fail "5: skip must not kill the holder"
printf '%s' $(( $(date +%s) - 1000 )) > "$G/quotawatch.lock/ts"      # past the 120s deadline
run_watch || fail "5b: superseding tick must exit 0"
grep -q 'superseding' "$WORK/stderr" || fail "5b: past the deadline ⇒ supersede on stderr"
sleep 0.3; kill -0 "$HOLDER" 2>/dev/null && fail "5b: the wedged holder must be TERMed"
HOLDER=''
[ "$(ccq_calls)" = $((before+1)) ] || fail "5b: superseding tick must fetch"
[ ! -d "$G/quotawatch.lock" ] || fail "5b: lock released after the superseding tick"
mkdir -p "$G/quotawatch.lock"; printf '999999' > "$G/quotawatch.lock/pid"; date +%s > "$G/quotawatch.lock/ts"
run_watch || fail "5c: dead-holder tick must exit 0"
[ "$(ccq_calls)" = $((before+2)) ] || fail "5c: a dead holder is taken over (tick fetches)"
[ ! -d "$G/quotawatch.lock" ] || fail "5c: lock released"
ok

# 6. stale --------------------------------------------------------------------
printf '%s' $(( $(date +%s) - 700 )) > "$G/account.quota.ts"
run_watch --status; case "$(cat "$WORK/stdout")" in stale*) : ;; *) fail "6: a 700s-old stamp ⇒ --status stale (got: $(cat "$WORK/stdout"))";; esac
age=$( CCQUOTA_HUB_URL="$HUB" FLEET_ACCOUNTS_DIR="$WORK/accounts" TMPDIR="$WORK" bash -c '. "$0"; fleet_quota_stale_age' "$WORK/bin/usage-lib.sh" )
[ "${age:-0}" -ge 700 ] || fail "6: fleet_quota_stale_age prints the age when stale (got '$age')"
age=$( CCQUOTA_HUB_URL="" FLEET_ACCOUNTS_DIR="$WORK/accounts" TMPDIR="$WORK" bash -c '. "$0"; fleet_quota_stale_age' "$WORK/bin/usage-lib.sh" )
[ -z "$age" ] || fail "6: unconfigured ⇒ fleet_quota_stale_age prints nothing"
n=$(notifies)
run_watch || fail "6b: tick after a stale spell must exit 0"
grep -q 'was 11m stale before this tick' "$WORK/stderr" || fail "6b: the blind spell is logged (stderr: $(cat "$WORK/stderr"))"
grep -q '# quota watch was blind for 11m' "$WORK/notify.log" || fail "6b: one notify about the blind spell"
[ "$(notifies)" = $((n+1)) ] || fail "6b: exactly one blind-spell notify"
run_watch || fail "6c: next tick must exit 0"
[ "$(notifies)" = $((n+1)) ] || fail "6c: fresh again ⇒ no repeat blind-spell notify"
run_watch --status; case "$(cat "$WORK/stdout")" in fresh*) : ;; *) fail "6c: --status fresh again";; esac
ok

# 7. human --------------------------------------------------------------------
h() { bash -c '. "$0"; fleet_usage_human_secs "$1"' "$WORK/bin/usage-lib.sh" "$1"; }
[ "$(h 47)" = 47s ] && [ "$(h 2820)" = 47m ] && [ "$(h 7200)" = 2h ] && [ "$(h 90000)" = 1d ] && [ "$(h x)" = 0s ] \
  || fail "7: fleet_usage_human_secs: $(h 47) $(h 2820) $(h 7200) $(h 90000) $(h x)"
ok

printf 'selftest PASS: fleet-quotawatch — %s groups (off, status, policy 50/72/90 + once-per-window, dry-run, lock skip/supersede/takeover, staleness alarm, human secs) (#551)\n' "$CHECKS"
exit 0
