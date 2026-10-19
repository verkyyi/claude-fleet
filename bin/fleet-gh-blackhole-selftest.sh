#!/bin/bash
# fleet-gh-blackhole-selftest.sh — the live half of the GitHub black-hole drill
# (bin/fleet-gh-blackhole.sh, issue #4840) against a FAKE pfctl / launchctl / nft /
# systemd-run / id: nothing here touches a real packet filter or a real login.
#
#   A  plan prints the rules for the test login's uid (meta's ranges + hosts), loads nothing
#   B  refused: no --user, root, a system uid, the person's own login
#   C  macOS apply → the deadline armed BEFORE a rule is loaded; revert → the anchor
#      empty, pf's enable token released, the LaunchDaemon gone
#   D  revert --if-expired: nothing before the deadline, everything after it
#   E  Linux apply: skuid rules whose elements time out in the kernel, a systemd-run
#      timer; revert deletes the table
#   F  a second apply refused while one is on; refuse mode = block return / reject
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
CLI="$BIN/fleet-gh-blackhole.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ghbh-live.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
for v in $(compgen -e | grep -E '^FLEET_GH_BLACKHOLE_'); do unset "$v"; done
unset SUDO_USER

fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- got ---\n%s\n' "$2" >&2; exit 1; }
ok() { printf 'ok   %s\n' "$1"; }

F="$WORK/fake"; mkdir -p "$F"
LOG="$WORK/calls"; : > "$LOG"
ME=$(id -un)
cat > "$F/id" <<EOF
#!/bin/sh
# drilluser is the test login; root is 0; daemon a system account; anyone else: the real id
case "\$*" in
  '-u drilluser') echo 4840 ;;
  '-u root') echo 0 ;;
  '-u daemon') echo 1 ;;
  '-u $ME') echo 501 ;;
  *) exec /usr/bin/id "\$@" ;;
esac
EOF
cat > "$F/pfctl" <<EOF
#!/bin/sh
printf 'pfctl %s\n' "\$*" >> "$LOG"
case "\$*" in
  *' -f '*) eval "f=\\\${\$#}"; cp "\$f" "$WORK/anchor" ;;
  *'-F all'*) : > "$WORK/anchor" ;;
  -E) echo 'No ALTQ support in kernel' >&2; echo 'pf enabled' >&2; echo 'Token : 9876543210' >&2 ;;
esac
exit 0
EOF
cat > "$F/launchctl" <<EOF
#!/bin/sh
printf 'launchctl %s\n' "\$*" >> "$LOG"; exit 0
EOF
cat > "$F/nft" <<EOF
#!/bin/sh
printf 'nft %s\n' "\$*" >> "$LOG"
case "\$1" in -f) cp "\$2" "$WORK/table" ;; delete) : > "$WORK/table" ;; esac
exit 0
EOF
cat > "$F/systemd-run" <<EOF
#!/bin/sh
printf 'systemd-run %s\n' "\$*" >> "$LOG"; exit 0
EOF
chmod +x "$F"/*
printf '{"web":["140.82.112.0/20","2a0a:a440::/29"],"api":["192.30.252.0/22"],"git":["140.82.112.0/20"],"pages":["185.199.108.0/22"],"hooks":["9.9.9.0/24"]}\n' > "$WORK/meta.json"

run() {  # run <os> <args…> → OUT RC
  OUT=$(env PATH="$F:$PATH" FLEET_GH_BLACKHOLE_OS="$1" FLEET_GH_BLACKHOLE_STATE="$WORK/state" \
    FLEET_GH_BLACKHOLE_LAUNCHD="$WORK/LaunchDaemons" FLEET_GH_BLACKHOLE_ROOT_OK=1 \
    bash "$CLI" "${@:2}" 2>&1); RC=$?
}

# --- A ---
run Darwin plan --user drilluser --meta "$WORK/meta.json"
[ "$RC" = 0 ] || fail "A plan exited $RC" "$OUT"
case "$OUT" in *"block drop out quick proto { tcp udp } from any to <fleet_gh> user 4840"*) ;; *) fail "A plan has no uid-scoped drop rule" "$OUT" ;; esac
case "$OUT" in *140.82.112.0/20*2a0a:a440::/29*api.github.com*raw.githubusercontent.com*) ;; *) fail "A plan lacks the meta ranges or the hosts" "$OUT" ;; esac
case "$OUT" in *9.9.9.0/24*) fail "A plan took a meta key outside web·api·git·pages" "$OUT" ;; esac
[ "$(grep -o '140.82.112.0/20' <<<"$OUT" | wc -l | tr -d ' ')" = 1 ] || fail "A a range listed twice" "$OUT"
[ ! -s "$LOG" ] || fail "A plan ran a tool" "$(cat "$LOG")"
[ ! -e "$WORK/state/applied" ] || fail "A plan wrote state"
run Darwin plan --user drilluser --meta "$WORK/none.json"
case "$OUT" in *"built-in list"*140.82.112.0/20*) ;; *) fail "A no meta stored must fall back to the built-in list, and say so" "$OUT" ;; esac
ok "A plan prints the uid-scoped rules (meta ranges + hosts, built-in without a copy) and loads nothing"

# --- B ---
run Darwin plan;                         [ "$RC" = 2 ] || fail "B no --user must refuse (2), got $RC" "$OUT"
run Darwin plan --user root;             [ "$RC" = 2 ] && case "$OUT" in *root*) ;; *) false ;; esac || fail "B root must be refused" "$OUT"
run Darwin plan --user daemon;           [ "$RC" = 2 ] || fail "B a system uid must be refused, got $RC" "$OUT"
run Darwin apply --user "$ME";           [ "$RC" = 2 ] && case "$OUT" in *"never your own"*) ;; *) false ;; esac || fail "B the caller's own login must be refused" "$OUT"
OUT=$(env SUDO_USER=drilluser PATH="$F:$PATH" FLEET_GH_BLACKHOLE_OS=Darwin FLEET_GH_BLACKHOLE_STATE="$WORK/state" \
  FLEET_GH_BLACKHOLE_ROOT_OK=1 bash "$CLI" apply --user drilluser 2>&1); RC=$?
[ "$RC" = 2 ] || fail "B \$SUDO_USER (the person behind sudo) must be refused, got $RC" "$OUT"
[ ! -s "$LOG" ] || fail "B a refusal ran a tool" "$(cat "$LOG")"
ok "B refused: no --user · root · a system uid · the caller · \$SUDO_USER — before any tool runs"

# --- C ---
run Darwin apply --user drilluser --meta "$WORK/meta.json"
[ "$RC" = 0 ] || fail "C apply exited $RC" "$OUT"
grep -q 'user 4840' "$WORK/anchor" || fail "C the anchor holds no rule" "$(cat "$WORK/anchor" 2>/dev/null)"
grep -q "pfctl -a com.apple/fleet-gh-blackhole -f " "$LOG" || fail "C not loaded into the com.apple/ anchor" "$(cat "$LOG")"
b=$(grep -n 'launchctl bootstrap system' "$LOG" | cut -d: -f1); l=$(grep -n 'pfctl .* -f ' "$LOG" | cut -d: -f1)
[ -n "$b" ] && [ -n "$l" ] && [ "$b" -lt "$l" ] || fail "C the deadline must be armed BEFORE the rules load" "$(cat "$LOG")"
P="$WORK/LaunchDaemons/com.claude-fleet.gh-blackhole-revert.plist"
grep -q "$WORK/state/revert.sh" "$P" && grep -q -- '--if-expired' "$P" && grep -q '<integer>60</integer>' "$P" \
  || fail "C the LaunchDaemon must run the root copy's revert --if-expired every minute" "$(cat "$P" 2>/dev/null)"
cmp -s "$CLI" "$WORK/state/revert.sh" || fail "C the reverter is not a copy of the script"
grep -qx 'token=9876543210' "$WORK/state/applied" || fail "C pf's enable token not kept" "$(cat "$WORK/state/applied")"
run Darwin status; case "$OUT" in "applied: drilluser (uid 4840) · drop ·"*) ;; *) fail "C status" "$OUT" ;; esac
: > "$LOG"
run Darwin revert
[ "$RC" = 0 ] || fail "C revert exited $RC" "$OUT"
[ ! -s "$WORK/anchor" ] || fail "C the anchor still holds rules after revert" "$(cat "$WORK/anchor")"
grep -qx 'pfctl -X 9876543210' "$LOG" || fail "C pf's enable token not released" "$(cat "$LOG")"
grep -q 'launchctl bootout system/com.claude-fleet.gh-blackhole-revert' "$LOG" || fail "C the deadline not booted out" "$(cat "$LOG")"
[ ! -e "$P" ] && [ ! -e "$WORK/state/applied" ] || fail "C the plist / state survived revert"
run Darwin status; [ "$OUT" = 'not applied' ] || fail "C status after revert" "$OUT"
ok "C macOS: deadline armed first, rules in the com.apple/ anchor; revert empties it, releases the token, removes the deadline"

# --- D ---
run Darwin apply --user drilluser --minutes 5
: > "$LOG"
run Darwin revert --if-expired
[ "$RC" = 0 ] && [ ! -s "$LOG" ] && [ -s "$WORK/state/applied" ] || fail "D revert --if-expired before the deadline must do nothing" "$OUT $(cat "$LOG")"
sed -i.bak 's/^until=.*/until=1/' "$WORK/state/applied"
run Darwin revert --if-expired
[ ! -e "$WORK/state/applied" ] && [ ! -s "$WORK/anchor" ] || fail "D past the deadline the minute's tick must revert" "$OUT"
ok "D the minute's revert --if-expired waits for the deadline, then takes everything out"

# --- E ---
: > "$LOG"
run Linux apply --user drilluser --meta "$WORK/meta.json" --minutes 30
[ "$RC" = 0 ] || fail "E Linux apply exited $RC" "$OUT"
grep -q 'meta skuid 4840 ip daddr @gh4 drop' "$WORK/table" && grep -q 'meta skuid 4840 ip6 daddr @gh6 drop' "$WORK/table" \
  || fail "E the nft table has no skuid rules" "$(cat "$WORK/table")"
grep -q 'flags interval, timeout; timeout 30m' "$WORK/table" || fail "E the set elements must time out in the kernel" "$(cat "$WORK/table")"
grep -q 'systemd-run .*--on-active=30m' "$LOG" || fail "E no systemd-run timer" "$(cat "$LOG")"
run Linux revert
grep -q 'nft delete table inet fleet_gh_blackhole' "$LOG" && [ ! -s "$WORK/table" ] || fail "E revert must delete the table" "$(cat "$LOG")"
ok "E Linux: skuid rules whose elements time out in the kernel + a systemd-run timer; revert deletes the table"

# --- F ---
run Darwin apply --user drilluser
run Darwin apply --user drilluser; [ "$RC" = 4 ] || fail "F a second apply must be refused (4), got $RC" "$OUT"
run Darwin revert
run Darwin plan --user drilluser --mode refuse; case "$OUT" in *'block return out quick'*) ;; *) fail "F refuse on pf = block return" "$OUT" ;; esac
run Linux plan --user drilluser --mode refuse; case "$OUT" in *'ip daddr @gh4 reject'*) ;; *) fail "F refuse on nft = reject" "$OUT" ;; esac
run Darwin plan --user drilluser --mode slow; [ "$RC" = 2 ] || fail "F an unknown mode must be refused" "$OUT"
ok "F one apply at a time; refuse mode = block return / reject"
printf 'PASS fleet-gh-blackhole-selftest\n'
