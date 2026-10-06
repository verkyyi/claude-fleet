#!/bin/bash
# fleet-node-join.sh — a new machine joins the hub in one command (issue #1418,
# EPIC #1407 R3). Run on the NEW machine, as the login that will run the fleet:
#
#   curl -fsSL <script-url> | bash -s -- --hub https://hub.example.com --token fj_…
#
# The hub's /nodes page mints the join code and prints that exact line. The code
# is one-time and expires after 10 minutes; it is traded for this machine's own
# enrollment token in the FIRST step, before anything slow, so a long Homebrew
# install cannot outlive it.
#
# `fleet node join` (issue #1627) runs this script too, with no code: the scan
# (`fleet-login.py node`, the same page as `fleet login`) already holds the
# hub's node pass, handed over as --joined <file>; --ui prints the steps the way
# `fleet login` does — one `✓ …` line each, a failure as one `✗ …` line with
# 「重跑同一条命令即可」 — and keeps the detail in $FLEET_CONF_DIR/node-join.log.
# A rerun needs neither a code nor a pass while node.env's token still works.
#
# Steps (each prints one `<step>: …` line; a rerun redoes only what is missing):
#
#   join      POST <hub>/v1/node/join {code, hostname, os_user} → this login's
#             agent token, kept in ~/.config/claude-fleet/node.env (0600, never
#             printed). A rerun whose saved token the hub still accepts skips it
#             and leaves the code unspent — no second endpoint.
#   deps      git tmux gh python3 zsh curl — apt-get / dnf / yum / apk as root or
#             through passwordless sudo on Linux; Homebrew on macOS (installed
#             non-interactively when missing and sudo -n works). --no-deps skips.
#   agent     ccquota → ~/.local/bin/ccquota: --ccquota <file>, else the hub's own
#             build (/v1/node/dist/<os>-<arch>, SHA-256 checked), else one already
#             on PATH, else `go install`.
#   service   the agent under the platform's supervisor, as THIS login:
#             macOS — a LaunchAgent in the gui domain, else (SSH-only login) a
#             LaunchDaemon with UserName through sudo -n; Linux — a systemd user
#             unit (+ linger), else a system unit with User= through sudo -n;
#             neither (a container) — started detached, and said so: it will not
#             come back after a reboot. CCQUOTA_FLEET=1; --admin (the default)
#             adds CCQUOTA_FLEET_ADMIN=1, so the hub's account ops and SSH user CA
#             (#1411/#1412) reach this machine — the hub honours it only for a
#             login in its CCQUOTA_FLEET_ADMIN_USERS, and the admin agent writes
#             the CA + sshd_config.d snippet itself (sshd -t first, rollback on
#             failure, never a restart). Refuses to replace an agent service it
#             did not write unless --force.
#             COMPUTE (issue #1719): a FIRST join writes CCQUOTA_FLEET_COMPUTE=0
#             into node.env — the login heartbeats, holds its identity and
#             certificates, and coordinates, but the hub places no session on it
#             and leases it no account (it uses its own). `--compute 1` opens it
#             (EPIC #1718: «默认不在本机跑»). A rerun keeps what node.env says —
#             a node joined before #1719 has no line and keeps running sessions —
#             unless --compute is given.
#   online    polls <hub>/v1/node/self until the hub sees this agent (--wait).
#   fleet     ~/.claude/fleet cloned at `stable` (or --fleet-src/--ref), then
#             bin/fleet-login-bootstrap.sh: Claude Code, hooks, daemons, a seed
#             fleet, doctor. Its failure is a WARN — the machine is already on the
#             hub — with the rerun line. --no-fleet skips.
#
# Usage:
#   fleet-node-join.sh --hub <url> --token <fj_code> [--no-admin] [--no-deps]
#                      [--joined <file>] [--ui]
#                      [--no-fleet] [--fleet-src <git url|dir>] [--ref <ref>]
#                      [--ccquota <file>] [--service auto|detached|none]
#                      [--wait <secs>] [--force] [--compute 0|1]
#
# Env (test seams): FLEET_JOIN_SUDO (the sudo prefix; default `sudo -n`) ·
#   FLEET_JOIN_OS / FLEET_JOIN_ARCH (override uname) · FLEET_JOIN_POLL (poll
#   interval, default 3) · FLEET_INSTALL_ROOT (~/.claude/fleet) ·
#   FLEET_CONF_DIR (~/.config/claude-fleet)
# Exit: 0 joined and online · 1 a step failed (the line says which) · 2 usage
set -uo pipefail

PROG=fleet-node-join
HUB="" CODE="" JOINED="" UI=0 ADMIN=1 DEPS=1 FLEET=1 SERVICE=auto WAIT=180 FORCE=0
SRC_REPO="https://github.com/verkyyi/claude-fleet.git" SRC_REF="" CCQ_SRC=""
SRC_SET=0
COMPUTE=""   # "" = a first join's 0, a rerun's whatever node.env says (issue #1719)

usage() {
  if [ -f "$0" ]; then sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  else echo "usage: fleet-node-join.sh --hub <url> --token <fj_code> [--no-admin] [--no-deps] [--no-fleet] [--service auto|detached|none] [--wait <secs>] [--force]"; fi
}
die() {
  LAST="$1"
  # under --ui the EXIT trap says it as the one ✗ line, once it is set
  [ "$UI" = 1 ] && [ "${TRAPPED:-0}" = 1 ] || printf '%s: %s\n' "$PROG" "$1" >&2
  exit "${2:-1}"
}
# --ui (fleet node join): the `<step>: …` lines go to the log, and each step
# that lands prints one ✓ line through ui(); the last FAIL becomes the ✗ line.
LAST="" LOG=""
say() {
  # the FIRST failure is the one that stopped the run (the fleet step still
  # runs after a failed online wait)
  case "$*" in *FAIL*) [ -n "$LAST" ] || LAST="$*" ;; esac
  if [ "$UI" = 1 ] && [ -n "$LOG" ]; then printf '%s\n' "$*" >>"$LOG"; return 0; fi
  [ "$UI" = 1 ] && return 0
  printf '%s\n' "$*"
}
ui() { [ "$UI" = 1 ] && printf '%s\n' "$*"; return 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --hub) HUB="${2:-}"; shift ;;
    --token) CODE="${2:-}"; shift ;;
    --joined) JOINED="${2:-}"; shift ;;
    --ui) UI=1 ;;
    --admin) ADMIN=1 ;;
    --no-admin) ADMIN=0 ;;
    --no-deps) DEPS=0 ;;
    --no-fleet) FLEET=0 ;;
    --fleet-src) SRC_REPO="${2:-}"; SRC_SET=1; shift ;;
    --ref) SRC_REF="${2:-}"; shift ;;
    --ccquota) CCQ_SRC="${2:-}"; shift ;;
    --service) SERVICE="${2:-}"; shift ;;
    --wait) WAIT="${2:-}"; shift ;;
    --force) FORCE=1 ;;
    --compute) COMPUTE="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" 2 ;;
  esac
  shift
done

[ -n "$HUB" ] || die "--hub <url> is required" 2
HUB="${HUB%/}"
case "$HUB" in http://*|https://*) ;; *) die "--hub must be an http(s) URL: $HUB" 2 ;; esac
if [ -n "$JOINED" ]; then
  [ -r "$JOINED" ] || die "--joined $JOINED is not readable" 2
fi
case "$SERVICE" in auto|detached|none) ;; *) die "--service: auto | detached | none" 2 ;; esac
case "$WAIT" in ''|*[!0-9]*) die "--wait: seconds" 2 ;; esac
case "$COMPUTE" in ''|0|1) ;; *) die "--compute: 0 | 1" 2 ;; esac
# fj_ + 26 base32 characters — checked here so a typo fails before anything runs.
if [ -n "$CODE" ] && ! printf '%s' "$CODE" | grep -Eq '^fj_[a-z2-7]{26}$'; then
  die "--token does not look like a join code (fj_ + 26 characters)" 2
fi
command -v curl >/dev/null 2>&1 || die "curl is required"

OS="${FLEET_JOIN_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"
case "$OS" in darwin|linux) ;; *) die "unsupported OS: $OS (macOS or Linux)" ;; esac
ARCH="${FLEET_JOIN_ARCH:-$(uname -m)}"
case "$ARCH" in x86_64|amd64) ARCH=amd64 ;; arm64|aarch64) ARCH=arm64 ;; *) die "unsupported CPU: $ARCH" ;; esac

ME="$(id -un)"
UID_N="$(id -u)"
HOSTN="$(hostname -s 2>/dev/null || hostname)"
CONF="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
ROOT="${FLEET_INSTALL_ROOT:-$HOME/.claude/fleet}"
ENVF="$CONF/node.env"
STATE="$HOME/.ccquota"
LBIN="$HOME/.local/bin"
CCQ="$LBIN/ccquota"
RUNNER="$STATE/run-agent.sh"
MARK="claude-fleet node-join (issue #1418)"
POLL="${FLEET_JOIN_POLL:-3}"
SUDO="${FLEET_JOIN_SUDO-sudo -n}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-node-join.XXXXXX")" || die "no temp dir"
if [ "$UI" = 1 ]; then
  LOG="$CONF/node-join.log"
  mkdir -p "$CONF" && printf '\n== %s %s\n' "$(date '+%F %T')" "$HUB" >>"$LOG" || LOG=""
fi
# step_zh <line> — the step a `<step>: …` line names, in the ✗ line's words.
step_zh() {
  case "$1" in
    join:*) echo 登记 ;; deps:*) echo 装依赖 ;; agent:*) echo 装 agent ;;
    service:*) echo 起服务 ;; online:*) echo 等上线 ;; fleet:*) echo 装 fleet ;; *) echo 加节点 ;;
  esac
}
on_exit() {
  rc=$?
  rm -rf "$WORK"
  if [ "$UI" = 1 ] && [ "$rc" != 0 ]; then
    why="${LAST#*: }"; why="${why#FAIL — }"
    printf '✗ %s失败：%s\n  重跑同一条命令即可：fleet node join%s\n' "$(step_zh "$LAST")" "${why:-exit $rc}" \
      "${LOG:+（详细记录 ${LOG}）}"
  fi
  return "$rc"
}
trap on_exit EXIT
TRAPPED=1

# One JSON string field from the hub's compact answer. The hub writes Go's
# encoding/json: no whitespace, and the fields read here (tokens, ids, names,
# an ssh public key) carry no quote or backslash — so this needs no python3,
# which a clean Linux box does not have yet.
jfield() { sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p" | head -n 1; }
jbool() { if grep -q "\"$1\":true"; then echo 1; else echo 0; fi; }

# Root, or passwordless sudo, or nothing — never a password prompt.
priv() {
  if [ "$UID_N" = 0 ]; then "$@"; return; fi
  [ -n "$SUDO" ] || return 1
  # shellcheck disable=SC2086
  $SUDO "$@"
}
can_priv() { [ "$UID_N" = 0 ] || { [ -n "$SUDO" ] && priv true >/dev/null 2>&1; }; }

load_env() { # → TOKEN, saved HUB match, KIND, SAVED_COMPUTE
  TOKEN="" SAVED_HUB="" KIND="" SAVED_COMPUTE=""
  [ -f "$ENVF" ] || return 1
  SAVED_COMPUTE="$(sed -n 's/^CCQUOTA_FLEET_COMPUTE=//p' "$ENVF" | head -n 1)"
  TOKEN="$(sed -n 's/^CCQUOTA_TOKEN=//p' "$ENVF" | head -n 1)"
  SAVED_HUB="$(sed -n 's/^CCQUOTA_HUB_URL=//p' "$ENVF" | head -n 1)"
  KIND="$(sed -n 's/^CCQUOTA_FLEET_NODE_KIND=//p' "$ENVF" | head -n 1)"
  [ -n "$TOKEN" ]
}

write_env() {
  mkdir -p "$CONF" || return 1
  ( umask 077
    {
      printf '# %s — this login'"'"'s ccquota agent. Holds a credential: 0600.\n' "$MARK"
      printf 'CCQUOTA_HUB_URL=%s\n' "$HUB"
      printf 'CCQUOTA_TOKEN=%s\n' "$1"
      printf 'CCQUOTA_FLEET=1\n'
      if [ "$ADMIN" = 1 ]; then printf 'CCQUOTA_FLEET_ADMIN=1\n'; fi
      # The node's kind, from the hub's answer to the join (issue #1428):
      # ephemeral = a SPOT node, whose agent treats SIGTERM as the cloud
      # taking the machine (tell the hub, move idle sessions off, then stop).
      if [ "${KIND:-}" = ephemeral ]; then printf 'CCQUOTA_FLEET_NODE_KIND=ephemeral\n'; fi
      # Coordinate only (issue #1719): no placement, no lease. Absent = on.
      if [ -n "$COMPUTE" ]; then printf 'CCQUOTA_FLEET_COMPUTE=%s\n' "$COMPUTE"; fi
    } > "$ENVF.tmp" ) && mv "$ENVF.tmp" "$ENVF" && chmod 600 "$ENVF"
}

self_status() { # → the /v1/node/self body on stdout; exit 0 iff 200
  curl -fsS --max-time 15 -H "Authorization: Bearer $TOKEN" "$HUB/v1/node/self" 2>/dev/null
}

# ── join ────────────────────────────────────────────────────────────────────
TOKEN="" SAVED_HUB="" KIND="" SAVED_COMPUTE=""
# compute (issue #1719): --compute wins; else a node.env already here keeps its
# word (no line = a node from before #1719, still on); else a first join is 0.
if [ -z "$COMPUTE" ]; then
  if [ -f "$ENVF" ]; then load_env; COMPUTE="$SAVED_COMPUTE"; else COMPUTE=0; fi
fi
if [ -z "$JOINED" ] && load_env && [ "$SAVED_HUB" = "$HUB" ] && self_status >/dev/null; then
  say "join: already registered with $HUB — the join code was not spent"
  # Keep the admin choice of THIS run.
  write_env "$TOKEN" || die "join: cannot rewrite $ENVF"
  ADMIN_OK="?"; SSH_CA=""
  ui "✓ 已是 $HUB 的节点（沿用 $ENVF 的通行证）"
else
  if [ -n "$JOINED" ]; then
    # The scan's node pass (fleet node join, #1627): the hub already enrolled
    # this machine when the person confirmed — nothing to redeem.
    cp "$JOINED" "$WORK/join" || die "join: cannot read $JOINED"
    code=200
  elif [ -n "$CODE" ]; then
    body="{\"code\":\"$CODE\",\"hostname\":\"$HOSTN\",\"os_user\":\"$ME\"}"
    code=$(curl -sS --max-time 30 -o "$WORK/join" -w '%{http_code}' -H 'Content-Type: application/json' \
      -X POST --data "$body" "$HUB/v1/node/join" 2>"$WORK/join.err") || code=000
  else
    die "join: this login is not registered with $HUB yet — run: fleet node join (or pass --token <join code>)" 2
  fi
  case "$code" in
    200) ;;
    401) die "join: the hub refused the code — unknown, already used, or older than 10 minutes. Mint a new one on $HUB/nodes" ;;
    404) die "join: $HUB has no /v1/node/join — is it a ccquota hub with CCQUOTA_FLEET=1, and new enough?" ;;
    000) die "join: cannot reach $HUB ($(tr '\n' ' ' < "$WORK/join.err"))" ;;
    *) die "join: HTTP $code from $HUB: $(head -c 300 "$WORK/join")" ;;
  esac
  TOKEN="$(jfield token < "$WORK/join")"
  [ -n "$TOKEN" ] || die "join: the hub answered without a token"
  KIND="$(jfield kind < "$WORK/join")"
  write_env "$TOKEN" || die "join: cannot write $ENVF"
  ADMIN_OK="$(jbool admin < "$WORK/join")"
  SSH_CA="$(jfield ssh_ca < "$WORK/join")"
  kind_note=""
  [ "$KIND" = ephemeral ] && kind_note=" · SPOT node (ephemeral): SIGTERM moves idle sessions off, then stops"
  say "join: registered as $(jfield label < "$WORK/join") ($(jfield endpoint_id < "$WORK/join")); token in $ENVF$kind_note"
  [ -n "$JOINED" ] || ui "✓ 已登记为节点 $(jfield label < "$WORK/join")（通行证在 ${ENVF}）"
fi
DIST_LIST=""
[ -f "$WORK/join" ] && DIST_LIST="$(sed -n 's/.*"dist":\[\([^]]*\)\].*/\1/p' "$WORK/join" | tr -d '"')"

# ── deps ────────────────────────────────────────────────────────────────────
# fc_tmux_ok — tmux ≥ 3.2 on PATH; an older one counts as missing (issue #1629).
# A COPY of bin/fleet-client-lib.sh's (this script runs as `curl … | bash`, with
# nothing beside it to source); fleet-install-selftest.sh leg F holds the two
# byte-identical.
fc_tmux_ok() {
  FC_TMUX_V=""
  command -v tmux >/dev/null 2>&1 || return 1
  FC_TMUX_V=$(tmux -V 2>/dev/null); FC_TMUX_V=${FC_TMUX_V#tmux }
  _fc_v=${FC_TMUX_V#next-}; _fc_maj=${_fc_v%%.*}
  case "$_fc_v" in *.*) _fc_min=${_fc_v#*.}; _fc_min=${_fc_min%%[!0-9]*} ;; *) _fc_maj=${_fc_maj%%[!0-9]*}; _fc_min=0 ;; esac
  case "$_fc_maj" in ''|*[!0-9]*) return 1 ;; esac
  case "$_fc_min" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_fc_maj" -gt 3 ] || { [ "$_fc_maj" -eq 3 ] && [ "$_fc_min" -ge 2 ]; }
}
have() {
  case "$1" in
    tmux) fc_tmux_ok ;;
    # macOS ships git/python3 as stubs that pop a GUI installer: ask them to run.
    git|python3) "$1" --version >/dev/null 2>&1 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}
brew_bin() {
  for b in "$(command -v brew 2>/dev/null)" /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [ -n "$b" ] && [ -x "$b" ] && { echo "$b"; return 0; }
  done
  return 1
}
install_deps() {
  missing=""
  for d in git tmux gh python3 zsh curl; do have "$d" || missing="$missing $d"; done
  missing="${missing# }"
  if [ -z "$missing" ]; then say "deps: git tmux gh python3 zsh curl present"; ui "✓ 依赖齐了（git tmux gh python3 zsh curl）"; return 0; fi
  say "deps: installing $missing"
  if [ "$OS" = darwin ]; then
    BREW="$(brew_bin)" || {
      can_priv || { say "deps: FAIL — no Homebrew, and installing it needs passwordless sudo. Install https://brew.sh, then rerun"; return 1; }
      NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" >"$WORK/brew.log" 2>&1 \
        || { say "deps: FAIL — Homebrew install (log: $(tail -n 3 "$WORK/brew.log" | tr '\n' ' '))"; return 1; }
      BREW="$(brew_bin)" || { say "deps: FAIL — Homebrew installed but not found"; return 1; }
    }
    eval "$("$BREW" shellenv)"
    # shellcheck disable=SC2086
    "$BREW" install $missing >"$WORK/deps.log" 2>&1 || { say "deps: FAIL — brew install $missing: $(tail -n 3 "$WORK/deps.log" | tr '\n' ' ')"; return 1; }
  else
    can_priv || { say "deps: FAIL — installing$missing needs root or passwordless sudo"; return 1; }
    pkgs=""
    for d in $missing; do pkgs="$pkgs $d"; done
    if command -v apt-get >/dev/null 2>&1; then
      priv env DEBIAN_FRONTEND=noninteractive apt-get update -qq >"$WORK/deps.log" 2>&1
      # gh separately: older releases lack the package, and the agent does not need it.
      core=$(printf '%s\n' $pkgs | grep -vx gh | tr '\n' ' ')
      if [ -n "${core// /}" ]; then
        # shellcheck disable=SC2086
        priv env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates $core >>"$WORK/deps.log" 2>&1 \
          || { say "deps: FAIL — apt-get install $core: $(tail -n 3 "$WORK/deps.log" | tr '\n' ' ')"; return 1; }
      fi
      case " $pkgs " in *" gh "*)
        priv env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh >>"$WORK/deps.log" 2>&1 \
          || say "deps: WARN — gh is not in this distro's packages; install it from https://cli.github.com before using a repo fleet" ;;
      esac
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
      pm=dnf; command -v dnf >/dev/null 2>&1 || pm=yum
      # shellcheck disable=SC2086
      priv "$pm" install -y $pkgs >"$WORK/deps.log" 2>&1 || { say "deps: FAIL — $pm install$pkgs"; return 1; }
    elif command -v apk >/dev/null 2>&1; then
      # shellcheck disable=SC2086
      priv apk add --no-cache bash $pkgs >"$WORK/deps.log" 2>&1 || { say "deps: FAIL — apk add$pkgs"; return 1; }
    else
      say "deps: FAIL — no apt-get / dnf / yum / apk; install$missing yourself and rerun with --no-deps"; return 1
    fi
  fi
  still=""
  for d in $missing; do have "$d" || still="$still $d"; done
  case " $still " in *" gh "*) still="$(printf '%s' "$still" | sed 's/ gh//')" ;; esac
  [ -z "${still// /}" ] || { say "deps: FAIL — still missing:$still"; return 1; }
  say "deps: ok"
  ui "✓ 已装依赖：$missing"
}
if [ "$DEPS" = 1 ]; then install_deps || exit 1; else say "deps: skipped (--no-deps)"; fi

# ── agent binary ────────────────────────────────────────────────────────────
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}
install_ccquota() {
  mkdir -p "$LBIN" || return 1
  if [ -n "$CCQ_SRC" ]; then
    [ -x "$CCQ_SRC" ] || { say "agent: FAIL — --ccquota $CCQ_SRC is not an executable"; return 1; }
    if ! [ "$CCQ_SRC" -ef "$CCQ" ]; then
      cp "$CCQ_SRC" "$CCQ.tmp" && mv "$CCQ.tmp" "$CCQ" || { say "agent: FAIL — cannot copy $CCQ_SRC to $CCQ"; return 1; }
    fi
    say "agent: ccquota from $CCQ_SRC"
    return 0
  fi
  case ",$DIST_LIST," in
    *",$OS-$ARCH,"*|",,")
      # ",," = a rerun (no join answer to read the list from): just ask.
      code=$(curl -sS --max-time 300 -D "$WORK/dist.h" -o "$WORK/ccquota" -w '%{http_code}' \
        -H "Authorization: Bearer $TOKEN" "$HUB/v1/node/dist/$OS-$ARCH" 2>/dev/null) || code=000
      if [ "$code" = 200 ]; then
        want="$(tr -d '\r' < "$WORK/dist.h" | sed -n 's/^[Xx]-[Cc]cquota-[Ss]ha256: *//p' | head -n 1)"
        got="$(sha256_of "$WORK/ccquota")"
        if [ -z "$want" ] || [ "$want" != "$got" ]; then
          say "agent: FAIL — the hub's ccquota-$OS-$ARCH did not match its SHA-256 (want ${want:-none}, got $got)"; return 1
        fi
        chmod 755 "$WORK/ccquota" && mv "$WORK/ccquota" "$CCQ" || return 1
        say "agent: ccquota-$OS-$ARCH from the hub (sha256 $got)"
        return 0
      fi ;;
  esac
  if [ -x "$CCQ" ] && "$CCQ" version >/dev/null 2>&1; then say "agent: keeping $CCQ"; return 0; fi
  if p="$(command -v ccquota 2>/dev/null)" && [ -n "$p" ]; then
    cp "$p" "$CCQ" && say "agent: ccquota from $p" && return 0
  fi
  if command -v go >/dev/null 2>&1; then
    GOBIN="$LBIN" go install github.com/verkyyi/claude-fleet/tokenledger/cmd/ccquota@latest >"$WORK/go.log" 2>&1 \
      && say "agent: ccquota built with go install" && return 0
    say "agent: go install failed: $(tail -n 2 "$WORK/go.log" | tr '\n' ' ')"
  fi
  say "agent: FAIL — the hub serves no ccquota-$OS-$ARCH, none is on PATH and there is no Go. Pass --ccquota <file>"
  return 1
}
install_ccquota || exit 1
"$CCQ" version >/dev/null 2>&1 || { say "agent: FAIL — $CCQ does not run"; exit 1; }
ui "✓ agent 已装好：$CCQ"

# ── service ─────────────────────────────────────────────────────────────────
mkdir -p "$STATE" || die "service: cannot create $STATE"
cat > "$RUNNER.tmp" <<EOF
#!/bin/sh
# $MARK — runs this login's ccquota agent with the settings in $ENVF.
PATH="$LBIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
set -a
. "$ENVF"
set +a
cd "\$HOME" || exit 1
exec "$CCQ" agent --state "$STATE"
EOF
chmod 755 "$RUNNER.tmp" && mv "$RUNNER.tmp" "$RUNNER" || die "service: cannot write $RUNNER"

ours() { [ ! -e "$1" ] || grep -q "$MARK" "$1" 2>/dev/null; }
refuse_foreign() {
  ours "$1" && return 0
  [ "$FORCE" = 1 ] && { cp "$1" "$1.bak-$(date +%Y%m%d%H%M%S)" 2>/dev/null || priv cp "$1" "$1.bak-$(date +%Y%m%d%H%M%S)"; return 0; }
  say "service: FAIL — $1 exists and was not written by this script (another agent for this login?). Rerun with --force to replace it (a backup is kept)"
  return 1
}

start_detached() {
  pidf="$STATE/agent.pid"
  if [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
    kill "$(cat "$pidf")" 2>/dev/null
    sleep 1
  fi
  # A simple command in the background, not a list: `cd && x &` would fork a
  # subshell that waits on x while holding our stdout, and $! would be it.
  detach="nohup"
  command -v setsid >/dev/null 2>&1 && detach="setsid"
  (cd "$HOME" || exit 1; "$detach" "$RUNNER" >>"$STATE/agent.log" 2>&1 < /dev/null & echo $! > "$pidf")
  say "service: WARN — no service manager here; agent started detached (pid $(cat "$pidf"), log $STATE/agent.log) and will NOT come back after a reboot"
}

plist_body() { # $1 = label, $2 = UserName or ""
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- $MARK -->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$1</string>
$( [ -n "$2" ] && printf '  <key>UserName</key><string>%s</string>\n' "$2" )
  <key>ProgramArguments</key>
  <array><string>$RUNNER</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$STATE/agent.log</string>
  <key>StandardOutPath</key><string>$STATE/agent.log</string>
</dict>
</plist>
EOF
}

start_launchd() {
  if launchctl print "gui/$UID_N" >/dev/null 2>&1; then
    label=com.ccquota.agent
    plist="$HOME/Library/LaunchAgents/$label.plist"
    refuse_foreign "$plist" || return 1
    mkdir -p "$HOME/Library/LaunchAgents"
    plist_body "$label" "" > "$plist"
    launchctl bootout "gui/$UID_N/$label" >/dev/null 2>&1
    launchctl bootstrap "gui/$UID_N" "$plist" || { say "service: FAIL — launchctl bootstrap gui/$UID_N $plist"; return 1; }
    say "service: LaunchAgent $plist (gui/$UID_N)"
    return 0
  fi
  # SSH-only login: no gui domain. A system daemon running as this login.
  if can_priv; then
    label="com.ccquota.agent.$ME"
    plist="/Library/LaunchDaemons/$label.plist"
    refuse_foreign "$plist" || return 1
    plist_body "$label" "$ME" > "$WORK/plist"
    priv install -m 644 -o root -g wheel "$WORK/plist" "$plist" || { say "service: FAIL — cannot write $plist"; return 1; }
    priv launchctl bootout "system/$label" >/dev/null 2>&1
    priv launchctl bootstrap system "$plist" || { say "service: FAIL — launchctl bootstrap system $plist"; return 1; }
    say "service: LaunchDaemon $plist (runs as $ME; this login has no GUI session)"
    return 0
  fi
  return 2
}

unit_body() { # $1 = User= line or ""
  cat <<EOF
# $MARK
[Unit]
Description=ccquota agent ($ME) — claude-fleet node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
$1
ExecStart=$RUNNER
Restart=always
RestartSec=10

[Install]
WantedBy=$( [ -n "$1" ] && echo multi-user.target || echo default.target )
EOF
}

start_systemd() {
  if systemctl --user show-environment >/dev/null 2>&1; then
    unit="$HOME/.config/systemd/user/ccquota-agent.service"
    refuse_foreign "$unit" || return 1
    mkdir -p "$(dirname "$unit")"
    unit_body "" > "$unit"
    systemctl --user daemon-reload && systemctl --user enable --now ccquota-agent.service >/dev/null 2>&1 \
      && systemctl --user restart ccquota-agent.service \
      || { say "service: FAIL — systemctl --user enable --now ccquota-agent"; return 1; }
    if can_priv && command -v loginctl >/dev/null 2>&1; then
      priv loginctl enable-linger "$ME" >/dev/null 2>&1 || true
    fi
    say "service: systemd user unit $unit"
    return 0
  fi
  if [ -d /run/systemd/system ] && can_priv; then
    unit="/etc/systemd/system/ccquota-agent-$ME.service"
    refuse_foreign "$unit" || return 1
    unit_body "User=$ME" > "$WORK/unit"
    priv install -m 644 "$WORK/unit" "$unit" && priv systemctl daemon-reload \
      && priv systemctl enable --now "ccquota-agent-$ME.service" >/dev/null 2>&1 \
      && priv systemctl restart "ccquota-agent-$ME.service" \
      || { say "service: FAIL — systemctl enable --now ccquota-agent-$ME"; return 1; }
    say "service: systemd unit $unit (User=$ME)"
    return 0
  fi
  return 2
}

case "$SERVICE" in
  none) say "service: skipped (--service none) — run $RUNNER under your own supervisor" ;;
  detached) start_detached ;;
  auto)
    rc=2
    if [ "$OS" = darwin ]; then start_launchd; rc=$?
    elif command -v systemctl >/dev/null 2>&1; then start_systemd; rc=$?; fi
    case "$rc" in 0) ;; 2) start_detached ;; *) exit 1 ;; esac ;;
esac
case "$SERVICE" in
  none) ui "! 没起服务（--service none）：用你自己的方式运行 $RUNNER" ;;
  detached) ui "! agent 已在后台运行，但重启后不会自己起来（--service detached）" ;;
  *) if [ "${rc:-0}" = 2 ]; then ui "! agent 已在后台运行，但这里没有服务管理器，重启后不会自己起来"
     else ui "✓ agent 已作为服务运行（开机自动起）"; fi ;;
esac

# ── online ──────────────────────────────────────────────────────────────────
ONLINE=0
if [ "$SERVICE" != none ]; then
  deadline=$(( $(date +%s) + WAIT ))
  while :; do
    st="$(self_status)" || st=""
    if printf '%s' "$st" | grep -q '"status":"online"'; then ONLINE=1; break; fi
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep "$POLL"
  done
  if [ "$ONLINE" = 1 ]; then
    extra=""
    printf '%s' "$st" | grep -q '"admin":true' && extra=" · admin agent"
    ca="$(printf '%s' "$st" | jfield ssh_ca)"
    [ -n "$ca" ] && extra="$extra · ssh CA: $ca"
    say "online: the hub sees this login$extra — $HUB/nodes"
    ui "✓ 入口看到它在线：$HUB/nodes"
  else
    say "online: FAIL — the hub has not seen this agent within ${WAIT}s (status: $(printf '%s' "$st" | jfield status)); see $STATE/agent.log"
  fi
fi
if [ "$ADMIN" = 1 ] && [ "$ADMIN_OK" = 0 ]; then
  ui "! 入口没把 $ME 列为管理登录：这台机器不开账号、不装 SSH CA（要的话在入口的 CCQUOTA_FLEET_ADMIN_USERS 里加上它）"
  say "admin: WARN — the hub does not list '$ME' in CCQUOTA_FLEET_ADMIN_USERS, so it sends this machine no account ops and no SSH CA"
fi
if [ "$ADMIN" = 1 ] && ! can_priv; then
  say "admin: WARN — '$ME' has no passwordless sudo; opening accounts and installing the SSH CA will fail on this machine"
fi
[ -n "$SSH_CA" ] && [ "$ADMIN" = 1 ] && [ "$ADMIN_OK" = 1 ] && \
  say "admin: the agent installs the hub's SSH user CA (/etc/ssh/fleet_user_ca.pub + sshd_config.d) on connect"

# ── fleet ───────────────────────────────────────────────────────────────────
FLEET_RC=0
if [ "$FLEET" = 1 ]; then
  if [ -d "$ROOT/.git" ]; then
    say "fleet: $ROOT already there"
  else
    mkdir -p "$(dirname "$ROOT")"
    if [ "$SRC_SET" = 1 ] && [ -z "$SRC_REF" ]; then
      git clone -q "$SRC_REPO" "$ROOT" >"$WORK/clone.log" 2>&1
    else
      git clone -q -b "${SRC_REF:-stable}" "$SRC_REPO" "$ROOT" >"$WORK/clone.log" 2>&1
    fi || { say "fleet: FAIL — git clone $SRC_REPO: $(tail -n 2 "$WORK/clone.log" | tr '\n' ' ')"; FLEET_RC=1; }
  fi
  if [ "$FLEET_RC" = 0 ]; then
    say "fleet: running $ROOT/bin/fleet-login-bootstrap.sh"
    if [ "$UI" = 1 ]; then
      "$ROOT/bin/fleet-login-bootstrap.sh" >>"${LOG:-/dev/null}" 2>&1
      FLEET_RC=$?
    else
      "$ROOT/bin/fleet-login-bootstrap.sh" 2>&1 | sed 's/^/  │ /'
      FLEET_RC=${PIPESTATUS[0]}
    fi
    if [ "$FLEET_RC" = 0 ]; then say "fleet: ok"; ui "✓ fleet 已装好：$ROOT"
    else
      say "fleet: WARN — bootstrap exited $FLEET_RC; this machine is on the hub already. Fix the step above and rerun: $ROOT/bin/fleet-login-bootstrap.sh"
      ui "! fleet 没装完（初始化退出码 $FLEET_RC${LOG:+，见 $LOG}）：节点已在线；修好后重跑同一条命令即可"
    fi
  else
    ui "! fleet 没装完（git clone 失败${LOG:+，见 $LOG}）：节点已在线；重跑同一条命令即可"
  fi
else
  say "fleet: skipped (--no-fleet)"
fi

if [ "$COMPUTE" = 0 ]; then
  say "compute: off (CCQUOTA_FLEET_COMPUTE=0) — the hub places no session here and leases no account"
  ui "✓ 只协调：入口不往这台派会话、不借账号（本机跑会话用自己的账号）"
fi
[ "$ONLINE" = 1 ] || [ "$SERVICE" = none ] || exit 1
say "done: $HOSTN/$ME joined $HUB"
ui "✓ 已上线：$HOSTN/$ME 是 $HUB 的节点"
exit 0
