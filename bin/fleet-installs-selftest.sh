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
#   G. 来源 (issue #2776): the runtime is hub; a versions-link install with no
#      GitHub remote hub, one whose origin is GitHub github, FLEET_DIST_SOURCE=github
#      in its fleet.conf github, one whose files link into the runtime runtime, a
#      plain checkout dev; a client with a hub= hub, an empty hub= github; the
#      shell takes its install's; the summary counts github; --json carries it.
#   H. the doctor's `dist` row (bin/fleet-dist-source.sh, issue #2776): nothing
#      installed → no line; no hub → INFO; a hub + origin GitHub → WARN naming the
#      fix; + FLEET_DIST_SOURCE=github (conf or env) → WARN; a client with an empty
#      hub= → WARN with the install line; a hub, no GitHub remote, a client with
#      the hub → PASS; the doctor prints it as its `dist` row.
#   L. 落后 (issue #2934): an install not at stable says how long since this
#      machine first saw that stable (install-sync's stable_since, the updater's
#      target_seen — the earliest); past 30m WARN on the row + a closing line.
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

run() { OUT=$(FLEET_INSTALLS_HOMES="$H" FLEET_INSTALLS_SUDO='' FLEET_NODE_ROOT="$WORK/root" FLEET_NODE_STATE="$WORK/state" sh "$IS" "$@" 2>&1); RC=$?; }

# --- A/B. alice's install is the version S1; stable = S1 ----------------------------
FLEET_INSTALLS_STABLE=$S1 run
has "A: runtime read" "$OUT" "machine runtime  1111111  = stable"
has "A: link install = its version" "$OUT" "alice          1111111  = stable"
has "A: plain checkout = its HEAD" "$OUT" "bob            $(printf '%.7s' "$B_HEAD")"
has "A: plain checkout named" "$OUT" "plain checkout"
has "A: alice's shell follows" "$OUT" "(follows its login install)"
has "A: bob's shell pinned" "$OUT" "2222222  ≠ stable  来源 ?  (pinned to one version dir until the next install switch"
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

# --- L. 落后 (issue #2934) ------------------------------------------------------------
# nothing recorded: no 落后 word (above). alice's install-sync saw S2 at T0, the
# machine updater at T0+600: the earliest counts — 40m on, every install not at
# S2 says 落后 40m WARN; 20m on, 落后 20m and no WARN; a record of ANOTHER
# stable says nothing.
T0=1800000000
mkdir -p "$H/alice/.config/claude-fleet/global" "$WORK/state"
printf 'result: deferred\nstable: %s\nstable_since: %s\n' "$S2" "$T0" > "$H/alice/.config/claude-fleet/global/install-sync.state"
printf '{"target_seen": {"sha": "%s", "at": %s}}\n' "$S2" "$((T0 + 600))" > "$WORK/state/update.json"
FLEET_INSTALLS_STABLE=$S2 FLEET_INSTALLS_NOW=$((T0 + 2400)) run
has "L: the runtime says how long" "$OUT" "machine runtime  1111111  ≠ stable · 落后 40m WARN  来源 hub"
has "L: a login install too" "$OUT" "alice          1111111  ≠ stable · 落后 40m WARN"
has "L: a closing WARN line" "$OUT" "WARN: 4 install(s) behind stable for over 30m — stable 2222222 first seen here"
case "$OUT" in *"2222222  = stable · 落后"*) bad "L: an install at stable says 落后" ;; *) ok ;; esac
FLEET_INSTALLS_STABLE=$S2 FLEET_INSTALLS_NOW=$((T0 + 1200)) run
has "L: under 30m no WARN" "$OUT" "alice          1111111  ≠ stable · 落后 20m  来源"
case "$OUT" in *WARN*) bad "L: a WARN under the threshold" ;; *) ok ;; esac
FLEET_INSTALLS_STABLE=$S2 FLEET_INSTALLS_NOW=$((T0 + 2400)) run --json
J=$(printf '%s' "$OUT" | python3 -c 'import json,sys
d=json.load(sys.stdin); L={l["login"]: l for l in d["logins"]}
print(d["stable_seen"], d["late"], d["runtime"]["behind_secs"], L["alice"]["install"]["late"])' 2>&1)
eq "L: json lag" "$T0 4 2400 True" "$J"
printf 'stable: %s\nstable_since: %s\n' "$S1" "$T0" > "$H/alice/.config/claude-fleet/global/install-sync.state"
rm -f "$WORK/state/update.json"
FLEET_INSTALLS_STABLE=$S2 FLEET_INSTALLS_NOW=$((T0 + 2400)) run
case "$OUT" in *落后*) bad "L: another stable's record counted" ;; *) ok ;; esac
rm -rf "$H/alice/.config"

# --- G. 来源 -----------------------------------------------------------------------
FLEET_INSTALLS_STABLE=$S1 run
has "G: runtime from the hub" "$OUT" "machine runtime  1111111  = stable  来源 hub"
has "G: a versions link with no GitHub remote" "$OUT" "alice          1111111  = stable  来源 hub"
has "G: a plain checkout is dev" "$OUT" "bob            $(printf '%.7s' "$B_HEAD")  ≠ stable  来源 dev"
has "G: the shell takes its install's" "$OUT" "1111111  = stable  来源 hub  (follows its login install)"
has "G: no github in the summary" "$OUT" "· github 0"
# erin: origin GitHub; frank: FLEET_DIST_SOURCE=github; gina: files link into the runtime;
# hana: a client with a hub, ivan: a client that follows GitHub
for u in erin frank gina; do
  mkdir -p "$H/$u/.claude/fleet.versions/$S1/bin"; ln -s "$H/$u/.claude/fleet.versions/$S1" "$H/$u/.claude/fleet"
  ( cd "$H/$u/.claude/fleet.versions/$S1" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m e ) || exit 2
done
git -C "$H/erin/.claude/fleet" remote add origin https://github.com/verkyyi/claude-fleet.git
mkdir -p "$H/frank/.config/claude-fleet"; printf '[common]\nFLEET_DIST_SOURCE=github\n' > "$H/frank/.config/claude-fleet/fleet.conf"
ln -s "$WORK/root/$S1/bin/fleet-lib.sh" "$H/gina/.claude/fleet/bin/fleet-lib.sh"
mkdir -p "$H/hana/.local/share/claude-fleet" "$H/ivan/.local/share/claude-fleet"
printf 'version=%s\nhub=https://hub.example\n' "$S1" > "$H/hana/.local/share/claude-fleet/.client-version"
printf 'version=%s\nhub=\n' "$S1" > "$H/ivan/.local/share/claude-fleet/.client-version"
FLEET_INSTALLS_STABLE=$S1 run
has "G: origin GitHub" "$OUT" "erin           1111111  = stable  来源 github"
has "G: FLEET_DIST_SOURCE=github" "$OUT" "frank          1111111  = stable  来源 github"
has "G: linked into the runtime" "$OUT" "gina           1111111  = stable  来源 runtime"
has "G: a client with a hub" "$OUT" "hana           1111111  = stable  来源 hub  (client install)"
has "G: a client on GitHub" "$OUT" "ivan           1111111  = stable  来源 github  (client install)"
has "G: the summary counts github" "$OUT" "· github 3"
FLEET_INSTALLS_STABLE=$S1 run --json
J=$(printf '%s' "$OUT" | python3 -c 'import json,sys
d=json.load(sys.stdin); L={l["login"]: l for l in d["logins"]}
print(d["runtime"]["source"], L["erin"]["install"]["source"], L["gina"]["install"]["source"], L["alice"]["shell"]["source"], L["ivan"]["client"]["source"])' 2>&1)
eq "G: json sources" "hub github runtime hub github" "$J"
# issue #2774: a linked tree beside a checkout of the same sha is <sha>-linked —
# still that sha, still the runtime's
mkdir -p "$H/jade/.claude/fleet.versions/$S1-linked/bin"; ln -s "$H/jade/.claude/fleet.versions/$S1-linked" "$H/jade/.claude/fleet"
ln -s "$WORK/root/$S1/bin/fleet-lib.sh" "$H/jade/.claude/fleet/bin/fleet-lib.sh"
FLEET_INSTALLS_STABLE=$S1 run
has "G: a -linked version dir is its sha" "$OUT" "jade           1111111  = stable  来源 runtime"
# …and one known only by the updater's mark (no fleet-lib.sh link to read)
rm "$H/jade/.claude/fleet/bin/fleet-lib.sh"
printf '{"sha": "%s", "root": "%s", "at": 1}\n' "$S1" "$WORK/root" > "$H/jade/.claude/fleet/.fleet-linked"
FLEET_INSTALLS_STABLE=$S1 run
has "G: the .fleet-linked mark is the runtime" "$OUT" "jade           1111111  = stable  来源 runtime"
rm -rf "$H/erin" "$H/frank" "$H/gina" "$H/hana" "$H/ivan" "$H/jade"

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

# --- H. the doctor's dist row --------------------------------------------------------
DH="$WORK/dist"; mkdir -p "$DH/conf" "$DH/client"
ds() { OUT=$(env -u FLEET_DIST_SOURCE HOME="$DH" FLEET_CONF_DIR="$DH/conf" FLEET_LIVE_DIR="$DH/live" FLEET_INSTALL_HOME="$DH/client" "$@" sh "$BIN/fleet-dist-source.sh" 2>&1); }
ds FLEET_HUB_URL=https://hub.example
eq "H: nothing installed → no line" "" "$OUT"
mkdir -p "$DH/live"; git -C "$DH/live" init -q
ds FLEET_HUB_URL=
has "H: no hub → INFO" "$OUT" "INFO	没有入口"
ds FLEET_HUB_URL=https://hub.example/
has "H: a hub, no GitHub remote → PASS" "$OUT" "PASS	新版本只从入口来（https://hub.example）"
git -C "$DH/live" remote add origin git@github.com:verkyyi/claude-fleet.git
ds FLEET_HUB_URL=https://hub.example
has "H: origin GitHub → WARN" "$OUT" "WARN	还在找 GitHub 拿新版本：$DH/live 的 origin 是 GitHub"
has "H: …with the fix" "$OUT" "修：bash $DH/live/bin/fleet-install-sync.sh"
git -C "$DH/live" remote remove origin
printf '[common]\nFLEET_DIST_SOURCE="github"\n' > "$DH/conf/fleet.conf"
ds FLEET_HUB_URL=https://hub.example
has "H: FLEET_DIST_SOURCE=github in fleet.conf → WARN" "$OUT" "FLEET_DIST_SOURCE=github（一版内的回退开关）"
rm -f "$DH/conf/fleet.conf"
ds FLEET_HUB_URL=https://hub.example FLEET_DIST_SOURCE=github
has "H: …or in the environment" "$OUT" "FLEET_DIST_SOURCE=github"
printf 'version=%s\nhub=\n' "$S1" > "$DH/client/.client-version"
ds FLEET_HUB_URL=https://hub.example
has "H: a client on GitHub → WARN with the install line" "$OUT" "修：curl -fsSL https://hub.example/install | sh"
printf 'version=%s\nhub=https://hub.example\n' "$S1" > "$DH/client/.client-version"
ds FLEET_HUB_URL=https://hub.example
has "H: a client with the hub → PASS" "$OUT" "PASS	"
grep -q 'fleet-dist-source.sh' "$BIN/fleet-doctor.sh" && grep -q 'pass dist\|warn dist' "$BIN/fleet-doctor.sh" && ok || bad "H: the doctor does not print fleet-dist-source.sh as its dist row"

if [ "$BAD" -gt 0 ]; then printf 'selftest FAIL: %d of %d\n' "$BAD" "$N" >&2; exit 1; fi
printf 'selftest OK: fleet-installs (%d assertions — runtime, link/plain installs, follow/pinned shells, client, verdicts, json, doctor --installs, 来源)\n' "$N"
