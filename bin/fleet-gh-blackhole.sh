#!/bin/bash
# fleet-gh-blackhole.sh — the GitHub black-hole drill, live half (issue #4840,
# EPIC #4839 C1; the sandbox half is bin/gh-blackhole-selftest.sh). It cuts ONE
# test login (or a hub test copy's user) off GitHub at the packet filter, so the
# drill's rows can be read on a real machine, and puts it back with one command.
#
#   fleet-gh-blackhole.sh plan   --user <login> [--mode drop|refuse] [--meta <file>]
#   sudo fleet-gh-blackhole.sh apply --user <login> [--mode drop|refuse] [--minutes 30]
#   sudo fleet-gh-blackhole.sh revert [--if-expired]
#   fleet-gh-blackhole.sh status
#   fleet-gh-blackhole.sh run --repo <owner/name> --issue <N> --pr <P> [--worktree <dir>]
#                             [--rows 1,4,G2] [--cap 20] [--tsv <file>]
#   fleet-gh-blackhole.sh refresh-meta [--meta <file>]
#
#   plan     prints the rules apply would load — nothing changes
#   apply    loads them (root): macOS pf, anchor com.apple/fleet-gh-blackhole (the
#            stock /etc/pf.conf already evaluates com.apple/*), `user <uid>` rules;
#            Linux nftables, table inet fleet_gh_blackhole, `meta skuid <uid>` rules
#   revert   takes every rule out, releases pf's enable token, removes the deadline
#   status   applied or not, for whom, until when
#   run      as the TEST login, while applied: every row of conf/gh-blackhole.rows
#            against its real fleet, cut at --cap, the drill's table (mode live-<m>)
#   refresh-meta  store https://api.github.com/meta (while GitHub answers) — the
#            address list plan / apply read; with none stored a built-in list is used
#
# drop = 连上不回 (packets vanish: the caller waits) · refuse = 连接拒绝 (an RST / ICMP
# at once). 额度用尽 needs no filter: FLEET_GH_FAKE_LIMIT=all in the run's env.
#
# Only a test login: --user is required, never root, never the person running it
# (`$SUDO_USER`, or the caller), and a uid below 500 is refused. Nothing but that
# uid's packets to GitHub's addresses is touched.
#
# The deadline lives on the managed side (the fleet-loadgen idea): apply arms it
# before it loads a rule. macOS: a root LaunchDaemon (com.claude-fleet.gh-blackhole-
# revert, a root-owned copy of this script) runs `revert --if-expired` every minute,
# so a killed shell, a closed pane or a reboot cannot leave the filter on past
# --minutes. Linux: every address in the sets carries an nftables `timeout`, so the
# KERNEL forgets them at the deadline whatever happens to us; a transient
# systemd-run timer then removes the empty table (no systemd: the table stays, inert).
#
# Paths (tests): FLEET_GH_BLACKHOLE_STATE (/var/db/fleet-gh-blackhole),
# FLEET_GH_BLACKHOLE_LAUNCHD (/Library/LaunchDaemons), FLEET_GH_BLACKHOLE_OS
# (uname -s), FLEET_GH_BLACKHOLE_ROOT_OK=1 (skip the euid 0 check — a fake pfctl).
# Tools come off PATH: pfctl, launchctl (Darwin) · nft, systemd-run (Linux).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
STATE="${FLEET_GH_BLACKHOLE_STATE:-/var/db/fleet-gh-blackhole}"
LAUNCHD="${FLEET_GH_BLACKHOLE_LAUNCHD:-/Library/LaunchDaemons}"
OS="${FLEET_GH_BLACKHOLE_OS:-$(uname -s)}"
ANCHOR=com.apple/fleet-gh-blackhole
NFT_TABLE=fleet_gh_blackhole
LABEL=com.claude-fleet.gh-blackhole-revert
HOSTS='github.com api.github.com raw.githubusercontent.com codeload.github.com objects.githubusercontent.com uploads.github.com'  # dist-ok: the hosts the drill BLOCKS
# GitHub's own ranges (api.github.com/meta: web · api · git · pages), for a
# machine that never stored a copy
BUILTIN='140.82.112.0/20 143.55.64.0/20 185.199.108.0/22 192.30.252.0/22 20.201.28.151/32 20.205.243.166/32 20.87.245.0/32 4.237.22.38/32 2a0a:a440::/29 2606:50c0::/32'

die() { printf 'fleet-gh-blackhole: %s\n' "$1" >&2; exit "${2:-1}"; }
need_root() { [ "${FLEET_GH_BLACKHOLE_ROOT_OK:-}" = 1 ] || [ "$(id -u)" = 0 ] || die "$1 needs root (sudo)" 3; }

CMD=${1:-}; [ $# -gt 0 ] && shift
USER_ARG='' MODE=drop META='' MINUTES=30 IFEXP=0 RREPO='' RISSUE='' RPR='' RWT='' RROWS='' RCAP=20 RTSV=''
while [ $# -gt 0 ]; do
  case "$1" in
    --user) USER_ARG=${2:-}; shift 2 ;;
    --mode) MODE=${2:-}; shift 2 ;;
    --meta) META=${2:-}; shift 2 ;;
    --minutes) MINUTES=${2:-}; shift 2 ;;
    --if-expired) IFEXP=1; shift ;;
    --repo) RREPO=${2:-}; shift 2 ;;
    --issue) RISSUE=${2:-}; shift 2 ;;
    --pr) RPR=${2:-}; shift 2 ;;
    --worktree) RWT=${2:-}; shift 2 ;;
    --rows) RROWS=${2:-}; shift 2 ;;
    --cap) RCAP=${2:-}; shift 2 ;;
    --tsv) RTSV=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1" 2 ;;
  esac
done
case "$MODE" in drop|refuse) ;; *) die "--mode is drop or refuse (got $MODE)" 2 ;; esac
case "$MINUTES" in ''|*[!0-9]*) die "--minutes is a number of minutes" 2 ;; esac
[ "$MINUTES" -ge 1 ] && [ "$MINUTES" -le 120 ] || die "--minutes is 1..120" 2
[ -n "$META" ] || META="$STATE/gh-meta.json"

# --- who: a test login, never root, never the person -------------------------------
target_uid() {
  local u=$USER_ARG uid me
  [ -n "$u" ] || die "--user <test login> is required (only a test login is ever cut off)" 2
  uid=$(id -u "$u" 2>/dev/null) || die "no such login: $u" 2
  [ "$uid" != 0 ] || die "refused: $u is root" 2
  [ "$uid" -ge 500 ] || die "refused: $u (uid $uid) is a system account" 2
  me=${SUDO_USER:-$(id -un)}
  [ "$u" != "$me" ] || die "refused: $u is the login running this — only a test login, never your own" 2
  printf '%s' "$uid"
}

# --- what: the address list ----------------------------------------------------------
addrs() {  # one CIDR / address a line: the stored meta's web·api·git·pages, else the built-in list
  if [ -s "$META" ]; then
    python3 -I - "$META" <<'PY' && return 0
import json, sys
m = json.load(open(sys.argv[1]))
seen = []
for k in ("web", "api", "git", "pages"):
    for c in m.get(k) or []:
        if c not in seen:
            seen.append(c)
if not seen:
    sys.exit(1)
print("\n".join(seen))
PY
  fi
  # shellcheck disable=SC2086  # a word list
  printf '%s\n' $BUILTIN
}
meta_note() {
  if [ -s "$META" ]; then printf 'addresses: %s (%s)\n' "$META" "$(date -r "$META" '+%F %R' 2>/dev/null || stat -c %y "$META" 2>/dev/null | cut -c1-16)"
  else printf 'addresses: built-in list (no %s — `refresh-meta` stores GitHub'"'"'s own)\n' "$META"; fi
}

pf_rules() {  # pf_rules <uid>
  local act='block drop' v4='' v6='' a
  [ "$MODE" = refuse ] && act='block return'
  while IFS= read -r a; do case "$a" in *:*) v6="$v6 $a" ;; ?*) v4="$v4 $a" ;; esac; done < <(addrs)
  printf '# fleet-gh-blackhole · uid %s · %s · drill issue #4840\n' "$1" "$MODE"
  printf 'table <fleet_gh> persist {%s %s %s }\n' "$v4" "$v6" "$HOSTS"
  printf '%s out quick proto { tcp udp } from any to <fleet_gh> user %s\n' "$act" "$1"
}
nft_rules() {  # nft_rules <uid> — every element times out at the deadline (in the kernel)
  local act=drop v4='' v6='' a t="${MINUTES}m"
  [ "$MODE" = refuse ] && act=reject
  while IFS= read -r a; do case "$a" in *:*) v6="$v6${v6:+, }$a" ;; ?*) v4="$v4${v4:+, }$a" ;; esac; done < <(addrs)
  printf '# fleet-gh-blackhole · uid %s · %s · drill issue #4840\n' "$1" "$MODE"
  printf 'table inet %s {\n' "$NFT_TABLE"
  printf '  set gh4 { type ipv4_addr; flags interval, timeout; timeout %s; elements = { %s } }\n' "$t" "$v4"
  [ -n "$v6" ] && printf '  set gh6 { type ipv6_addr; flags interval, timeout; timeout %s; elements = { %s } }\n' "$t" "$v6"
  printf '  chain out { type filter hook output priority 0; policy accept;\n'
  printf '    meta skuid %s ip daddr @gh4 %s\n' "$1" "$act"
  [ -n "$v6" ] && printf '    meta skuid %s ip6 daddr @gh6 %s\n' "$1" "$act"
  printf '  }\n}\n'
}
rules() { case "$OS" in Darwin) pf_rules "$1" ;; Linux) nft_rules "$1" ;; *) die "no packet filter for $OS" 2 ;; esac; }

applied() { [ -s "$STATE/applied" ]; }
akey() { sed -n "s/^$1=//p" "$STATE/applied" 2>/dev/null | head -1; }

plist() {  # the deadline's LaunchDaemon: revert --if-expired every minute
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$STATE/revert.sh</string><string>revert</string><string>--if-expired</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>FLEET_GH_BLACKHOLE_STATE</key><string>$STATE</string>
    <key>FLEET_GH_BLACKHOLE_LAUNCHD</key><string>$LAUNCHD</string>
  </dict>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><false/>
  <key>StandardErrorPath</key><string>$STATE/revert.log</string>
</dict></plist>
EOF
}

do_revert() {
  local tok
  if [ "$IFEXP" = 1 ]; then
    applied || exit 0
    [ "$(date +%s)" -ge "$(akey until)" ] || exit 0
  fi
  case "$OS" in
    Darwin)
      pfctl -a "$ANCHOR" -F all >/dev/null 2>&1
      tok=$(akey token); [ -n "$tok" ] && pfctl -X "$tok" >/dev/null 2>&1
      launchctl bootout system/"$LABEL" >/dev/null 2>&1
      rm -f "$LAUNCHD/$LABEL.plist" ;;
    Linux)
      nft delete table inet "$NFT_TABLE" >/dev/null 2>&1
      command -v systemctl >/dev/null 2>&1 && systemctl stop fleet-gh-blackhole-revert.timer >/dev/null 2>&1 ;;
  esac
  local who; who=$(akey user)
  rm -f "$STATE/applied" "$STATE/rules"
  printf 'reverted%s — no GitHub rule left\n' "${who:+ ($who)}"
}

case "$CMD" in
  plan)
    uid=$(target_uid) || exit $?
    printf 'would cut %s (uid %s) off GitHub · %s · %s · for %s min\n' "$USER_ARG" "$uid" "$MODE" "$OS" "$MINUTES"
    meta_note
    case "$OS" in
      Darwin) printf 'load: pfctl -a %s -f <rules> ; pfctl -E · deadline: %s/%s.plist (revert --if-expired every 60 s)\n' "$ANCHOR" "$LAUNCHD" "$LABEL" ;;
      Linux)  printf 'load: nft -f <rules> · deadline: the elements'"'"' own timeout (%sm), then systemd-run removes the table\n' "$MINUTES" ;;
    esac
    printf -- '--- rules\n'; rules "$uid" ;;
  apply)
    need_root apply
    uid=$(target_uid) || exit $?
    applied && die "already applied for $(akey user) until $(date -r "$(akey until)" '+%R' 2>/dev/null || akey until) — revert first" 4
    mkdir -p "$STATE" && chmod 700 "$STATE" || die "cannot make $STATE"
    until=$(( $(date +%s) + MINUTES * 60 ))
    rules "$uid" > "$STATE/rules" || exit 1
    printf 'user=%s\nuid=%s\nmode=%s\nos=%s\nuntil=%s\nat=%s\n' "$USER_ARG" "$uid" "$MODE" "$OS" "$until" "$(date +%s)" > "$STATE/applied"
    # the deadline first: no rule is ever loaded without its revert armed
    cp "$0" "$STATE/revert.sh" && chmod 755 "$STATE/revert.sh" || { rm -f "$STATE/applied"; die "cannot copy the reverter"; }
    case "$OS" in
      Darwin)
        mkdir -p "$LAUNCHD" && plist > "$LAUNCHD/$LABEL.plist" && chmod 644 "$LAUNCHD/$LABEL.plist" \
          && launchctl bootstrap system "$LAUNCHD/$LABEL.plist" \
          || { rm -f "$STATE/applied" "$LAUNCHD/$LABEL.plist"; die "could not arm the deadline (launchd) — nothing loaded"; }
        pfctl -a "$ANCHOR" -f "$STATE/rules" 2>"$STATE/pfctl.err" || { do_revert >/dev/null; die "pfctl refused the rules: $(cat "$STATE/pfctl.err")"; }
        tok=$(pfctl -E 2>&1 | sed -n 's/.*Token : *\([0-9][0-9]*\).*/\1/p' | head -1)
        printf 'token=%s\n' "$tok" >> "$STATE/applied" ;;
      Linux)
        nft -f "$STATE/rules" 2>"$STATE/nft.err" || { do_revert >/dev/null; die "nft refused the rules: $(cat "$STATE/nft.err")"; }
        command -v systemd-run >/dev/null 2>&1 \
          && systemd-run --quiet --unit fleet-gh-blackhole-revert --on-active="${MINUTES}m" \
               --setenv=FLEET_GH_BLACKHOLE_STATE="$STATE" /bin/bash "$STATE/revert.sh" revert >/dev/null 2>&1 ;;
    esac
    printf 'applied: %s (uid %s) cut off GitHub · %s · until %s (auto-revert) · undo: sudo %s revert\n' \
      "$USER_ARG" "$uid" "$MODE" "$(date -r "$until" '+%R' 2>/dev/null || date -d "@$until" '+%R' 2>/dev/null)" "$0" ;;  # portable-ok: BSD -r, else GNU -d
  revert)
    need_root revert
    do_revert ;;
  status)
    if applied; then
      left=$(( $(akey until) - $(date +%s) ))
      printf 'applied: %s (uid %s) · %s · %s s left\n' "$(akey user)" "$(akey uid)" "$(akey mode)" "$left"
    else
      printf 'not applied\n'
    fi ;;
  refresh-meta)
    mkdir -p "$(dirname "$META")" || exit 1
    if curl -fsS --max-time 15 https://api.github.com/meta -o "$META.tmp"; then  # dist-ok: GitHub's address list, not fleet code
      mv "$META.tmp" "$META" && printf 'stored %s\n' "$META"
    else
      rm -f "$META.tmp"; die "could not read GitHub's meta (is GitHub reachable?)"
    fi ;;
  run)
    [ -n "$RREPO" ] && [ -n "$RISSUE" ] && [ -n "$RPR" ] || die "run needs --repo --issue --pr (a ticket of the test login's GitHub repo)" 2
    applied || [ "${FLEET_GH_BLACKHOLE_RUN_ANYWAY:-}" = 1 ] || die "not applied — sudo $0 apply --user <test login> first" 4
    W=$(mktemp -d "${TMPDIR:-/tmp}/gh-blackhole-run.XXXXXX") || exit 1
    trap 'rm -rf "$W"' EXIT
    m=live-$(akey mode); [ "$m" = live- ] && m=live
    printf 'row\tmode\tresult\tsecs\tgh_tries\tnote\n' > "$W/table"
    while IFS=$'\t' read -r id _name cmd _exp; do
      case "$id" in ''|'#'*) continue ;; esac
      [ -z "$RROWS" ] || case ",$RROWS," in *",$id,"*) ;; *) continue ;; esac
      case "$cmd" in '- '*|-) printf '%s\t%s\tskip\t0\t-\t%s\n' "$id" "$m" "${cmd#- }" >> "$W/table"; continue ;; esac
      c="$W/$id"; mkdir -p "$c"
      ( cd "${RWT:-$PWD}" || exit 1
        export BIN REPO="$RREPO" ISSUE="$RISSUE" PR="$RPR" CELL="$c" SESS="${FLEET_SESSION:-}"
        export JOIN_URL="${JOIN_URL:-https://raw.githubusercontent.com/verkyyi/claude-fleet/stable/bin/fleet-node-join.sh}"  # dist-ok: the row measures the join line's own default
        python3 -I "$BIN/gh_blackhole.py" cell --cap "$RCAP" --out "$c/verdict" -- bash -c "$cmd" > "$c/out" 2> "$c/err" )
      IFS=$'\t' read -r res secs rc < "$c/verdict"
      printf '%s\t%s\t%s\t%s\t-\trc=%s · %s\n' "$id" "$m" "$res" "$secs" "$rc" \
        "$(grep -v '^[[:space:]]*$' "$c/err" | head -1 | tr '\t' ' ' | cut -c1-120)" >> "$W/table"
    done < "$ROOT/conf/gh-blackhole.rows"
    if command -v column >/dev/null 2>&1; then column -t -s $'\t' < "$W/table"; else cat "$W/table"; fi
    [ -n "$RTSV" ] && cp "$W/table" "$RTSV" ;;
  ''|-h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command $CMD (plan · apply · revert · status · run · refresh-meta)" 2 ;;
esac
