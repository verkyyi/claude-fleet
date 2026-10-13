#!/bin/bash
# fleet-hub-notify-selftest.sh — the hub image's FLEET_NOTIFY_CMD (issue #4086):
# tokenledger/notify/fleet-hub-notify.sh is one path that execs `ccquota notify`
# (its logic and tests: tokenledger/cmd/ccquota/notify.go, notify_test.go).
#
#   A. delegate  it execs `ccquota notify -- <the message>` unchanged (a stub
#                ccquota on PATH records its argv)
#   B. image     the Dockerfile copies it to /usr/local/bin/fleet-hub-notify, and
#                it is executable in git (the COPY keeps the mode)
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
N="$ROOT/tokenledger/notify/fleet-hub-notify.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/hub-notify-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

mkdir -p "$WORK/stub"
printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "$STUB_LOG"\nexit 7\n' > "$WORK/stub/ccquota"
chmod 755 "$WORK/stub/ccquota"
export STUB_LOG="$WORK/argv"
msg='svc_degraded svc:livepage: 3 "failed"
code=infra_error'
PATH="$WORK/stub:$PATH" sh "$N" "$msg"; rc=$?
want=$(printf 'notify\n--\n%s' "$msg")
[ "$rc" = 7 ] && [ "$(cat "$STUB_LOG")" = "$want" ] && ok "A execs ccquota notify with the message" \
  || bad "A rc=$rc argv=$(cat "$STUB_LOG" 2>/dev/null)"

grep -qx 'COPY notify/fleet-hub-notify.sh /usr/local/bin/fleet-hub-notify' "$ROOT/tokenledger/Dockerfile" \
  && ok "B Dockerfile copies it" || bad "B Dockerfile line missing"
if git -C "$ROOT" ls-files -s tokenledger/notify/fleet-hub-notify.sh 2>/dev/null | grep -q '^100755'; then
  ok "B executable in git"
elif [ -x "$N" ]; then ok "B executable (not a checkout)"; else bad "B not executable"; fi

[ "$fail" = 0 ] && echo "hub-notify selftest: PASS" || echo "hub-notify selftest: FAIL"
exit "$fail"
