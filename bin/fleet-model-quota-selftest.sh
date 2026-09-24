#!/bin/bash
# fleet-model-quota-selftest.sh — FLEET_MODEL is gated on ccquota's PER-MODEL
# window (issue #1073), so a spawn skips a capped Fable BEFORE the wall, not after.
#
# Why. The Fable cap is its own weekly window (anthropic-ratelimit-unified-7d_oi),
# invisible in the account's 5h/7d: on 2026-09-23 three of four pool accounts sat
# at 7d_oi 1.0 while their 7d read 0.68–0.80. Until now the fleet learned of it
# only from a pane's banner — after a worker had already stalled on its first
# turn, or never, for a session that was idle when the cap landed. TokenLedger
# (tokenledger#155) exposes it as `accounts[].models[<model>]`; pinned here:
#   • quota_models_parse — capped / ok / unknown per (label, model), the
#     FLEET_MODEL_CAP_PCT knob, `model_available`, and no rows without `models`.
#   • model_quota_sync (every fetch) — seeds the model-limited ledger with the
#     REAL reset, drops ccquota's row once the window is available again, and
#     treats a banner row as a refresh hint: an OLDER reading cannot clear it.
#   • the spawn, end to end through the REAL fleet-claude.sh + fleet-account.sh:
#     A capped / B allowed → launches on B with FLEET_MODEL; both capped → the
#     fallback; no banner in any pane at any point.
#   • the provider-aware selector ranks an account that runs FLEET_MODEL first.
#   • the degenerate case: a payload with no `models` leaves the ledger unopened
#     and the spawn exactly where it was.
#
# Hermetic: fake ccquota (payload from a file), fake claude (records argv + token),
# fake tmux; scratch pool / conf / HOME. No network, no tmux server.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/model-quota-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/accounts" "$WORK/conf" "$WORK/.claude-dash/global"
for f in fleet-account.sh fleet-lib.sh usage-lib.sh fleet-claude.sh .fleet-account.py; do
  [ -f "$BIN/$f" ] && cp "$BIN/$f" "$WORK/bin/"
done
# The GLOBAL conf names no model: the fleet's model reaches the account pick only
# through the launcher (FLEET_PICK_MODEL), as a per-fleet overlay's would.
printf 'FLEET_MODEL_FALLBACK="opus"\n' > "$WORK/fleet.conf"
printf 'tok-a\n' > "$WORK/accounts/a"; printf 'tok-b\n' > "$WORK/accounts/b"
chmod 600 "$WORK/accounts/a" "$WORK/accounts/b"
G="$WORK/.claude-dash/global"
LEDGER="$G/account.model-limited"
PAYLOAD="$WORK/payload.json"

cat > "$WORK/fakepath/ccquota" <<FAKE
#!/bin/bash
cat "$PAYLOAD"
FAKE
cat > "$WORK/fakepath/claude" <<FAKE
#!/bin/bash
printf '%s\n' "\$*" > "$WORK/argv"
printf '%s\n' "\${CLAUDE_CODE_OAUTH_TOKEN:-}" > "$WORK/token"
FAKE
# no fleet session (display-message → nothing); every capture-pane is logged, so
# "no banner" is checkable: nothing in this test ever reads a pane.
cat > "$WORK/fakepath/tmux" <<FAKE
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/tmux.log"
exit 0
FAKE
chmod +x "$WORK/fakepath/"*

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf -- '--- got ---\n%s\n' "$2" >&2; exit 1; }
eq() { CHECKS=$((CHECKS+1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }

run() {
  env -u FLEET_MODEL -u FLEET_MODEL_FALLBACK -u FLEET_ACCOUNT_LABEL -u TMUX -u TMUX_PANE \
    PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
    FLEET_CONF_DIR="$WORK/conf" FLEET_ACCOUNTS_DIR="$WORK/accounts" FLEET_ACCOUNT_CEILING=85 \
    FLEET_FAILOVER=0 FLEET_PRETRUST=0 CCQUOTA_HUB_URL="http://hub.test:8787" "$@"
}
acct() { run bash "$WORK/bin/fleet-account.sh" "$@" 2>/dev/null; }
fetch() { acct quota --refresh >/dev/null; }
spawn() {   # → "<token> <model>" the REAL launcher chose
  rm -f "$WORK/argv" "$WORK/token"
  run env FLEET_MODEL=fable bash "$WORK/bin/fleet-claude.sh" >/dev/null 2>&1
  printf '%s %s' "$(cat "$WORK/token" 2>/dev/null)" \
    "$(sed -n 's/.*--model \([^ ]*\).*/\1/p' "$WORK/argv" 2>/dev/null)"
}
iso() { python3 -c "import datetime;print(datetime.datetime.fromtimestamp($1,datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }

NOW=$(date +%s)
RA=$(( NOW + 2 * 86400 )); RB=$(( NOW + 5 * 86400 ))
OBS=$(( NOW - 30 ))
# payload <a-models-json|-> <b-models-json|->   ('-' = no `models` key at all)
# a has the better 5h (5% vs 30%), so it is the pick whenever models don't say otherwise.
payload() {
  local am="" bm=""
  [ "$1" = - ] || am=",\"models\":$1"
  [ "$2" = - ] || bm=",\"models\":$2"
  cat > "$PAYLOAD" <<JSON
{"verdict":"go","accounts":[
 {"account_uuid":"u-a","label":"a","headroom_pct":95,"five_hour":{"utilization":5,"resets_at":"$(iso $((NOW+3600)))"},"seven_day":{"utilization":20,"resets_at":"$(iso $((NOW+86400)))"}$am},
 {"account_uuid":"u-b","label":"b","headroom_pct":70,"five_hour":{"utilization":30,"resets_at":"$(iso $((NOW+3600)))"},"seven_day":{"utilization":20,"resets_at":"$(iso $((NOW+86400)))"}$bm}]}
JSON
}
fm() {   # fm <status> <util> <reset-epoch> [observed-epoch] → one models object
  printf '{"claude-fable-5-1":{"claim":"7d_oi","utilization":%s,"status":"%s","resets_at":"%s","observed_at":"%s"}}' \
    "$2" "$1" "$(iso "$3")" "$(iso "${4:-$OBS}")"
}
reset_state() { rm -f "$G"/account.* "$WORK/tmux.log"; }

# --- degenerate: no `models` anywhere → nothing changes ----------------------
reset_state; payload - -
fetch
eq "no models: model-quota prints nothing" "" "$(acct model-quota)"
eq "no models: the ledger is never opened" no "$([ -e "$LEDGER" ] && echo yes || echo no)"
rows_plain=$(cat "$G/account.quota")
eq "no models: the spawn lands on the best-5h account with FLEET_MODEL" "tok-a fable" "$(spawn)"

# --- parse ----------------------------------------------------------------------
reset_state; payload "$(fm rejected 100 $RA)" "$(fm allowed 9 $RB)"
fetch
eq "models: quota rows are byte-identical to the no-models payload" "$rows_plain" "$(cat "$G/account.quota")"
got=$(acct model-quota)
eq "parse: A capped, with its reset + observation" "a	claude-fable-5-1	capped	$RA	$OBS	100	rejected" "$(printf '%s\n' "$got" | grep '^a	')"
eq "parse: B ok" "b	claude-fable-5-1	ok	$RB	$OBS	9	allowed" "$(printf '%s\n' "$got" | grep '^b	')"
payload "$(fm allowed_warning 97 $RA)" "$(printf '{"claude-fable-5-1":{"utilization":20},"claude-opus-5-5":{"status":"weird"}}')"
fetch; got=$(FLEET_MODEL_CAP_PCT=95 acct model-quota)
eq "parse: utilization ≥ FLEET_MODEL_CAP_PCT is capped even while allowed" capped "$(printf '%s\n' "$got" | awk -F'\t' '$1=="a"{print $3}')"
eq "parse: neither status nor flag → unknown" "unknown unknown" "$(printf '%s\n' "$got" | awk -F'\t' '$1=="b"{printf "%s%s",s,$3; s=" "}')"
payload "$(printf '{"claude-fable-5-1":{"utilization":10}}' )" -
sed -i.bak 's/"models"/"model_available":{"claude-fable-5-1":false},"models"/' "$PAYLOAD"
fetch; got=$(acct model-quota)
eq "parse: model_available false → capped" capped "$(printf '%s\n' "$got" | awk -F'\t' '{print $3}')"
eq "parse: an account without models is absent, not ok" "a" "$(printf '%s\n' "$got" | cut -f1 | tr '\n' ' ' | sed 's/ $//')"

# --- the acceptance: A capped, B allowed → B with FLEET_MODEL, no banner ------
reset_state; payload "$(fm rejected 100 $RA)" "$(fm allowed 9 $RB)"
fetch
eq "sync: A's cap is in the ledger until ccquota's reset + buffer" "$(( RA + 60 ))" "$(acct model-limited-until a fable)"
eq "sync: B has no cap" 0 "$(acct model-limited-until b fable)"
eq "sync: the row names ccquota, not a banner" "ccquota: claude-fable-5-1 rejected 100%" "$(awk -F'\t' '$1=="a"{print $4}' "$LEDGER")"
eq "spawn: lands on B with FLEET_MODEL (before any turn)" "tok-b fable" "$(spawn)"
eq "spawn: no pane was ever read for a banner" 0 "$(cat "$WORK/tmux.log" 2>/dev/null | grep -c capture-pane)"
eq "inventory: model_primary is 0 on A, 1 on B (the selector's field 11)" "a 0 b 1" \
   "$(run env FLEET_MODEL=fable bash "$WORK/bin/fleet-account.sh" _claude-inventory 2>/dev/null | awk -F'\t' '{printf "%s%s %s",s,$1,$11; s=" "}')"
m1=$(cksum < "$LEDGER"); fetch
eq "sync: the same reading again does not rewrite the ledger" "$m1" "$(cksum < "$LEDGER")"

# --- every account capped → the fallback ------------------------------------------
payload "$(fm rejected 100 $RA)" "$(fm rejected 100 $RB)"
fetch
eq "both capped: B's cap is recorded too" "$(( RB + 60 ))" "$(acct model-limited-until b fable)"
got=$(spawn)
eq "both capped: the spawn launches on FLEET_MODEL_FALLBACK" opus "${got#* }"
eq "both capped: …on the ordinary best account" tok-a "${got% *}"

# --- the window opens again → ccquota's own row is dropped -------------------------
payload "$(fm allowed 0 $((RA + 7 * 86400)))" "$(fm rejected 100 $RB)"
fetch
eq "reopened: A's ccquota row dropped" 0 "$(acct model-limited-until a fable)"
eq "reopened: B still capped" "$(( RB + 60 ))" "$(acct model-limited-until b fable)"
eq "reopened: the spawn is back on A with FLEET_MODEL" "tok-a fable" "$(spawn)"

# --- a banner is a refresh hint: only a NEWER reading clears it ----------------
reset_state
printf 'a\tfable\t%s\treached your Fable limit\t%s\n' $(( NOW + 604800 )) $(( NOW - 10 )) > "$LEDGER"
payload "$(fm allowed 50 $RA $(( NOW - 60 )))" -
fetch
eq "banner row newer than the reading survives it" $(( NOW + 604800 )) "$(acct model-limited-until a fable)"
payload "$(fm allowed 50 $RA $NOW)" -
fetch
eq "…and a reading observed after it clears it" 0 "$(acct model-limited-until a fable)"
printf 'a\tfable\t%s\treached your Fable limit\t%s\n' $(( NOW + 604800 )) $(( NOW - 10 )) > "$LEDGER"
payload "$(fm rejected 100 $RA)" -
fetch
eq "a capped reading replaces the banner's TTL guess with the real reset" "$(( RA + 60 ))" "$(acct model-limited-until a fable)"
eq "…as ONE row" 1 "$(grep -c . "$LEDGER")"
payload "$(fm rejected 100 $(( NOW - 5 )))" -
fetch
eq "a capped reading whose reset has passed is stale — not written" "$(( RA + 60 ))" "$(acct model-limited-until a fable)"
printf 'b\topus\t%s\treached your Opus limit\t%s\n' $(( NOW + 600 )) $(( NOW - 999 )) >> "$LEDGER"
payload - "$(fm allowed 0 $RB $NOW)"
fetch
eq "a fable reading never touches another model's row" $(( NOW + 600 )) "$(acct model-limited-until b opus)"

# --- the banner writer keeps its row one field wide and stamps set-at -----------
reset_state
acct model-limited a fable $'hit your Fable limit\twith a tab' >/dev/null
eq "model-limited: 5 fields, set-at last" 5 "$(awk -F'\t' '{print NF}' "$LEDGER")"

# --- the provider-aware selector: FLEET_MODEL first, then score -------------------
got=$(python3 - "$WORK/bin/.fleet-account.py" <<'PY'
import runpy, sys
m = runpy.run_path(sys.argv[1], run_name='selftest')
def row(label, score, primary):
    return dict(agent='claude', label=label, account=label, key='claude/' + label, available=True,
                utilization=10, score=score, limited_until=0, hold_until=0, reset_at=0,
                login='valid', model_ok=True, model_primary=primary)
d = {'accounts': [row('a', 200, False), row('b', 150, True)]}
print(m['choose'](d, 'claude', allowed=('claude',))['target']['label'],
      m['choose'](d, 'claude', current='claude/a', allowed=('claude',))['target']['label'],
      m['choose']({'accounts': [row('a', 200, False), row('b', 195, False)]}, 'claude', current='claude/b', allowed=('claude',))['target']['label'])
PY
)
eq "selector: model_primary beats score; hysteresis never keeps a fallback-only current; ties keep hysteresis" "b b b" "$got"

printf 'fleet-model-quota-selftest: %d checks passed\n' "$CHECKS"
