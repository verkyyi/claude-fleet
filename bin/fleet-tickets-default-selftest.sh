#!/bin/bash
# fleet-tickets-default-selftest.sh — a NEW repo's tickets go to the hub, an existing
# repo's stay where they are (issue #3739).
#
#   A  no hub here: fleet-repo.sh add writes no FLEET_TICKETS (the conf as before),
#      fleet-ticket.sh id answers gh:
#   B  a hub here (node.env: address + token): add writes FLEET_TICKETS="hub", id
#      answers hub: — and the repo already hosted keeps every byte (CLAUDE.md
#      «adding a repo changes nothing for the others»)
#   C  --tickets github on a hub login writes github; a bad --tickets is refused
#      (refused:invalid-tickets) and writes nothing
#   D  fleet-conf.sh migrate pins every repo with no FLEET_TICKETS line to its home
#      now (github; hub when its fleet conf says so) — the old bytes kept as the
#      prefix, a repo that has the line untouched, --dry-run writes nothing, a
#      second run changes nothing
#   E  fleet_repo_register / fleet-repo.sh fold carry the source's home (--tickets)
#   F  fleet-doctor.sh prints a tickets row per repo
#
# Drives bin/fleet-repo.sh, bin/fleet-conf.sh, bin/fleet-ticket.sh, bin/fleet-lib.sh
# (fleet_repo_register, fleet_ticket_hub_ready, fleet_ticket_home), bin/fleet-doctor.sh.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
command -v git >/dev/null 2>&1 || { echo 'selftest: git not installed — SKIP' >&2; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tickets-default.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/home" "$WORK/conf"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/gh"; chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH" HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf"
export FLEET_SKIP_GLOBAL_CONF=1 _FLEET_REGISTER_NO_KICK=1 GIT_TERMINAL_PROMPT=0
# hub.example is never asked: the new-repo authority ask (issue #4885, its own
# selftest fleet-authority-default-selftest.sh) answers legacy here.
printf '#!/bin/sh\necho legacy\n' > "$WORK/bin/authority-stub"; chmod +x "$WORK/bin/authority-stub"
export FLEET_HUB_AUTHORITY_CMD="$WORK/bin/authority-stub"
unset TMUX TMUX_PANE CCQUOTA_TOKEN CCQUOTA_HUB_URL FLEET_HUB_URL FLEET_TICKETS FLEET_SESSION

FAILS=0
ok()   { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILS=$((FAILS+1)); }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: expected [$3], got [$2]"; fi; }

g() { git -c user.email=t@t -c user.name=t "$@" >/dev/null 2>&1; }
mkrepo() {   # $1=dir $2=owner/name
  mkdir -p "$(dirname "$1")"
  g init -q "$1" && g -C "$1" commit -q --allow-empty -m init && g -C "$1" branch -q -M master \
    && g -C "$1" remote add origin "https://github.com/$2.git" \
    && g -C "$1" update-ref refs/remotes/origin/master HEAD
}
for r in a b c d e; do mkrepo "$WORK/src/$r" "o/$r"; done

S=ft
mkdir -p "$FLEET_CONF_DIR/fleets/$S"
: > "$FLEET_CONF_DIR/fleets/$S/conf"
: > "$FLEET_CONF_DIR/fleet.conf"   # one file already: migrate's fold step has nothing to do
conf() { printf '%s/fleets/%s/repos/o-%s.conf' "$FLEET_CONF_DIR" "$S" "$1"; }
add() { bash "$BIN/fleet-repo.sh" add --session "$S" "$@" 2>"$WORK/add.err"; }
tid() { bash "$BIN/fleet-ticket.sh" id "$1" 1 2>/dev/null; }

# ---- A: no hub here ----
out=$(add o/a "$WORK/src/a" --base master)
chk "A add o/a" "$out" "added:o-a"
grep -q FLEET_TICKETS "$(conf a)" && fail "A no hub ⇒ no FLEET_TICKETS line" || ok "A no hub ⇒ no FLEET_TICKETS line"
chk "A id is gh:" "$(tid o/a)" "gh:o/a#1"

# ---- B: a hub here ----
printf 'CCQUOTA_HUB_URL=https://hub.example\nCCQUOTA_TOKEN=t0k\n' > "$FLEET_CONF_DIR/node.env"
chmod 600 "$FLEET_CONF_DIR/node.env"
cp "$(conf a)" "$WORK/a.before"
out=$(add o/b "$WORK/src/b" --base master)
chk "B add o/b" "$out" "added:o-b"
chk "B new repo written hub" "$(grep '^FLEET_TICKETS=' "$(conf b)")" 'FLEET_TICKETS="hub"'
chk "B id is hub:" "$(tid o/b)" "hub:o/b#1"
cmp -s "$WORK/a.before" "$(conf a)" && ok "B o/a's conf unchanged by adding o/b" || fail "B o/a's conf changed"
chk "B o/a still gh:" "$(tid o/a)" "gh:o/a#1"

# ---- C: --tickets ----
out=$(add o/c "$WORK/src/c" --base master --tickets github)
chk "C add --tickets github" "$out" "added:o-c"
chk "C written github" "$(grep '^FLEET_TICKETS=' "$(conf c)")" 'FLEET_TICKETS="github"'
chk "C id is gh:" "$(tid o/c)" "gh:o/c#1"
out=$(add o/d "$WORK/src/d" --base master --tickets gitlab); rc=$?
chk "C bad --tickets refused" "$out/$rc" "refused:invalid-tickets/1"
[ -e "$(conf d)" ] && fail "C refused add wrote a conf" || ok "C refused add wrote nothing"

# ---- D: migrate pins the existing repos ----
cp "$(conf b)" "$WORK/b.before"; cp "$(conf c)" "$WORK/c.before"
bash "$BIN/fleet-conf.sh" migrate --dry-run >"$WORK/dry.out" 2>&1
cmp -s "$WORK/a.before" "$(conf a)" && ok "D --dry-run writes nothing" || fail "D --dry-run wrote"
grep -q "would pin o/a's tickets to github" "$WORK/dry.out" && ok "D --dry-run says what it would pin" \
  || fail "D dry-run output: $(cat "$WORK/dry.out")"
bash "$BIN/fleet-conf.sh" migrate >"$WORK/mig.out" 2>&1 || fail "D migrate failed: $(cat "$WORK/mig.out")"
chk "D o/a pinned github" "$(grep '^FLEET_TICKETS=' "$(conf a)")" 'FLEET_TICKETS="github"'
n=$(wc -c < "$WORK/a.before" | tr -d ' ')
head -c "$n" "$(conf a)" | cmp -s - "$WORK/a.before" && ok "D o/a's old bytes kept as the prefix" || fail "D o/a's old bytes changed"
chk "D o/a pin is two lines" "$(( $(wc -l < "$(conf a)") - $(wc -l < "$WORK/a.before") ))" 2
cmp -s "$WORK/b.before" "$(conf b)" && ok "D o/b (has the line) untouched" || fail "D o/b touched"
cmp -s "$WORK/c.before" "$(conf c)" && ok "D o/c (has the line) untouched" || fail "D o/c touched"
grep -q 'pinned for every existing repo: o/a=github' "$WORK/mig.out" && ok "D migrate says what it pinned" \
  || fail "D migrate output: $(cat "$WORK/mig.out")"
chk "D o/a still gh: after migrate" "$(tid o/a)" "gh:o/a#1"
cp "$(conf a)" "$WORK/a.pinned"
bash "$BIN/fleet-conf.sh" migrate >/dev/null 2>&1
cmp -s "$WORK/a.pinned" "$(conf a)" && ok "D second migrate changes nothing" || fail "D second migrate rewrote o/a"
# A fleet whose conf says hub: its unpinned repo is pinned hub — its home now.
S2=fh; mkdir -p "$FLEET_CONF_DIR/fleets/$S2/repos"
printf 'FLEET_TICKETS=hub\n' > "$FLEET_CONF_DIR/fleets/$S2/conf"
printf 'FLEET_REPO="o/e"\nFLEET_MAIN="%s"\nFLEET_BASE_BRANCH="master"\n' "$WORK/src/e" > "$FLEET_CONF_DIR/fleets/$S2/repos/o-e.conf"
printf 'o/e\n' > "$FLEET_CONF_DIR/fleets/$S2/repos/.order"
bash "$BIN/fleet-conf.sh" migrate >/dev/null 2>&1
chk "D fleet conf hub ⇒ pinned hub" "$(grep '^FLEET_TICKETS=' "$FLEET_CONF_DIR/fleets/$S2/repos/o-e.conf")" 'FLEET_TICKETS="hub"'

# ---- E: no hub, and fold's carry ----
mv "$FLEET_CONF_DIR/node.env" "$WORK/node.env.off"
( . "$BIN/fleet-lib.sh"; fleet_ticket_hub_ready ) && fail "E no node.env ⇒ not ready" || ok "E no node.env ⇒ not ready"
mv "$WORK/node.env.off" "$FLEET_CONF_DIR/node.env"
( . "$BIN/fleet-lib.sh"; fleet_ticket_hub_ready ) && ok "E node.env ⇒ ready" || fail "E node.env ⇒ ready"
grep -q -- '--tickets "$(fleet_ticket_home "$SRC_REPO" "$FROM")"' "$BIN/fleet-repo.sh" \
  && ok "E fold re-adds a repo with its source's home" || fail "E fold does not carry the ticket home"

# ---- F: doctor's tickets row ----
if command -v tmux >/dev/null 2>&1; then
  dout=$(bash "$BIN/fleet-doctor.sh" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')
  case "$dout" in *"tickets  o/b: tickets on the hub"*) ok "F doctor shows o/b on the hub" ;;
    *) fail "F doctor tickets row for o/b missing: $(printf '%s\n' "$dout" | grep -i tickets)" ;; esac
  case "$dout" in *"tickets  o/a: tickets on GitHub"*) ok "F doctor shows o/a on GitHub" ;;
    *) fail "F doctor tickets row for o/a missing" ;; esac
else
  ok "F (no tmux — doctor leg skipped)"
fi

[ "$FAILS" = 0 ] && { echo "fleet-tickets-default-selftest: PASS"; exit 0; }
echo "fleet-tickets-default-selftest: $FAILS failure(s)" >&2; exit 1
