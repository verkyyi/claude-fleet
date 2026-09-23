#!/bin/bash
# fleet-doctor-webhook-selftest.sh — bin/fleet-doctor.sh's webhook row counts the
# repos the daemon actually FORWARDS (issue #1004), resolved per hosted repo the
# way `fleet-webhook.sh --desired` does.
#
# Before #1004 the row grepped each fleet conf for a literal FLEET_WEBHOOK=1, so a
# login-wide opt-in (the live install sets it in fleet.conf) printed NO webhook row
# at all while the daemon forwarded three repos, and a repos/<slug>.conf overlay
# opt-in (per repo since #800) was invisible too.
#
# Sandbox: fleet-a hosts o/alpha (conf) + o/beta (overlay); fleet-b hosts o/alpha
# too. A sandbox bin/../fleet.conf is the install-wide layer; a PATH-shim `gh`
# reports the gh-webhook extension. Pinned:
#   1. global opt-in only → PASS, every hosted repo named, o/alpha counted ONCE;
#   2. overlay-only opt-in → exactly o/beta (o/alpha stays off);
#   3. an overlay FLEET_WEBHOOK=0 beats the global 1 for that repo alone;
#   4. nobody opts in → no webhook row;
#   5. degenerate: one-repo fleet conf FLEET_WEBHOOK=1 → exactly that repo;
#   6. the row agrees with `fleet-webhook.sh --desired` on the same sandbox.
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
for f in fleet-doctor.sh fleet-daemon-lib.sh fleet-trust.sh fleet-lib.sh fleet-webhook.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/doctor-webhook-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/home" "$WORK/shim" "$WORK/conf/fleets/fleet-a/repos" "$WORK/conf/fleets/fleet-b"
for f in fleet-doctor.sh fleet-daemon-lib.sh fleet-trust.sh fleet-lib.sh fleet-webhook.sh; do cp "$BIN/$f" "$WORK/bin/"; done
chmod +x "$WORK/bin/"*.sh

cat > "$WORK/shim/gh" <<'EOF'
#!/bin/sh
[ "$1 $2" = "extension list" ] && echo 'gh webhook	cli/gh-webhook	v0.0.1'
exit 0
EOF
chmod +x "$WORK/shim/gh"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; printf -- '--- stdout ---\n%s\n--- stderr ---\n%s\n' "$(cat "$WORK/stdout" 2>/dev/null)" "$(cat "$WORK/stderr" 2>/dev/null)" >&2; exit 1; }
ok() { CHECKS=$((CHECKS + 1)); }

# setup <global 1|''> <fleet-a conf value|''> <o-beta overlay value|''> <fleet-b 1|0>
setup() {
  if [ -n "$1" ]; then printf 'FLEET_WEBHOOK=%s\n' "$1" > "$WORK/fleet.conf"; else rm -f "$WORK/fleet.conf"; fi
  { echo 'FLEET_REPO="o/alpha"'; [ -n "$2" ] && echo "FLEET_WEBHOOK=$2"; } > "$WORK/conf/fleets/fleet-a/conf"
  { echo 'FLEET_REPO="o/beta"'; [ -n "$3" ] && echo "FLEET_WEBHOOK=$3"; } > "$WORK/conf/fleets/fleet-a/repos/o-beta.conf"
  if [ "$4" = 1 ]; then echo 'FLEET_REPO="o/alpha"' > "$WORK/conf/fleets/fleet-b/conf"; else rm -f "$WORK/conf/fleets/fleet-b/conf"; fi
}
# The global layer is the point here, so the gate's FLEET_SKIP_GLOBAL_CONF is
# dropped: the only fleet.conf in reach is the sandbox's own.
run_doctor() {
  env -u FLEET_SKIP_GLOBAL_CONF HOME="$WORK/home" TMPDIR="$WORK" FLEET_CONF_DIR="$WORK/conf" \
    PATH="$WORK/shim:$PATH" sh "$WORK/bin/fleet-doctor.sh" >"$WORK/stdout" 2>"$WORK/stderr"
  grep -q 'unbound variable' "$WORK/stderr" && fail "doctor died on an unbound variable"
  return 0
}
whrow() { grep -E '^[[:space:]]+(PASS|WARN|FAIL)[[:space:]]+webhook[[:space:]]' "$WORK/stdout"; }

# 1. global opt-in only
setup 1 '' '' 1; run_doctor
r=$(whrow) || fail "1: global FLEET_WEBHOOK=1 printed no webhook row"
printf '%s' "$r" | grep -Eq 'PASS[[:space:]]+webhook[[:space:]]+2 repo\(s\) forwarded \(o/alpha, o/beta\)' \
  || fail "1: expected PASS naming o/alpha, o/beta once each, got: $r"; ok

# 6. agrees with the daemon's own resolution on the same sandbox
want=$(env -u FLEET_SKIP_GLOBAL_CONF HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" FLEET_WEBHOOK_STATE_DIR="$WORK/wh" \
  bash "$WORK/bin/fleet-webhook.sh" --desired fleet-a fleet-b 2>/dev/null | paste -sd, - | sed 's/,/, /g')
[ "$want" = "o/alpha, o/beta" ] || fail "6: fleet-webhook.sh --desired gave '$want'"
printf '%s' "$r" | grep -Fq "($want)" || fail "6: doctor row disagrees with --desired ($want): $r"; ok

# 2. overlay-only opt-in
setup '' '' 1 0; run_doctor
r=$(whrow) || fail "2: overlay FLEET_WEBHOOK=1 printed no webhook row"
printf '%s' "$r" | grep -Eq '1 repo\(s\) forwarded \(o/beta\)' || fail "2: expected only o/beta, got: $r"; ok

# 3. overlay 0 beats global 1 for that repo alone
setup 1 '' 0 0; run_doctor
r=$(whrow) || fail "3: no webhook row"
printf '%s' "$r" | grep -Eq '1 repo\(s\) forwarded \(o/alpha\)' || fail "3: expected only o/alpha, got: $r"; ok

# 4. nobody opts in
setup '' '' '' 1; run_doctor
whrow >/dev/null && fail "4: webhook row printed with no opt-in: $(whrow)"; ok

# 5. degenerate one-repo fleet (no overlay dir contents)
rm -f "$WORK/conf/fleets/fleet-a/repos/o-beta.conf"
{ echo 'FLEET_REPO="o/alpha"'; echo 'FLEET_WEBHOOK=1'; } > "$WORK/conf/fleets/fleet-a/conf"
rm -f "$WORK/fleet.conf" "$WORK/conf/fleets/fleet-b/conf"; run_doctor
r=$(whrow) || fail "5: fleet conf FLEET_WEBHOOK=1 printed no webhook row"
printf '%s' "$r" | grep -Eq 'PASS[[:space:]]+webhook[[:space:]]+1 repo\(s\) forwarded \(o/alpha\)' || fail "5: got: $r"; ok

printf 'fleet-doctor-webhook-selftest: PASS (%d checks)\n' "$CHECKS"
