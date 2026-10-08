#!/bin/bash
# fleet-break-it-tenant-selftest.sh — the docs/BREAK-IT.md rows a new ordinary
# login's three lines added (issue #2298, EPIC #2293 C7): each drill builds the
# fake machine of bin/fleet-tenant-scan-selftest.sh (TENANT_SCAN_LIB=1), opens
# the way for real, and passes when bin/fleet-tenant-scan.sh's item goes red on
# it and green again once it is closed. Runner and timing helpers are
# bin/fleet-break-it-cred-selftest.sh's (BREAK_CRED_LIB=1); bin/fleet-break-it-selftest.sh's
# lockstep lint reads the drill names here too.
#
#   tenant-sudo         the login has password-less sudo / sits in the admin group (#2210)
#   tenant-other-home   another login's home, tmux dir, shared-dir file readable
#   preview-no-code     a preview page opened without its code (#1153)
#   bootstrap-abroad    the bootstrap cache missing: opening a login reaches abroad (#2297)
#
# Root (whom chmod 000 does not refuse) → SKIP.
# shellcheck disable=SC2034  # CAP / SECS / WHY / WHAT are read by the sourced runner
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" != 0 ] || { echo "fleet-break-it-tenant: running as root — SKIP"; exit 0; }
# shellcheck source=fleet-break-it-cred-selftest.sh
BREAK_CRED_LIB=1 . "$BIN/fleet-break-it-cred-selftest.sh"
# shellcheck source=fleet-tenant-scan-selftest.sh
TENANT_SCAN_LIB=1 . "$BIN/fleet-tenant-scan-selftest.sh"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; ts_cleanup; cleanup' EXIT

# tenant_round <dir> <item> <open…> -- <close…> — green, open the way → red, close → green
tenant_round() {
  local d="$1" item="$2" t0 opn=() cls=() seen=0 a
  shift 2
  for a in "$@"; do
    if [ "$a" = -- ]; then seen=1; elif [ "$seen" = 0 ]; then opn+=("$a"); else cls+=("$a"); fi
  done
  ts_scan "$d" --only "$item" --no-drill
  ts_row "$item" | grep -q '| PASS |' || { WHY="already red before the break: $(ts_row "$item")"; return 1; }
  t0=$(now)
  ${opn[@]+"${opn[@]}"}
  ts_scan "$d" --only "$item" --no-drill
  ts_row "$item" | grep -q '| HIT |' && [ "$RC" = 1 ] || { WHY="the way was open, yet $item did not go red (rc $RC): $(ts_row "$item")"; return 1; }
  HITROW=$(ts_row "$item")
  ${cls[@]+"${cls[@]}"}
  ts_scan "$d" --only "$item" --no-drill
  SECS=$(since "$t0")
  ts_row "$item" | grep -q '| PASS |' && [ "$RC" = 0 ] || { WHY="closed again, yet $item stayed red: $(ts_row "$item")"; return 1; }
}

drill_tenant_sudo() {
  CAP=30
  local d="$WORK/sudo"
  ts_build "$d"
  cp "$d/bin/sudo" "$d/sudo.ok"
  tenant_round "$d" sudo sh -c "printf '#!/bin/sh\nexit 0\n' > '$d/bin/sudo'" -- cp "$d/sudo.ok" "$d/bin/sudo" || return 1
  printf '%s' "$HITROW" | grep -q '免密 sudo' || { WHY="red without saying why: $HITROW"; return 1; }
  WHAT="账号有免密 sudo：扫描的 sudo 项变红、写明「免密 sudo」；收回后变绿"
}

drill_tenant_other_home() {
  CAP=30
  local d="$WORK/home"
  ts_build "$d"
  tenant_round "$d" homes chmod 755 "$d/Users/bob" -- chmod 000 "$d/Users/bob" || return 1
  tenant_round "$d" tmux chmod 700 "$d/tmp/tmux-12345" -- chmod 000 "$d/tmp/tmux-12345" || return 1
  tenant_round "$d" shared chmod 644 "$d/shared/other/t.jsonl" -- chmod 000 "$d/shared/other/t.jsonl" || return 1
  printf '%s' "$HITROW" | grep -q 'secret plan' && { WHY="the scan printed another login's file content"; return 1; }
  WHAT="别人的家目录 / tmux 目录 / 共享目录里的文件一打开，homes、tmux、shared 三项各自变红（只报路径不报内容）；关上后变绿"
}

drill_preview_no_code() {
  CAP=30
  local d="$WORK/prev" p2 i
  ts_build "$d"
  mkdir -p "$d/www" && printf '<title>open</title>\n' > "$d/www/index.html"
  p2=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  (cd "$d/www" && exec python3 -m http.server --bind 127.0.0.1 "$p2") >/dev/null 2>&1 &
  TS_PIDS="$TS_PIDS $!"
  i=0; until curl -s -o /dev/null "http://127.0.0.1:$p2/" 2>/dev/null || [ "$i" -ge 50 ]; do sleep 0.1; i=$((i + 1)); done
  tenant_round "$d" preview sh -c "printf '%s %s\n' '$TS_PORT' '$p2' > '$d/ports'" -- sh -c "printf '%s\n' '$TS_PORT' > '$d/ports'" || return 1
  printf '%s' "$HITROW" | grep -q ":$p2/" || { WHY="red, but not on the open server's port: $HITROW"; return 1; }
  printf '%s' "$HITROW" | grep -q ":$TS_PORT" && { WHY="doc-preview's server.py answered without a code: $HITROW"; return 1; }
  WHAT="同机一个匿名可读的 http.server：preview 项变红、给出端口和标题；doc-preview 的 server.py 不带码一律 404"
}

drill_bootstrap_abroad() {
  CAP=30
  local d="$WORK/boot"
  ts_build "$d"
  chmod -R u+w "$d/ro"
  tenant_round "$d" bootstrap mv "$d/ro/cache" "$d/ro/cache.off" -- mv "$d/ro/cache.off" "$d/ro/cache" || return 1
  printf '%s' "$HITROW" | grep -q 'github.com' && printf '%s' "$HITROW" | grep -q 'claude.ai' \
    || { WHY="red without naming both addresses: $HITROW"; return 1; }
  WHAT="本机没有开号缓存：bootstrap 项变红、记 github.com 与 claude.ai 两处；缓存放回后变绿"
}

cred_run_drills "$0"
