#!/bin/bash
# fleet-admin-seat-selftest.sh — bin/fleet_admin_seat.py (issue #3696, EPIC #3500
# C15·b): the install step's `ensure` (role account, admin/, the account key
# pinned once, the gate copies, /etc/sudoers.d/fleet-admin exactly two lines),
# `ensure --check`, `status --check`, `remove`, and the seat-off case (a hub with
# no account key ⇒ exit 3, nothing made). A sandbox state / root / sudoers file;
# the role account is the running user (FLEET_ADMIN_ROLE); the hub a one-route
# server on 127.0.0.1. The core's switch placing the gate is
# bin/fleet-node-core-selftest.py G_Switch; the tampering drill is
# bin/fleet-break-it-admin-selftest.sh fleetadmin-gate-tampered.
# shellcheck disable=SC2034  # out / rc are read inside check's eval strings
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fas.XXXXXX")"
PIDS=()
cleanup() { for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT
FAILS=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# hub <dir> <key line|''> — sets URL; '' = 404 (the seat off)
hub() {
  local d="$1" key="$2"
  mkdir -p "$d"
  printf '%s' "$key" > "$d/key"
  python3 - "$d" >/dev/null 2>&1 <<'PY' &
import http.server, os, sys
d = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        key = open(os.path.join(d, "key")).read()
        if self.path != "/v1/fleet/account-key" or not key:
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.end_headers(); self.wfile.write((key + "\n").encode())
    def log_message(self, *a):
        pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(d, "port.tmp"), "w").write(str(s.server_address[1]))
os.rename(os.path.join(d, "port.tmp"), os.path.join(d, "port"))
s.serve_forever()
PY
  PIDS+=($!)
  local i
  for _ in $(seq 50); do [ -f "$d/port" ] && break; sleep 0.1; done
  URL="http://127.0.0.1:$(cat "$d/port")"
}

KEY1="ed25519 $(python3 -c 'import base64; print(base64.b64encode(b"\x01" * 32).decode())')"
KEY2="ed25519 $(python3 -c 'import base64; print(base64.b64encode(b"\x02" * 32).decode())')"
ST="$WORK/state"; ROOT="$WORK/root"; REL="$ROOT/$(printf 'c%.0s' $(seq 40))"
mkdir -p "$ST" "$REL/bin" "$WORK/sudoers.d"
cp "$BIN/fleet-admin-gate.sh" "$REL/bin/"
ln -s "$REL" "$ROOT/current"
ME=$(id -un)
export FLEET_NODE_TEST=1 FLEET_NODE_STATE="$ST" FLEET_NODE_ROOT="$ROOT" FLEET_ADMIN_ROLE="$ME" \
  FLEET_ADMIN_SUDOERS="$WORK/sudoers.d/fleet-admin" FLEET_ADMIN_VISUDO=""
AS=(python3 -I "$BIN/fleet_admin_seat.py")

# A — a hub with no account key: the seat stays off, nothing made
hub "$WORK/hub-off" ""; OFF=$URL
out=$("${AS[@]}" ensure --hub "$OFF" 2>&1); rc=$?
check "A seat off: exit 3, nothing made" '[ "$rc" = 3 ] && [ ! -e "$ST/admin" ] && [ ! -e "$FLEET_ADMIN_SUDOERS" ]'
check "A status on a machine with no seat: off, --check 0" '"${AS[@]}" status --check | grep -q "admin seat  off"'

# B — ensure: everything in place, then --check says converged
hub "$WORK/hub-on" "$KEY1"; ON=$URL
out=$("${AS[@]}" ensure --hub "$ON" --check 2>&1); rc=$?
check "B --check before: 1, nothing written" '[ "$rc" = 1 ] && [ ! -e "$ST/admin" ]'
out=$("${AS[@]}" ensure --hub "$ON" 2>&1); rc=$?
check "B ensure: exit 0 ($out)" '[ "$rc" = 0 ]'
check "B account.pub pinned" '[ "$(cat "$ST/admin/account.pub")" = "$KEY1" ]'
check "B both names are the release's gate" 'cmp -s "$ST/admin/fleet-login-new.sh" "$BIN/fleet-admin-gate.sh" && cmp -s "$ST/admin/fleet-login-remove.sh" "$BIN/fleet-admin-gate.sh"'
check "B admin.conf bin=<root>/current/bin + hub=" '[ "$(cat "$ST/admin/admin.conf")" = "$(printf "bin=%s\nhub=%s" "$ROOT/current/bin" "$ON")" ]'
"${AS[@]}" place --release "$REL" >/dev/null
check "B a switch keeps hub=" 'grep -qx "hub=$ON" "$ST/admin/admin.conf"'
check "B sudoers: exactly one rule line naming the two copies" \
  '[ "$(grep -vc "^#" "$FLEET_ADMIN_SUDOERS")" = 1 ] && grep -qx "$(id -un) ALL=(root) NOPASSWD: $ST/admin/fleet-login-new.sh, $ST/admin/fleet-login-remove.sh" "$FLEET_ADMIN_SUDOERS"'
check "B sudoers mode 0440" '[ "$(python3 -c "import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))" "$FLEET_ADMIN_SUDOERS")" = 0o440 ]'
out=$("${AS[@]}" ensure --hub "$ON" --check 2>&1); rc=$?
check "B --check after: 0 converged ($out)" '[ "$rc" = 0 ]'
check "B status --check: 0" '"${AS[@]}" status --check >/dev/null'

# C — drift: a sudoers line added, a copy edited ⇒ status --check 1; ensure puts it back
chmod 644 "$FLEET_ADMIN_SUDOERS"; echo "$(id -un) ALL=(root) NOPASSWD: ALL" >> "$FLEET_ADMIN_SUDOERS"
echo "# edited" >> "$ST/admin/fleet-login-new.sh"
"${AS[@]}" status --check >/dev/null; rc=$?
check "C status --check sees the drift" '[ "$rc" = 1 ]'
"${AS[@]}" ensure --hub "$ON" >/dev/null 2>&1
check "C ensure: sudoers back to two names, the copy back" \
  '! grep -q "NOPASSWD: ALL" "$FLEET_ADMIN_SUDOERS" && cmp -s "$ST/admin/fleet-login-new.sh" "$BIN/fleet-admin-gate.sh"'

# D — visudo refuses the new text: the old file stays
cp "$FLEET_ADMIN_SUDOERS" "$WORK/sudoers.keep"
chmod 644 "$FLEET_ADMIN_SUDOERS"; echo "# hand edit" >> "$FLEET_ADMIN_SUDOERS"
out=$(FLEET_ADMIN_VISUDO=/usr/bin/false "${AS[@]}" ensure --hub "$ON" 2>&1); rc=$?
check "D visudo -c refuses: ensure fails, the old file untouched" \
  '[ "$rc" != 0 ] && grep -q "hand edit" "$FLEET_ADMIN_SUDOERS" && ! ls "$WORK/sudoers.d" | grep -q tmp-admin'
rm -f "$FLEET_ADMIN_SUDOERS"; cp -p "$WORK/sudoers.keep" "$FLEET_ADMIN_SUDOERS"

# E — the hub's key changed: never re-pinned silently; FLEET_ADMIN_KEY_REPIN=1 does
printf '%s' "$KEY2" > "$WORK/hub-on/key"
out=$("${AS[@]}" ensure --hub "$ON" 2>&1); rc=$?
check "E a rotated key is refused without the repin word" '[ "$rc" = 1 ] && [ "$(cat "$ST/admin/account.pub")" = "$KEY1" ]'
out=$(FLEET_ADMIN_KEY_REPIN=1 "${AS[@]}" ensure --hub "$ON" 2>&1); rc=$?
check "E FLEET_ADMIN_KEY_REPIN=1 pins the new one" '[ "$rc" = 0 ] && [ "$(cat "$ST/admin/account.pub")" = "$KEY2" ]'

# F — remove: the sudoers file and admin/ go
out=$("${AS[@]}" remove 2>&1); rc=$?
check "F remove" '[ "$rc" = 0 ] && [ ! -e "$FLEET_ADMIN_SUDOERS" ] && [ ! -e "$ST/admin" ]'

if [ "$FAILS" = 0 ]; then echo "fleet-admin-seat selftest: OK"; exit 0; fi
echo "fleet-admin-seat selftest: $FAILS FAILED"; exit 1
