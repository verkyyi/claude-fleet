#!/bin/bash
# fleet-account-quota-why-selftest.sh — `fleet-account.sh quota` never answers an
# empty read in silence (issue #2588).
#
# An EPIC run loop asked `fleet-account.sh quota` six times from a session pane
# and got exit 0 with stdout AND stderr empty every time: the pane has no
# CCQUOTA_HUB_URL (the fleet conf keeps FLEET_HUB_URL, the node's URL is in
# node.env), and quota_fetch returned before asking anyone. Now the hub URL falls
# back through FLEET_HUB_URL and node.env, and a read with no row says why on
# stderr and exits 4 (nothing configured) or 3 (configured, no reading now).
#
#   A  rows → exit 0, rows on stdout, nothing on stderr
#   B  hub only as FLEET_HUB_URL (a pane) → still fetched, rows, exit 0
#   C  hub only in node.env → still fetched, rows, exit 0
#   D  no hub anywhere → exit 4 「quota none — no ccquota hub」
#   E  no pool account → exit 4 「quota none — no pool account」
#   F  the hub refuses (401) → exit 3 「quota unknown — hub refused: … HTTP 401」
#   G  --cached with nothing cached yet → exit 3 「no reading cached yet」
#   H  the hub answers, no account maps to a pool label → exit 3 「no account maps」
#   I  a hub but no ccquota on PATH → exit 3 「not on PATH」
#   J  --json keeps its contract (the payload, exit 0) with the hub from FLEET_HUB_URL
#
# Hermetic: a FAKE ccquota, scratch pool / conf / TMPDIR / HOME. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
NEED="fleet-account.sh fleet-lib.sh"
for f in $NEED; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/quota-why-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/nopath" "$WORK/accounts" "$WORK/empty" "$WORK/conf"
for f in $NEED fleet-config-lib.sh fleet_iso.py usage-lib.sh fleet-daemon-lib.sh; do [ -f "$BIN/$f" ] && cp "$BIN/$f" "$WORK/bin/"; done
chmod +x "$WORK/bin/"*.sh
printf 'tok-a\n' > "$WORK/accounts/a"; printf 'tok-b\n' > "$WORK/accounts/b"
chmod 600 "$WORK/accounts/a" "$WORK/accounts/b"
MODE="$WORK/mode"

cat > "$WORK/fakepath/ccquota" <<'FAKE'
#!/bin/bash
[ "${1:-}" = version ] && { printf 'ccquota 9.9.9-testbuild\n'; exit 0; }
printf '%s\n' "${CCQUOTA_HUB_URL:-none}" > "${FAKE_MODE_FILE%/*}/ccquota.hub"
case "$(cat "$FAKE_MODE_FILE" 2>/dev/null)" in
  refused) printf '{"verdict":"unknown","reason":"hub unreachable: HTTP 401: {\\"error\\":\\"unauthorized\\"}","accounts":null}\n' ;;
  other)   printf '{"verdict":"go","accounts":[{"account_uuid":"u-z","label":"zed","headroom_pct":70,"five_hour":{"utilization":30,"resets_at":"2030-09-16T05:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2030-09-16T05:00:00Z"}}]}\n' ;;
  *) printf '{"verdict":"go","accounts":[{"account_uuid":"u-a","label":"a","headroom_pct":70,"five_hour":{"utilization":30,"resets_at":"2030-09-16T05:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2030-09-16T05:00:00Z"}},{"account_uuid":"u-b","label":"b","headroom_pct":80,"five_hour":{"utilization":20,"resets_at":"2030-09-16T05:00:00Z"},"seven_day":{"utilization":10,"resets_at":"2030-09-16T05:00:00Z"}}]}\n' ;;
esac
exit 0
FAKE
chmod +x "$WORK/fakepath/ccquota"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ $# -gt 1 ] && printf -- '--- got ---\n%s\n' "$2" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS+1)); }
# q <path-dir> <accounts-dir> [env…] -- quota args… → $OUT $ERR $RC, a fresh cache each time
q() {
  local pdir="$1" adir="$2"; shift 2
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  rm -rf "$WORK/.claude-dash"; mkdir -p "$WORK/.claude-dash/global"
  env -u CCQUOTA_HUB_URL -u FLEET_HUB_URL -u CCQUOTA_TOKEN -u CCQUOTA_VIEWER_TOKEN \
    PATH="$pdir:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
    FLEET_CONF_DIR="$WORK/conf" FLEET_ACCOUNTS_DIR="$adir" FLEET_C="$WORK/.claude-dash" \
    FAKE_MODE_FILE="$MODE" ${envs[@]+"${envs[@]}"} \
    bash "$WORK/bin/fleet-account.sh" quota "$@" >"$WORK/out" 2>"$WORK/err"
  RC=$?; OUT=$(cat "$WORK/out"); ERR=$(cat "$WORK/err")
}
HUB=CCQUOTA_HUB_URL=http://hub.test:8787

# --- A: rows ------------------------------------------------------------------
printf 'rows' > "$MODE"
q "$WORK/fakepath" "$WORK/accounts" "$HUB" -- --refresh
[ "$RC" = 0 ] || fail "A: rows exit 0 (got $RC)" "$ERR"
[ "$(printf '%s\n' "$OUT" | grep -c .)" = 2 ] || fail "A: two rows on stdout" "$OUT"
[ -z "$ERR" ] || fail "A: a read with rows says nothing on stderr" "$ERR"
ok

# --- B: the pane — FLEET_HUB_URL only ------------------------------------------
q "$WORK/fakepath" "$WORK/accounts" FLEET_HUB_URL=http://fleet-hub.test -- --refresh
[ "$RC" = 0 ] || fail "B: FLEET_HUB_URL alone must be enough to read (got $RC)" "$ERR"
[ "$(printf '%s\n' "$OUT" | grep -c .)" = 2 ] || fail "B: rows from a pane with FLEET_HUB_URL only" "$OUT"
[ "$(cat "$WORK/ccquota.hub")" = http://fleet-hub.test ] || fail "B: ccquota is handed FLEET_HUB_URL as CCQUOTA_HUB_URL" "$(cat "$WORK/ccquota.hub")"
ok

# --- C: node.env only ---------------------------------------------------------
printf 'CCQUOTA_HUB_URL=http://node-hub.test\nCCQUOTA_TOKEN=nodetok\n' > "$WORK/conf/node.env"; chmod 600 "$WORK/conf/node.env"
q "$WORK/fakepath" "$WORK/accounts" -- --refresh
[ "$RC" = 0 ] || fail "C: node.env's hub must be enough to read (got $RC)" "$ERR"
[ "$(cat "$WORK/ccquota.hub")" = http://node-hub.test ] || fail "C: ccquota is handed node.env's hub" "$(cat "$WORK/ccquota.hub")"
rm -f "$WORK/conf/node.env"
ok

# --- D: no hub anywhere --------------------------------------------------------
q "$WORK/fakepath" "$WORK/accounts" -- --refresh
[ "$RC" = 4 ] || fail "D: no hub → exit 4 (got $RC)" "$ERR"
[ -z "$OUT" ] || fail "D: no rows" "$OUT"
case "$ERR" in *"quota none — no ccquota hub configured"*) ;; *) fail "D: stderr names the missing hub" "$ERR" ;; esac
ok

# --- E: no pool account --------------------------------------------------------
q "$WORK/fakepath" "$WORK/empty" "$HUB" -- --refresh
[ "$RC" = 4 ] || fail "E: no pool → exit 4 (got $RC)" "$ERR"
case "$ERR" in *"quota none — no pool account"*) ;; *) fail "E: stderr names the empty pool" "$ERR" ;; esac
ok

# --- F: the hub refuses --------------------------------------------------------
printf 'refused' > "$MODE"
q "$WORK/fakepath" "$WORK/accounts" "$HUB" -- --refresh
[ "$RC" = 3 ] || fail "F: a refused read → exit 3 (got $RC)" "$ERR"
case "$ERR" in *"quota unknown — hub refused: "*"HTTP 401"*) ;; *) fail "F: stderr says refused, with the hub's words" "$ERR" ;; esac
ok

# --- G: --cached, nothing cached -----------------------------------------------
printf 'rows' > "$MODE"
q "$WORK/fakepath" "$WORK/accounts" "$HUB" -- --cached
[ "$RC" = 3 ] || fail "G: an empty cache → exit 3 (got $RC)" "$ERR"
case "$ERR" in *"quota unknown — no reading cached yet"*) ;; *) fail "G: stderr says nothing is cached" "$ERR" ;; esac
ok

# --- H: answered, nothing maps -------------------------------------------------
printf 'other' > "$MODE"
q "$WORK/fakepath" "$WORK/accounts" "$HUB" -- --refresh
[ "$RC" = 3 ] || fail "H: no label maps → exit 3 (got $RC)" "$ERR"
case "$ERR" in *"quota unknown — "*) ;; *) fail "H: stderr says unknown" "$ERR" ;; esac
case "$ERR" in *"no account maps to a pool label"*|*"hub empty"*) ;; *) fail "H: stderr says the answer mapped to no label" "$ERR" ;; esac
ok

# --- I: no ccquota ---------------------------------------------------------------
q "$WORK/nopath" "$WORK/accounts" "$HUB" -- --refresh
if command -v ccquota >/dev/null 2>&1 && [ "$(command -v ccquota)" != "$WORK/fakepath/ccquota" ] \
   && PATH="$WORK/nopath:/usr/bin:/bin:/usr/sbin:/sbin" command -v ccquota >/dev/null 2>&1; then
  : # a system ccquota under /usr/bin: the leg cannot hide it — skip
else
  [ "$RC" = 3 ] || fail "I: no ccquota with a hub → exit 3 (got $RC)" "$ERR"
  case "$ERR" in *"quota unknown — ccquota is not on PATH"*) ;; *) fail "I: stderr names the missing binary" "$ERR" ;; esac
fi
ok

# --- J: --json -------------------------------------------------------------------
printf 'rows' > "$MODE"
q "$WORK/fakepath" "$WORK/accounts" FLEET_HUB_URL=http://fleet-hub.test -- --json
[ "$RC" = 0 ] || fail "J: --json exits 0 (got $RC)" "$ERR"
case "$OUT" in *'"accounts"'*) ;; *) fail "J: --json prints the payload with FLEET_HUB_URL only" "$OUT" ;; esac
ok

printf 'fleet-account-quota-why-selftest: %d checks passed\n' "$CHECKS"
