# shellcheck shell=bash
# selftest-collect-fixture.sh — the collector tests' one environment (T601, EPIC T516
# R2): a sandbox copy of the collector and FAKE tmux / gh / git, so a change to the
# collector's surroundings is made here once. Sourced after selftest-lib.sh; every
# name is cfx_. Nothing here runs on a real tmux server, GitHub or repo.
#
#   cfx_sandbox <name>    WORK (physical) + its EXIT trap (kills $CFX_PIDS and any
#                         process carrying the $CFX_HANG argv marker), L=$WORK,
#                         fleet sessA → acme/widgets, accounts/a, the fakes on PATH
#   cfx_copy <file>...    copy bin files into $WORK/bin (the collector set by default)
#   cfx_lane <name>       a lane of its own in $WORK/<name> (L, G, C), for cases that
#                         run beside each other
#   cfx_run [args]        one real collector tick in $L: stdout $L/out, stderr $L/err
#   cfx_extract <out> <fn>...  the named collector functions into one sourceable file
#   cfx_hb <key>          a value off $G/collect.heartbeat
#   cfx_fail <msg>        st_fail, after $L/err and the heartbeat on stderr
#
# The fakes read their knobs from the environment of each cfx_run:
#   tmux  FAKE_DOWN (labels whose has-session fails); list-windows answers
#         #{pane_current_path} from $L/panepaths ($L/otherpaths for sessB;
#         FAKE_TMUX_EMPTY_SESS=<label|all> empty, FAKE_TMUX_FAIL_SESS=<label> rc 1),
#         and with FAKE_NWIN the banner's remote/working questions (@1-@3 working);
#         capture-pane logs to FAKE_CAPLOG, sleeps FAKE_CAP_SLEEP, wedges once on
#         FAKE_CAP_HANG
#   gh    logs "<mode> <repo name>" to $L/gh.log; an issue row per `issue`, the
#         GraphQL page FAKE_GQL_JSON (through the collector's own --jq) per `api`;
#         FAKE_GH_HANG=<name>:<mode> wedges
#   git   logs "<path><TAB><argv>" to $L/git.log; FAKE_GIT_HANG=<suffix> wedges,
#         FAKE_GIT_SLOW=<suffix> sleeps FAKE_GIT_SLOW_SECS on every call
# A wedge is `exec -a $CFX_HANG sleep`, so a test can ask whether it outlived its box.
unset GH_TTL FLEET_REPOS CCQUOTA_FLEET FLEET_HUB_URL   # never the caller's (#3371; hubsess phase)
CFX_FILES='tmux-dash-collect.sh fleet-account.sh fleet_iso.py fleet-lib.sh fleet-client-core.sh usage-lib.sh'

cfx_sandbox() {
  command -v python3 >/dev/null 2>&1 || { printf 'selftest: python3 not installed — SKIP\n' >&2; exit 0; }
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/collect-$1.XXXXXX") || exit 2
  WORK=$(cd "$WORK" && pwd -P)
  CFX_HANG="cfx-hang-$1-$$"; CFX_PIDS=''; export CFX_HANG
  trap '[ -n "$CFX_PIDS" ] && kill $CFX_PIDS 2>/dev/null; pkill -9 -f "$CFX_HANG" >/dev/null 2>&1; rm -rf "$WORK"' EXIT
  L="$WORK"; C="$WORK/.claude-dash"; G="$C/global"
  mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/accounts" "$WORK/conf/fleets/sessA" "$G"
  printf 'tok-a\n' > "$WORK/accounts/a"
  : > "$WORK/conf/fleets/sessA/conf"
  fx_repo "$WORK/conf" sessA acme/widgets
  cfx_fakes
}

cfx_copy() {
  local f list="$*"
  [ -n "$list" ] || list=$CFX_FILES
  for f in $list; do
    [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
    cp "$BIN/$f" "$WORK/bin/"
  done
  printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/fleet-restore.sh"   # the snapshot phase's helper
  chmod +x "$WORK/bin/"*.sh
}

cfx_lane() {
  L="$WORK/$1"; C="$L/.claude-dash"; G="$C/global"
  mkdir -p "$G"; cp -R "$WORK/conf" "$L/conf"
  [ ! -f "$WORK/panepaths" ] || cp "$WORK/panepaths" "$L/panepaths"
}

cfx_run() {
  : > "$L/gh.log"; : > "$L/git.log"
  env PATH="$WORK/fakepath:$PATH" TMPDIR="$L" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
    GH_TTL="${GH_TTL:-0}" FLEET_REPO='' FLEET_REPOS="${FLEET_REPOS-}" FLEET_NOTIFY_CMD='' \
    FLEET_CONF_DIR="$L/conf" FLEET_ACCOUNTS_DIR="$WORK/accounts" \
    FAKE_L="$L" CFX_HANG="$CFX_HANG" \
    bash "$WORK/bin/tmux-dash-collect.sh" "$@" > "$L/out" 2> "$L/err"
}

cfx_extract() {
  local out=$1; shift
  python3 - "$BIN/tmux-dash-collect.sh" "$out" "$@" <<'PY' || st_fail "could not extract $*"
import re, sys
s = open(sys.argv[1]).read()
out = []
for name in sys.argv[3:]:
    f = re.search(r'^' + name + r'\(\) \{\n.*?^\}', s, re.M | re.S)
    assert f, name
    out.append(f.group(0))
open(sys.argv[2], 'w').write('\n'.join(out) + '\n')
PY
}

cfx_hb() { sed -n "s/^$1=//p" "$G/collect.heartbeat" 2>/dev/null | head -1; }

cfx_fail() {
  local f
  for f in "$L/err" "$G/collect.heartbeat"; do
    [ -s "$f" ] && { printf -- '--- %s ---\n' "${f#"$WORK"/}"; cat "$f"; } >&2
  done
  st_fail "$1"
}

cfx_fakes() {
  cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/bin/bash
label=''
if [ "${1:-}" = -L ] || [ "${1:-}" = -S ]; then label="$2"; shift 2; fi
case "${1:-}" in
  has-session) for d in ${FAKE_DOWN:-}; do [ "$d" = "$label" ] && exit 1; done; exit 0 ;;
  list-sessions) [ -n "$label" ] && printf '%s\n' "$label"; exit 0 ;;
  list-windows)
    for a in "$@"; do
      case "$a" in
        *'#{pane_current_path}'*)   # fleet_lw prefixes the format (#1489)
          case "${FAKE_TMUX_EMPTY_SESS:-}" in all|"$label") exit 0 ;; esac
          f="$FAKE_L/panepaths"; [ "$label" = sessB ] && f="$FAKE_L/otherpaths"
          [ -f "$f" ] && cat "$f"
          [ "$label" = "${FAKE_TMUX_FAIL_SESS:-}" ] && exit 1   # partial output is no complete view
          exit 0 ;;
        *' x') i=1; while [ "$i" -le "${FAKE_NWIN:-0}" ]; do echo x; i=$((i+1)); done; exit 0 ;;
        *'@claude_state},working'*) [ -n "${FAKE_NWIN:-}" ] && printf '@1\n@2\n@3\n'; exit 0 ;;
      esac
    done
    exit 0 ;;
  capture-pane)
    [ -n "${FAKE_CAPLOG:-}" ] || exit 0
    t=''; prev=''
    for a in "$@"; do [ "$prev" = -t ] && t="$a"; prev="$a"; done
    printf '%s\n' "$t" >> "$FAKE_CAPLOG"
    if [ "$t" = "${FAKE_CAP_HANG:-__none__}" ] && [ ! -e "$FAKE_CAPLOG.hung" ]; then
      : > "$FAKE_CAPLOG.hung"; exec -a "$CFX_HANG" sleep 120
    fi
    [ -n "${FAKE_CAP_SLEEP:-}" ] && sleep "$FAKE_CAP_SLEEP"
    exit 0 ;;
esac
exit 0
FAKE
  cat > "$WORK/fakepath/gh" <<'FAKE'
#!/bin/bash
mode="${1:-}"; name=''; jqx=''
while [ "$#" -gt 0 ]; do
  case "$1" in --repo) shift; name=${1##*/} ;; name=*) name=${1#name=} ;; --jq) shift; jqx=$1 ;; esac
  shift
done
[ -n "${FAKE_L:-}" ] && printf '%s %s\n' "$mode" "$name" >> "$FAKE_L/gh.log"
[ "$name:$mode" = "${FAKE_GH_HANG:-}" ] && exec -a "$CFX_HANG" sleep 30
case "$mode" in
  issue) printf 'bug\tMilestone\t#1\t·\tFresh %s\n' "$name" ;;
  api) if [ -n "${FAKE_GQL_JSON:-}" ]; then printf '%s' "$FAKE_GQL_JSON" | jq -r "$jqx"
       else printf '2\t1\n'; fi ;;
esac
exit 0
FAKE
  cat > "$WORK/fakepath/git" <<'FAKE'
#!/bin/bash
path=''
if [ "${1:-}" = -C ]; then path="$2"; shift 2; fi
[ -n "${FAKE_L:-}" ] && printf '%s\t%s\n' "$path" "$*" >> "$FAKE_L/git.log"
case "$path" in *"${FAKE_GIT_HANG:-__nomatch__}") exec -a "$CFX_HANG" sleep 120 ;; esac
case "$path" in *"${FAKE_GIT_SLOW:-__nomatch__}") sleep "${FAKE_GIT_SLOW_SECS:-2}" ;; esac
case "${1:-} ${2:-}" in
  'rev-parse --git-dir')    printf '.git\n' ;;
  'rev-parse --abbrev-ref') printf 'b-%s\n' "${path##*/}" ;;
  'rev-list --left-right')  printf '1\t2\n' ;;   # behind=1 ahead=2
esac
exit 0
FAKE
  chmod +x "$WORK/fakepath/"*
}
