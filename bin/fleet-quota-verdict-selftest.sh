#!/bin/bash
# fleet-quota-verdict-selftest.sh — ccquota is the single source of truth for the
# SUBSCRIPTION limit; a limit banner is only a hint to refetch (issue #874).
#
# Why. The pane-banner scrape (ph_banner → mark-limited) false-benched healthy
# accounts twice: #782 (a Codex banner benched a Claude account) and 2026-09-22
# (a `--resume` replayed an old weekly banner and benched an account at 7d 34%,
# starting a failover cascade across the pool). Pinned here, end to end:
#   • `fleet-account.sh quota-verdict` — limited <until> | ok | unknown, per axis,
#     the refetch dedupe, and every way a reading is "not fresh" (no hub, stale
#     cache, blind hub, account absent).
#   • ph_banner (the REAL phase, extracted from tmux-dash-collect.sh) against the
#     REAL fleet-account.sh:
#       ① fresh 7d 34% + weekly banner → no account.limited row, ONE forced fetch
#       ② blind hub + banner → benched as before, `▲ quota · from banner` raised
#       ③ Fable-cap banner → model-limited, whatever the reading says
#       ④ fresh 7d at the ceiling + weekly banner → benched to ccquota's reset
# The failover controller's half (a replayed banner is not HARD evidence) is in
# fleet-failover-selftest.py (claude_wall).
#
# Hermetic: fake ccquota (switchable payload, counts its calls), fake tmux, stub
# account-truth; scratch pool / conf / TMPDIR / HOME. No network, no tmux server.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/quota-verdict-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/accounts" "$WORK/conf" "$WORK/.claude-dash/global"
for f in fleet-account.sh fleet-lib.sh usage-lib.sh; do cp "$BIN/$f" "$WORK/bin/"; done
printf 'tok-a\n' > "$WORK/accounts/a"; printf 'tok-b\n' > "$WORK/accounts/b"
chmod 600 "$WORK/accounts/a" "$WORK/accounts/b"
G="$WORK/.claude-dash/global"
MODE="$WORK/mode"; CALLS="$WORK/ccquota.calls"; : > "$CALLS"

# 7d reset far in the future so a `limited` until is checkable.
R7=$(( $(date +%s) + 3 * 86400 ))
R7ISO=$(python3 -c "import datetime,sys;print(datetime.datetime.fromtimestamp($R7,datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
cat > "$WORK/fakepath/ccquota" <<FAKE
#!/bin/bash
echo call >> "$CALLS"
row() { printf '{"account_uuid":"u-%s","label":"%s","headroom_pct":%s,"five_hour":{"utilization":%s,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":%s,"resets_at":"$R7ISO"}}' "\$1" "\$1" "\$((100-\$3))" "\$2" "\$3"; }
case "\$(cat "$MODE" 2>/dev/null)" in
  empty) printf '{"verdict":"unknown","accounts":[]}\n' ;;
  hot)   printf '{"verdict":"go","accounts":[%s,%s]}\n' "\$(row a 2 99)" "\$(row b 20 10)" ;;
  expired) printf '{"verdict":"go","accounts":[{"account_uuid":"u-a","label":"a","headroom_pct":2,"five_hour":{"utilization":98,"resets_at":"2020-01-01T00:00:00Z"},"seven_day":{"utilization":10,"resets_at":"$R7ISO"}}]}\n' ;;
  only-b) printf '{"verdict":"go","accounts":[%s]}\n' "\$(row b 20 10)" ;;
  *)     printf '{"verdict":"go","accounts":[%s,%s]}\n' "\$(row a 2 34)" "\$(row b 20 10)" ;;
esac
FAKE
chmod +x "$WORK/fakepath/ccquota"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf -- '--- got ---\n%s\n' "$2" >&2; exit 1; }
eq() { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }

HUB="http://hub.test:8787"
run() {
  env PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
    FLEET_CONF_DIR="$WORK/conf" FLEET_ACCOUNTS_DIR="$WORK/accounts" FLEET_ACCOUNT_CEILING=85 \
    CCQUOTA_HUB_URL="$HUB" "$@"
}
verdict() { run bash "$WORK/bin/fleet-account.sh" quota-verdict "$@" 2>/dev/null; }
calls() { wc -l < "$CALLS" | tr -d ' '; }
reset_state() { rm -f "$G"/account.* "$G"/quota.via-banner "$G"/banner-hint.*; : > "$CALLS"; : > "$WORK/tick.err"; }
age_cache() { printf '%s' "$(( $(date +%s) - $1 ))" > "$G/account.quota.ts"; }

# --- quota-verdict ------------------------------------------------------------
reset_state; echo fresh > "$MODE"
eq "no cache + no --refresh → unknown (nothing read yet)" unknown "$(verdict a)"
eq "…and it never fetched" 0 "$(calls)"
eq "--refresh fetches → 7d 34% is ok"           ok "$(verdict a --axis 7d --refresh)"
eq "…exactly one fetch" 1 "$(calls)"
eq "a second --refresh inside the dedupe window does not refetch" ok "$(verdict a --axis 7d --refresh)"
eq "…still one fetch" 1 "$(calls)"
age_cache 30
eq "past FLEET_ACCOUNT_VERDICT_REFETCH it refetches" ok "$(verdict a --refresh)"
eq "…two fetches" 2 "$(calls)"
echo hot > "$MODE"; age_cache 30
eq "7d 99% on the weekly axis → limited until ccquota's 7d reset" "limited $R7" "$(verdict a --axis 7d --refresh)"
eq "…the 5h axis of the same account is ok (2%)"   ok "$(verdict a --axis 5h)"
eq "…no axis weighs both → limited"               "limited $R7" "$(verdict a)"
eq "a healthy account in the same payload → ok"   ok "$(verdict b)"
echo expired > "$MODE"; age_cache 30
expired_until="$(verdict a --axis 5h --refresh)"
case "$expired_until" in "limited "*) expired_until="${expired_until#limited }" ;; *) fail "expired high reading did not remain a short limit" "$expired_until" ;; esac
now_s="$(date +%s)"
[ "$expired_until" -ge "$((now_s + 55))" ] && [ "$expired_until" -le "$((now_s + 65))" ] \
  || fail "expired reset was extended too far instead of retried in ~60s" "$expired_until"
CHECKS=$((CHECKS+1))
age_cache 700
eq "stale cache (> FLEET_ACCOUNT_QUOTA_STALE) → unknown" unknown "$(verdict a)"
echo only-b > "$MODE"; age_cache 30
eq "account absent from the hub → unknown"        unknown "$(verdict a --refresh)"
echo empty > "$MODE"; age_cache 30
eq "blind hub (empty answer) → unknown"           unknown "$(verdict b --refresh)"
eq "no hub configured → unknown" unknown "$(HUB='' verdict b)"
eq "bad axis → usage (exit 2)" 2 "$(run bash "$WORK/bin/fleet-account.sh" quota-verdict a --axis 1y >/dev/null 2>&1; echo $?)"

# --- ph_banner, the real phase --------------------------------------------------
python3 - "$BIN/tmux-dash-collect.sh" "$WORK/phase.sh" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
out=[]
for name in ('atomic_write','ph_banner'):
    m=re.search(r'^'+name+r'\(\) \{\n.*?^\}',s,re.M|re.S); assert m, name
    out.append(m.group(0))
open(sys.argv[2],'w').write('\n'.join(out)+'\n')
PY
# account-truth stub: window @1 / pane %1 runs account `a`, stamp already right.
printf '#!/bin/bash\nprintf "@1\\t%%%%1\\ta\\t0\\n"\n' > "$WORK/bin/fleet-account-truth.sh"
cat > "$WORK/fakepath/tmux" <<FAKE
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/tmux.log"
case "\$*" in *capture-pane*) cat "$WORK/banner" ;; esac
exit 0
FAKE
chmod +x "$WORK/fakepath/tmux"
tick() {
  run bash -c '
    BIN="$1"; . "$BIN/fleet-lib.sh"; . "$BIN/usage-lib.sh"; . "$2"
    now() { date +%s; }
    fleet_bg() { printf "%s\n" "$*" >> "$3"; }
    SOCKETS=fixture G="$4"
    ph_banner' tick "$WORK/bin" "$WORK/phase.sh" "$WORK/bg.log" "$G" 2>>"$WORK/tick.err"
}
limited_row() { awk -F'\t' -v l="$1" '$1==l' "$G/account.limited" 2>/dev/null; }
via() { run bash -c '. "$0"; fleet_quota_via_banner' "$WORK/bin/usage-lib.sh"; }

# ① the 2026-09-22 incident: fresh reading 7d 34%, a REPLAYED weekly banner.
reset_state; echo fresh > "$MODE"; : > "$WORK/bg.log"
printf "You've hit your weekly limit · resets Sep 25, 7pm (Asia/Shanghai)\n" > "$WORK/banner"
run bash "$WORK/bin/fleet-account.sh" quota --refresh >/dev/null 2>&1; age_cache 45; : > "$CALLS"
tick
eq "① fresh 7d 34% + weekly banner → NO account.limited row" "" "$(limited_row a)"
eq "① …exactly one forced refetch" 1 "$(calls)"
eq "① …no migrate/reconcile started" "" "$(cat "$WORK/bg.log")"
eq "① …no ▲ quota · from banner" "" "$(via)"
grep -q 'a banner ignored — ccquota 7d reading has headroom' "$WORK/tick.err" || fail "① the ignored banner left no log line" "$(cat "$WORK/tick.err")"
tick
eq "① a second tick inside the dedupe window does not refetch" 1 "$(calls)"
eq "① …and does not log the same banner again" 1 "$(grep -c 'banner ignored' "$WORK/tick.err")"
eq "① …still no bench" "" "$(limited_row a)"

# ② blind hub: no reading to overrule the banner → pre-#874 bench + the marker.
reset_state; echo empty > "$MODE"; : > "$WORK/bg.log"
tick
[ -n "$(limited_row a)" ] || fail "② blind hub + banner did not bench (fallback lost)"
eq "② …via the banner's own reset text, not ccquota" 1 "$(limited_row a | grep -c 'hit your weekly limit')"
case "$(via)" in "a	"*) CHECKS=$((CHECKS+1)) ;; *) fail "② ▲ quota · from banner not raised" "$(via)" ;; esac
grep -q "quota-banner warning quota 'from banner'" "$BIN/fleet-alerts.sh" || fail "② the alerts producer does not raise ▲ quota · from banner"
eq "② the marker expires (VIA_BANNER_SECS)" "" "$(FLEET_ACCOUNT_QUOTA_VIA_BANNER_SECS=0 via)"

# ③ a per-MODEL cap keeps its own signal, whatever ccquota says.
reset_state; echo fresh > "$MODE"; : > "$WORK/bg.log"
printf "You've hit your Fable 5 limit · resets Sep 26, 3am (Asia/Shanghai)\n" > "$WORK/banner"
tick
eq "③ Fable banner → model-limited recorded" 1 "$(grep -c '^a	fable	' "$G/account.model-limited" 2>/dev/null)"
eq "③ …never a subscription bench" "" "$(limited_row a)"
eq "③ …and no verdict fetch was needed" 0 "$(calls)"

# ④ the reading agrees with the banner → bench to ccquota's reset (+ buffer).
reset_state; echo hot > "$MODE"; : > "$WORK/bg.log"
printf "You've hit your weekly limit · resets Sep 25, 7pm (Asia/Shanghai)\n" > "$WORK/banner"
tick
eq "④ fresh 7d 99% + weekly banner → benched until ccquota's 7d reset + 60s" "$(( R7 + 60 ))" "$(limited_row a | cut -f2)"
eq "④ …the bench says ccquota decided" 1 "$(limited_row a | grep -c 'ccquota 7d at ceiling')"
eq "④ …no ▲ quota · from banner" "" "$(via)"

printf 'quota-verdict selftest: %d checks passed\n' "$CHECKS"
