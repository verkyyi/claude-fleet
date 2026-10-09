#!/bin/bash
# fleet-installs-selftest.sh — bin/fleet-installs.sh and `fleet doctor --installs`
# (issue #2692): every install on the machine in one table, judged against stable.
#
# Pinned:
#   A. the three kinds read right — the machine runtime's `current`, a login
#      install that is a versions link, one that is a plain checkout (its HEAD),
#      a client shell whose mirror follows its login's link vs one pinned to a
#      version dir, a client install's .client-version;
#   B. the verdict: all at stable → exit 0; one behind → exit 1 and `≠ stable`;
#      no stable → exit 2;
#   C. --json carries the same facts (at_stable per install, follows per shell);
#   D. a home nobody here can read is `unreadable`, never "no install";
#   E. `fleet-doctor.sh --installs` is the same table and exit code;
#   F. no runtime → "none (not a managed machine)".
# Hermetic: a sandbox homes root, FLEET_INSTALLS_SUDO empty. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
IS="$BIN/fleet-installs.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/installs-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
N=0 BAD=0
ok() { N=$((N + 1)); }
bad() { N=$((N + 1)); BAD=$((BAD + 1)); printf 'FAIL: %s\n' "$1" >&2; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1 — wanted «$3» in:
$2" ;; esac; }
eq() { [ "$2" = "$3" ] && ok || bad "$1 — wanted «$2», got «$3»"; }

S1=1111111111111111111111111111111111111111
S2=2222222222222222222222222222222222222222
H="$WORK/homes"
# alice: a versions-link install at S1, a shell mirrored THROUGH the link
mkdir -p "$H/alice/.claude/fleet.versions/$S1/bin" "$H/alice/.cache/claude-fleet/shell/bin"
ln -s "$H/alice/.claude/fleet.versions/$S1" "$H/alice/.claude/fleet"
( cd "$H/alice/.claude/fleet.versions/$S1" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m a ) || exit 2
: > "$H/alice/.claude/fleet.versions/$S1/bin/fleet-shell.sh"
ln -s "$H/alice/.claude/fleet/bin/fleet-shell.sh" "$H/alice/.cache/claude-fleet/shell/bin/fleet-shell.sh"
# bob: a plain-checkout install, a shell pinned to a version dir with a .client-version
mkdir -p "$H/bob/.claude/fleet" "$H/bob/.cache/claude-fleet/shell/bin" "$H/bob/.local/share/claude-fleet.versions/$S2/bin"
( cd "$H/bob/.claude/fleet" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m b ) || exit 2
B_HEAD=$(git -C "$H/bob/.claude/fleet" rev-parse HEAD)
printf 'version=%s\n' "$S2" > "$H/bob/.local/share/claude-fleet.versions/$S2/.client-version"
: > "$H/bob/.local/share/claude-fleet.versions/$S2/bin/fleet-shell.sh"
ln -s "$H/bob/.local/share/claude-fleet.versions/$S2/bin/fleet-shell.sh" "$H/bob/.cache/claude-fleet/shell/bin/fleet-shell.sh"
mkdir -p "$H/bob/.local/share/claude-fleet"; printf 'version=%s\n' "$S2" > "$H/bob/.local/share/claude-fleet/.client-version"
# carol: nothing at all — not listed
mkdir -p "$H/carol"
# the machine runtime at S1
mkdir -p "$WORK/root/$S1"; ln -s "$WORK/root/$S1" "$WORK/root/current"

run() { OUT=$(FLEET_INSTALLS_HOMES="$H" FLEET_INSTALLS_SUDO='' FLEET_NODE_ROOT="$WORK/root" sh "$IS" "$@" 2>&1); RC=$?; }

# --- A/B. alice's install is the version S1; stable = S1 ----------------------------
FLEET_INSTALLS_STABLE=$S1 run
has "A: runtime read" "$OUT" "machine runtime  1111111  = stable"
has "A: link install = its version" "$OUT" "alice          1111111  = stable"
has "A: plain checkout = its HEAD" "$OUT" "bob            $(printf '%.7s' "$B_HEAD")"
has "A: plain checkout named" "$OUT" "plain checkout"
has "A: alice's shell follows" "$OUT" "(follows its login install)"
has "A: bob's shell pinned" "$OUT" "2222222  ≠ stable  (pinned to one version dir"
has "A: client install read" "$OUT" "(client install)"
case "$OUT" in *carol*) bad "A: a home with no install is not listed" ;; *) ok ;; esac
eq "B: one behind → exit 1" 1 "$RC"
has "B: verdict line" "$OUT" "verdict: 3 of 6 install(s) at stable"

# --- C. --json ---------------------------------------------------------------------
FLEET_INSTALLS_STABLE=$S1 run --json
J=$(printf '%s' "$OUT" | python3 -c 'import json,sys
d=json.load(sys.stdin); L={l["login"]: l for l in d["logins"]}
print(d["runtime"]["version"], d["runtime"]["at_stable"], L["alice"]["install"]["kind"], L["alice"]["install"]["at_stable"],
      L["alice"]["shell"]["follows"], L["alice"]["shell"]["version"] == d["runtime"]["version"], L["bob"]["install"]["kind"],
      L["bob"]["install"]["at_stable"], L["bob"]["shell"]["follows"], L["bob"]["client"]["version"], sorted(L))' 2>&1)
eq "C: json facts" "$S1 True link True True True dir False False $S2 ['alice', 'bob']" "$J"

# --- B. all at stable → 0; no stable → 2 -------------------------------------------
rm -rf "$H/bob"
FLEET_INSTALLS_STABLE=$S1 run
eq "B: all at stable → exit 0" 0 "$RC"
has "B: all verdict" "$OUT" "verdict: 3 of 3 install(s) at stable"
FLEET_INSTALLS_STABLE=$S2 run
has "B: runtime behind" "$OUT" "machine runtime  1111111  ≠ stable"
eq "B: behind → exit 1" 1 "$RC"
rm -f "$WORK/root/current"
FLEET_INSTALLS_STABLE=$S1 run
has "F: no runtime" "$OUT" "machine runtime  none (not a managed machine)"
OUT=$(FLEET_LIVE_DIR="$WORK/nolive" FLEET_INSTALLS_HOMES="$H" FLEET_INSTALLS_SUDO='' FLEET_NODE_ROOT="$WORK/root" FLEET_INSTALLS_STABLE='' sh "$IS" 2>&1); RC=$?
eq "B: no stable → exit 2" 2 "$RC"
has "B: says stable unknown" "$OUT" "stable unknown"

# --- D. unreadable ----------------------------------------------------------------
# A home whose .claude this caller cannot enter, and no one else to ask (it is
# the caller's own, sudo is off): `unreadable`, never a login without an install.
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$H/dave/.claude/fleet"; chmod 000 "$H/dave/.claude"
  FLEET_INSTALLS_STABLE=$S1 run
  has "D: listed unreadable" "$OUT" "unreadable       dave"
  chmod 755 "$H/dave/.claude"; rm -rf "$H/dave"
fi

# --- E. the doctor flag -------------------------------------------------------------
OUT=$(FLEET_INSTALLS_HOMES="$H" FLEET_INSTALLS_SUDO='' FLEET_NODE_ROOT="$WORK/root" FLEET_INSTALLS_STABLE=$S1 sh "$BIN/fleet-doctor.sh" --installs 2>&1); RC=$?
eq "E: doctor --installs exit" 0 "$RC"
has "E: doctor --installs is the table" "$OUT" "claude-fleet installs —"

if [ "$BAD" -gt 0 ]; then printf 'selftest FAIL: %d of %d\n' "$BAD" "$N" >&2; exit 1; fi
printf 'selftest OK: fleet-installs (%d assertions — runtime, link/plain installs, follow/pinned shells, client, verdicts, json, doctor --installs)\n' "$N"
