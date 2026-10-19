#!/bin/bash
# client-core-selftest.sh — a client-only computer's scripts read the small client
# library, bin/fleet-client-core.sh, never the machine's bin/fleet-lib.sh (issue
# #4825, EPIC #4823 C2).
#
#   A  lint: no bin/ file on conf/client-runtime.list (the files a client really
#      uses, C1) names fleet-lib.sh in a code line — but the MACHINE_SIDE table
#      below, each with why, and every row of that table still names it
#   B  one implementation: no function is defined in both files; fleet-lib.sh
#      sources the core (beside it, or beside a symlink's target), so the machine
#      side calls the very same code; fleet_host_lib loads the lib where it is,
#      answers 1 where it is not
#   C  the client package carries the core (fleetclient/manifest), the runtime
#      list names it and no longer fleet-lib.sh
#   D  smoke, side by side: the client package laid out twice — once WITHOUT
#      fleet-lib.sh — and the client's actions run in both from the same HOME:
#      the answers are the same, and the one without never says fleet-lib
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$BIN/.." && pwd)"
LIST="$REPO/conf/client-runtime.list"
MANIFEST="$REPO/tokenledger/hub/api/fleetclient/manifest"
CORE="$BIN/fleet-client-core.sh"
LIB="$BIN/fleet-lib.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/client-core-st.XXXXXX")
trap 'rm -rf "${WORK:?}"' EXIT
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

# The client-package files that run only on a machine with a fleet (they are on
# the list because a client file NAMES them — a command it sends to its home over
# ssh, a config line it writes for a node): they may keep sourcing fleet-lib.sh.
# C3 (#4826) decides whether they leave the package.
MACHINE_SIDE='bin/fleet-client-core.sh	fleet_host_lib: loads the lib on a hosting machine
bin/fleet-remote-view.sh	runs on the home (fleet-thin.py: attach --thin over ssh)
bin/fleet-hub-sessions.sh	the home'"'"'s hub loop (session-cli --home refreshes it there)
bin/tmux-dashboard-rows.sh	the home'"'"'s row producer (session-cli --home)
bin/fleet-peer-cert.sh	a node'"'"'s ssh Match (fleet-login.py writes it only with node.env)
bin/fleet-install-apply.sh	the Agent package'"'"'s apply — leaves the client with it (C3)
bin/fleet-relay-cred.sh	the Agent package'"'"'s credential relay — leaves the client with it (C3)'

# code lines of a file: no comment line, no trailing ` # …` on a shell line
# (each prefixed with its line number); grep's answer read whole, never -q, so
# pipefail never sees awk's SIGPIPE
code() {
  awk '{ l = $0; sub(/^[[:space:]]+/, "", l) } l ~ /^#/ { next } { sub(/[[:space:]]#[[:space:]].*$/, ""); print NR ":" $0 }' "$1"
}

# --- A: the lint ------------------------------------------------------------------
bad=''
while IFS=$'\t' read -r p _; do
  case "$p" in bin/*) ;; *) continue ;; esac
  [ -f "$REPO/$p" ] || continue
  printf '%s\n' "$MACHINE_SIDE" | cut -f1 | grep -qx "$p" && continue
  hits=$(code "$REPO/$p" | grep 'fleet-lib\.sh')
  [ -z "$hits" ] || bad="$bad $p(${hits%%:*})"
done < <(grep -v '^#' "$LIST")
[ -z "$bad" ] && ok "A no client file names fleet-lib.sh in code" || no "A names fleet-lib.sh:$bad — read fleet-client-core.sh (fleet_host_lib for a machine-only branch), or add the file to MACHINE_SIDE with why"
stale=''
while IFS=$'\t' read -r p _; do
  [ -n "$p" ] || continue
  [ -n "$(code "$REPO/$p" 2>/dev/null | grep 'fleet-lib\.sh')" ] || stale="$stale $p"
done <<EOF
$MACHINE_SIDE
EOF
[ -z "$stale" ] && ok "A every MACHINE_SIDE row still names fleet-lib.sh" || no "A MACHINE_SIDE rows that no longer need it (drop them):$stale"

# --- B: one implementation ----------------------------------------------------------
defs() { grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$1" | tr -d '()' | sort -u; }
dup=$(comm -12 <(defs "$CORE") <(defs "$LIB") | tr '\n' ' ')
[ -z "$dup" ] && ok "B no function defined in both" || no "B defined twice: $dup"
n=$(defs "$CORE" | wc -l | tr -d ' ')
miss=$(bash -c '. "$1" >/dev/null 2>&1; for f in $2; do type "$f" >/dev/null 2>&1 || printf "%s " "$f"; done' _ "$LIB" "$(defs "$CORE" | tr '\n' ' ')")
[ -z "$miss" ] && ok "B fleet-lib.sh defines all $n core functions (sourced from the core)" || no "B missing after sourcing fleet-lib.sh: $miss"
mkdir -p "$WORK/link" "$WORK/alone"
ln -s "$LIB" "$WORK/link/fleet-lib.sh"
got=$(bash -c '. "$1/fleet-lib.sh" 2>&1; type fleet_each_conf >/dev/null 2>&1 && echo found' _ "$WORK/link")
[ "$got" = found ] && ok "B a lone symlink to fleet-lib.sh finds the core beside its target" || no "B symlinked lib: $got"
got=$(zsh -c '. "$1" >/dev/null 2>&1; whence fleet_find_tool >/dev/null && echo found' _ "$LIB" 2>/dev/null)
command -v zsh >/dev/null 2>&1 || got=found
[ "$got" = found ] && ok "B zsh sources fleet-lib.sh → the core's functions" || no "B zsh: $got"
cp "$CORE" "$WORK/alone/"
got=$(bash -c '. "$1/fleet-client-core.sh"; fleet_host_lib; echo "rc=$? lib=${_FLEET_LIB_DIR:-}"' _ "$WORK/alone")
[ "$got" = "rc=1 lib=" ] && ok "B fleet_host_lib answers 1 with no fleet-lib.sh beside it" || no "B fleet_host_lib alone: $got"
got=$(bash -c '. "$1/fleet-client-core.sh"; fleet_host_lib && type fleet_load_conf >/dev/null && echo loaded' _ "$BIN")
[ "$got" = loaded ] && ok "B fleet_host_lib loads fleet-lib.sh where it is" || no "B fleet_host_lib: $got"

# --- C: the package and the list -----------------------------------------------------
grep -qx 'bin/fleet-client-core.sh' "$MANIFEST" && ok "C the client package carries the core" || no "C bin/fleet-client-core.sh not in $MANIFEST"
grep -q $'^bin/fleet-client-core.sh\t' "$LIST" && ok "C the runtime list names the core" || no "C core not on $LIST"
grep -q $'^bin/fleet-lib.sh\t' "$LIST" && no "C fleet-lib.sh is still on the client's runtime list" || ok "C fleet-lib.sh is not on the client's runtime list"

# --- D: smoke, with and without fleet-lib.sh ------------------------------------------
lay() {   # lay <root> [<extra>] — the client package (its installed files, not
          # the `served` ones — issue #4826) in the install's (the repo's) layout
  { awk '!/^[[:space:]]*#/ && NF && $2 != "served" { print $1 }' "$MANIFEST"; [ -z "${2:-}" ] || echo "$2"; } | while read -r p; do
    mkdir -p "$1/$(dirname "$p")"; cp -p "$REPO/$p" "$1/$p"
  done
}
# the package carries no fleet-lib.sh since #4826: «with» puts it beside, as a
# machine's tree has it
lay "$WORK/with" bin/fleet-lib.sh
lay "$WORK/without"
[ -f "$WORK/with/bin/fleet-lib.sh" ] && [ ! -e "$WORK/without/bin/fleet-lib.sh" ] \
  && ok "D two packages: with and without fleet-lib.sh" || no "D the packages were not laid"
# run <root> <name> <cmd…> — in a fresh HOME seeded as a signed-in client
run() {
  local root=$1 name=$2 h; shift 2
  h="$WORK/home-${root##*/}-$name"; mkdir -p "$h/.config/claude-fleet" "$h/tmp"
  printf '{"url": "http://127.0.0.1:9"}\n' > "$h/.config/claude-fleet/hub.json"
  printf 'FLEET_UI_LANG=zh\n' > "$h/.config/claude-fleet/shell.conf"
  ( cd "$h" && env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$h" TMPDIR="$h/tmp" LANG=C.UTF-8 TERM=dumb \
      R="$root" "$@" ) > "$WORK/$name.${root##*/}" 2>&1 < /dev/null
  printf 'rc=%s\n' "$?" >> "$WORK/$name.${root##*/}"
  [ -f "$h/.config/claude-fleet/fleet.conf" ] && grep -v '^# Migrated by' "$h/.config/claude-fleet/fleet.conf" >> "$WORK/$name.${root##*/}"
  # paths differ by sandbox only
  sed -i.bak -e "s|$WORK/home-${root##*/}-$name|HOME|g" -e "s|$root|ROOT|g" "$WORK/$name.${root##*/}"
}
side() {   # side <name> <cmd…> — both packages, the same answer, no fleet-lib in it
  local name=$1; shift
  run "$WORK/with" "$name" "$@"; run "$WORK/without" "$name" "$@"
  if ! diff -q "$WORK/$name.with" "$WORK/$name.without" >/dev/null; then
    no "D $name differs without fleet-lib.sh: $(diff "$WORK/$name.with" "$WORK/$name.without" | head -6 | tr '\n' '|')"
  elif grep -qiE 'fleet-lib|command not found|No such file|unbound variable' "$WORK/$name.without"; then
    no "D $name: $(grep -iE 'fleet-lib|command not found|No such file|unbound variable' "$WORK/$name.without" | head -2 | tr '\n' '|')"
  else
    ok "D $name: the same without fleet-lib.sh ($(tail -n 1 "$WORK/$name.without" | grep -o 'rc=[0-9]*' || grep -o 'rc=[0-9]*' "$WORK/$name.without" | head -1))"
  fi
}
side help         sh -c '"$R/bin/fleet" --help'
side host         sh -c '"$R/bin/fleet" host status'
side conf-host    bash -c '"$R/bin/fleet-conf.sh" host --why'
side conf-migrate bash -c '"$R/bin/fleet-conf.sh" migrate'
side conf-sethost bash -c '"$R/bin/fleet-conf.sh" set-host 1 && "$R/bin/fleet-conf.sh" host && "$R/bin/fleet-conf.sh" set-host 0'
side where        bash -c 'FLEET_HUB_URL= "$R/bin/fleet-client-where.sh" --json'
side place        bash -c 'FLEET_HUB_URL= "$R/bin/fleet-client-place.sh" - scratch'
side ticket-url   python3 -c 'import sys,os; sys.path.insert(0, os.environ["R"] + "/bin"); import fleet_ticket_url as t; print(t.ticket_url("o/r", 7))'
side session-road python3 -c '
import importlib.util, os
s = importlib.util.spec_from_file_location("cli", os.environ["R"] + "/bin/fleet-session-cli.py")
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.tools_on_path(); print("road", m.road(), "here", repr(m.fleet_here()))'
side hub-write    bash -c '"$R/bin/fleet-hub-write.sh" identity 2>&1 | head -n 3'

printf '\nclient-core-selftest: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
