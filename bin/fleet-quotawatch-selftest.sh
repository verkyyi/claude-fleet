#!/bin/bash
# fleet-quotawatch-selftest.sh — the ccquota pre-emptive rotation as its OWN tick
# (issue #551): policy, once-per-window markers, overlap lock, heartbeat, and the
# staleness alarm. Drives the REAL bin/fleet-quotawatch.sh + fleet-account.sh
# against a FAKE ccquota / tmux / notifier on PATH (no network, no tmux server).
#
#   1. off      — the two fail-open gates (#569): NEITHER an accounts pool nor a
#                 hub ⇒ exit 0, ccquota never called, no heartbeat; an accounts
#                 pool but NO hub ⇒ the per-model sweep still ticks (heartbeat,
#                 modelsweep=1) while ccquota stays uncalled and `--status` off.
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
#   9. budget   — (#582) a cap probe that outlives FLEET_QUOTAWATCH_PROBE_BUDGET is
#                 tree-killed and reported, the ccquota fetch still runs (the
#                 stamp is the liveness signal — it must never be starved by the
#                 sweep), the tick logs a per-phase breakdown, the phase budget
#                 defers the remaining fleets and arms the fairness cursor, and a
#                 tick never releases a lock some other tick now owns.
#   8. nowhere  — (#567) EVERY account ≥ ceiling in one tick: both benched, both
#                 ceiling markers, NO `migrate` fan-out (a move would cold-boot
#                 each session back onto the account just benched), the toast +
#                 notify say "nowhere to move"; --dry-run says the same.
#  10. noread   — (#628) ccquota says it CANNOT read b (available:false): b gets no
#                 row, so it is never benched and — the point — never the landing
#                 spot a ceiling fan-out moves a's sessions onto; the tick LOGS the
#                 reason, does not repeat it every 60 s, announces the recovery,
#                 and is equally loud about a payload shape it cannot parse.
#  11. selfbudget— (#698) the tick bounds ITSELF, not just its pieces. The two
#                 invariants are enforced in code, not left to four defaults
#                 agreeing (budget + wind-down ≤ deadline; the sweep cannot starve
#                 the fetch); the ccquota fetch is budgeted and TREE-killed; and at
#                 the budget the tick WINDS DOWN — it defers the rest, records what
#                 it dropped, releases the lock and exits 0, and the NEXT tick does
#                 the deferred work (deferral is not starvation).
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
# Unique per run: a wedged fetch of OURS must never be confused with a peer test's.
HANGMARK="quotawatch-selftest-hang-$$"
trap '[ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null
      pkill -9 -f "$HANGMARK" >/dev/null 2>&1
      rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/accounts" "$WORK/conf/fleets/sessA" "$WORK/.claude-dash/global"
for f in fleet-quotawatch.sh fleet-account.sh fleet-lib.sh usage-lib.sh; do cp "$BIN/$f" "$WORK/bin/"; done
chmod +x "$WORK/bin/"*.sh
printf 'tok-a\n' > "$WORK/accounts/a"; printf 'tok-b\n' > "$WORK/accounts/b"
printf 'FLEET_REPO="acme/widgets"\n' > "$WORK/conf/fleets/sessA/conf"
G="$WORK/.claude-dash/global"

# --- fake ccquota: `budget --account all --json …` → two pool accounts; a's 5h %
# comes from $FAKE_PCT_FILE (b's from $FAKE_PCT_B_FILE, default 20), the 5h reset
# from $FAKE_RESET_FILE (ISO). Logs calls.
cat > "$WORK/fakepath/ccquota" <<'FAKE'
#!/bin/bash
echo "$*" >> "$FAKE_LOG"
# A hub that accepts the connection and never answers (issue #698). The sleep is a
# CHILD, carrying the run's marker, so "the fetch was killed" can be checked as
# `no marked process survives` rather than taken on the log's word (#682).
if [ -n "${FAKE_CCQ_HANG:-}" ]; then bash -c "sleep $FAKE_CCQ_HANG # $FAKE_HANG_MARK"; fi
p=$(cat "$FAKE_PCT_FILE" 2>/dev/null || echo 10); pb=$(cat "$FAKE_PCT_B_FILE" 2>/dev/null || echo 20); r5=$(cat "$FAKE_RESET_FILE")
# b's SHAPE is switchable (issue #628): `unavail` is TokenLedger saying out loud
# that it cannot read the account (available:false + reason, both omitempty
# windows gone from the JSON), `shape` is a payload this fleet does not
# understand (no window, no flag). Anything else = the ordinary readable account.
case "$(cat "$FAKE_B_SHAPE_FILE" 2>/dev/null)" in
  unavail) b='{"account_uuid":"u-b","label":"b","available":false,"reason":"no reading","headroom_pct":0}' ;;
  shape)   b='{"account_uuid":"u-b","label":"b","headroom_pct":0}' ;;
  *)       b=$(printf '{"account_uuid":"u-b","label":"b","headroom_pct":%d,"five_hour":{"utilization":%d,"resets_at":"%s"},"seven_day":{"utilization":10,"resets_at":"2026-09-16T05:00:00Z"}}' "$((100-pb))" "$pb" "$r5") ;;
esac
# verdict: go|hold|unknown only (cmd/ccquota/budget.go) — never "ok" (issue #668).
printf '{"verdict":"go","accounts":[{"account_uuid":"u-a","label":"a","headroom_pct":%d,"five_hour":{"utilization":%d,"resets_at":"%s","percent_per_hour":30},"seven_day":{"utilization":10,"resets_at":"2026-09-16T05:00:00Z"}},%s]}' "$((100-p))" "$p" "$r5" "$b"
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
# ...and one wedged the way a REAL tick wedges (#582): bash DEFERS a trapped
# signal until the running FOREGROUND command returns, so this ignores SIGTERM
# for the full 300 s. A plain `sleep 300` holder cannot catch that — it dies on
# the first TERM — which is why the live supersede looked like it worked.
printf '#!/bin/bash\ntrap %s INT TERM\nx=$(sleep 300)\n' "'exit 143'" > "$WORK/fakepath/fleet-quotawatch-wedged"
chmod +x "$WORK/fakepath/"*

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
NOW=$(date +%s)
RESET1=$(( NOW + 10800 )); RESET2=$(( NOW + 10800 + 14400 ))   # two windows, 4h apart (> the 15-min tolerance)
RESET3=$(( RESET2 + 14400 ))                                    # a third, for the every-account-capped case (#567)
RESET4=$(( RESET3 + 14400 ))                                    # a fourth, for the unreadable-account case (#628)
iso "$RESET1" > "$WORK/reset"
HUB="http://hub.test:8787"
ACCTS=""            # per-case override of the accounts pool (see case 1)
run_watch() {
  PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
  FLEET_CONF_DIR="$WORK/conf" FLEET_ACCOUNTS_DIR="${ACCTS:-$WORK/accounts}" CCQUOTA_HUB_URL="$HUB" \
  FLEET_ACCOUNT_QUOTA_TTL=0 FLEET_NOTIFY_CMD="$WORK/fakepath/notify" \
  FAKE_LOG="$WORK/ccquota.calls" FAKE_TMUX_LOG="$WORK/tmux.calls" FAKE_NOTIFY_LOG="$WORK/notify.log" \
  FAKE_PCT_FILE="$WORK/pct" FAKE_PCT_B_FILE="$WORK/pct-b" FAKE_RESET_FILE="$WORK/reset" \
  FAKE_B_SHAPE_FILE="$WORK/b-shape" FAKE_HANG_MARK="$HANGMARK" \
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

# 1. off — one gate per job (#569) --------------------------------------------
echo 50 > "$WORK/pct"
# 1a. neither an accounts pool nor a hub: nothing runs at all.
HUB="" ACCTS="$WORK/nope" run_watch || fail "1a: fully unconfigured tick must exit 0"
[ "$(ccq_calls)" = 0 ]             || fail "1a: no hub URL ⇒ ccquota must not be called"
[ ! -f "$G/quotawatch.heartbeat" ] || fail "1a: nothing configured ⇒ no heartbeat"
ok
# 1b. an accounts pool but no hub: the per-model cap sweep needs no ccquota, so it
# ticks (and stamps a heartbeat) while the quota policy stays switched off.
HUB="" run_watch || fail "1b: pool-only tick must exit 0"
[ "$(ccq_calls)" = 0 ] || fail "1b: no hub URL ⇒ ccquota must STILL not be called"
[ -f "$G/quotawatch.heartbeat" ] || fail "1b: a pool-only tick must still stamp a heartbeat"
[ "$(hbget "$G/quotawatch.heartbeat" phase)" = "done" ] || fail "1b: a pool-only tick must reach phase=done (got: $(hbget "$G/quotawatch.heartbeat" phase))"
[ "$(hbget "$G/quotawatch.heartbeat" modelsweep)" = 1 ] || fail "1b: the heartbeat must mark the tick as model-sweep-only"
rm -f "$G/quotawatch.heartbeat"
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
# The dispatch goes through fleet_bg, so the command tmux is handed is the SILENCED
# wrapped form (issue #575): `( bash … --toast\n) >/dev/null 2>&1 || :`. Assert both
# halves — the command AND the tail that keeps migrate's stdout (and a nonzero exit)
# from becoming an Esc-to-dismiss view over whatever window the operator is in.
grep -q "run-shell -b ( bash '$WORK/bin/fleet-account.sh' migrate --account 'a' --session 'sessA' --toast" "$WORK/tmux.calls" || fail "3c: migrate goes through fleet_bg (run-shell -b, subshell-wrapped) on the fleet socket with --session sessA"
grep -qx ') >/dev/null 2>&1 || :' "$WORK/tmux.calls" || fail "3c: the backgrounded migrate must be SILENCED by fleet_bg (#575) — run-shell paints a job's stdout, and a nonzero exit, over the operator's window"
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

# 8. nowhere to move (#567) ------------------------------------------------------
# A NEW reset window with a at 90% AND b at 95%. Row a fires first: a is benched
# (already was, from the earlier 90% tick) and b — though not benched yet — is at
# the ceiling in this tick's rows, so it is no target; row b fires next with a
# benched. Neither may fan out a migrate: `fleet-account.sh active` would name a
# benched account and every session would be cold-booted back onto its own wall.
iso "$RESET3" > "$WORK/reset"; echo 90 > "$WORK/pct"; echo 95 > "$WORK/pct-b"
m=$(migrates); n=$(notifies)
run_watch --dry-run || fail "8: --dry-run must exit 0"
grep -q "^would: bench a (90% of 5-hour.*nowhere to move" "$WORK/stdout" || fail "8: --dry-run must say a has nowhere to move (stdout: $(cat "$WORK/stdout"))"
grep -q "^would: bench b (95% of 5-hour.*nowhere to move" "$WORK/stdout" || fail "8: --dry-run must say b has nowhere to move (stdout: $(cat "$WORK/stdout"))"
! grep -q "migrate --account" "$WORK/stdout" || fail "8: --dry-run must plan no migrate when every account is capped (stdout: $(cat "$WORK/stdout"))"
run_watch || fail "8b: the every-account-capped tick must exit 0"
[ "$(cat "$G/quota.ceiling.a" 2>/dev/null)" = "$RESET3" ] || fail "8b: a's ceiling marker = the new reset epoch (got: $(cat "$G/quota.ceiling.a" 2>/dev/null))"
[ "$(cat "$G/quota.ceiling.b" 2>/dev/null)" = "$RESET3" ] || fail "8b: b's ceiling marker = the new reset epoch (got: $(cat "$G/quota.ceiling.b" 2>/dev/null))"
[ "$(awk -F'\t' '$1=="a"{print $3}' "$G/account.limited" 2>/dev/null)" = "ccquota: 5-hour window at 90%" ] || fail "8b: a must still be benched (account.limited: $(cat "$G/account.limited" 2>/dev/null))"
[ "$(awk -F'\t' '$1=="b"{print $3}' "$G/account.limited" 2>/dev/null)" = "ccquota: 5-hour window at 95%" ] || fail "8b: b must be benched too (account.limited: $(cat "$G/account.limited" 2>/dev/null))"
[ "$(migrates)" = "$m" ] || fail "8b: NO migrate --account a when every account is capped (got $(( $(migrates) - m )) new)"
! grep -q "migrate --account 'b'" "$WORK/tmux.calls" || fail "8b: NO migrate --account b either"
grep -q 'display-message fleet: a at 90%.*nowhere to move: no other account is readable and under the ceiling' "$WORK/tmux.calls" || fail "8b: the toast must say nowhere to move (tmux.calls: $(grep display-message "$WORK/tmux.calls" | tail -2))"
grep -q '# subscription at its limit — nowhere to move' "$WORK/notify.log" || fail "8b: the notify must say nowhere to move"
grep -q 'sessions were NOT moved: they stay on \*\*b\*\*' "$WORK/notify.log" || fail "8b: the notify names the account the sessions stay on (notify: $(tail -4 "$WORK/notify.log"))"
[ "$(notifies)" = $((n+2)) ] || fail "8b: one notify per capped account (got $(( $(notifies) - n )))"
grep -q 'nowhere to move' "$WORK/stderr" || fail "8b: the tick logs the no-move on stderr (stderr: $(cat "$WORK/stderr"))"
run_watch || fail "8c: next tick must exit 0"
[ "$(notifies)" = $((n+2)) ] || fail "8c: same window ⇒ no repeat notify"
[ "$(migrates)" = "$m" ] || fail "8c: still no migrate"
ok

# 9. budgets — a wedged cap probe must not eat the tick (#582) -----------------
# The shape that broke it live: the sweep probe blocks in tmux for minutes, the
# tick blows past its own 60s period, the ccquota fetch behind it never runs, and
# the stamp goes stale — while `launchctl list` still shows exit 0.
cat > "$WORK/bin/fleet-model-switch.sh" <<'FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_SWITCH_LOG"
# The breadcrumb the real probe keeps (issue #706). Written BEFORE the sleep on
# purpose: that is the whole point of the file — the probe is tree-killed at the
# budget, so the only record of where it got to is what it had already written.
[ -n "${FLEET_MODEL_SWITCH_TRACE:-}" ] && \
  printf 'step=capture\nwin=3/9\nwid=@7\nelapsed=1\nsteps=t_meta=1 t_capture=1\nname=w3\n' > "$FLEET_MODEL_SWITCH_TRACE"
if [ "${FAKE_SWITCH_SLEEP:-0}" -gt 0 ]; then
  sleep "$FAKE_SWITCH_SLEEP"
  printf 'completed\n' >> "$FAKE_SWITCH_DONE"     # only reached if the kill MISSED
fi
exit 0
FAKE
chmod +x "$WORK/bin/fleet-model-switch.sh"
export FAKE_SWITCH_LOG="$WORK/switch.calls" FAKE_SWITCH_DONE="$WORK/switch.done"

# 9a. probe over budget → killed + reported, and the fetch behind it STILL runs.
export FAKE_SWITCH_SLEEP=6 FLEET_QUOTAWATCH_PROBE_BUDGET=2
before=$(ccq_calls); t0=$(date +%s)
run_watch || fail "9a: a tick whose probe timed out must still exit 0"
elapsed=$(( $(date +%s) - t0 ))
grep -q 'hit its 2s budget' "$WORK/stderr" || fail "9a: the timed-out probe must say so on stderr (stderr: $(cat "$WORK/stderr"))"
[ "$(ccq_calls)" = $((before+1)) ] || fail "9a: the ccquota fetch must NOT be starved by a wedged sweep"
[ "$elapsed" -lt 6 ] || fail "9a: the tick must not wait out the wedged probe (took ${elapsed}s, probe sleeps 6s)"
pgrep -f "$WORK/bin/fleet-model-switch.sh" >/dev/null 2>&1 && fail "9a: the timed-out probe must be gone, not detached"
[ "$(hbget "$G/quotawatch.heartbeat" phase)" = "done" ] || fail "9a: the tick must reach phase=done"
ok

# 9b. the whole TREE dies, not just the script: the fake's post-sleep marker is
# the proof — a `sleep` reparented to init would still write it.
sleep 5
[ ! -f "$WORK/switch.done" ] || fail "9b: the probe's children must be killed too (marker was written)"
ok

# 9c. the log answers "which half was slow?" — per-phase breakdown, both places.
grep -q 'tick done in .*modelcap .*fetch .*policy ' "$WORK/stderr" || fail "9c: the tick must log a per-phase breakdown (stderr: $(cat "$WORK/stderr"))"
grep -q "^t_modelcap=" "$G/quotawatch.heartbeat" || fail "9c: heartbeat must carry t_modelcap"
grep -q "^t_fetch="    "$G/quotawatch.heartbeat" || fail "9c: heartbeat must carry t_fetch"
grep -q "^t_policy="   "$G/quotawatch.heartbeat" || fail "9c: heartbeat must carry t_policy"
grep -q 'sessA=timeout' "$WORK/stderr" || fail "9c: the breakdown must name the fleet that timed out"
ok

# 9c2. …and WHICH STEP ate the budget (issue #706). "timeout" alone was the entire
# diagnosis available for 69% of this daemon's ticks on a live fleet, and it is
# not enough to act on: a probe stuck in `capture` (a blocked tmux server) and one
# stuck in `ledger` (a slow fleet-account fork) want opposite fixes, and neither
# wants the bigger PROBE_BUDGET that a bare "timeout" invites. The probe cannot
# report this itself — it is killed — so the killer reads its breadcrumb.
grep -q 'sessA=timeout@capture' "$WORK/stderr" || fail "9c2: the breakdown must name the STEP, not just the fleet (stderr: $(cat "$WORK/stderr"))"
grep -q 'budget in step capture' "$WORK/stderr" || fail "9c2: the kill line must name the step it died in"
grep -q 'window 3/9' "$WORK/stderr" || fail "9c2: the kill line must say how far into the sweep it got"
grep -q 't_meta=1 t_capture=1' "$WORK/stderr" || fail "9c2: the kill line must carry the per-step timings the probe had accrued"
ok

# 9c3. the per-fleet health ledger fleet-doctor reads. A single timeout is noise;
# the STREAK is what says a fleet's cap detection has gone dark.
qmf="$G/quotawatch.modelcap.sessA"
[ -f "$qmf" ] || fail "9c3: a timed-out probe must record the fleet's cap-probe health"
[ "$(sed -n 's/^streak=//p' "$qmf" | head -1)" -ge 1 ] || fail "9c3: a timeout must increment the streak (file: $(cat "$qmf"))"
[ "$(sed -n 's/^step=//p' "$qmf" | head -1)" = capture ] || fail "9c3: the health file must remember the step it died in"
ok

# 9d. phase budget: 0s of budget → every fleet deferred, cursor armed, fetch runs.
export FLEET_QUOTAWATCH_SWEEP_BUDGET=0
before=$(ccq_calls)
run_watch || fail "9d: a fully deferred sweep must still exit 0"
grep -q 'deferred to the next tick: sessA' "$WORK/stderr" || fail "9d: a blown phase budget must name what it deferred (stderr: $(cat "$WORK/stderr"))"
[ "$(cat "$G/quotawatch.sweep.start" 2>/dev/null)" = sessA ] || fail "9d: the fairness cursor must be armed with the deferred fleet"
[ "$(ccq_calls)" = $((before+1)) ] || fail "9d: a deferred sweep must not stop the fetch"
unset FLEET_QUOTAWATCH_SWEEP_BUDGET

# 9e. a tick releases ONLY a lock it still holds — the bug that let ticks pile up
# three-deep: a superseded-but-alive tick deleted its SUCCESSOR's lock on exit.
export FAKE_SWITCH_SLEEP=4 FLEET_QUOTAWATCH_PROBE_BUDGET=20
run_watch & WATCHER=$!
i=0; while [ ! -f "$G/quotawatch.lock/pid" ] && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i+1)); done
[ -f "$G/quotawatch.lock/pid" ] || { kill "$WATCHER" 2>/dev/null; fail "9e: the running tick must take the lock"; }
printf '999999' > "$G/quotawatch.lock/pid"          # somebody else owns it now
wait "$WATCHER" 2>/dev/null
[ -d "$G/quotawatch.lock" ] || fail "9e: a tick must NOT remove a lock another tick now owns"
[ "$(cat "$G/quotawatch.lock/pid")" = 999999 ] || fail "9e: the other tick's lock must be untouched"
rm -rf "$G/quotawatch.lock"
unset FAKE_SWITCH_SLEEP FLEET_QUOTAWATCH_PROBE_BUDGET
ok

# 9f. a probe that COMPLETES clears the streak and stamps lastok — otherwise the
# doctor verdict would latch on the first bad tick and never let go.
[ "$(sed -n 's/^streak=//p' "$G/quotawatch.modelcap.sessA" | head -1)" = 0 ] \
  || fail "9f: a completed probe must reset the streak (file: $(cat "$G/quotawatch.modelcap.sessA"))"
[ "$(sed -n 's/^lastok=//p' "$G/quotawatch.modelcap.sessA" | head -1)" -gt 0 ] \
  || fail "9f: a completed probe must stamp lastok"
ok

# 9f. supersede must actually KILL a tick wedged in a command substitution.
# `kill -TERM <pid>` alone does not: the trap is deferred until the foreground
# child returns, so the "superseded" tick kept running — 26 minutes, live, against
# a 120s deadline — and kept hammering the tmux server that wedged it.
bash "$WORK/fakepath/fleet-quotawatch-wedged" >/dev/null 2>&1 </dev/null & HOLDER=$!; disown "$HOLDER"
sleep 0.3
mkdir -p "$G/quotawatch.lock"; printf '%s' "$HOLDER" > "$G/quotawatch.lock/pid"
printf '%s' $(( $(date +%s) - 1000 )) > "$G/quotawatch.lock/ts"      # past the deadline
run_watch || fail "9f: superseding tick must exit 0"
grep -q 'superseding' "$WORK/stderr" || fail "9f: past the deadline ⇒ supersede on stderr"
kill -0 "$HOLDER" 2>/dev/null && { kill -KILL "$HOLDER" 2>/dev/null
  fail "9f: a tick wedged in a command substitution must be tree-killed, not just TERMed"; }
HOLDER=''
[ ! -d "$G/quotawatch.lock" ] || fail "9f: lock released after the superseding tick"
ok

# 10. an account ccquota cannot READ is not a landing spot (#628) ---------------
# The old parser turned TokenLedger's `available:false, reason: no reading` into
# a row of zeroes — 0% used AND 0% headroom — so b looked like a brand-new idle
# subscription: never benched, and the FIRST account quota_move_target handed a's
# sessions to. Now it produces no row, and no row is no target.
iso "$RESET4" > "$WORK/reset"; echo 90 > "$WORK/pct"; echo 20 > "$WORK/pct-b"; echo unavail > "$WORK/b-shape"
: > "$G/account.limited"        # case 8 benched both; a bench would keep b out of
                                # quota_move_target for the wrong reason
m=$(migrates); n=$(notifies)
run_watch || fail "10: the tick must exit 0"
grep -q 'has no reading for b (available=false, reason: no reading)' "$WORK/stderr" \
  || fail "10: the tick must LOG that ccquota cannot read b (stderr: $(cat "$WORK/stderr"))"
[ "$(cat "$G/quota.ceiling.a" 2>/dev/null)" = "$RESET4" ] || fail "10: a at 90% must still be benched for the new window"
[ -z "$(awk -F'\t' '$1=="b"{print $3}' "$G/account.limited" 2>/dev/null)" ] || fail "10: b has no row ⇒ the policy loop never sees it ⇒ no bench"
[ "$(migrates)" = "$m" ] || fail "10: NO migrate onto an account ccquota cannot read (got $(( $(migrates) - m )) new)"
grep -q 'nowhere to move' "$WORK/stderr" || fail "10: the tick must say nowhere to move (stderr: $(cat "$WORK/stderr"))"
grep -q 'unreadable to ccquota' "$WORK/notify.log" || fail "10: the notify must name the unreadable account as a reason (notify: $(tail -4 "$WORK/notify.log"))"
ok

# 10b. deduped: the same complaint every 60 s would drown the tick log — one line
# per CHANGE, including the change back to clean.
run_watch || fail "10b: the next tick must exit 0"
! grep -q 'has no reading for b' "$WORK/stderr" || fail "10b: an unchanged complaint must not be re-logged every tick"
echo '' > "$WORK/b-shape"
run_watch || fail "10c: the recovering tick must exit 0"
grep -q 'reads every pool account again' "$WORK/stderr" || fail "10c: going clean again must be announced once (stderr: $(cat "$WORK/stderr"))"
ok

# 10d. a payload shape the parser does not know is the LOUD half: same no-row
# rail, but fleet-doctor.sh turns the quota line RED on it (it means ccquota and
# the fleet have drifted, not that one account is unreadable today).
echo shape > "$WORK/b-shape"
run_watch || fail "10d: the tick must exit 0"
grep -q 'payload shape not recognized for b' "$WORK/stderr" || fail "10d: an unparseable account must be logged (stderr: $(cat "$WORK/stderr"))"
[ "$(migrates)" = "$m" ] || fail "10d: still no migrate onto it"
echo '' > "$WORK/b-shape"
ok

# 11. the tick's OWN budget (#698) ---------------------------------------------
# The bug: FLEET_QUOTAWATCH_DEADLINE (120s) is only a SUPERSEDE threshold — it tells
# a successor that the lock holder is stuck. launchd does not overlap a
# StartInterval job, so while a slow tick runs there is no successor to come and
# judge it, and #671 gates the collector's fallback off for exactly that window. A
# tick that was slow but PROGRESSING had nothing bounding it at all: 5m45s measured
# live on 2026-09-15 against that 120s, on a host that already had #688.
hang_survivors() { sleep 2; pgrep -f "$HANGMARK" 2>/dev/null | wc -l | tr -d ' '; }
echo 10 > "$WORK/pct"; echo 20 > "$WORK/pct-b"; echo '' > "$WORK/b-shape"

# 11a. INVARIANT ONE, in code: the budget must leave room to wind down before the
# deadline. Two knobs that disagree are clamped — the BUDGET down, never the
# deadline up — because a tick still running when its successor supersedes it is
# tree-killed mid-wind-down, and the lock release lives in its EXIT trap (#582).
FLEET_QUOTAWATCH_TICK_BUDGET=200 run_watch || fail "11a: an over-large budget must not fail the tick"
grep -q 'exceeds FLEET_QUOTAWATCH_DEADLINE (120s)' "$WORK/stderr" \
  || fail "11a: a budget that would outlive the deadline must be clamped, loudly (stderr: $(cat "$WORK/stderr"))"
grep -q 'clamping the budget to 100s' "$WORK/stderr" || fail "11a: the clamp must name the value it used"
[ "$(hbget "$G/quotawatch.heartbeat" budget)" = 100 ] \
  || fail "11a: the heartbeat must record the budget actually in force (got: $(hbget "$G/quotawatch.heartbeat" budget))"
ok

# 11b. INVARIANT TWO: the sweep can never starve the ccquota fetch. That is what
# #582 gave the sweep a budget FOR — the fetch is ~1s and its stamp is the liveness
# signal every staleness alarm reads — and with four independent knobs it held only
# by arithmetic luck. Ask for a sweep bigger than the whole tick and it is cut back
# to leave the fetch its budget; the proof is that the fetch still happened.
before=$(ccq_calls)
FLEET_QUOTAWATCH_SWEEP_BUDGET=999 run_watch || fail "11b: an over-large sweep budget must not fail the tick"
grep -q 'would starve the liveness stamp' "$WORK/stderr" \
  || fail "11b: a sweep budget that squeezes the fetch must be clamped, loudly (stderr: $(cat "$WORK/stderr"))"
[ "$(ccq_calls)" = $((before+1)) ] || fail "11b: the fetch must still run after the sweep is clamped"
ok

# 11c. the ccquota fetch is BUDGETED and tree-killed. `fleet-account.sh quota` asks
# ccquota with its own `--timeout 10s`, which binds ccquota and nothing else: a hub
# that hangs before that timer arms, a build that ignores it, or the python parser
# behind it in the pipeline are all unbounded from the fleet's side. The marker
# child is the honest check — a `sleep` reparented to init would still be alive.
export FAKE_CCQ_HANG=30
t0=$(date +%s)
FLEET_QUOTAWATCH_FETCH_BUDGET=2 run_watch || fail "11c: a tick whose fetch timed out must still exit 0"
elapsed=$(( $(date +%s) - t0 ))
unset FAKE_CCQ_HANG
[ "$elapsed" -lt 25 ] || fail "11c: the tick waited out the hung fetch (${elapsed}s against a 2s budget)"
grep -q 'ccquota fetch hit its 2s budget' "$WORK/stderr" \
  || fail "11c: the killed fetch must say so on stderr (stderr: $(cat "$WORK/stderr"))"
[ "$(hbget "$G/quotawatch.heartbeat" phase)" = "done" ] || fail "11c: the tick must still reach phase=done"
grep -q '^over=.*fetch' "$G/quotawatch.heartbeat" || fail "11c: the heartbeat's over= must name the fetch"
n=$(hang_survivors)
[ "$n" = 0 ] || fail "11c: $n hung fetch child(ren) outlived the budget — it bounded the ledger, not the processes (#682)"
[ ! -d "$G/quotawatch.lock" ] || fail "11c: a tick that killed its own fetch must still release the lock"
ok

# 11d. WIND DOWN, don't self-kill: at the budget the tick stops STARTING work. A
# zero policy budget defers every account — and the once-per-window marker is
# written by the branch that HANDLES an account, so a deferred one has none and the
# next tick does the whole episode. `kill $$` here would be the #582 regression:
# this process holds the lock and only its EXIT trap releases it.
iso "$RESET1" > "$WORK/reset"; echo 90 > "$WORK/pct"
rm -f "$G/quota.ceiling.a" "$G/quota.warn.a"; : > "$G/account.limited"
m=$(migrates)
FLEET_QUOTAWATCH_POLICY_BUDGET=0 run_watch || fail "11d: a fully deferred policy must still exit 0"
grep -q 'policy phase spent its 0s budget — deferred to the next tick: a' "$WORK/stderr" \
  || fail "11d: the wind-down must name what it deferred (stderr: $(cat "$WORK/stderr"))"
[ ! -f "$G/quota.ceiling.a" ] || fail "11d: a DEFERRED account must not get a once-per-window marker — the next tick would skip it forever"
[ "$(migrates)" = "$m" ] || fail "11d: nothing may be acted on in a deferred row"
case "$(hbget "$G/quotawatch.heartbeat" skipped)" in *policy*) : ;; *) fail "11d: the heartbeat's skipped= must name the deferred phase (got: $(hbget "$G/quotawatch.heartbeat" skipped))";; esac
[ "$(hbget "$G/quotawatch.heartbeat" phase)" = "done" ] || fail "11d: a wound-down tick must still reach phase=done"
[ ! -d "$G/quotawatch.lock" ] || fail "11d: a wound-down tick must release its lock"
ok

# 11e. …and deferral is NOT starvation: the very next tick, with its normal budget,
# does the episode the wound-down one dropped.
run_watch || fail "11e: the resuming tick must exit 0"
[ "$(cat "$G/quota.ceiling.a" 2>/dev/null)" = "$RESET1" ] || fail "11e: the next tick must handle the deferred account"
[ "$(migrates)" -gt "$m" ] || fail "11e: the next tick must actually act on it (migrate fan-out)"
ok

# 11f. the whole-TICK budget is the backstop over all of them: with 1s there is no
# room to start anything, and the tick still exits 0, still reaches done, still
# releases the lock — and says what it dropped instead of dropping it silently.
FLEET_QUOTAWATCH_TICK_BUDGET=1 run_watch || fail "11f: a tick with no room must still exit 0"
grep -q 'no room left in the 1s tick budget for the ccquota fetch' "$WORK/stderr" \
  || fail "11f: the tick budget must be able to stop the fetch too, and say so (stderr: $(cat "$WORK/stderr"))"
[ "$(hbget "$G/quotawatch.heartbeat" phase)" = "done" ] || fail "11f: it must still reach phase=done"
[ "$(hbget "$G/quotawatch.heartbeat" budget)" = 1 ] || fail "11f: the heartbeat must record the budget in force"
case "$(hbget "$G/quotawatch.heartbeat" skipped)" in *fetch*) : ;; *) fail "11f: skipped= must name the fetch (got: $(hbget "$G/quotawatch.heartbeat" skipped))";; esac
grep -q 'tick done in .*s/1s' "$WORK/stderr" || fail "11f: the tick line must print duration against its budget"
[ ! -d "$G/quotawatch.lock" ] || fail "11f: it must release the lock"
ok

printf 'selftest PASS: fleet-quotawatch — %s groups (off, status, policy 50/72/90 + once-per-window, dry-run, lock skip/supersede/takeover, staleness alarm, human secs, nowhere-to-move #567, probe budget/tree-kill/phase breakdown/lock ownership, wedged-tick supersede #582, unreadable-account #628, tick self-budget + wind-down #698)\n' "$CHECKS"
exit 0
