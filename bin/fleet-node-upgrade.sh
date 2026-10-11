#!/bin/bash
# fleet-node-upgrade.sh — every login's node agent (ccquota) on this machine to
# the stable version, in one command (issue #1525, EPIC #1524 C6).
#
#   fleet-node-upgrade.sh [<sha>|stable] [--dry-run] [--logins all|<name>…]
#                         [--status] [--no-hub] [--host <ssh-host>]
#                         [--binary <file> [--sha256 <hex>]] [--wait <secs>]
#                         [--dist] [--rollback]
#
# Upgrading the agent used to be by hand, and a login forgotten was a machine
# whose half of a change never showed up. This does the whole thing:
#
#   target   `stable` (default: the sha fleet-stable.sh reads off the public
#            tag) or a sha → version prod-<7-char sha>.
#   build    from THIS checkout's tree at that sha (git archive, never touching
#            the worktree), with tokenledger/Makefile's LDFLAGS and
#            VERSION=prod-<sha>; `<built> version` must say so. --binary <file>
#            uses a ready build instead (its version is checked the same way;
#            --sha256 pins its bytes too). --dist asks the hub first
#            (GET /v1/node/dist/<os>-<arch> with this login's node token from
#            node.env, piped to curl on stdin — never on argv; the body must match
#            its X-Ccquota-Sha256 AND say the target version) and builds only when
#            the hub has no such binary (issue #1723).
#   install  onto every distinct binary path the selected logins' agents run
#            (the running process's own path, else the service's
#            ProgramArguments): <path>.prev keeps the old bytes, the new one
#            lands as <path>.new then renames over — sudo -n only where this
#            login cannot write. The installed file's SHA-256 must match.
#   restart  login by login: launchctl kickstart -k system/com.ccquota.agent.<login>
#            (a LaunchDaemon, through sudo -n) or gui/<uid>/com.ccquota.agent
#            (this login's own LaunchAgent); then WAIT until the hub's /v1/nodes
#            shows that login connected on the target version before touching the
#            next one. Only the agent restarts (its heartbeat drops a few
#            seconds) — tmux, sessions and windows are never touched.
#            A step that fails stops there with exit 1; logins already done stay
#            done (no rollback — `mv <path>.prev <path>` + kickstart is the undo).
#            --rollback does that undo itself when a restarted login never shows
#            up on the target: every installed path no finished login runs goes
#            back to its .prev and the failed login is kickstarted onto it again
#            (the install-sync tick passes it, issue #1723).
#   --host   run the same upgrade on another machine over ssh: the binary is
#            built (or taken) HERE and shipped, and this very script is streamed
#            to `bash -s` there — the remote needs neither Go nor this script.
#            On a hub node each ssh rides a five-minute hub certificate
#            (fleet-peer-cert.sh, issue #1626), never a standing key.
#
# --status prints one row per login (login · path · version on disk · version
# the hub sees + heartbeat) and a `summary: <k>/<n> behind <target>` line; the
# doctor's `agent` line reads that (with --no-hub). --dry-run resolves and
# prints the whole plan and changes nothing: no build, no file, no restart.
# --no-hub skips /v1/nodes (status: no hub columns; upgrade: a restarted agent is
# confirmed by its new process only).
#
# The hub is read with the VIEWER token (CCQUOTA_VIEWER_TOKEN or
# ~/.ccquota/viewer-token), the same as fleet-hub-sessions.sh; the hub URL from
# CCQUOTA_HUB_URL / FLEET_HUB_URL / ~/.config/claude-fleet/hub.json. No token is
# ever printed, and the node token is never read.
#
# macOS (launchd) only. Env seams (tests): FLEET_NODE_UPGRADE_DAEMON_DIR
# (/Library/LaunchDaemons) · FLEET_NODE_UPGRADE_AGENT_DIR (~/Library/LaunchAgents)
# · FLEET_NODE_UPGRADE_PS (prints `uid pid path` rows; default ps) ·
# FLEET_NODE_UPGRADE_SUDO (`sudo -n`) · FLEET_NODE_UPGRADE_LAUNCHCTL (launchctl) ·
# FLEET_NODE_UPGRADE_NODES_CMD (prints the /v1/nodes JSON) ·
# FLEET_NODE_UPGRADE_HOSTNAME · FLEET_NODE_UPGRADE_OS · FLEET_NODE_UPGRADE_POLL (2)
# · FLEET_NODE_UPGRADE_UIDS ("login=uid …", before id -u) ·
# FLEET_NODE_UPGRADE_DIST_CMD (`<cmd> <os-arch> <body> <headers>` writes both
# files and prints the HTTP code — stands in for the --dist curl)
#
# Exit: 0 done / all current · 1 a step failed (the line says which) · 2 usage
set -uo pipefail

PROG=fleet-node-upgrade
BIN_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
TARGET="" DRY=0 STATUS=0 NOHUB=0 HOST="" BINARY="" WANT_SUM="" WAIT=90 DIST=0 ROLLBACK=0
LOGINS_ARG=""
SUDO="${FLEET_NODE_UPGRADE_SUDO-sudo -n}"
LAUNCHCTL="${FLEET_NODE_UPGRADE_LAUNCHCTL:-launchctl}"
DDIR="${FLEET_NODE_UPGRADE_DAEMON_DIR:-/Library/LaunchDaemons}"
# A managed machine's root runtime: an agent whose binary lives under it runs the
# release's ccquota — the machine's updater moves and restarts it (issue #3034),
# and this script never writes over a release's bytes.
NODE_ROOT="${FLEET_NODE_ROOT:-/Library/Application Support/claude-fleet}"
ADIR="${FLEET_NODE_UPGRADE_AGENT_DIR:-$HOME/Library/LaunchAgents}"
POLL="${FLEET_NODE_UPGRADE_POLL:-2}"

say() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit "${RC:-2}"; }
fail() { printf '%s: FAIL — %s\n' "$PROG" "$*" >&2; exit 1; }
usage() { sed -n '2,8p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    --status)     STATUS=1 ;;
    --no-hub)     NOHUB=1 ;;
    --dist)       DIST=1 ;;
    --rollback)   ROLLBACK=1 ;;
    --host)       HOST="${2:-}"; [ -n "$HOST" ] || die "--host needs an ssh host"; shift ;;
    --binary)     BINARY="${2:-}"; [ -n "$BINARY" ] || die "--binary needs a file"; shift ;;
    --sha256)     WANT_SUM="${2:-}"; shift ;;
    --wait)       WAIT="${2:-}"; shift ;;
    --logins)     shift
                  while [ "$#" -gt 0 ]; do
                    case "$1" in -*) break ;; esac
                    LOGINS_ARG="$LOGINS_ARG $1"; shift
                  done
                  [ -n "$LOGINS_ARG" ] || die "--logins needs all or login names"
                  continue ;;
    -h|--help)    sed -n '2,69p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)           usage >&2; die "unknown flag $1" ;;
    *)            [ -z "$TARGET" ] || die "one target only (got $TARGET and $1)"; TARGET="$1" ;;
  esac
  shift
done
case "$WAIT" in ''|*[!0-9]*) die "--wait needs seconds" ;; esac
case "$POLL" in ''|*[!0-9]*|0) POLL=2 ;; esac
[ -n "$TARGET" ] || TARGET=stable

# ── target ──────────────────────────────────────────────────────────────────
# FULL = the commit (as long as known), S7 = its 7-char short, VER = prod-<S7>.
CHECKOUT="$(cd "$BIN_DIR/.." 2>/dev/null && pwd)"
resolve_target() {
  local t="$TARGET" out
  if [ "$t" = stable ]; then
    [ -x "$BIN_DIR/fleet-stable.sh" ] || die "no fleet-stable.sh beside this script — pass a sha"
    out=$(sh "$BIN_DIR/fleet-stable.sh" show 2>/dev/null)
    t=$(printf '%s\n' "$out" | sed -n 's/^stable: *\([0-9a-f][0-9a-f]*\).*/\1/p' | head -n 1)
    [ -n "$t" ] || RC=1 die "cannot read the stable tag (fleet-stable.sh show: $(printf '%s' "$out" | tr '\n' ' '))"
  fi
  case "$t" in *[!0-9a-f]*|'') die "target must be a hex sha or 'stable' (got $t)" ;; esac
  [ "${#t}" -ge 7 ] || die "target sha too short (need ≥7 chars): $t"
  FULL="$t"
  # Only in a claude-fleet checkout: streamed through `bash -s` (--host) there is
  # none, and the caller already passed the full sha.
  if [ -f "$CHECKOUT/tokenledger/Makefile" ] && git -C "$CHECKOUT" rev-parse --git-dir >/dev/null 2>&1; then
    out=$(git -C "$CHECKOUT" rev-parse -q --verify "$t^{commit}" 2>/dev/null) \
      || { git -C "$CHECKOUT" fetch -q origin "+refs/tags/stable:refs/fleet-node-upgrade/stable" master >/dev/null 2>&1
           out=$(git -C "$CHECKOUT" rev-parse -q --verify "$t^{commit}" 2>/dev/null); } || out=""
    [ -n "$out" ] && FULL="$out"
  fi
  S7=$(printf '%s' "$FULL" | cut -c1-7)
  VER="prod-$S7"
}

# A version string is the target when it is prod-<prefix of FULL>, ≥7 chars
# (builds have used both 7- and 8-char shorts).
ver_ok() {
  local v="${1#prod-}"
  [ "$1" != "$v" ] && [ "${#v}" -ge 7 ] || return 1
  case "$FULL" in "$v"*) return 0 ;; esac
  case "$v" in "$FULL"*) return 0 ;; esac
  return 1
}

sha256_of() { { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1" 2>/dev/null; } | awk '{print $1}'; }
bin_version() { "$1" version 2>/dev/null | awk 'NR==1 {print $2}'; }

# ── --host: ship binary + this script to another machine ────────────────────
if [ -n "$HOST" ]; then
  resolve_target
  # Machine to machine (issue #1626): each ssh asks the hub for a five-minute
  # certificate to $HOST first (fleet-peer-cert.sh). rc 3 = no hub here, plain
  # ssh as before; anything else = the hub said no or is down — stop and say so.
  peer_ssh() {
    local out rc o
    PEER=()
    [ -f "$(dirname "$0")/fleet-peer-cert.sh" ] || return 0
    out=$(bash "$(dirname "$0")/fleet-peer-cert.sh" "$HOST" upgrade); rc=$?
    case "$rc" in
      0) while IFS= read -r o; do [ -n "$o" ] && PEER+=("$o"); done <<EOF_PEER
$out
EOF_PEER
         ;;
      3) ;;
      *) fail "the hub gave no certificate to reach $HOST (fleet-peer-cert exit $rc) — cross-machine access paused" ;;
    esac
  }
  pass=()
  [ "$DRY" = 1 ] && pass+=(--dry-run)
  [ "$STATUS" = 1 ] && pass+=(--status)
  [ "$NOHUB" = 1 ] && pass+=(--no-hub)
  pass+=(--wait "$WAIT")
  # The hub URL is not a secret and a non-interactive ssh has no profile; the
  # viewer token is never sent — the remote reads its own.
  renv=""
  case "${CCQUOTA_HUB_URL:-}" in http*) case "$CCQUOTA_HUB_URL" in *[!A-Za-z0-9.:/_-]*) ;; *) renv="CCQUOTA_HUB_URL=$CCQUOTA_HUB_URL " ;; esac ;; esac
  # shellcheck disable=SC2206
  [ -n "$LOGINS_ARG" ] && pass+=(--logins $LOGINS_ARG)
  if [ "$DRY" = 1 ] || [ "$STATUS" = 1 ]; then
    [ "$DRY" = 1 ] && [ "$STATUS" != 1 ] && pass+=(--binary shipped-by-caller)
    say "host: $HOST — running there with target $VER"
    peer_ssh
    exec ssh -o BatchMode=yes ${PEER[@]+"${PEER[@]}"} "$HOST" "${renv}bash -s -- $FULL ${pass[*]-}" < "$0"
  fi
  if [ -z "$BINARY" ]; then
    # Re-enter ourselves locally for the build only: --dry-run would skip it.
    WORK_H=$(mktemp -d "${TMPDIR:-/tmp}/fleet-node-upgrade.XXXXXX") || fail "mktemp"
    trap 'rm -rf "$WORK_H"' EXIT
    command -v go >/dev/null 2>&1 || fail "no Go on this machine to build $VER — build where Go is, or pass --binary <file>"
    git -C "$CHECKOUT" archive "$FULL" tokenledger | tar -x -C "$WORK_H" || fail "git archive $FULL tokenledger"
    make -s -C "$WORK_H/tokenledger" build "VERSION=$VER" >/dev/null || fail "build ($VER) failed"
    BINARY="$WORK_H/tokenledger/bin/ccquota"
  fi
  [ "$(bin_version "$BINARY")" = "$VER" ] || fail "$BINARY says $(bin_version "$BINARY"), not $VER"
  sum=$(sha256_of "$BINARY")
  [ -z "$WANT_SUM" ] || [ "$WANT_SUM" = "$sum" ] || fail "$BINARY sha256 $sum ≠ --sha256 $WANT_SUM"
  rtmp="/tmp/fleet-node-upgrade-$S7-$$"
  say "host: $HOST — shipping $VER (sha256 $sum) to $rtmp"
  peer_ssh
  ssh -o BatchMode=yes ${PEER[@]+"${PEER[@]}"} "$HOST" "cat > $rtmp && chmod 755 $rtmp" < "$BINARY" || fail "cannot copy the binary to $HOST"
  peer_ssh
  ssh -o BatchMode=yes ${PEER[@]+"${PEER[@]}"} "$HOST" "${renv}bash -s -- $FULL --binary $rtmp --sha256 $sum ${pass[*]-}; rc=\$?; rm -f $rtmp; exit \$rc" < "$0"
  exit $?
fi

[ "${FLEET_NODE_UPGRADE_OS:-$(uname -s)}" = Darwin ] || RC=1 die "macOS (launchd) only for now"
HOSTN="${FLEET_NODE_UPGRADE_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"

# ── logins: one row per agent service on this machine ───────────────────────
# L_NAME/L_DOMAIN/L_LABEL/L_UID/L_PATH/L_DISK parallel arrays.
L_NAME=() L_DOMAIN=() L_LABEL=() L_UID=() L_PATH=()
ME=$(id -un)
ps_rows() {
  if [ -n "${FLEET_NODE_UPGRADE_PS:-}" ]; then sh -c "$FLEET_NODE_UPGRADE_PS"
  else ps -axo uid=,pid=,comm= 2>/dev/null; fi
}
# the path may hold a space (/Library/Application Support/… — the release's, #3034)
PSROWS=$(ps_rows | awk '{ c = $0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", c)
                          n = split(c, p, "/"); if (p[n] == "ccquota") print $1, $2, c }')
running_path() { printf '%s\n' "$PSROWS" | awk -v u="$1" '$1 == u { c = $0; sub(/^[0-9]+ [0-9]+ /, "", c); print c; exit }'; }
running_pid() { printf '%s\n' "$PSROWS" | awk -v u="$1" '$1 == u {print $2; exit}'; }
# The binary a service runs when it is not running right now: ProgramArguments[0],
# or the `exec "<bin>" agent` line of the runner script fleet-node-join writes.
# Reads only that one key — the plist's environment holds the token.
service_path() {
  local p
  p=$(plutil -extract ProgramArguments.0 raw -o - "$1" 2>/dev/null) || p=""
  if [ -n "$p" ] && [ -f "$p" ] && head -c 2 "$p" 2>/dev/null | grep -q '#!'; then
    p=$(sed -n 's/^exec "\([^"]*\)" agent.*/\1/p' "$p" 2>/dev/null | head -n 1)
  fi
  # a credsep launcher's plist names python, not the agent: never a path to write over
  case "$p" in */ccquota) ;; *) p="" ;; esac
  printf '%s\n' "$p"
}
add_login() { # name domain label plist
  local uid p
  uid=$(printf '%s\n' ${FLEET_NODE_UPGRADE_UIDS:-} | sed -n "s/^$1=//p" | head -n 1)
  [ -n "$uid" ] || uid=$(id -u "$1" 2>/dev/null) || uid=""
  p=""
  [ -n "$uid" ] && p=$(running_path "$uid")
  [ -n "$p" ] || p=$(service_path "$4")
  L_NAME+=("$1"); L_DOMAIN+=("$2"); L_LABEL+=("$3"); L_UID+=("${uid:-?}"); L_PATH+=("${p:-?}")
}
for f in "$DDIR"/com.ccquota.agent.*.plist; do
  [ -f "$f" ] || continue
  n=$(basename "$f" .plist); n=${n#com.ccquota.agent.}
  add_login "$n" system "com.ccquota.agent.$n" "$f"
done
[ -f "$ADIR/com.ccquota.agent.plist" ] && add_login "$ME" gui com.ccquota.agent "$ADIR/com.ccquota.agent.plist"
[ "${#L_NAME[@]}" -gt 0 ] || RC=1 die "no ccquota agent service on $HOSTN (looked in $DDIR and $ADIR)"

# Selection: --logins all (default) or names, each of which must exist.
SEL=()
if [ -z "$LOGINS_ARG" ] || [ "$(printf '%s' "$LOGINS_ARG" | tr -d ' ')" = all ]; then
  i=0; while [ "$i" -lt "${#L_NAME[@]}" ]; do SEL+=("$i"); i=$((i+1)); done
else
  for want in $LOGINS_ARG; do
    i=0 hit=""
    while [ "$i" -lt "${#L_NAME[@]}" ]; do [ "${L_NAME[$i]}" = "$want" ] && hit=$i; i=$((i+1)); done
    [ -n "$hit" ] || die "no agent for login '$want' on $HOSTN (have: ${L_NAME[*]-})"
    SEL+=("$hit")
  done
fi

# Only now — a machine with no agent has already left, without a network read.
resolve_target

# ── the hub's view: HR = `<os_user> <agent_version> <connected> <age_sec>` rows
# for this host; HUB_NOTE says why there are none. Set in THIS shell, never in a
# $(…) — the note must survive.
HUB_URL="${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-}}" HUB_TOK="" HUB_NOTE="" HR=""
if [ -z "${FLEET_NODE_UPGRADE_NODES_CMD:-}" ] && [ "$NOHUB" != 1 ]; then
  # the machine's one config file (issue #1623) holds the address, FLEET_HUB_URL
  [ -n "$HUB_URL" ] || HUB_URL=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?FLEET_HUB_URL=//p' \
      "${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}/fleet.conf" 2>/dev/null | tail -n1 | tr -d "\"' ")
  [ -n "$HUB_URL" ] || HUB_URL=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("url") or "")
except Exception: pass' "${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet/hub.json" 2>/dev/null)
  HUB_TOK="${CCQUOTA_VIEWER_TOKEN:-}"
  if [ -z "$HUB_TOK" ] && [ -r "$HOME/.ccquota/viewer-token" ]; then read -r HUB_TOK < "$HOME/.ccquota/viewer-token" || true; fi
fi
hub_load() {
  local j
  HR=""
  if [ "$NOHUB" = 1 ]; then HUB_NOTE="--no-hub"; return 1; fi
  if [ -n "${FLEET_NODE_UPGRADE_NODES_CMD:-}" ]; then
    j=$(sh -c "$FLEET_NODE_UPGRADE_NODES_CMD") || { HUB_NOTE="hub unreachable"; return 1; }
  else
    [ -n "$HUB_URL" ] || { HUB_NOTE="no hub URL"; return 1; }
    [ -n "$HUB_TOK" ] || { HUB_NOTE="no viewer token"; return 1; }
    j=$(curl -fsS -m 10 -H "Authorization: Bearer $HUB_TOK" "${HUB_URL%/}/v1/nodes" 2>/dev/null) \
      || { HUB_NOTE="hub unreachable"; return 1; }
  fi
  HR=$(printf '%s' "$j" | python3 -c '
import json, sys
host = sys.argv[1].lower().split(".")[0]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for n in d.get("nodes") or []:
    if str(n.get("hostname") or "").lower().split(".")[0] != host:
        continue
    age = n.get("age_sec")
    print("%s %s %s %s" % (n.get("os_user") or "?", n.get("agent_version") or "?",
          "yes" if n.get("connected") else "no", "?" if age is None else int(age)))
' "$HOSTN") || { HUB_NOTE="hub answer unreadable"; return 1; }
  HUB_NOTE=""
  [ -n "$HR" ] || HUB_NOTE="hub lists no login on $HOSTN"
  return 0
}
hub_field() { printf '%s\n' "$2" | awk -v u="$1" -v f="$3" '$1 == u {print $f; exit}'; }

# ── --status ────────────────────────────────────────────────────────────────
if [ "$STATUS" = 1 ]; then
  hub_load || true
  say "target: $VER  (host $HOSTN${HUB_NOTE:+; hub: $HUB_NOTE})"
  printf '%-10s %-34s %-14s %-14s %s\n' LOGIN PATH VERSION HUB HEARTBEAT
  behind=0 n=0
  for i in ${SEL[@]+"${SEL[@]}"}; do
    nm="${L_NAME[$i]}" p="${L_PATH[$i]}"
    v=$( [ -x "$p" ] && bin_version "$p" ); v=${v:-?}
    hv=$(hub_field "$nm" "$HR" 2); hc=$(hub_field "$nm" "$HR" 3); ha=$(hub_field "$nm" "$HR" 4)
    hb="-"
    [ -n "$hv" ] && { [ "$hc" = yes ] && hb="connected ${ha}s" || hb="down ${ha}s"; }
    n=$((n+1))
    # Behind = the bytes on disk, or the version the hub sees running, is not it.
    if ! ver_ok "$v" || { [ -n "$hv" ] && ! ver_ok "$hv"; }; then behind=$((behind+1)); mark=behind; else mark=ok; fi
    printf '%-10s %-34s %-14s %-14s %s  %s\n' "$nm" "$p" "$v" "${hv:--}" "$hb" "$mark"
  done
  say "summary: $behind/$n behind $VER"
  exit 0
fi

# ── plan ────────────────────────────────────────────────────────────────────
hub_load || true
say "target: $VER  (commit $FULL; host $HOSTN${HUB_NOTE:+; hub: $HUB_NOTE})"
if [ -n "$BINARY" ]; then say "binary: $BINARY"
elif [ "$DRY" = 1 ] && [ "$DIST" = 1 ]; then say "binary: would ask the hub for ${VER}, else build tokenledger at $S7"
elif [ "$DRY" = 1 ]; then say "binary: would build tokenledger at $S7 (make build VERSION=$VER)"
fi
PATHS=() TODO=()
for i in ${SEL[@]+"${SEL[@]}"}; do
  nm="${L_NAME[$i]}" p="${L_PATH[$i]}"
  [ "$p" != "?" ] || fail "cannot tell which binary $nm's agent runs (not running, no ProgramArguments)"
  case "$p" in
    "$NODE_ROOT"/*) say "  $nm  ${L_DOMAIN[$i]}/${L_LABEL[$i]}  $p  → the release's ccquota — the machine's updater moves it (#3034), skip"
                    continue ;;
  esac
  v=$( [ -x "$p" ] && bin_version "$p" ); v=${v:-?}
  hv=$(hub_field "$nm" "$HR" 2)
  # Hub not read at all (--no-hub, no viewer token, down) → the bytes on disk
  # decide, as --status does; a hub that answers but lists no such login does not
  # vouch for it.
  if ver_ok "$v" && { if [ -n "$hv" ]; then ver_ok "$hv"; else [ -z "$HR" ] && [ -n "$HUB_NOTE" ]; fi; }; then act="current — skip"
  else act="upgrade"; TODO+=("$i"); fi
  say "  $nm  ${L_DOMAIN[$i]}/${L_LABEL[$i]}  $p  disk ${v} · hub ${hv:--}  → $act"
  case " ${PATHS[*]-} " in *" $p "*) ;; *) PATHS+=("$p") ;; esac
done
if [ "${#TODO[@]}" -eq 0 ]; then say "all ${#SEL[@]} on $VER — nothing to do"; exit 0; fi
if [ "$DRY" = 1 ]; then say "dry-run: ${#TODO[@]} login(s) would be upgraded and restarted one by one; nothing changed"; exit 0; fi

# ── build / check the binary ────────────────────────────────────────────────
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-node-upgrade.XXXXXX") || fail "mktemp"
trap 'rm -rf "$WORK"' EXIT
# --dist: the hub's build of this platform, when it is the target version. Any
# miss (no token, no hub, 404, a bad hash, another version) says why on one line
# and falls through to the local build.
dist_fetch() {
  local os arch envf url code want got tok
  os=$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$(uname -m)
  case "$arch" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; esac
  if [ -n "${FLEET_NODE_UPGRADE_DIST_CMD:-}" ]; then
    code=$(sh -c "$FLEET_NODE_UPGRADE_DIST_CMD \"\$@\"" _ "$os-$arch" "$WORK/dist" "$WORK/dist.h" 2>/dev/null) || code=000
  else
    envf="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}/node.env"
    url="${CCQUOTA_HUB_URL:-}"
    [ -n "$url" ] || url=$(sed -n 's/^CCQUOTA_HUB_URL=//p' "$envf" 2>/dev/null | head -n 1 | tr -d "\"' ")
    [ -n "$url" ] || url="$HUB_URL"
    [ -n "$url" ] || { say "dist: no hub URL — building locally"; return 1; }
    # The node token: read here, handed to curl on stdin, gone with this function.
    tok="${CCQUOTA_TOKEN:-}"
    [ -n "$tok" ] || tok=$(sed -n 's/^CCQUOTA_TOKEN=//p' "$envf" 2>/dev/null | head -n 1 | tr -d "\"' ")
    [ -n "$tok" ] || { say "dist: no node token ($envf) — building locally"; return 1; }
    code=$(printf 'Authorization: Bearer %s\n' "$tok" | curl -sS --max-time 300 -H @- \
      -D "$WORK/dist.h" -o "$WORK/dist" -w '%{http_code}' "${url%/}/v1/node/dist/$os-$arch" 2>/dev/null) || code=000
    tok=""
  fi
  [ "$code" = 200 ] || { say "dist: the hub serves no ccquota-$os-$arch (HTTP $code) — building locally"; return 1; }
  want=$(tr -d '\r' < "$WORK/dist.h" 2>/dev/null | sed -n 's/^[Xx]-[Cc]cquota-[Ss]ha256: *//p' | head -n 1)
  got=$(sha256_of "$WORK/dist")
  [ -n "$want" ] && [ "$want" = "$got" ] || { say "dist: ccquota-$os-$arch sha256 ${got:-?} ≠ the hub's ${want:-none} — building locally"; return 1; }
  chmod 755 "$WORK/dist" || return 1
  got=$(bin_version "$WORK/dist")
  [ "$got" = "$VER" ] || { say "dist: the hub serves ${got:-an unreadable binary}, not $VER — building locally"; return 1; }
  say "dist: ccquota-$os-$arch $VER from the hub (sha256 $want)"
  BINARY="$WORK/dist"
}
[ -z "$BINARY" ] && [ "$DIST" = 1 ] && dist_fetch
if [ -z "$BINARY" ]; then
  command -v go >/dev/null 2>&1 || fail "no Go on $HOSTN to build $VER — run this where Go is with --host $HOSTN, or pass --binary <file>"
  git -C "$CHECKOUT" archive "$FULL" tokenledger | tar -x -C "$WORK" || fail "git archive $FULL tokenledger (is $FULL in $CHECKOUT?)"
  say "build: tokenledger at $S7 (VERSION=$VER)"
  make -s -C "$WORK/tokenledger" build "VERSION=$VER" >"$WORK/build.log" 2>&1 \
    || fail "build failed: $(tail -n 3 "$WORK/build.log" | tr '\n' ' ')"
  BINARY="$WORK/tokenledger/bin/ccquota"
fi
[ -x "$BINARY" ] || fail "$BINARY is not an executable"
got=$(bin_version "$BINARY")
[ "$got" = "$VER" ] || fail "$BINARY says '${got:-nothing}', not $VER — refusing to install it"
SUM=$(sha256_of "$BINARY")
[ -n "$SUM" ] || fail "cannot hash $BINARY"
[ -z "$WANT_SUM" ] || [ "$WANT_SUM" = "$SUM" ] || fail "$BINARY sha256 $SUM ≠ --sha256 $WANT_SUM"
say "binary: $VER sha256 $SUM"

# ── install onto every path ─────────────────────────────────────────────────
INST_P=() INST_PRIV=()
for p in ${PATHS[@]+"${PATHS[@]}"}; do
  if [ -f "$p" ] && [ "$(sha256_of "$p")" = "$SUM" ]; then say "install: $p already $VER"; continue; fi
  d=$(dirname "$p")
  owner=$(stat -f %Su "$p" 2>/dev/null || stat -c %U "$p" 2>/dev/null)
  if [ -w "$d" ] && { [ ! -e "$p" ] || [ -w "$p" ]; }; then priv=""; else priv="$SUDO"; fi
  own=()
  [ -n "$priv" ] && [ -n "$owner" ] && own=(-o "$owner")
  # shellcheck disable=SC2086
  { [ ! -f "$p" ] || $priv cp -p "$p" "$p.prev"; } \
    && $priv install -m 755 ${own[@]+"${own[@]}"} "$BINARY" "$p.new" \
    && $priv mv -f "$p.new" "$p" \
    || fail "install onto $p${priv:+ (via $priv)} — nothing restarted yet"
  [ "$(sha256_of "$p")" = "$SUM" ] || fail "$p sha256 after install is not $SUM"
  INST_P+=("$p"); INST_PRIV+=("$priv")
  say "install: $p ← $VER (old kept as $p.prev)"
done

# ── restart, one login at a time, waiting for its control channel ───────────
# kick <i> — launchctl kickstart -k that login's service.
kick() {
  if [ "${L_DOMAIN[$1]}" = gui ]; then
    $LAUNCHCTL kickstart -k "gui/${L_UID[$1]}/${L_LABEL[$1]}" >/dev/null 2>&1
  else
    # shellcheck disable=SC2086
    $SUDO $LAUNCHCTL kickstart -k "system/${L_LABEL[$1]}" >/dev/null 2>&1
  fi
}
# undo <i> — --rollback: every path this run installed that no finished login
# runs goes back to its .prev, then login <i> is kickstarted onto the old bytes.
DONE_P=()
undo() {
  local k=0 p back=""
  [ "$ROLLBACK" = 1 ] || return 0
  while [ "$k" -lt "${#INST_P[@]}" ]; do
    p="${INST_P[$k]}"
    case " ${DONE_P[*]-} " in *" $p "*) k=$((k+1)); continue ;; esac
    # shellcheck disable=SC2086
    [ -f "$p.prev" ] && ${INST_PRIV[$k]} mv -f "$p.prev" "$p" && back="$back $p"
    k=$((k+1))
  done
  kick "$1" || true
  RB="; rolled back:${back:- nothing to restore} (${L_NAME[$1]} kickstarted on the old binary)"
}
RB=""
done_n=0
for i in ${TODO[@]+"${TODO[@]}"}; do
  nm="${L_NAME[$i]}" uid="${L_UID[$i]}"
  old=$(running_pid "$uid")
  if ! kick "$i"; then
    undo "$i"
    if [ "${L_DOMAIN[$i]}" = gui ]; then fail "$nm: launchctl kickstart -k gui/$uid/${L_LABEL[$i]} ($done_n done)$RB"
    else fail "$nm: ${SUDO:+$SUDO }launchctl kickstart -k system/${L_LABEL[$i]} ($done_n done)$RB"; fi
  fi
  deadline=$((SECONDS + WAIT)) ok=""
  while [ "$SECONDS" -le "$deadline" ]; do
    sleep "$POLL"
    if [ "$NOHUB" != 1 ] && hub_load; then
      hv=$(hub_field "$nm" "$HR" 2); hc=$(hub_field "$nm" "$HR" 3)
      ver_ok "$hv" && [ "$hc" = yes ] && { ok="hub: connected on $hv"; break; }
    else
      PSROWS=$(ps_rows | awk '{ n=split($3, p, "/"); if (p[n] == "ccquota") print $1, $2, $3 }')
      new=$(running_pid "$uid")
      [ -n "$new" ] && [ "$new" != "$old" ] && { ok="process $new running (hub not checked${HUB_NOTE:+: $HUB_NOTE})"; break; }
    fi
  done
  [ -n "$ok" ] || { undo "$i"; fail "$nm: restarted, but no control channel on $VER within ${WAIT}s — stopping here ($done_n done; the rest untouched)$RB"; }
  done_n=$((done_n+1)); DONE_P+=("${L_PATH[$i]}")
  say "restart: $nm — $ok"
done
say "done: ${done_n}/${#TODO[@]} login(s) on $VER"
