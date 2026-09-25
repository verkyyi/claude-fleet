#!/bin/bash
# fleet-seed-selftest.sh — the seed repo only looks (issue #1167), in a sandbox
# login (its own HOME, FLEET_CONF_DIR, install root and tmux sockets):
#   1. degenerate: `fleet-up o/a` WITHOUT --seed writes exactly the conf it always
#      has — header + the derived three, byte for byte — and says nothing of a seed.
#   2. `fleet-up o/a --seed` adds FLEET_SEED=1 + FLEET_AUTOFILL=0 +
#      FLEET_ISSUE_BRIDGE=0; a re-run is idempotent (no duplicate keys), and with
#      --no-attach (issue #1165) never tries to attach.
#   3. one dispatch tick on the seed fleet is a no-op — even with FLEET_AUTOFILL=1
#      flipped on afterwards (the seed check wins); the same conf minus FLEET_SEED
#      goes on past the gate (control).
#   4. one issue-bridge tick on the seed fleet is a no-op — even with
#      FLEET_ISSUE_BRIDGE=1; the same conf minus FLEET_SEED is queued (control).
#   5. repo-scoped: a repo ADDED to the seed fleet is not the seed
#      (fleet_repo_is_seed), and its overlay's FLEET_AUTOFILL=1 passes the seed check.
#   6. `--seed` for a repo the fleet would only add is refused, conf untouched.
#   7. fleet-settings.sh merge keeps FLEET_SEED in the fleet conf (identity), so
#      it can never become a login-wide setting.
#   8. fleet-doctor prints the seed line for a seeded fleet only.
#   9. the starter can go (issue #1172): seed + o/b → `fleet-repo.sh remove o/a`
#      promotes o/b into the conf's own slot, and the conf is byte for byte what
#      `fleet-up o/b` writes for a fresh fleet (minus the header's timestamp) with
#      no repos/ dir left; the guide — a scratch of the seed — never blocks it, an
#      issue window of the seed does (conf untouched); afterwards no reader sees a
#      seed, and o/b, a non-seed conf repo, is refused exactly as before.
#  10. with repos left: --promote picks the one, a kept overlay's overrides stay
#      scoped to it (never folded into the conf), an identity-only overlay goes,
#      the seed's own keys go while the operator's switches stay; the refusals —
#      the seed as the only repo, --promote of an unhosted repo or on a non-seed.
# Hub, collector, disk gate and trust check are stubbed in a sandbox bin/; tmux: a
# PATH shim maps every `-L <label>` to a private socket under $SOCKD.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
command -v git >/dev/null 2>&1 || { printf 'selftest: git not installed — SKIP\n' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-seed-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
mkdir -p "$WORK/shim" "$WORK/root/bin" "$WORK/home" "$WORK/tmp"
# Sockets in a SHORT dir: a unix socket path is capped at ~104 bytes.
SOCKD="$(mktemp -d /tmp/f1167.XXXXXX)" || exit 2
cat > "$WORK/shim/tmux" <<EOF
#!/bin/bash
if [ "\${1:-}" = -L ]; then s="$SOCKD/\$2"; shift 2; exec "$REAL_TMUX" -S "\$s" "\$@"; fi
exec "$REAL_TMUX" -S "$SOCKD/none" "\$@"
EOF
printf '#!/bin/sh\nexit 1\n' > "$WORK/shim/gh"
chmod +x "$WORK/shim/tmux" "$WORK/shim/gh"
export PATH="$WORK/shim:$PATH"

cleanup() {
  local s; for s in "$SOCKD"/*; do [ -S "$s" ] && "$REAL_TMUX" -S "$s" kill-server 2>/dev/null; done
  rm -rf "$WORK" "$SOCKD"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf" TMPDIR="$WORK/tmp" FLEET_C="$WORK/cache"
export FLEET_ISSUE_BRIDGE_STATE_DIR="$WORK/bridge"
unset TMUX TMUX_PANE FLEET_MAIN FLEET_REPO FLEET_BASE_BRANCH FLEET_SESSION FLEET_SKIP_GLOBAL_CONF
unset _FLEET_GLOBAL_CONF_SOURCED FLEET_GLOBAL_MAX_SESSIONS FLEET_SEED FLEET_AUTOFILL FLEET_ISSUE_BRIDGE
export FLEET_ONBOARD=0     # no first-fleet guide here (#1169)

FAILS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
eq()   { [ "$2" = "$3" ] || fail "$1: expected [$3], got [$2]"; }
has()  { case "$2" in *"$3"*) ;; *) fail "$1: [$3] not in: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) fail "$1: [$3] unexpectedly in: $2" ;; esac; }
leg()  { if [ "$FAILS" = "${_legf:-0}" ]; then printf 'PASS %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fi; _legf=$FAILS; }

# ---- sandbox install root: the real scripts, hub/collector/gates stubbed ----
SB="$WORK/root/bin"
for f in "$BIN"/*; do ln -s "$f" "$SB/$(basename "$f")"; done
rm -f "$SB/hub-session.sh" "$SB/tmux-dash-collect.sh" "$SB/fleet-diskguard.sh" "$SB/fleet-trust.sh"
cat > "$SB/hub-session.sh" <<'EOF'
#!/bin/bash
tmux -L "$HUB_SESSION" new-window -d -t "$HUB_SESSION:" -n plan -c "$HUB_CWD" 'sleep 3600'
EOF
printf '#!/bin/sh\nexit 0\n' > "$SB/tmux-dash-collect.sh"
printf '#!/bin/sh\nexit 0\n' > "$SB/fleet-diskguard.sh"
printf '#!/bin/sh\necho trusted\n' > "$SB/fleet-trust.sh"
chmod +x "$SB"/hub-session.sh "$SB"/tmux-dash-collect.sh "$SB"/fleet-diskguard.sh "$SB"/fleet-trust.sh
UP="$SB/fleet-up.sh"

mkrepo() { git init -q "$1" && git -C "$1" remote add origin "https://github.com/$2.git"; }
for r in a b; do mkrepo "$WORK/src/$r" "o/$r"; done
up()    { bash "$UP" "$@" --base master </dev/null 2>&1; }
val()   { ( . "$1" >/dev/null 2>&1; eval "printf '%s' \"\${$2:-}\"" ); }
lib()   { bash -c ". '$SB/fleet-lib.sh'; $1"; }
down()  { "$REAL_TMUX" -S "$SOCKD/fleet" kill-server 2>/dev/null; }
nohdr() { grep -v '^# claude-fleet: fleet ' "$1"; }   # the header's only moving part is its timestamp
C="$FLEET_CONF_DIR/fleets/fleet/conf"

# ---- 1. degenerate: no --seed → the conf fleet-up has always written ----
out=$(up o/a "$WORK/src/a"); eq "1 rc" "$?" 0
hasnt "1 no seed line" "$out" "seed repo"
hasnt "1 attaches as always (no --no-attach)" "$out" "not attaching"
want=$(printf '%s\n' \
  "# Overlays the global fleet.conf for this fleet's tmux session. Add any other" \
  '# FLEET_* keys (see fleet.conf.example) — e.g. FLEET_CTX_WINDOW, FLEET_PROTECTED_RE.' \
  'FLEET_REPO="o/a"' "FLEET_MAIN=\"$WORK/src/a\"" 'FLEET_BASE_BRANCH="master"')
eq "1 conf byte for byte" "$(nohdr "$C")" "$want"
head -1 "$C" | grep -qE "^# claude-fleet: fleet 'fleet' — written by fleet-up\.sh [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}\$" \
  || fail "1 header line: $(head -1 "$C")"
lib 'fleet_repo_is_seed fleet o/a' && fail "1: o/a reads as the seed without --seed"
down
leg "1 degenerate: no --seed, conf unchanged"

# ---- 2. --seed: the three keys, idempotent ----
export FLEET_CONF_DIR="$WORK/conf2"; C="$FLEET_CONF_DIR/fleets/fleet/conf"
out=$(up o/a "$WORK/src/a" --seed); eq "2 rc" "$?" 0
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '$ fleet-up o/a --seed\n%s\n' "$out"
has "2 says so" "$out" "o/a is this fleet's seed repo"
eq "2 seed" "$(val "$C" FLEET_SEED)" 1
eq "2 autofill" "$(val "$C" FLEET_AUTOFILL)" 0
eq "2 bridge" "$(val "$C" FLEET_ISSUE_BRIDGE)" 0
lib 'fleet_repo_is_seed fleet o/a' || fail "2: o/a is not read as the seed"
out=$(up o/a "$WORK/src/a" --seed --no-attach); eq "2 re-run rc" "$?" 0
has "2 --no-attach stops short (#1165)" "$out" "not attaching (--no-attach)"
hasnt "2 --no-attach never tries" "$out" "attach:  tmux"
eq "2 no dup keys" "$(grep -cE '^FLEET_(SEED|AUTOFILL|ISSUE_BRIDGE)=' "$C")" 3
[ -e "$C.tmp.$$" ] && fail "2: temp file left behind"
leg "2 --seed writes SEED=1 AUTOFILL=0 ISSUE_BRIDGE=0"

# ---- 3. one dispatch tick: a no-op, even with autofill flipped on ----
lib "fleet_conf_set '$C' FLEET_AUTOFILL 1"
out=$(bash "$SB/fleet-dispatch.sh" --dry-run fleet 2>&1)
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '$ fleet-dispatch --dry-run fleet (seed)\n%s\n' "$out"
has "3 seed skip" "$out" "fleet: seed repo (FLEET_SEED=1) — never autofills, skip"
hasnt "3 no spawn" "$out" "would spawn"
cp "$C" "$WORK/seedconf"; grep -v '^FLEET_SEED=' "$WORK/seedconf" > "$C"
out=$(bash "$SB/fleet-dispatch.sh" --dry-run fleet 2>&1)
hasnt "3 control passes the seed check" "$out" "seed repo"
hasnt "3 control passes the autofill gate" "$out" "autofill off"
cp "$WORK/seedconf" "$C"
leg "3 dispatch tick on the seed repo is a no-op"

# ---- 4. one issue-bridge tick: a no-op, even with the bridge flipped on ----
lib "fleet_conf_set '$C' FLEET_ISSUE_BRIDGE 1"
out=$(bash "$SB/fleet-issue-bridge.sh" 2>&1)
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '$ fleet-issue-bridge (seed)\n%s\n' "$out"
has "4 nothing to relay" "$out" "no fleet has FLEET_ISSUE_BRIDGE=1 — nothing to do"
cp "$C" "$WORK/seedconf"; grep -v '^FLEET_SEED=' "$WORK/seedconf" > "$C"
out=$(bash "$SB/fleet-issue-bridge.sh" 2>&1)
hasnt "4 control is queued" "$out" "nothing to do"
cp "$WORK/seedconf" "$C"
leg "4 issue-bridge tick on the seed repo is a no-op"

# ---- 5. repo-scoped: an added repo is not the seed ----
out=$(up o/b "$WORK/src/b"); eq "5 add rc" "$?" 0
has "5 added" "$out" "added o/b to fleet 'fleet'"
lib 'fleet_repo_is_seed fleet o/b' && fail "5: the added o/b inherited FLEET_SEED"
lib 'fleet_repo_is_seed fleet o/a' || fail "5: o/a lost its seed mark once o/b was added"
lib "fleet_conf_set \"\$(fleet_repo_conf_file fleet o/b)\" FLEET_AUTOFILL 1"
out=$(bash "$SB/fleet-dispatch.sh" --dry-run fleet 2>&1)
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '$ fleet-dispatch --dry-run fleet (o/a seed + o/b)\n%s\n' "$out"
has "5 seed skipped" "$out" "fleet: o/a: seed repo (FLEET_SEED=1)"
hasnt "5 o/b not seed" "$out" "fleet: o/b: seed repo"
hasnt "5 o/b armed" "$out" "fleet: o/b: autofill off"
leg "5 FLEET_SEED is the conf repo's alone"

# ---- 6. --seed for a repo the fleet would only add: refused ----
before=$(cat "$C")
out=$(up o/b "$WORK/src/b" --seed); eq "6 rc" "$?" 1
has "6 refused" "$out" "--seed marks a fleet's OWN repo"
eq "6 conf untouched" "$(cat "$C")" "$before"
down
leg "6 --seed on an added repo refused"

# ---- 7. fleet-settings merge: FLEET_SEED stays in the fleet conf ----
out=$(bash "$SB/fleet-settings.sh" merge 2>&1); eq "7 rc" "$?" 0
eq "7 conf keeps seed" "$(val "$C" FLEET_SEED)" 1
grep -q '^FLEET_SEED=' "$FLEET_CONF_DIR/fleet.settings" && fail "7: FLEET_SEED moved into the login-wide settings"
lib 'fleet_repo_is_seed fleet o/a' || fail "7: o/a lost its seed mark in the merge"
leg "7 settings merge keeps the seed mark repo-scoped"

# ---- 8. doctor: the seed line, only where seeded ----
out=$(sh "$SB/fleet-doctor.sh" 2>&1)
has "8 seed line" "$out" "o/a — 起步仓库，只读"
export FLEET_CONF_DIR="$WORK/conf"
out=$(sh "$SB/fleet-doctor.sh" 2>&1)
hasnt "8 no seed line unseeded" "$out" "起步仓库"
leg "8 doctor names the seed repo"

# ---- 9. the starter can go (issue #1172): seed + o/b → remove o/a ≡ fleet-up o/b ----
# The reference: what `fleet-up o/b` writes for a FRESH fleet, in its own conf dir.
export FLEET_CONF_DIR="$WORK/conf3"
out=$(up o/b "$WORK/src/b" --no-attach); eq "9 reference fleet-up rc" "$?" 0
want=$(nohdr "$FLEET_CONF_DIR/fleets/fleet/conf")
down
# The seed fleet of legs 2–7 (o/a seed + o/b overlay), its server up with the guide
# — a scratch of the seed, as fleet-up opens it — and an issue window of the seed.
export FLEET_CONF_DIR="$WORK/conf2"; C="$FLEET_CONF_DIR/fleets/fleet/conf"
tmux -L fleet new-session -d -s fleet -n plan -x 120 -y 30 || fail "9: could not start the isolated server"
tmux -L fleet new-window -d -t fleet -n guide 'sleep 300'
tmux -L fleet set-option -w -t fleet:guide @repo o/a; tmux -L fleet set-option -w -t fleet:guide @raw 1
tmux -L fleet new-window -d -t fleet -n issue-7 'sleep 300'
tmux -L fleet set-option -w -t fleet:issue-7 @repo o/a; tmux -L fleet set-option -w -t fleet:issue-7 @issue 7
OVB=$(lib 'fleet_repo_conf_file fleet o/b')
# Leg 5 armed o/b's overlay (FLEET_AUTOFILL=1); the fold carries an override into
# the conf (leg 10 pins that), so put the overlay back to what `fleet-up o/b` wrote
# — identity only — for the byte-for-byte claim below.
lib "fleet_conf_unset '$OVB' FLEET_AUTOFILL"
before=$(cat "$C")
list0=$(bash "$SB/fleet-repo.sh" list --session fleet 2>&1)
has "9 list before: the seed" "$list0" "o/a"
has "9 list before: o/b as an overlay" "$list0" "[repos/o-b.conf]"
out=$(bash "$SB/fleet-repo.sh" remove --session fleet o/a 2>&1); eq "9 an issue window of the seed refuses" "$?" 1
has "9 the refusal names it" "$out" "issue-7"
eq "9 conf untouched on refusal" "$(cat "$C")" "$before"
[ -f "$OVB" ] || fail "9: a refused remove dropped o/b's overlay"
tmux -L fleet kill-window -t fleet:issue-7
out=$(bash "$SB/fleet-repo.sh" remove --session fleet o/a 2>&1); eq "9 remove rc" "$?" 0
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '$ fleet-repo.sh list   (before)\n%s\n$ fleet-repo.sh remove o/a\n%s\n' "$list0" "$out"
has "9 says who was promoted" "$out" "o/b is now fleet's own repo"
has "9 the guide (a seed scratch) did not block" "$out" "1 scratch window(s) of o/a keep running"
eq "9 conf ≡ fleet-up o/b's, byte for byte" "$(nohdr "$C")" "$want"
head -1 "$C" | grep -qE "^# claude-fleet: fleet 'fleet' — written by fleet-up\.sh [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}\$" \
  || fail "9 header line: $(head -1 "$C")"
[ -e "$FLEET_CONF_DIR/fleets/fleet/repos" ] && fail "9: repos/ left behind — not a one-repo fleet"
eq "9 fleet_repos" "$(lib 'fleet_repos fleet')" o/b
lib 'fleet_repo_is_seed fleet o/b' && fail "9: o/b became the seed"
lib 'fleet_has_repo_overlays fleet' && fail "9: fleet_has_repo_overlays still true"
list1=$(bash "$SB/fleet-repo.sh" list --session fleet 2>&1)
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '$ fleet-repo.sh list   (after)\n%s\n' "$list1"
has "9 list after: o/b from the conf" "$list1" "o/b"
has "9 list after: …as the conf's own" "$list1" "[conf]"
hasnt "9 list after: no seed" "$list1" "o/a"
tmux -L fleet list-windows -t fleet -F '#{window_name}' | grep -qx guide || fail "9: the guide window was killed"
out=$(bash "$SB/fleet-dispatch.sh" --dry-run fleet 2>&1)
hasnt "9 dispatch sees no seed" "$out" "seed repo"
out=$(sh "$SB/fleet-doctor.sh" 2>&1)
hasnt "9 doctor prints no seed line" "$out" "起步仓库"
out=$(bash "$SB/fleet-onboard.sh" brief --session fleet --no-gh 2>&1)
hasnt "9 the wizard's brief tags no seed" "$out" "[seed]"
out=$(bash "$SB/fleet-repo.sh" remove --session fleet o/b 2>&1); eq "9 the promoted (non-seed) conf repo is refused as always" "$?" 1
has "9 …with the historic wording" "$out" "o/b is the fleet conf's own repo"
eq "9 …conf untouched" "$(nohdr "$C")" "$want"
down
leg "9 remove the seed: the promoted repo's conf ≡ fleet-up's, no repos/ left"

# ---- 10. repos left, --promote, and the refusals ----
mk10() {   # $1=conf dir → seed o/a + o/b (identity) + o/c (FLEET_MODEL override)
  export FLEET_CONF_DIR="$1"; C="$FLEET_CONF_DIR/fleets/fleet/conf"
  mkdir -p "$FLEET_CONF_DIR/fleets/fleet/repos"
  printf 'FLEET_REPO="o/a"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\nFLEET_SEED="1"\nFLEET_AUTOFILL="0"\nFLEET_ISSUE_BRIDGE="1"\nFLEET_DEPLOY_REF="/deploy-a"\nFLEET_CTX_WINDOW="7"\n' "$WORK/src/a" > "$C"
  printf 'FLEET_REPO="o/b"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\n' "$WORK/src/b" > "$FLEET_CONF_DIR/fleets/fleet/repos/o-b.conf"
  printf 'FLEET_REPO="o/c"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="main"\nFLEET_MODEL="sonnet"\n' "$WORK/src/c" > "$FLEET_CONF_DIR/fleets/fleet/repos/o-c.conf"
}
mkdir -p "$WORK/src/c"
# the seed as the only repo: refused, nothing to promote
mk10 "$WORK/conf5"; rm -rf "$FLEET_CONF_DIR/fleets/fleet/repos"; before=$(cat "$C")
out=$(bash "$SB/fleet-repo.sh" remove --session fleet o/a 2>&1); eq "10 seed alone rc" "$?" 1
has "10 seed alone: says add one first" "$out" "only repo"
eq "10 seed alone: conf untouched" "$(cat "$C")" "$before"
mk10 "$WORK/conf6"; before=$(cat "$C")
out=$(bash "$SB/fleet-repo.sh" remove --session fleet o/a --promote o/zzz 2>&1); eq "10 --promote unhosted rc" "$?" 1
has "10 --promote unhosted: refused" "$out" "not a repo fleet hosts"
eq "10 --promote unhosted: conf untouched" "$(cat "$C")" "$before"
out=$(bash "$SB/fleet-repo.sh" remove --session fleet o/b --promote o/c 2>&1); eq "10 --promote on a non-seed rc" "$?" 1
has "10 --promote on a non-seed: refused" "$out" "only goes with removing the seed"
[ -f "$FLEET_CONF_DIR/fleets/fleet/repos/o-b.conf" ] || fail "10: a refused --promote dropped o/b's overlay"
# promote o/c, whose overlay carries an override, with o/b left: kept, scoped
out=$(bash "$SB/fleet-repo.sh" remove --session fleet o/a --promote o/c 2>&1); eq "10 promote o/c rc" "$?" 0
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '$ fleet-repo.sh remove o/a --promote o/c\n%s\n' "$out"
eq "10 identity → o/c" "$(val "$C" FLEET_REPO)|$(val "$C" FLEET_MAIN)|$(val "$C" FLEET_BASE_BRANCH)" "o/c|$WORK/src/c|main"
eq "10 the seed's keys go (SEED, AUTOFILL=0, DEPLOY_REF)" "$(grep -cE '^FLEET_(SEED|AUTOFILL|DEPLOY_REF)=' "$C")" 0
eq "10 a switch the operator set stays" "$(val "$C" FLEET_ISSUE_BRIDGE)" 1
eq "10 a fleet-wide key stays" "$(val "$C" FLEET_CTX_WINDOW)" 7
eq "10 o/c's override is NOT folded into the conf" "$(grep -c '^FLEET_MODEL=' "$C")" 0
[ -f "$FLEET_CONF_DIR/fleets/fleet/repos/o-c.conf" ] || fail "10: o/c's overlay (it carries an override) was dropped"
has "10 says the overrides stay put" "$out" "its overrides stay in"
eq "10 hosts" "$(lib 'fleet_repos fleet' | tr '\n' ' ')" "o/c o/b "
[ "$(lib 'fleet_repo_conf_get fleet o/b FLEET_MODEL')" != sonnet ] || fail "10: o/b reads o/c's FLEET_MODEL — the promoted override leaked into the fleet's fallback"
eq "10 o/c reads its own" "$(lib 'fleet_repo_conf_get fleet o/c FLEET_MODEL')" sonnet
lib 'fleet_repo_is_seed fleet o/c' && fail "10: o/c became the seed"
# promote o/b — identity only — with o/c left: its overlay goes, o/c's stays
mk10 "$WORK/conf7"
out=$(bash "$SB/fleet-repo.sh" remove --session fleet o/a 2>&1); eq "10 default promotion rc" "$?" 0
eq "10 default = the first other repo" "$(val "$C" FLEET_REPO)" o/b
[ -e "$FLEET_CONF_DIR/fleets/fleet/repos/o-b.conf" ] && fail "10: o/b's identity-only overlay was kept"
[ -f "$FLEET_CONF_DIR/fleets/fleet/repos/o-c.conf" ] || fail "10: o/c's overlay was dropped with o/b promoted"
eq "10 hosts after" "$(lib 'fleet_repos fleet' | tr '\n' ' ')" "o/b o/c "
# the LAST overlay carries an override: folded into the conf, then no repos/ at all
mk10 "$WORK/conf8"; rm -f "$FLEET_CONF_DIR/fleets/fleet/repos/o-b.conf"
out=$(bash "$SB/fleet-repo.sh" remove --session fleet o/a 2>&1); eq "10 last-overlay fold rc" "$?" 0
has "10 says it folded" "$out" "its overlay folded in, no repos/ left"
eq "10 the override is now the conf's" "$(val "$C" FLEET_MODEL)|$(val "$C" FLEET_REPO)" "sonnet|o/c"
[ -e "$FLEET_CONF_DIR/fleets/fleet/repos" ] && fail "10: repos/ left after the last overlay folded"
leg "10 repos left: --promote, scoped overrides, the fold, the refusals"

[ "$FAILS" = 0 ] || { printf 'selftest FAIL: %d assertion(s)\n' "$FAILS" >&2; exit 1; }
printf 'selftest PASS: the seed repo only looks — no autofill, no bridge, repo-scoped (issue #1167) — and can go once another repo is in (issue #1172)\n'
