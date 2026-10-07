#!/bin/bash
# fleet-seed-selftest.sh — the seed repo only looks (issue #1167), in a sandbox
# login (its own HOME, FLEET_CONF_DIR, install root and tmux sockets). Every repo
# is put one way since issue #1937 — repos/<slug>.conf, the seed too:
#   1. `fleet-up o/a` WITHOUT --seed: the fleet conf holds the header and no repo;
#      o/a is repos/o-a.conf (identity only) and first in repos/.order; no seed.
#   2. `fleet-up o/a --seed` puts FLEET_SEED=1 + FLEET_AUTOFILL=0 +
#      FLEET_ISSUE_BRIDGE=0 in o/a's OVERLAY, none in the fleet conf; a re-run is
#      idempotent (no duplicate keys), and with --no-attach (issue #1165) never
#      tries to attach.
#   3. one dispatch tick on the seed fleet is a no-op — even with FLEET_AUTOFILL=1
#      flipped on afterwards (the seed check wins); the same overlay minus
#      FLEET_SEED goes on past the gate (control).
#   4. one issue-bridge tick on the seed fleet is a no-op — even with
#      FLEET_ISSUE_BRIDGE=1; the same overlay minus FLEET_SEED is queued (control).
#   5. repo-scoped: a repo ADDED to the seed fleet is not the seed
#      (fleet_repo_is_seed), and its overlay's FLEET_AUTOFILL=1 passes the seed check.
#   6. `--seed` for a repo the fleet would add beside another is refused, nothing written.
#   7. fleet-settings.sh merge leaves FLEET_SEED in the seed's overlay, so it can
#      never become a login-wide setting.
#   8. fleet-doctor prints the seed line for a seeded fleet only.
#   9. the starter goes like any repo (issues #1172, #1937): seed + o/b →
#      `fleet-repo.sh remove o/a` is the same road as every remove — no promotion,
#      the fleet conf untouched, o/b's overlay untouched; the guide — a scratch of
#      the seed — never blocks it, an issue window of the seed does; afterwards no
#      reader sees a seed, and o/b (the last repo) goes the same way, leaving a
#      fleet with none.
#  10. the OLD layout (the seed in the fleet conf, beside o/b + o/c overlays):
#      remove o/a first moves it into repos/ (conf kept as .bak), then removes it
#      — the seed's AUTOFILL=0 goes from the conf while the operator's switch and a
#      fleet-wide key stay, o/c's override stays scoped to o/c, the order holds.
#  11. a fleet with no repo: `fleet-up --no-attach` outside any checkout brings it
#      up (conf, session, hub in $HOME); a repo added later goes in repos/ too.
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

OV() { printf '%s/fleets/fleet/repos/o-%s.conf' "$FLEET_CONF_DIR" "$1"; }

# ---- 1. no --seed: the conf holds the fleet, o/a its own overlay ----
out=$(up o/a "$WORK/src/a"); eq "1 rc" "$?" 0
hasnt "1 no seed line" "$out" "seed repo"
hasnt "1 attaches as always (no --no-attach)" "$out" "not attaching"
want=$(printf '%s\n' \
  "# Overlays the global fleet.conf for this fleet's tmux session. Add any other" \
  '# FLEET_* keys (see fleet.conf.example) — e.g. FLEET_CTX_WINDOW, FLEET_PROTECTED_RE.')
eq "1 conf: the header, no repo" "$(nohdr "$C")" "$want"
head -1 "$C" | grep -qE "^# claude-fleet: fleet 'fleet' — written by fleet-up\.sh [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}\$" \
  || fail "1 header line: $(head -1 "$C")"
eq "1 o/a's overlay: identity" "$(grep -v '^#' "$(OV a)")" "$(printf 'FLEET_REPO="o/a"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"' "$WORK/src/a")"
eq "1 repos/.order" "$(cat "$FLEET_CONF_DIR/fleets/fleet/repos/.order")" o-a
eq "1 fleet_repos" "$(lib 'fleet_repos fleet')" o/a
eq "1 FLEET_REPO resolves as always" "$(lib 'fleet_load_conf fleet; printf %s "$FLEET_REPO|$FLEET_BASE_BRANCH"')" "o/a|master"
lib 'fleet_repo_is_seed fleet o/a' && fail "1: o/a reads as the seed without --seed"
down
leg "1 no --seed: the repo in repos/, the conf holds none"

# ---- 2. --seed: the three keys in the seed's overlay, idempotent ----
export FLEET_CONF_DIR="$WORK/conf2"; C="$FLEET_CONF_DIR/fleets/fleet/conf"
out=$(up o/a "$WORK/src/a" --seed); eq "2 rc" "$?" 0
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '$ fleet-up o/a --seed\n%s\n' "$out"
has "2 says so" "$out" "o/a is this fleet's seed repo"
eq "2 seed" "$(val "$(OV a)" FLEET_SEED)" 1
eq "2 autofill" "$(val "$(OV a)" FLEET_AUTOFILL)" 0
eq "2 bridge" "$(val "$(OV a)" FLEET_ISSUE_BRIDGE)" 0
eq "2 none of them in the fleet conf" "$(grep -cE '^FLEET_(SEED|AUTOFILL|ISSUE_BRIDGE)=' "$C")" 0
lib 'fleet_repo_is_seed fleet o/a' || fail "2: o/a is not read as the seed"
out=$(up o/a "$WORK/src/a" --seed --no-attach); eq "2 re-run rc" "$?" 0
has "2 --no-attach stops short (#1165)" "$out" "not attaching (--no-attach)"
hasnt "2 --no-attach never tries" "$out" "attach:  tmux"
eq "2 no dup keys" "$(grep -cE '^FLEET_(SEED|AUTOFILL|ISSUE_BRIDGE)=' "$(OV a)")" 3
[ -e "$C.tmp.$$" ] && fail "2: temp file left behind"
leg "2 --seed writes SEED=1 AUTOFILL=0 ISSUE_BRIDGE=0 into the seed's overlay"

# ---- 3. one dispatch tick: a no-op, even with autofill flipped on ----
lib "fleet_conf_set '$(OV a)' FLEET_AUTOFILL 1"
out=$(bash "$SB/fleet-dispatch.sh" --dry-run fleet 2>&1)
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '$ fleet-dispatch --dry-run fleet (seed)\n%s\n' "$out"
has "3 seed skip" "$out" "seed repo (FLEET_SEED=1) — never autofills, skip"
hasnt "3 no spawn" "$out" "would spawn"
cp "$(OV a)" "$WORK/seedconf"; grep -v '^FLEET_SEED=' "$WORK/seedconf" > "$(OV a)"
out=$(bash "$SB/fleet-dispatch.sh" --dry-run fleet 2>&1)
hasnt "3 control passes the seed check" "$out" "seed repo"
hasnt "3 control passes the autofill gate" "$out" "autofill off"
cp "$WORK/seedconf" "$(OV a)"
leg "3 dispatch tick on the seed repo is a no-op"

# ---- 4. one issue-bridge tick: a no-op, even with the bridge flipped on ----
lib "fleet_conf_set '$(OV a)' FLEET_ISSUE_BRIDGE 1"
out=$(bash "$SB/fleet-issue-bridge.sh" 2>&1)
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '$ fleet-issue-bridge (seed)\n%s\n' "$out"
has "4 nothing to relay" "$out" "no fleet has FLEET_ISSUE_BRIDGE=1 — nothing to do"
cp "$(OV a)" "$WORK/seedconf"; grep -v '^FLEET_SEED=' "$WORK/seedconf" > "$(OV a)"
out=$(bash "$SB/fleet-issue-bridge.sh" 2>&1)
hasnt "4 control is queued" "$out" "nothing to do"
cp "$WORK/seedconf" "$(OV a)"
leg "4 issue-bridge tick on the seed repo is a no-op"

# ---- 5. repo-scoped: an added repo is not the seed ----
out=$(up o/b "$WORK/src/b"); eq "5 add rc" "$?" 0
has "5 added" "$out" "added o/b to fleet 'fleet'"
lib 'fleet_repo_is_seed fleet o/b' && fail "5: the added o/b inherited FLEET_SEED"
lib 'fleet_repo_is_seed fleet o/a' || fail "5: o/a lost its seed mark once o/b was added"
eq "5 order" "$(lib 'fleet_repos fleet' | tr '\n' ' ')" "o/a o/b "
lib "fleet_conf_set \"\$(fleet_repo_conf_file fleet o/b)\" FLEET_AUTOFILL 1"
out=$(bash "$SB/fleet-dispatch.sh" --dry-run fleet 2>&1)
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '$ fleet-dispatch --dry-run fleet (o/a seed + o/b)\n%s\n' "$out"
has "5 seed skipped" "$out" "fleet: o/a: seed repo (FLEET_SEED=1)"
hasnt "5 o/b not seed" "$out" "fleet: o/b: seed repo"
hasnt "5 o/b armed" "$out" "fleet: o/b: autofill off"
leg "5 FLEET_SEED is the seed's alone"

# ---- 6. --seed for a repo the fleet would add beside another: refused ----
mkrepo "$WORK/src/d" o/d
out=$(up o/d "$WORK/src/d" --seed); eq "6 rc" "$?" 1
has "6 refused" "$out" "--seed marks a fleet's only repo"
[ -e "$(OV d)" ] && fail "6: a refused --seed still wrote o/d's overlay"
down
leg "6 --seed on an added repo refused"

# ---- 7. fleet-settings merge: FLEET_SEED stays in the seed's overlay ----
out=$(bash "$SB/fleet-settings.sh" merge 2>&1); eq "7 rc" "$?" 0
eq "7 overlay keeps seed" "$(val "$(OV a)" FLEET_SEED)" 1
grep -q '^FLEET_SEED=' "$FLEET_CONF_DIR/fleet.settings" 2>/dev/null && fail "7: FLEET_SEED moved into the login-wide settings"
lib 'fleet_repo_is_seed fleet o/a' || fail "7: o/a lost its seed mark in the merge"
leg "7 settings merge keeps the seed mark repo-scoped"

# ---- 8. doctor: the seed line, only where seeded ----
out=$(sh "$SB/fleet-doctor.sh" 2>&1)
has "8 seed line" "$out" "o/a — 起步仓库，只读"
export FLEET_CONF_DIR="$WORK/conf"
out=$(sh "$SB/fleet-doctor.sh" 2>&1)
hasnt "8 no seed line unseeded" "$out" "起步仓库"
leg "8 doctor names the seed repo"

# ---- 9. the starter goes like any repo (issues #1172, #1937) ----
# The seed fleet of legs 2–7 (o/a seed + o/b), its server up with the guide — a
# scratch of the seed, as fleet-up opens it — and an issue window of the seed.
export FLEET_CONF_DIR="$WORK/conf2"; C="$FLEET_CONF_DIR/fleets/fleet/conf"
tmux -L fleet new-session -d -s fleet -n plan -x 120 -y 30 || fail "9: could not start the isolated server"
tmux -L fleet new-window -d -t fleet -n guide 'sleep 300'
tmux -L fleet set-option -w -t fleet:guide @repo o/a; tmux -L fleet set-option -w -t fleet:guide @raw 1
tmux -L fleet new-window -d -t fleet -n issue-7 'sleep 300'
tmux -L fleet set-option -w -t fleet:issue-7 @repo o/a; tmux -L fleet set-option -w -t fleet:issue-7 @issue 7
before=$(cat "$C"); ovb=$(cat "$(OV b)")
list0=$(bash "$SB/fleet-repo.sh" list --session fleet 2>&1)
has "9 list before: the seed" "$list0" "[repos/o-a.conf]"
has "9 list before: o/b" "$list0" "[repos/o-b.conf]"
out=$(bash "$SB/fleet-repo.sh" remove --session fleet o/a 2>&1); eq "9 an issue window of the seed refuses" "$?" 1
has "9 the refusal names it" "$out" "issue-7"
[ -f "$(OV a)" ] || fail "9: a refused remove dropped o/a's overlay"
tmux -L fleet kill-window -t fleet:issue-7
out=$(bash "$SB/fleet-repo.sh" remove --session fleet o/a 2>&1); eq "9 remove rc" "$?" 0
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '$ fleet-repo.sh list   (before)\n%s\n$ fleet-repo.sh remove o/a\n%s\n' "$list0" "$out"
has "9 one road: says what is left" "$out" "fleet no longer hosts o/a (1 repo(s) left)"
hasnt "9 no promotion" "$out" "promot"
eq "9 the fleet conf untouched" "$(cat "$C")" "$before"
eq "9 o/b's overlay untouched" "$(cat "$(OV b)")" "$ovb"
[ -e "$(OV a)" ] && fail "9: o/a's overlay left behind"
eq "9 fleet_repos" "$(lib 'fleet_repos fleet')" o/b
eq "9 FLEET_REPO now resolves to o/b" "$(lib 'fleet_load_conf fleet; printf %s "$FLEET_REPO"')" o/b
lib 'fleet_repo_is_seed fleet o/b' && fail "9: o/b became the seed"
tmux -L fleet list-windows -t fleet -F '#{window_name}' | grep -qx guide || fail "9: the guide window was killed"
out=$(bash "$SB/fleet-dispatch.sh" --dry-run fleet 2>&1)
hasnt "9 dispatch sees no seed" "$out" "seed repo"
out=$(sh "$SB/fleet-doctor.sh" 2>&1)
hasnt "9 doctor prints no seed line" "$out" "起步仓库"
out=$(bash "$SB/fleet-onboard.sh" brief --session fleet --no-gh 2>&1)
hasnt "9 the wizard's brief tags no seed" "$out" "[seed]"
out=$(bash "$SB/fleet-repo.sh" remove --session fleet o/b 2>&1); eq "9 the last repo goes the same way" "$?" 0
has "9 …leaving none" "$out" "(0 repo(s) left)"
eq "9 fleet_repos: none" "$(lib 'fleet_repos fleet')" ""
eq "9 no repo key resolves" "$(lib 'fleet_load_conf fleet; printf %s "${FLEET_REPO:-}|${FLEET_MAIN:-}"')" "|"
down
leg "9 remove the seed: one road, no promotion; the last repo too"

# ---- 10. the old layout: the seed in the fleet conf ----
mk10() {   # $1=conf dir → seed o/a in the conf + o/b (identity) + o/c (FLEET_MODEL override)
  export FLEET_CONF_DIR="$1"; C="$FLEET_CONF_DIR/fleets/fleet/conf"
  mkdir -p "$FLEET_CONF_DIR/fleets/fleet/repos"
  printf 'FLEET_REPO="o/a"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\nFLEET_SEED="1"\nFLEET_AUTOFILL="0"\nFLEET_ISSUE_BRIDGE="1"\nFLEET_DEPLOY_REF="/deploy-a"\nFLEET_CTX_WINDOW="7"\n' "$WORK/src/a" > "$C"
  printf 'FLEET_REPO="o/b"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\n' "$WORK/src/b" > "$FLEET_CONF_DIR/fleets/fleet/repos/o-b.conf"
  printf 'FLEET_REPO="o/c"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="main"\nFLEET_MODEL="sonnet"\n' "$WORK/src/c" > "$FLEET_CONF_DIR/fleets/fleet/repos/o-c.conf"
}
mkdir -p "$WORK/src/c"
mk10 "$WORK/conf5"
eq "10 old layout: hosts" "$(lib 'fleet_repos fleet' | tr '\n' ' ')" "o/a o/b o/c "
lib 'fleet_repo_is_seed fleet o/a' || fail "10: the old layout's seed is not read (one version)"
out=$(bash "$SB/fleet-repo.sh" remove --session fleet o/a 2>&1); eq "10 remove rc" "$?" 0
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '$ fleet-repo.sh remove o/a   (old layout)\n%s\n' "$out"
has "10 moved first" "$out" "moved out of"
[ -f "$C.bak" ] || fail "10: the fleet conf was not kept as .bak"
eq "10 the conf names no repo" "$(grep -cE '^FLEET_(REPO|MAIN|BASE_BRANCH|SEED|DEPLOY_REF)=' "$C")" 0
eq "10 the seed's AUTOFILL=0 went with it" "$(grep -c '^FLEET_AUTOFILL=' "$C")" 0
eq "10 a switch the operator set stays" "$(val "$C" FLEET_ISSUE_BRIDGE)" 1
eq "10 a fleet-wide key stays" "$(val "$C" FLEET_CTX_WINDOW)" 7
eq "10 hosts after" "$(lib 'fleet_repos fleet' | tr '\n' ' ')" "o/b o/c "
[ "$(lib 'fleet_repo_conf_get fleet o/b FLEET_MODEL')" != sonnet ] || fail "10: o/b reads o/c's FLEET_MODEL"
eq "10 o/c reads its own" "$(lib 'fleet_repo_conf_get fleet o/c FLEET_MODEL')" sonnet
eq "10 o/b is first now" "$(lib 'fleet_load_conf fleet; printf %s "$FLEET_REPO|$FLEET_BASE_BRANCH"')" "o/b|master"
lib 'fleet_repo_is_seed fleet o/b' && fail "10: o/b became the seed"
leg "10 old layout: moved into repos/ first, then removed like any repo"

# ---- 11. a fleet with no repo comes up (issue #1937) ----
export FLEET_CONF_DIR="$WORK/conf9"; C="$FLEET_CONF_DIR/fleets/fleet/conf"
out=$(cd "$HOME" && bash "$UP" --no-attach </dev/null 2>&1); eq "11 rc" "$?" 0
[ -n "${FLEET_SELFTEST_SHOW:-}" ] && printf '$ fleet-up --no-attach   (no repo)\n%s\n' "$out"
has "11 says it has none" "$out" "0 repo(s)"
[ -f "$C" ] || fail "11: no fleet conf written"
eq "11 the conf names no repo" "$(grep -c '^FLEET_REPO=' "$C")" 0
eq "11 fleet_repos: none" "$(lib 'fleet_repos fleet')" ""
tmux -L fleet has-session -t fleet 2>/dev/null || fail "11: the fleet's session is not up"
eq "11 the hub opens in \$HOME" "$(tmux -L fleet display-message -p -t fleet:plan '#{pane_current_path}' 2>/dev/null)" "$HOME"
# then a repo, the same way as any: it is the fleet's one repo, and the hub's next start opens there
out=$(up o/a "$WORK/src/a" --no-attach); eq "11 add rc" "$?" 0
has "11 added" "$out" "added o/a to fleet 'fleet'"
eq "11 fleet_repos after" "$(lib 'fleet_repos fleet')" o/a
eq "11 the conf still names no repo" "$(grep -c '^FLEET_REPO=' "$C")" 0
down
leg "11 a fleet with no repo comes up, and takes one later the same way"

[ "$FAILS" = 0 ] || { printf 'selftest FAIL: %d assertion(s)\n' "$FAILS" >&2; exit 1; }
printf 'selftest PASS: the seed repo only looks — no autofill, no bridge, repo-scoped (issue #1167) — and goes like any repo (issues #1172, #1937)\n'
