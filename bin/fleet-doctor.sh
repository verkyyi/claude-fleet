#!/bin/sh
# fleet-doctor.sh — preflight for a claude-fleet install. Checks the tools the
# fleet actually depends on and prints a pass/warn/fail line for each, so a
# manual or Linux user can see what's missing before wiring up tmux + daemons.
#
#   pass  — present and new enough
#   warn  — degraded but usable (a feature silently loses quality)
#   fail  — a core piece will not work
#
# Exit status is the number of FAILs (0 = everything at least usable), so it can
# gate an install script: `sh fleet-doctor.sh && ...`.
#
# Dependency truth (keep in sync with README.md#dependencies and docs/INSTALL.md):
#   tmux ≥ 3.2   core — the whole thing is a tmux session
#   fzf  ≥ 0.45  dash — the dashboard binds use `transform` (fzf 0.45+)
#   gh (authed)  backlog + PR/CI map (unauthed → panels silently empty)
#   python3      collector context% + usage caches
#   claude       the sessions you run + the optional classify hook
#   perl HiRes   soft — dash spinner sub-second frames (degrades to 1s ticks)
#   jq is NOT required standalone: the collector only uses `gh --jq` (built in).
#
# Network: doctor is a HUMAN-run preflight, so it may pay for network reads no
# daemon could afford — `gh` for the base-branch check, and one `git fetch` of a
# single branch for the live-install freshness check (issue #635).
set -u  # POSIX sh: pipefail is bash-only (dash has none)

# --- output helpers (color only on a tty) ---
if [ -t 1 ]; then
  R=$(printf '\033[31m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m')
  B=$(printf '\033[1m'); Z=$(printf '\033[0m')
else
  R=''; G=''; Y=''; B=''; Z=''
fi
fails=0; warns=0

# Where the fleet's durable state lives. fleet-lib.sh defaults this for every bash
# caller, but this doctor is /bin/sh and cannot source it, so it defaults the
# value ITSELF — and every `$FLEET_CONF_DIR` below must read `$conf_dir`, never
# the raw variable. Under `set -u` a raw read is fatal when the variable is unset,
# and it is unset exactly where the doctor is run by hand: the launcher never
# exports it and neither does a login shell. The selftest gate DOES export it
# (bin/run-selftests.sh points it at an empty shadow dir), which is how a raw
# read once shipped green through CI and killed the doctor on both live machines
# at its first use (#759: `line 254: FLEET_CONF_DIR: unbound variable`, every
# later check silently gone). bin/fleet-doctor-conf-dir-selftest.sh pins this.
conf_dir="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"

# The interval-daemon liveness registry (issue #639). POSIX-clean on purpose so
# this /bin/sh doctor can source it, unlike the bash-only fleet-lib.sh.
_dlib="$(dirname "$0")/fleet-daemon-lib.sh"
# shellcheck source=/dev/null
[ -f "$_dlib" ] && . "$_dlib"
# _pr <LEVEL> <color> <label> <msg> — one row. A two-character CJK label (能力 /
# 承载, issue #1806) is padded by hand: printf's %-8s counts bytes in one shell
# and characters in another, and either way it is not the 8 columns it shows.
_pr() {
  case "$3" in
    能力|承载) printf '  %s%s%s  %s     %s\n' "$2" "$1" "$Z" "$3" "$4" ;;
    *)         printf '  %s%s%s  %-8s %s\n' "$2" "$1" "$Z" "$3" "$4" ;;
  esac
}
pass() { _pr PASS "$G" "$1" "$2"; }
warn() { _pr WARN "$Y" "$1" "$2"; warns=$((warns+1)); }
fail() { _pr FAIL "$R" "$1" "$2"; fails=$((fails+1)); }
info() { _pr INFO "$B" "$1" "$2"; }   # advice; never counted

# vge A B → 0 (true) if dotted-numeric version A >= B (compares up to 3 parts).
vge() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    n=split(a,x,"."); m=split(b,y,".");
    for(i=1;i<=3;i++){ xi=(i<=n?x[i]+0:0); yi=(i<=m?y[i]+0:0);
      if(xi>yi) exit 0; if(xi<yi) exit 1 }
    exit 0 }'
}

# `fleet doctor --machine` (issue #2334): the machine half alone — the root
# runtime and every part release.json pins, the rows the machine updater's
# rollback gate reads, plus one `version` line. Exit = its FAIL count.
if [ "${1:-}" = --machine ]; then
  printf '%sclaude-fleet doctor — machine%s\n' "$B" "$Z"
  exec python3 "$(dirname "$0")/fleet-node-update.py" doctor
fi

# `fleet doctor --installs` (issue #2692): every install on this machine — the
# machine runtime, each login's ~/.claude/fleet, each client shell — one table,
# each judged against stable. Exit = fleet-installs.sh's (0 all at stable).
if [ "${1:-}" = --installs ]; then
  shift
  exec sh "$(dirname "$0")/fleet-installs.sh" "$@"
fi

# `fleet doctor --json` (issue #2674): the same run, its rows as one JSON object —
# {"v":1,"rc":N,"fails":N,"warns":N,"rows":[{"level","row","msg"}…]} — for the
# steward's health watch (bin/fleet_steward_health.py). It runs the doctor once,
# off a tty (no color), and parses the `  LEVEL  label  msg` lines; a line indented
# past the label column continues the row above. Exit = the doctor's.
if [ "${1:-}" = --json ]; then
  shift
  _dj=$(sh "$0" "$@" </dev/null 2>/dev/null); _djrc=$?
  printf '%s\n' "$_dj" | python3 -c '
import json, re, sys
rows = []
for line in sys.stdin.read().splitlines():
    m = re.match(r"^  (PASS|WARN|FAIL|INFO)  (\S+)\s+(.*)$", line)
    if m:
        rows.append({"level": m.group(1), "row": m.group(2), "msg": m.group(3).rstrip()})
    elif rows and line.startswith("    ") and line.strip():
        rows[-1]["msg"] += "\n" + line.strip()
n = lambda lv: sum(1 for r in rows if r["level"] == lv)
print(json.dumps({"v": 1, "rc": int(sys.argv[1]), "fails": n("FAIL"), "warns": n("WARN"), "rows": rows},
                 ensure_ascii=False))' "$_djrc"
  exit "$_djrc"
fi

printf '%sclaude-fleet doctor%s\n' "$B" "$Z"

# --- per-fleet conf enumeration (shared by the optional-daemon checks below) ---
# $conf_dir is defaulted once at the top of the file (see the note there).

# Enumerate configured fleet conf paths, dual-layout (issue #203): the new
# per-fleet layout (fleets/<sess>/conf, #181) preferred, with the legacy flat
# <sess>.conf read only when that session has no new-layout dir. POSIX inline copy
# (doctor is /bin/sh; it can't source the bash-only fleet-lib.sh) — KEEP IN SYNC
# with fleet_each_conf() in bin/fleet-lib.sh. A flat `for cf in "$conf_dir"/*.conf`
# glob matches nothing after the #181 migration, so this under-counts armed fleets.
_fleet_confs() {
  _cd="$1"
  if [ -d "$_cd/fleets" ]; then
    for _d in "$_cd"/fleets/*/; do
      [ -d "$_d" ] || continue
      [ -f "${_d}conf" ] || continue
      printf '%s\n' "${_d}conf"
    done
  fi
  for _c in "$_cd"/*.conf; do
    [ -f "$_c" ] || continue
    _s=$(basename "$_c" .conf)
    case "$_s" in fleet|shell) continue ;; esac   # the machine's config + the shell's (#1623), not fleets
    [ -f "$_cd/fleets/$_s/conf" ] && continue
    printf '%s\n' "$_c"
  done
}

# _conf_val <file> <KEY> → the LAST uncommented assignment's value, quotes/blanks
# stripped ('' if none) — what sourcing the file would leave in KEY.
_conf_val() {
  [ -f "$1" ] || return 0
  sed -n 's/^[[:space:]]*'"$2"'[[:space:]]*=[[:space:]]*\([^#]*\).*/\1/p' "$1" | tail -1 | tr -d "\"' 	"
}

# _gconf_val <KEY> → the login-wide value: the machine's one config file (issue
# #1623), else the login's settings file (issue #979), else the install's
# fleet.conf they replace (dual-read).
_gconf_val() {
  _gv=$(_conf_val "$conf_dir/fleet.conf" "$1")
  [ -n "$_gv" ] || _gv=$(_conf_val "$conf_dir/fleet.settings" "$1")
  [ -n "$_gv" ] || _gv=$(_conf_val "$(dirname "$0")/../fleet.conf" "$1")
  printf '%s' "$_gv"
}

# _conf_has <file> <KEY> → 0 iff the file assigns KEY (uncommented), even to "".
_conf_has() {
  [ -f "$1" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?$2[[:space:]]*=" "$1"
}

# _xconf_val <file> <KEY> → the last assignment's value, `export` allowed
# (`export CCQUOTA_FLEET=1` is how the install's fleet.conf spells it;
# _conf_val does not allow the prefix).
_xconf_val() {  # <file> <KEY> → the last assignment's value, `export` allowed
  [ -f "$1" ] || return 0
  sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}'"$2"'[[:space:]]*=[[:space:]]*\([^#]*\).*/\2/p' "$1" | tail -1 | tr -d "\"' 	"
}

# --- fleet · 能力 · 承载 (issue #1806, EPIC #1813 C4): what this computer IS ----
# Three words used to describe one computer — `client` (the installed client),
# `role` (FLEET_ROLE client|node|client,node) and `node` (the hub token) — and a
# newcomer had to learn all three to know whether theirs runs sessions. Now the
# first rows say it the way everything else does:
#   fleet  what is installed — the client's own verdict (version vs the hub,
#          tmux, cert — bin/fleet-client-update.sh doctor, issue #1722) when the
#          install-line client is here, else this checkout's commit + the hub
#   能力   基础 (everyone) · 承载 (FLEET_HOST=1 — fleet-conf.sh host, the old
#          FLEET_ROLE read for one version) + the ONE config file's state
#          (issue #1623): PASS one file · INFO not folded yet / an old key ·
#          WARN the file AND an old one still read
#   承载   only on a computer that hosts (or has the hub switch on): which
#          machine, and the node token verdict (issue #1491 — WARN when the
#          entry's lease / placement / move would fall back silently)
# The hub protocol's word stays node (node.env, /v1/node/*): docs/TERMS.md.
_hub_url=${FLEET_HUB_URL:-}
[ -n "$_hub_url" ] || _hub_url=$(_xconf_val "$conf_dir/fleet.conf" FLEET_HUB_URL)
[ -n "$_hub_url" ] || _hub_url=$(_xconf_val "$conf_dir/fleet.conf" CCQUOTA_HUB_URL)
_hub_url=${_hub_url%/}
_cu="$(dirname "$0")/fleet-client-update.sh"
_cu_root="${FLEET_INSTALL_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/claude-fleet}"
_cu_out=''
if [ -f "$_cu" ] && [ -f "$_cu_root/.client-version" ]; then
  _cu_out=$(bash "$_cu" doctor --root "$_cu_root" 2>/dev/null)
fi
case "$_cu_out" in
  PASS*) pass fleet "${_cu_out#*	}" ;;
  WARN*) warn fleet "${_cu_out#*	}" ;;
  INFO*) info fleet "${_cu_out#*	}" ;;
  *)
    # a checkout leads with the same word an installed client does — 版本
    # <stable's short commit> — so two computers on one stable read alike on
    # their first row (issue #1805); install-sync's state says where stable is
    _fl_root=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
    _fl_head=$(git -C "$_fl_root" rev-parse HEAD 2>/dev/null)
    _fl_st=$(sed -n 's/^stable: //p' "$conf_dir/global/install-sync.state" 2>/dev/null | head -n 1)
    if [ -n "$_hub_url" ]; then _fl_hub="入口 $(printf '%s' "$_hub_url" | sed 's#^[a-z]*://##')"; else _fl_hub='入口 不接'; fi
    case "$_fl_st" in
      "$_fl_head") _fl_hub="$_fl_hub · 跟 stable 同版" ;;
      ''|none|-) ;;
      *) [ -n "$_fl_head" ] && _fl_hub="$_fl_hub · stable $(printf '%.7s' "$_fl_st")（install-sync 跟上）" ;;
    esac
    # the client shell running here on code other than this install's (issue
    # #2737): a switch it was not reloaded by — WARN until it is
    _fl_txt="${_fl_head:+版本 $(printf '%.7s' "$_fl_head") · }$(printf '%s' "$_fl_root" | sed "s#^$HOME#~#") · $_fl_hub"
    if [ ! -f "$_cu" ] || _fl_run=$(bash "$_cu" running --root "$_fl_root" 2>/dev/null); then
      pass fleet "$_fl_txt"
    else
      warn fleet "$_fl_txt · $_fl_run"
    fi ;;
esac

# A resident daemon on code older than the install (issue #2716): a KeepAlive
# unit keeps the script it started with, so after a version switch (the install
# link's own mtime — install-sync swaps it by one rename) every one that started
# BEFORE it still runs the old version. fleet-install-apply.sh restarts them on
# the switch; this names one it could not (a system LaunchDaemon with no sudo, a
# kick that failed). A checkout install (no link) or no resident unit: no row.
#   FLEET_DOCTOR_RESIDENT_CMD  the selftests' seam: prints `<unit> <started epoch>`
_rs_root="${FLEET_INSTALL_ROOT:-$HOME/.claude/fleet}"
_rs_old=''
if [ -L "$_rs_root" ]; then
  _rs_sw=$(stat -c %Y "$_rs_root" 2>/dev/null || stat -f %m "$_rs_root" 2>/dev/null)
  _rs_rows=''
  if [ -n "${FLEET_DOCTOR_RESIDENT_CMD:-}" ]; then
    _rs_rows=$(sh -c "$FLEET_DOCTOR_RESIDENT_CMD" 2>/dev/null)
  elif command -v fleet_daemon_label >/dev/null 2>&1 && ! fleet_node_manages 2>/dev/null; then
    _rs_now=$(date +%s)
    for _rs_t in "$(dirname "$0")"/../launchd/com.claude-fleet.*.plist.tmpl "$(dirname "$0")"/../systemd/claude-fleet-*.service; do
      [ -f "$_rs_t" ] || continue
      _rs_pid=''
      case "$_rs_t" in
        *.plist.tmpl)
          [ "$(uname)" = Darwin ] && grep -q '<key>KeepAlive</key>' "$_rs_t" || continue
          _rs_u=${_rs_t##*/com.claude-fleet.}; _rs_u=${_rs_u%.plist.tmpl}
          [ -f "$(fleet_daemon_plist "$_rs_u")" ] || continue
          _rs_pid=$(launchctl print "$(fleet_daemon_domain)/$(fleet_daemon_label "$_rs_u")" 2>/dev/null \
                     | awk '$1 == "pid" && $2 == "=" { print $3; exit }') ;;
        *)
          [ "$(uname)" = Linux ] && grep -q '^Restart=' "$_rs_t" || continue
          _rs_u=${_rs_t##*/claude-fleet-}; _rs_u=${_rs_u%.service}
          _rs_pid=$(systemctl --user show -p MainPID --value "claude-fleet-$_rs_u.service" 2>/dev/null) ;;
      esac
      case "$_rs_pid" in ''|0|*[!0-9]*) continue ;; esac
      # etime [[dd-]hh:]mm:ss → seconds running
      _rs_et=$(ps -o etime= -p "$_rs_pid" 2>/dev/null | awk '{
        t = $1; d = 0; k = index(t, "-")
        if (k) { d = substr(t, 1, k - 1); t = substr(t, k + 1) }
        n = split(t, a, ":"); s = 0
        for (i = 1; i <= n; i++) s = s * 60 + a[i]
        print d * 86400 + s }')
      case "$_rs_et" in ''|*[!0-9]*) continue ;; esac
      _rs_rows="$_rs_rows$_rs_u $((_rs_now - _rs_et))
"
    done
  fi
  case "$_rs_sw" in
    ''|*[!0-9]*) ;;
    *) _rs_old=$(printf '%s' "$_rs_rows" | awk -v sw="$_rs_sw" 'NF == 2 && $2 ~ /^[0-9]+$/ && $2 < sw { printf "%s%s", s, $1; s = ", " }') ;;
  esac
fi
if [ -n "$_rs_old" ]; then
  if [ "$(uname)" = Darwin ]; then _rs_fix="launchctl kickstart -k gui/$(id -u)/com.claude-fleet.<名>"
  else _rs_fix="systemctl --user restart claude-fleet-<名>.service"; fi
  warn fleet "常驻服务还在跑切换前的版本：${_rs_old}（安装 $(date -r "$_rs_sw" '+%m-%d %H:%M' 2>/dev/null || date -d "@$_rs_sw" '+%m-%d %H:%M' 2>/dev/null) 切换，它们启动得更早）— \`$_rs_fix\` 重启一次"
fi

_hub_on=${CCQUOTA_FLEET:-}
[ -n "$_hub_on" ] || _hub_on=$(_xconf_val "$conf_dir/fleet.conf" CCQUOTA_FLEET)
[ -n "$_hub_on" ] || _hub_on=$(_xconf_val "$conf_dir/fleet.settings" CCQUOTA_FLEET)
[ -n "$_hub_on" ] || _hub_on=$(_xconf_val "$(dirname "$0")/../fleet.conf" CCQUOTA_FLEET)
if [ -z "$_hub_on" ] && [ -d "$conf_dir" ]; then
  while IFS= read -r _cf; do
    [ -n "$_cf" ] || continue
    _hub_on=$(_xconf_val "$_cf" CCQUOTA_FLEET); [ -n "$_hub_on" ] && break
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
fi
if [ "$_hub_on" = 1 ]; then
  _nenv="$conf_dir/node.env"
  _nfix="\`bash $(dirname "$0")/fleet-hub-node.sh env --write\` (fills it from this login's agent service), or re-join with fleet-node-join.sh"
  if ! command -v ccquota >/dev/null 2>&1; then
    _tok_lv=WARN _tok_msg="CCQUOTA_FLEET=1 but ccquota is not on PATH — the entry's lease / placement / move all fall back: spawns are guarded by the GitHub claim alone, every session opens here, no move lands. Install the agent (fleet-node-join.sh, or \`go install github.com/verkyyi/claude-fleet/tokenledger/cmd/ccquota@latest\`)"  # dist-ok: advice printed to a person, never fetched here
  elif [ -n "${CCQUOTA_TOKEN:-}" ]; then
    # Reaches the hub, but the wrong way round: a token exported into the shell is
    # inherited by every worker a pane spawns (a node credential in each session's
    # environment) — the stop-gap the operator added to fleet.conf before #1491.
    if [ -f "$_nenv" ] && grep -q '^CCQUOTA_TOKEN=.' "$_nenv" 2>/dev/null; then
      _tok_lv=WARN _tok_msg="CCQUOTA_TOKEN is exported into this environment — every worker spawned from a pane inherits a node credential; fleet_hub_* read $_nenv per call now, so drop the export (the fleet.conf stop-gap, issue #1491)"
    else
      _tok_lv=WARN _tok_msg="CCQUOTA_TOKEN is exported into this environment and $_nenv is missing — the hub is reached only while the export stays, and every worker inherits a node credential; write the file, then drop the export: $_nfix"
    fi
  elif [ -L "$_nenv" ] && [ ! -r "$_nenv" ] && [ -f "$conf_dir/credsep.json" ]; then
    # separated (issue #1971): the token is in the role account's store, the
    # broker hands this login a short-lived stand-in — the credsep row checks it
    _tok_lv=PASS _tok_msg="通行证在单独账号的保管处（这个登录读不到，经本机代理用）"
  elif [ -f "$_nenv" ] && grep -q '^CCQUOTA_TOKEN=.' "$_nenv" 2>/dev/null; then
    # ls -ld perms: char 5 = group-read, char 8 = other-read (as the account check)
    _nm=$(ls -ld "$_nenv" 2>/dev/null | cut -c1-10)
    if [ "$(printf '%s' "$_nm" | cut -c5)" = r ] || [ "$(printf '%s' "$_nm" | cut -c8)" = r ]; then
      _tok_lv=WARN _tok_msg="$_nenv holds this login's node token but is group/other-readable ($_nm) — \`chmod 600 $_nenv\`"
    else
      _tok_lv=PASS _tok_msg="通行证 $(printf '%s' "$_nenv" | sed "s#^$HOME#~#")（0600，ccquota 每次调用时读，不进窗格环境）"
    fi
  elif [ -f "$_nenv" ]; then
    _tok_lv=WARN _tok_msg="CCQUOTA_FLEET=1 but $_nenv has no CCQUOTA_TOKEN= line — the entry's lease / placement / move all fall back silently (issue #1491); rewrite it: \`bash $(dirname "$0")/fleet-hub-node.sh env --write --force\`"
  else
    _tok_lv=WARN _tok_msg="CCQUOTA_FLEET=1 but no node token: CCQUOTA_TOKEN unset and $_nenv missing — the entry's lease / placement / move all fall back silently: spawns are guarded by the GitHub claim alone, every session opens here, no move lands (issue #1491). Write it: $_nfix"
  fi
fi


_ho=$(bash "$(dirname "$0")/fleet-conf.sh" host --why 2>/dev/null)
_ho_on=${_ho%%	*}; _ho_how=${_ho#*	}
[ "$_ho_on" = 1 ] || _ho_on=0
_ho_old=''
for _rf in "$(dirname "$0")/../fleet.conf" "$conf_dir/fleet.settings" "$conf_dir/shell.conf"; do
  [ -f "$_rf" ] && _ho_old="${_ho_old:+$_ho_old, }$(printf '%s' "$_rf" | sed "s#^$HOME#~#")"
done
_ho_mc=$(printf '%s' "$conf_dir/fleet.conf" | sed "s#^$HOME#~#")
if [ "$_ho_on" = 1 ]; then _ho_w='基础 · 承载'; else _ho_w='基础 · 承载 未开（fleet host on）'; fi
case "$_ho_how" in
  *FLEET_ROLE*) _ho_how="$_ho_how — 同步时自动改写成 FLEET_HOST（\`bash $(dirname "$0")/fleet-conf.sh migrate\`）" ;;
esac
if [ -f "$conf_dir/fleet.conf" ] && [ -n "$_ho_old" ]; then
  warn 能力 "$_ho_w — $_ho_how; $_ho_mc 之外还在读旧文件: $_ho_old — 并进去后改名 .bak"
elif [ -f "$conf_dir/fleet.conf" ]; then
  case "$_ho_how" in
    *FLEET_ROLE*) info 能力 "$_ho_w — $_ho_how" ;;
    *)            pass 能力 "$_ho_w — $_ho_how; 配置只有一份: $_ho_mc" ;;
  esac
elif [ -n "$_ho_old" ] || [ -n "$(_fleet_confs "$conf_dir")" ]; then
  info 能力 "$_ho_w — $_ho_how; 设置仍分散在: ${_ho_old:-fleets/<会话>/conf · hub.json} — \`bash $(dirname "$0")/fleet-conf.sh migrate\` 并成一份（同步时自动跑）"
else
  pass 能力 "$_ho_w"
fi
if [ "$_ho_on" = 1 ] || [ "$_hub_on" = 1 ]; then
  _hs_name=$(hostname -s 2>/dev/null || hostname 2>/dev/null)
  if [ "$_hub_on" != 1 ]; then
    pass 承载 "${_hs_name:-本机} · 不接入口（只走本机）"
  elif [ "${_tok_lv:-}" = WARN ]; then
    warn 承载 "${_hs_name:-本机} · $_tok_msg"
  else
    _hs_cp=$(sed -n 's/^CCQUOTA_FLEET_COMPUTE=//p' "$conf_dir/node.env" 2>/dev/null | head -n 1)
    if [ "$_hs_cp" = 0 ]; then _hs_cw='入口只协调，不往这台派会话（fleet host on 打开）'; else _hs_cw='入口可往这台派会话'; fi
    pass 承载 "${_hs_name:-本机} · $_hs_cw · ${_tok_msg:-}"
  fi
fi

# --- hub: does fleet.conf say what node.env says (issue #2116) ----------------
# The node agent reads node.env and uses the hub; every fleet script reads the
# config files. When node.env has CCQUOTA_FLEET=1 / a hub URL and the files do
# not, the relay / trust / worker-assertion roads all answer "the hub module is
# off" while the agent is plainly on it. Read from the FILES only — an export in
# this shell is exactly the hand fix that hides it. No node.env ⇒ no row.
_hb_nenv="$conf_dir/node.env"; [ -r "$_hb_nenv" ] || _hb_nenv="$conf_dir/node.pub.env"
if [ -r "$_hb_nenv" ]; then
  _hb_non=$(sed -n 's/^CCQUOTA_FLEET=//p' "$_hb_nenv" | head -n 1 | tr -d "\"' ")
  _hb_nurl=$(sed -n 's/^CCQUOTA_HUB_URL=//p' "$_hb_nenv" | head -n 1 | tr -d "\"' ")
  _hb_con=$(_xconf_val "$conf_dir/fleet.conf" CCQUOTA_FLEET)
  [ -n "$_hb_con" ] || _hb_con=$(_xconf_val "$conf_dir/fleet.settings" CCQUOTA_FLEET)
  [ -n "$_hb_con" ] || _hb_con=$(_xconf_val "$(dirname "$0")/../fleet.conf" CCQUOTA_FLEET)
  _hb_curl=$(_xconf_val "$conf_dir/fleet.conf" FLEET_HUB_URL)
  [ -n "$_hb_curl" ] || _hb_curl=$(_xconf_val "$conf_dir/fleet.conf" CCQUOTA_HUB_URL)
  [ -n "$_hb_curl" ] || _hb_curl=$(_xconf_val "$(dirname "$0")/../fleet.conf" CCQUOTA_HUB_URL)
  _hb_miss=''
  [ "$_hb_non" = 1 ] && [ "$_hb_con" != 1 ] && _hb_miss="CCQUOTA_FLEET=1"
  [ -n "$_hb_nurl" ] && [ -z "$_hb_curl" ] && _hb_miss="${_hb_miss:+${_hb_miss}、}FLEET_HUB_URL"
  _hb_show=$(printf '%s' "${_hb_curl:-$_hb_nurl}" | sed 's#^[a-z]*://##; s#/$##')
  if [ -n "$_hb_miss" ]; then
    if [ "$_hb_non" = 1 ] && [ "$_hb_con" = 0 ]; then
      warn hub "node.env 接着入口 ${_hb_show}，fleet.conf 却写着 CCQUOTA_FLEET=0 — 中转 / 可信 / 会话通行证都以为入口关着；是有意关的就把 node.env 也关掉，否则删掉那一行再跑 \`bash $(dirname "$0")/fleet-conf.sh migrate\`"
    else
      warn hub "node.env 接着入口 ${_hb_show}，fleet.conf 没写 ${_hb_miss} — fleet 工具（中转 / 可信 / 会话通行证）都以为入口关着；\`bash $(dirname "$0")/fleet-conf.sh migrate\` 补齐（同步时自动跑）"
    fi
  elif [ "$_hb_non" = 1 ]; then
    pass hub "接着入口 ${_hb_show}（fleet.conf 与 node.env 一致）"
  fi
fi

# --- 可信: does the hub hand this machine subscription credentials (issue #1968) ---
# The operator's word on the hub (fleet.node_trust.<machine>), read as this
# login's node sees it (GET /v1/node/self). Only where the node token row
# passed: no hub, no token → no row. (The `trust` row is
# Claude Code's folder trust, #563 — a different word.) Untrusted is a WARN while sessions here
# still lease credentials directly (FLEET_CRED_PROXY≠1): the hub refuses them,
# so nothing here borrows the subscription until the operator trusts the
# machine; with the proxy on it is the central road, an INFO. A hub that
# cannot be asked, or predates #1968, is an INFO.
if [ "$_hub_on" = 1 ] && [ "${_tok_lv:-}" = PASS ] && [ -f "$(dirname "$0")/fleet-node-trust.sh" ]; then
  _tr=$(CCQUOTA_FLEET=1 FLEET_CONF_DIR="$conf_dir" FLEET_HUB_TIMEOUT="${FLEET_HUB_TIMEOUT:-5}" \
        bash "$(dirname "$0")/fleet-node-trust.sh" self 2>&1); _trc=$?
  _tr_m=$(printf '%s' "$_tr" | sed -n 's/^trust: \([^ ]*\) .*/\1/p' | head -n 1)
  case "$_trc:$_tr" in
    0:*' trusted') pass 可信 "${_tr_m:-本机} · 可信 — 入口给这台发订阅凭据" ;;
    0:*' untrusted')
      if [ "${FLEET_CRED_PROXY:-0}" = 1 ]; then
        info 可信 "${_tr_m:-本机} · 不可信 — 入口不给这台发订阅凭据，会话走中心代理"
      else
        warn 可信 "${_tr_m:-本机} · 不可信 — 入口不给这台发订阅凭据，这里的会话用不上订阅（操作者：fleet-node-trust.sh set ${_tr_m:-<machine>} trusted）"
      fi ;;
    *) info 可信 "问不到入口: $(printf '%s' "$_tr" | tail -n 1 | sed 's/^fleet-node-trust: //')" ;;
  esac
fi

# --- compute: may the hub open sessions on this login (issue #2480) --------------
# node.env's CCQUOTA_FLEET_COMPUTE beside the hub's own verdict (GET /v1/node/self:
# compute_off / compute_why / compute_auto). Off is why `fleet claude` lands on
# another machine — or nowhere: a WARN on a computer that hosts (承载), an INFO on
# one that only coordinates by choice. Only where the node token row passed.
if [ "$_hub_on" = 1 ] && [ "${_tok_lv:-}" = PASS ] && [ -f "$(dirname "$0")/fleet-node-trust.sh" ]; then
  _cp_env=$(sed -n 's/^CCQUOTA_FLEET_COMPUTE=//p' "$conf_dir/node.env" 2>/dev/null | head -n 1 | tr -d "\"' ")
  _cp_j=$(CCQUOTA_FLEET=1 FLEET_CONF_DIR="$conf_dir" FLEET_HUB_TIMEOUT="${FLEET_HUB_TIMEOUT:-5}" \
          bash "$(dirname "$0")/fleet-node-trust.sh" self --json 2>/dev/null) || _cp_j=''
  _cp=$(printf '%s' "$_cp_j" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    d = None
if not isinstance(d, dict):
    print("?"); sys.exit(0)
host = (d.get("hostname") or "").split(".")[0]
print("%s\n%s\n%s" % ("off" if d.get("compute_off") else ("auto" if d.get("compute_auto") else "on"),
                      host, " ".join(str(d.get("compute_why") or "").split())))' 2>/dev/null)
  _cp_v=$(printf '%s\n' "${_cp:-?}" | sed -n 1p); _cp_h=$(printf '%s\n' "$_cp" | sed -n 2p); _cp_why=$(printf '%s\n' "$_cp" | sed -n 3p)
  _cp_who="${_cp_h:-$(hostname -s 2>/dev/null)}/$(id -un)"
  _cp_open='打开：在这台运行 fleet host on（即 node.env CCQUOTA_FLEET_COMPUTE=1），或在入口打开团队策略 fleet.compute_auto'
  case "$_cp_why" in *出口地区*) _cp_open='出口地区不在支持范围；确要打开：fleet host on --force（记进入口审计）' ;; esac
  _cp_lv=warn; [ "$_ho_on" = 1 ] || _cp_lv=info
  case "$_cp_v" in
    on)   pass compute "$_cp_who · 入口可往这台派会话（node.env CCQUOTA_FLEET_COMPUTE=${_cp_env:-未写，按开}）" ;;
    auto) pass compute "$_cp_who · 入口可往这台派会话（团队策略 fleet.compute_auto 打开的；node.env CCQUOTA_FLEET_COMPUTE=${_cp_env:-未写}）" ;;
    off)
      if [ "$_cp_env" = 0 ]; then
        $_cp_lv compute "$_cp_who · 只协调：${_cp_why:-compute off} — 入口不往这台派会话，fleet claude 只能去别的机器开；$_cp_open"
      else
        $_cp_lv compute "$_cp_who · 入口判它只协调（${_cp_why:-compute off}），node.env 却是 CCQUOTA_FLEET_COMPUTE=${_cp_env:-未写} — 下一次心跳才生效，仍是这样就看 agent 在不在跑（fleet node status）；$_cp_open"
      fi ;;
    *)
      if [ "$_cp_env" = 0 ]; then
        $_cp_lv compute "$_cp_who · node.env CCQUOTA_FLEET_COMPUTE=0：只协调 — 入口不往这台派会话（问不到入口的判断）；$_cp_open"
      else
        info compute "$_cp_who · node.env CCQUOTA_FLEET_COMPUTE=${_cp_env:-未写，按开}；问不到入口的判断"
      fi ;;
  esac
fi

# --- credsep: the credentials out of this login's reach (issue #1971) --------------
# FLEET_CRED_SEPARATE=1 → the role account's store must be unreadable here, no
# credential back at a login path, its proxy up; =0 and not separated → no row.
if [ -f "$(dirname "$0")/fleet-credsep.py" ]; then
  _cs=$(FLEET_CONF_DIR="$conf_dir" bash "$(dirname "$0")/fleet-credsep.sh" check 2>&1 | tail -n 1)
  _cs_m=${_cs#credsep: }; _cs_lv=${_cs_m%% —*}; _cs_m=${_cs_m#* — }
  case "$_cs_lv" in
    OK)   pass credsep "$_cs_m" ;;
    WARN) warn credsep "$_cs_m" ;;
    INFO) case "$_cs_m" in off*) ;; *) info credsep "$_cs_m" ;; esac ;;   # off: no row, as before
    *)    info credsep "$_cs_m" ;;
  esac
fi

# --- rootlog: no root service writes its log in a home (issue #2296) --------------
# launchd / systemd open a root job's stdout file AS ROOT and follow a symlink:
# a log in a home is a root write its login aims. Only on a machine the fleet put
# services on (a com.ccquota.agent.* / com.claude-fleet.* / ccquota-agent-* unit).
_rl_dir="${FLEET_CREDSEP_DAEMON_DIR:-$([ "$(uname)" = Darwin ] && echo /Library/LaunchDaemons || echo /etc/systemd/system)}"
if [ -f "$(dirname "$0")/fleet-credsep.py" ] && [ -d "$_rl_dir" ] \
   && find "$_rl_dir" -maxdepth 1 \( -name 'com.ccquota.agent.*' -o -name 'com.claude-fleet.*' \
        -o -name 'ccquota-agent-*' -o -name 'claude-fleet-*' \) 2>/dev/null | grep -q .; then
  _rl=$(bash "$(dirname "$0")/fleet-credsep.sh" rootlogs 2>&1 | tail -n 1)
  _rl_m=${_rl#rootlog: }; _rl_lv=${_rl_m%% —*}; _rl_m=${_rl_m#* — }
  case "$_rl_lv" in
    OK)   pass rootlog "$_rl_m" ;;
    WARN) warn rootlog "$_rl_m" ;;
    *)    info rootlog "$_rl_m" ;;
  esac
fi

# --- cred: which road this login's sessions take, and why (issue #1975) -----------
# FLEET_CRED_PROXY=1 only (off = no row, as before): trust × probe → direct /
# relay / central per agent, the proxy alive, credsep, session-pass renewal —
# one line from `fleet-cred-proxy.sh doctor` (its exit 3 = off).
if [ -f "$(dirname "$0")/fleet-cred-proxy.py" ]; then
  _cr=$(FLEET_CONF_DIR="$conf_dir" bash "$(dirname "$0")/fleet-cred-proxy.sh" doctor 2>/dev/null); _crc=$?
  if [ "$_crc" = 0 ] && [ -n "$_cr" ]; then
    _cr_lv=$(printf '%s' "$_cr" | cut -f1); _cr_m=$(printf '%s' "$_cr" | cut -f2-)
    case "$_cr_lv" in
      PASS) pass cred "$_cr_m" ;;
      FAIL) fail cred "$_cr_m" ;;
      *)    warn cred "$_cr_m" ;;
    esac
  fi
fi

# --- tmux ≥ 3.2 (core) ---
if command -v tmux >/dev/null 2>&1; then
  v=$(tmux -V 2>/dev/null | sed -E 's/[^0-9.]//g')
  if [ -n "$v" ] && vge "$v" 3.2; then pass tmux "$v (≥ 3.2)"
  else fail tmux "$v — need ≥ 3.2 (attention layer + status bar)"; fi
else
  fail tmux "not found — the fleet is a tmux session (need ≥ 3.2)"
fi

# --- fzf ≥ 0.45 (dashboard) ---
if command -v fzf >/dev/null 2>&1; then
  v=$(fzf --version 2>/dev/null | awk '{print $1}')
  if [ -n "$v" ] && vge "$v" 0.45; then pass fzf "$v (≥ 0.45)"
  else fail fzf "$v — need ≥ 0.45; dash binds use \`transform\` (prefix+g breaks below)"; fi
else
  fail fzf "not found — need ≥ 0.45 for the prefix+g dashboard"
fi

# --- gh + auth (backlog + PR/CI map) ---
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then pass gh "authed"
  else warn gh "installed but not authed — backlog + PR/CI panels stay empty (\`gh auth login\`)"; fi
  # PR status has its own fast daemon (decoupled from the 60s collector) so
  # CI-green / merged shows within ~15s. Recommended alongside the collector.
  printf '        note: install com.claude-fleet.pr-refresh (~15s, FLEET_PR_REFRESH_INTERVAL) for fast PR/CI status — single writer of prmap + @prci.\n'
else
  fail gh "not found — no backlog, no PR/CI map (\`brew install gh\`)"
fi

# --- github: is the account rate-limited right now? (issue #989, EPIC #1262 C2) ---
# READ off the shared gh-limit marker + logs/gh-limit.log (bin/fleet-gh-lib.sh) —
# never a probe, and never `gh api rate_limit` (it reported 5000 left while every
# GraphQL call was refused, #946 #989 #1211). The last-hour tally is the log's
# limited / skip / fallback-ok events; a `used=` field, when a writer logs one,
# reports the highest X-RateLimit-Used seen.
# The lib is bash and this script is POSIX sh, so it runs in a bash child (as the
# alerts row does), which also renders each row's HH:MM.
_gh_lib="$(dirname "$0")/fleet-gh-lib.sh"
_gh_rows=''; _gh_hour=''
# shellcheck disable=SC2016
[ -f "$_gh_lib" ] && _gh_rows=$(bash -c '. "$1" || exit 1
  fleet_gh_limit_rows | while IFS="	" read -r b r s; do
    case "$r" in fake) echo "$b limited (injected: FLEET_GH_FAKE_LIMIT)" ;;
      *) echo "$b limited until $(fleet_gh_hhmm "$r") (seen by $s)" ;; esac
  done' _ "$_gh_lib" 2>/dev/null)
_gh_log="${FLEET_GH_LOG:-$(dirname "$0")/../logs/gh-limit.log}"
if [ -f "$_gh_lib" ] && [ -f "$_gh_log" ]; then
  _gh_cut=$(date -u -r $(( $(date +%s) - 3600 )) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$(( $(date +%s) - 3600 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  _gh_hour=$(awk -v cut="$_gh_cut" '$1 >= cut {
      n[$2]++
      for (i = 3; i <= NF; i++) if ($i ~ /^used=[0-9]+$/) { u = substr($i, 6) + 0; if (u > mu) mu = u }
    } END {
      printf "last hour: %d limited · %d skipped · %d fallback-ok", n["limited"], n["skip"], n["fallback-ok"]
      if (mu > 0) printf " · X-RateLimit-Used max %d", mu
    }' "$_gh_log" 2>/dev/null)
fi
# One account, one set of background reads (issue #1271): which login of this
# token fetches (leader) and which read its copy (follower). Off → no clause.
_gh_share=''
# shellcheck disable=SC2016
[ -f "$_gh_lib" ] && _gh_share=$(bash -c '[ -f "$2" ] && . "$2" >/dev/null 2>&1; . "$1" || exit 1
  fleet_gh_share_on || exit 0
  me=$(fleet_gh_share_me)
  if lead=$(fleet_gh_leader); then
    if [ "$lead" = "$me" ]; then echo "background reads: leader ($me)"
    else echo "background reads: follower of $lead"; fi
  else echo "background reads: no live leader — this login fetches"; fi' _ "$_gh_lib" "$(dirname "$0")/../fleet.conf" 2>/dev/null)
_gh_hour="${_gh_hour}${_gh_share:+${_gh_hour:+ · }$_gh_share}"
if [ -n "$_gh_rows" ]; then
  _gh_msg=$(printf '%s\n' "$_gh_rows" | awk 'NF { printf "%s%s", (n++ ? "; " : ""), $0 }')
  warn github "$_gh_msg — the shared account limit, not a permission problem: GraphQL calls fall back to REST until then${_gh_hour:+ · $_gh_hour}"
elif [ -f "$_gh_lib" ]; then
  pass github "not rate-limited${_gh_hour:+ · $_gh_hour}"
fi

# --- python3 (collector context% + usage caches) ---
if command -v python3 >/dev/null 2>&1; then
  pass python3 "$(python3 --version 2>&1 | awk '{print $2}')"
else
  fail python3 "not found — collector context% and usage caches will be empty"
fi

# --- claude CLI (sessions + optional LLM daemons) ---
if command -v claude >/dev/null 2>&1; then
  pass claude "on PATH"
else
  warn claude "not found — the CLI you run per window and the optional classify hook"
fi

# Only enrolled logins need the one-line readiness verdict. This is a WARN,
# never a FAIL: install-sync uses the doctor's FAIL count as its rollback gate.
if [ -f "$conf_dir/global/bootstrapped" ]; then
  if onboard=$(FLEET_CONF_DIR="$conf_dir" bash "$(dirname "$0")/fleet-doctor-onboard.sh" 2>/dev/null); then
    pass onboard "$onboard · 本机 / 联机模式: docs/LOCAL-AND-HUB.md"
  else warn onboard "${onboard:-readiness probe failed}"; fi
fi

# --- fleet quality-of-life commands (optional: repo-shipped /skills) ---
# TWO install paths reach a session with these (issue #611), and the fleet runs
# without either, so a missing set is a warn and never a fail:
#
#   plugin  `/plugin install fleet@claude-fleet` — commands, skills and the hook
#           table together, updated by `/plugin update`. Typed NAMESPACED:
#           `/fleet:fleet-claim`.
#   copy    commands/*.md → ~/.claude/commands/ (the historic path, still
#           supported). Typed bare: `/fleet-claim`.
#
# Each fleet skill carries a `fleet skill · owner:` marker just under its title
# (see commands/README.md); count how many landed in the copy dir. Match only the
# file head so README.md — which merely quotes the marker in prose — isn't
# miscounted as a skill.
cmd_dir="${CLAUDE_COMMANDS_DIR:-$HOME/.claude/commands}"
n=0
if [ -d "$cmd_dir" ]; then
  for f in "$cmd_dir"/*.md; do
    [ -f "$f" ] || continue   # literal *.md when the glob matches nothing
    head -n 3 "$f" 2>/dev/null | grep -qF 'fleet skill · owner:' && n=$((n+1))
  done
fi
# The plugin ships the same commands from its own cache. Doctor is /bin/sh and
# cannot source the bash-only fleet-lib.sh, so this inlines fleet_plugin_installed
# — KEEP IN SYNC with it. The cache path is
# <config>/plugins/cache/<marketplace>/<plugin>/<version>/, and the version dir
# moves on EVERY update, so glob it rather than remembering one.
plug=0
for _d in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/*/fleet/*/; do
  [ -f "$_d/commands/fleet-claim.md" ] && { plug=1; break; }
done
if [ "$n" -gt 0 ] && [ "$plug" = 1 ]; then
  pass commands "$n fleet command(s) in $cmd_dir + the fleet plugin (both resolve; the bare /fleet-claim wins)"
elif [ "$plug" = 1 ]; then
  pass commands "fleet plugin installed — commands are namespaced (/fleet:fleet-claim), updated by /plugin update"
elif [ "$n" -gt 0 ]; then
  pass commands "$n fleet command(s) in $cmd_dir (copy install; \`/plugin install fleet@claude-fleet\` replaces the copying)"
elif [ -d "$cmd_dir" ]; then
  warn commands "no fleet commands in $cmd_dir and no fleet plugin — optional /skills not installed (install the plugin, or copy commands/*.md)"
else
  warn commands "$cmd_dir absent and no fleet plugin — optional fleet /skills not installed"
fi

# --- fleet skills tree (optional: repo-shipped skills/ base skills) ---
# Some fleet commands delegate to a repo-versioned base SKILL under
# ~/.claude/skills/ (installed by /fleet-sync-install's skills pass — see
# docs/INSTALL.md). The load-bearing case is /fleet-handoff, which runs the base
# `handoff` skill VERBATIM: with the command present but the skill missing,
# /fleet-handoff points at a dependency a fresh install never shipped (issue #311).
# So specifically flag that combination — command installed, base skill absent.
# A plugin install ships commands AND skills from the same cache, so the pair can
# never be half-present there — this gap is specific to the copy path.
skills_dir="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
if [ "$plug" = 0 ] && [ -f "$cmd_dir/fleet-handoff.md" ] && [ ! -f "$skills_dir/handoff/SKILL.md" ]; then
  warn skills "/fleet-handoff installed but its base skill $skills_dir/handoff/SKILL.md is missing — handoff will have nothing to delegate to (run /fleet-sync-install to install skills/*)"
fi
# The orchestrating session (issue #1957) is seeded `/fleet-orchestrate`; with
# the skill missing it opens on `Unknown command` and sits there empty (issue
# #2110). Same switch fleet-orchestrator.sh reads: FLEET_ORCHESTRATOR, default 承载.
_orch_on=${FLEET_ORCHESTRATOR:-$(_gconf_val FLEET_ORCHESTRATOR)}
[ -n "$_orch_on" ] || _orch_on=$(bash "$(dirname "$0")/fleet-conf.sh" host 2>/dev/null)
case "$_orch_on" in 1|on|yes|true) _orch_on=1 ;; *) _orch_on=0 ;; esac
_orch_agent=${FLEET_AGENT:-$(_gconf_val FLEET_AGENT)}
if [ "$_orch_agent" = codex ]; then _orch_sk="${CODEX_HOME:-$HOME/.codex}/skills/fleet-orchestrate/SKILL.md"
else _orch_sk="$skills_dir/fleet-orchestrate/SKILL.md"; fi
if [ "$_orch_on" = 1 ] && [ "$plug" = 0 ] && [ ! -f "$_orch_sk" ]; then
  warn skills "the orchestrator is on here but $_orch_sk is missing — its session opens on \`Unknown command: /fleet-orchestrate\` and sits empty (run /fleet-sync-install; or FLEET_ORCHESTRATOR=0 to turn it off)"
fi

# doc-preview is a soft/opt dep on tailscale: it hosts Markdown docs on the
# machine's tailnet, so with the skill installed but tailscale absent it's a
# no-op (share.sh exits "tailscale is not running / logged out"), not a broken
# install. Warn, never fail — the fleet runs fine without it (issue #354).
if [ -f "$skills_dir/doc-preview/SKILL.md" ] && ! command -v tailscale >/dev/null 2>&1; then
  warn skills "doc-preview skill installed but tailscale not on PATH — the skill is a no-op without it (it serves docs over the tailnet); install/enable Tailscale to use it"
fi

# Can THIS login `tailscale serve`? Only the machine's ONE tailscale operator (or
# root) can; any other login's doc-preview falls back to plain http bound on the
# tailscale IPv4 ("http-direct", issue #1093). That is a supported mode, not a
# fault — the operator can't be shared, and moving it would break the login that
# holds it — so it is INFO, with the one-time root command for anyone who wants
# HTTPS for this login instead. The ports in it are bind-probed the way share.sh
# picks them (loopback server port from DOC_PREVIEW_PORT; a tailnet HTTPS port no
# serve route and no listener holds). Operator unreadable/unset → no row, never a guess.
if [ -f "$skills_dir/doc-preview/SKILL.md" ] && command -v tailscale >/dev/null 2>&1; then
  _dp_me="$(id -un 2>/dev/null || echo "${USER:-}")"
  _dp_op="$(tailscale debug prefs 2>/dev/null | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("OperatorUser") or "")
except Exception: pass' 2>/dev/null || true)"
  if [ "$(id -u 2>/dev/null)" = 0 ] || { [ -n "$_dp_op" ] && [ "$_dp_op" = "$_dp_me" ]; }; then
    pass docprev "this login ($_dp_me) can tailscale serve — doc-preview shares over tailnet HTTPS"
  elif [ -n "$_dp_op" ]; then
    _dp_ports="$(tailscale serve status --json 2>/dev/null | python3 -c 'import sys,json,socket
def free(a,p):
    s=socket.socket()
    try: s.bind((a,p)); return True
    except OSError: return False
    finally: s.close()
try: used=set(((json.load(sys.stdin) or {}).get("TCP") or {}).keys())
except Exception: used=set()
ip=sys.argv[2]; p=int(sys.argv[1])
while p < int(sys.argv[1])+50 and not free("127.0.0.1",p): p+=1
h=8443
while h < 8543 and (str(h) in used or (ip and not free(ip,h))): h+=1
print(h, p)' "${DOC_PREVIEW_PORT:-8765}" "$(tailscale ip -4 2>/dev/null | head -1)" 2>/dev/null || echo "8443 ${DOC_PREVIEW_PORT:-8765}")"
    _dp_hp="${_dp_ports% *}"; _dp_lp="${_dp_ports#* }"
    info docprev "this login ($_dp_me) is not tailscale's operator ($_dp_op), so it cannot tailscale serve — doc-preview falls back to http-direct: plain http on the tailscale IP, reachable only inside the tailnet (WireGuard-encrypted). For HTTPS instead, once: sudo tailscale serve --bg --https=$_dp_hp http://127.0.0.1:$_dp_lp, then share.sh --stop and re-share (it adopts that route). Don't move the operator — that breaks $_dp_op's doc-preview"
  fi
fi

# What doc-preview has OUT there (issue #1153): public (Funnel) links, how long the oldest
# has been up, one that never expires; tailscale serve routes stacked on one backend or
# left pointing at a dead port (one machine had ~260). share.sh --health is the one
# reader — it judges with the same expiry rule the server enforces. Nothing shared → no row.
if [ -x "$skills_dir/doc-preview/share.sh" ] && [ -d "$HOME/.cache/claude-doc-preview/entries" ]; then
  _dp_h="$("$skills_dir/doc-preview/share.sh" --health 2>/dev/null | tail -1)"
  _dp_v() { printf '%s\n' "$_dp_h" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
  _dp_pub="$(_dp_v public)"; _dp_old="$(_dp_v oldest_public_secs)"; _dp_inf="$(_dp_v unexpiring_public)"
  _dp_dup="$(_dp_v serve_dup)"; _dp_dead="$(_dp_v serve_dead)"; _dp_rt="$(_dp_v serve_routes)"
  # A server.py older than the installed copy keeps the old rules (issue #2415: one from
  # before #1153 listed every share without a code for a day after the install moved).
  if [ "$(_dp_v server_stale)" -gt 0 ] 2>/dev/null; then
    warn docprev "$(_dp_v server_stale) running doc-preview server.py older than the installed copy — it still serves the old rules: $skills_dir/doc-preview/share.sh --upgrade"
  fi
  if [ -n "$_dp_pub" ]; then
    _dp_msg="public links: ${_dp_pub} (oldest $(( ${_dp_old:-0} / 3600 ))h, never-expiring ${_dp_inf:-0}); serve routes to loopback: ${_dp_rt:-0} (stacked ${_dp_dup:-0}, dead ${_dp_dead:-0})"
    if [ "${_dp_dup:-0}" -gt 0 ] || [ "${_dp_dead:-0}" -gt 0 ]; then
      warn docprev "$_dp_msg — extra tailscale serve routes are left behind; the next share.sh run drops this login's (or: tailscale serve status, then tailscale serve --https=<port> off)"
    elif [ "${_dp_inf:-0}" -gt 0 ] || [ "${_dp_old:-0}" -gt 604800 ]; then
      warn docprev "$_dp_msg — a public link that never expires or is over 7 days old: share.sh --list, then share.sh --unpublish <id>"
    elif [ "${_dp_pub:-0}" -gt 0 ]; then
      info docprev "$_dp_msg"
    fi
  fi
fi

# --- live install freshness: is THIS machine's ~/.claude/fleet current? (#635) ---
# The commands/skills checks above answer "is it installed". This answers "is it
# CURRENT", which nothing used to. `/fleet-sync-install` is per-machine and
# manual, so machine #2 goes stale in silence: on 2026-09-14 macmini's live
# install sat 28 commits behind master — no #603 base-branch fix, no #617 quota
# ranking, no #608 matrix — and doctor was green on BOTH boxes. The plugin path
# (#611) fixed this for commands/skills/hooks only; `bin/`, `conf/` and the
# daemons still ride a hand-run `git pull`, and that half is what this measures.
#
# It costs ONE `git fetch` of one branch (~1s). That is fine here — doctor is
# run by a human — and is exactly why the fetching form must never be put on the
# collector's 60s tick (fleet-install-version.sh --no-fetch is the free read).
#
# A machine with no ~/.claude/fleet is not a fault: doctor's other job is
# preflight BEFORE an install exists. Nothing is printed in that case.
iv="$(dirname "$0")/fleet-install-version.sh"
live_dir="${FLEET_LIVE_DIR:-$HOME/.claude/fleet}"
if [ -f "$iv" ] && [ -d "$live_dir" ]; then
  ivout=$(sh "$iv" 2>/dev/null)
  # Parse the human form, not --json: these keys are line-anchored, so a path or
  # a message containing a quote can't shift the fields (doctor has no jq).
  _ivf() { printf '%s\n' "$ivout" | sed -n "s/^$1:  *//p"; }
  iv_verdict=$(_ivf verdict); iv_behind=$(_ivf behind); iv_ahead=$(_ivf ahead)
  iv_trunk=$(_ivf trunk); iv_head=$(_ivf head); iv_note=$(_ivf note); iv_dirty=$(_ivf dirty)
  iv_fix="git -C $live_dir pull --ff-only, then /fleet-sync-install (which also reloads the changed daemons — a bare pull does not)"
  case "$iv_verdict" in
    CURRENT)
      pass install "$live_dir at ${iv_head:-?} — up to date with ${iv_trunk%% *}"
      [ "$iv_dirty" = yes ] && printf '        note: the live install has uncommitted tracked changes — the next fast-forward will refuse.\n'
      ;;
    BEHIND)
      warn install "$live_dir is $iv_behind commit(s) behind ${iv_trunk%% *} — this machine runs old bin/ + daemons while master has moved (the drift nothing used to report, #635); fix: $iv_fix"
      ;;
    AHEAD)
      warn install "$live_dir has $iv_ahead local commit(s) not on ${iv_trunk%% *} — someone edited/tested in place; the next \`pull --ff-only\` will refuse until that is resolved"
      ;;
    DIVERGED)
      warn install "$live_dir has diverged from ${iv_trunk%% *} ($iv_ahead local commit(s), $iv_behind upstream) — \`pull --ff-only\` will refuse; resolve before the next sync"
      ;;
    *)
      warn install "could not tell whether $live_dir is current — reporting unknown, NOT up to date (${iv_note:-no reason given})"
      ;;
  esac
  # The stable mark (issue #1118): installs follow refs/tags/stable, not master,
  # so say how far the mark itself trails trunk — the operator's cue to move it.
  # INFO, never counted: a stable that trails master is a choice, not a fault.
  st="$(dirname "$0")/fleet-stable.sh"
  if [ -f "$st" ]; then
    stout=$(sh "$st" show --dir "$live_dir" 2>/dev/null)
    _stf() { printf '%s\n' "$stout" | sed -n "s/^$1:  *//p"; }
    st_sha=$(_stf stable); st_behind=$(_stf behind); st_trunk=$(_stf trunk)
    case "$(_stf verdict)" in
      CURRENT)  info install "stable (refs/tags/stable) at $st_sha — same commit as ${st_trunk%% *}" ;;
      BEHIND)   info install "stable (refs/tags/stable) at $st_sha is $st_behind commit(s) behind ${st_trunk%% *} — installs follow stable; move it with \`fleet-stable.sh move\` (forward only, CI-green only)" ;;
      NONE)     info install "no stable tag (refs/tags/stable) on the remote yet — nothing for installs to follow; set it with \`fleet-stable.sh move <sha>\`" ;;
      OFFTRUNK) info install "stable (refs/tags/stable) at $st_sha is not on ${st_trunk%% *} — the next \`fleet-stable.sh move\` must come from trunk" ;;
      *)        info install "could not read the stable tag — its distance from trunk is unknown, NOT 0" ;;
    esac
  fi
  # Is THIS login following stable, and are the others (issue #1123, EPIC #1117
  # C7)? The install-sync daemon (#1120) moves each login on its own, and when it
  # stops — refused, rolled back, deferred for a day, never ticked — nothing said
  # so. bin/fleet-install-follow.sh is the one reader of its state file: OK is a
  # PASS, STUCK a WARN (with the opt-out named, the documented way to silence it),
  # OFF / UNSEEN an INFO. Other logins are read as their owner (sudo -n); without
  # passwordless sudo they read `?`, never a WARN. Nothing counts a FAIL here: the
  # daemon's own post-update doctor compares FAIL lines, and a fresh install
  # waiting for its first tick must not roll a version back.
  fl="$(dirname "$0")/fleet-install-follow.sh"
  if [ -f "$fl" ]; then
    flout=$(sh "$fl" --self --dir "$live_dir" --conf-dir "$conf_dir" 2>/dev/null)
    _flf() { printf '%s\n' "$flout" | sed -n "s/^$1:  *//p"; }
    fl_off="opt out with FLEET_INSTALL_SYNC=0 in $conf_dir/fleet.settings — then this login neither follows nor warns"
    case "$(_flf verdict)" in
      OK)     pass install "install-sync on — $(_flf why) (last tick $(_flf checked))" ;;
      STUCK)  fl_retry=''
              # issue #2655: a rolled-back version is skipped until stable moves — or retried now
              case "$(_flf result)" in rolled-back|skipped) fl_retry="; try it again now: \`bash $(dirname "$0")/fleet-install-sync.sh --retry\`" ;; esac
              warn install "install-sync on but this login is NOT following stable: $(_flf why) (last tick $(_flf checked))$fl_retry; $fl_off" ;;
      OFF)    info install "install-sync off — $(_flf why)" ;;
      UNSEEN) info install "install-sync on — stable not seen at the last tick ($(_flf checked)): $(_flf why)" ;;
      *)      warn install "install-sync state unreadable — $(_flf why); $fl_off" ;;
    esac
    flo=$(sh "$fl" --others --summary --dir "$live_dir" --conf-dir "$conf_dir" 2>/dev/null); flrc=$?
    if [ "$flrc" -eq 1 ]; then
      warn install "other login(s) on this machine NOT following stable: $flo — each follows on its own once synced (bash $(dirname "$0")/fleet-sync-logins.sh --logins <login>); a login that opted out (FLEET_INSTALL_SYNC=0) reads \`off\` and is never warned about"
    elif [ -n "$flo" ]; then
      info install "other logins on this machine: $flo (\`?\` = unreadable without passwordless sudo; $(dirname "$0")/fleet-install-follow.sh for the table)"
    fi
  fi
  # The OTHER MACHINES (issue #644, EPIC #1524 R4). The install that is old is on
  # the machine you are not logged into: on 2026-09-14 the Mac mini sat 28 commits
  # behind while nobody ran doctor there. Every node's heartbeat carries its live
  # install's HEAD (fleet-install-version.sh --json, read by the agent); the hub
  # refresh loop (fleet-hub-sessions.sh) writes one row per machine into
  # global/hub_nodes and judges that version against THIS login's local
  # refs/tags/stable — the `old:<n>` word the status bar draws as 旧. This row
  # reads that cache, never the hub: no cache (hub off, a certificate identity)
  # prints nothing — the degenerate case. WARN when any machine is behind stable;
  # a version this checkout cannot resolve, or none reported, is "unknown" — the
  # #635 rule: never 0, never current.
  hn="${FLEET_STATUS_G:-${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash/global}/hub_nodes"
  if [ -s "$hn" ]; then
    hn_sum=$(LC_ALL=C awk -F "$(printf '\037')" '
      $1 == "#ts" { ts = $2; next }
      $1 == "" { next }
      { ver = $7; vs = $11; n++
        if (vs ~ /^old:/)        { sub(/^old:/, "", vs); w = $1 " at " ver " — " vs " behind stable (OLD)"; nold++ }
        else if (vs == "ok")     w = $1 " at " ver " — at stable"
        else if (vs ~ /^ahead:/) { sub(/^ahead:/, "", vs); w = $1 " at " ver " — " vs " ahead of stable" }
        else if (vs == "off")    w = $1 " at " ver " — not on stable'"'"'s line"
        else if (vs == "?")      w = $1 " at " ver " — unknown (a commit this checkout has not fetched)"
        else if (ver != "")      w = $1 " at " ver " — unknown (not judged against stable: no local refs/tags/stable yet, or an older refresh loop)"
        else                     w = $1 " — unknown (no fleet version reported)"
        s = (s == "" ? w : s " · " w) }
      END { printf "%d\n%d\n%s\n%s\n", nold + 0, n + 0, ts, s }' "$hn")
    _hnf() { printf '%s\n' "$hn_sum" | sed -n "${1}p"; }
    hn_old=$(_hnf 1); hn_n=$(_hnf 2); hn_ts=$(_hnf 3); hn_s=$(_hnf 4)
    hn_age=''; case "$hn_ts" in ''|*[!0-9]*) ;; *) hn_age=" (hub cache $(( $(date +%s) - hn_ts ))s old)" ;; esac
    if [ "${hn_n:-0}" -gt 0 ]; then
      if [ "${hn_old:-0}" -gt 0 ]; then
        warn install "machines (hub): $hn_s$hn_age — an OLD machine runs bin/ + daemons behind the mark every login follows; on it, \`sh fleet-install-follow.sh\` says whether install-sync is stuck or off, and /fleet-sync-install moves it by hand"
      else
        info install "machines (hub): $hn_s$hn_age"
      fi
    fi
  fi
fi

# --- config modal (prefix+c: view/edit per-fleet + global fleet config) ---
# The popup (bin/tmux-config.sh) sources its key list + per-key help from
# fleet.conf.example; without that file it can't render. It lives in the repo /
# install root (one dir up from bin/).
ex_root=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
if [ -f "$ex_root/fleet.conf.example" ]; then
  pass config "fleet.conf.example present — prefix+c config modal can render (view/edit keys)"
else
  warn config "fleet.conf.example missing — prefix+c config modal has no key list/help source"
fi

# --- panel keys vs the tmux prefix (issues #556/#558) ---
# tmux never delivers its prefix (or prefix2) to a pane, so a panel ⌃-key equal
# to it is dead on the keyboard (⌃a was: the operator's prefix is C-a).
# bin/dash-keymap.sh resolves each panel's bind table against the prefix (the live
# server, else the tmux conf) and remaps a colliding default to its ⌥ twin — the
# fleet-keys.sh shows the real key. Say so here anyway (docs name the defaults),
# and shout when even the fallback is a prefix: that key is unreachable.
km="$(dirname "$0")/dash-keymap.sh"
if [ -f "$km" ]; then
  pfx=$(bash "$km" prefixes 2>/dev/null); pfx="${pfx:-C-b -}"
  p1="${pfx%% *}"; p2="${pfx#* }"
  if [ "$p2" = "-" ]; then p2=""; else p2=" + prefix2 $p2"; fi
  for panel in dash backlog config; do
  coll=$(bash "$km" --panel "$panel" collisions 2>/dev/null)
  if [ -z "$coll" ]; then
    pass keys "no $panel key collides with the tmux prefix ($p1$p2)"
  else
    while read -r act def pname fb; do
      [ -n "$act" ] || continue
      if [ "$fb" = UNREACHABLE ]; then
        warn keys "$panel $def ($act) is your tmux prefix $pname and its ⌥ twin is one too — unreachable from $panel; change prefix2 or the key"
      else
        warn keys "$panel $def ($act) is your tmux prefix $pname — the $panel binds $fb instead (fleet-keys.sh shows it)"
      fi
    done <<EOF
$coll
EOF
  fi
  done
else
  warn keys "bin/dash-keymap.sh missing — panel keys are not checked against the tmux prefix"
fi

# --- multi-account token pool (optional: auto-failover across subscriptions) ---
if [ -d "$conf_dir/handoffs/quota-requests" ]; then
  _failover=$(python3 - "$conf_dir/handoffs/quota-requests" <<'PY'
import json,pathlib,sys
for p in pathlib.Path(sys.argv[1]).glob('*/request.json'):
    try: r=json.loads(p.read_text())
    except (OSError,ValueError): continue
    if r.get('state') not in ('bound','cancelled','recovered'):
        s=r.get('source',{})
        print('%s/%s: %s — %s' % (s.get('session','?'),s.get('window','?'),r.get('state','?'),r.get('detail','')))
PY
)
  if [ -n "$_failover" ]; then warn failover "$_failover (fleet-account.sh failover-status)";
  else pass failover 'no pending subscription cutovers'; fi
  # A request retrying on the same reason past FLEET_FAILOVER_STUCK_ATTEMPTS
  # (issue #872) — the ones that already paged the operator, counted apart
  # from ordinary pending cutovers.
  _stuck=$(python3 - "$conf_dir/handoffs/quota-requests" <<'PY'
import json,pathlib,sys
rows=[]
for p in pathlib.Path(sys.argv[1]).glob('*/request.json'):
    try: r=json.loads(p.read_text())
    except (OSError,ValueError): continue
    if r.get('stuck_notified') and r.get('state') not in ('bound','cancelled','recovered'):
        s=r.get('source',{})
        rows.append('%s/%s x%s' % (s.get('session','?'),s.get('window','?'),r.get('same_detail_streak','?')))
if rows: print('%d stuck: %s' % (len(rows),', '.join(rows)))
PY
)
  if [ -n "$_stuck" ]; then warn failover-stuck "$_stuck — same reason every retry (dash migrate key on the row, or fleet-account.sh migrate --stuck --force-bg --session <fleet>)";
  else pass failover-stuck '0 stuck failover requests'; fi
fi
# OFF unless token files exist. When ON, each file's contents must be a non-empty
# `claude setup-token` OAuth token, and 0600 so the token isn't world-readable.
acct_dir="${FLEET_ACCOUNTS_DIR:-$HOME/.config/claude-fleet/accounts}"
if [ -d "$acct_dir" ] && [ -n "$(find "$acct_dir" -maxdepth 1 -type f ! -name '.*' ! -name '*~' ! -name '*.conf' 2>/dev/null)" ]; then
  n=0; bad=0
  for f in "$acct_dir"/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in .*|*~|*.conf) continue;; esac   # .conf = per-account settings
    n=$((n+1))
    [ -s "$f" ] || { warn account "empty token file: ${f##*/} (run \`claude setup-token\`)"; bad=$((bad+1)); continue; }
    # ls -ld perms: chars are type + owner(3) + group(3) + other(3);
    # char 5 = group-read, char 8 = other-read. Either 'r' → token is exposed.
    # shellcheck disable=SC2012  # labels are our own [.~-safe] filenames, not arbitrary
    mode=$(ls -ld "$f" 2>/dev/null | cut -c1-10)
    gr=$(printf '%s' "$mode" | cut -c5); ot=$(printf '%s' "$mode" | cut -c8)
    if [ "$gr" = "r" ] || [ "$ot" = "r" ]; then
      warn account "${f##*/} is group/other-readable — \`chmod 600 $f\`"; bad=$((bad+1))
    fi
  done
  # optional per-account settings: <label>.conf with LIMIT_TTL=<N>[smhd]
  for cf in "$acct_dir"/*.conf; do
    [ -f "$cf" ] || continue
    base=${cf##*/}; base=${base%.conf}
    [ -f "$acct_dir/$base" ] || warn account "${cf##*/}: no matching token file '$base'"
    ttl=$(sed -n 's/^[[:space:]]*LIMIT_TTL[[:space:]]*=[[:space:]]*//p' "$cf" | head -1 | tr -d '[:space:]')
    case "$ttl" in
      '') warn account "${cf##*/}: no LIMIT_TTL= line — per-account bench window ignored";;
      *[0-9]s|*[0-9]m|*[0-9]h|*[0-9]d) : ;;
      *[!0-9]*) warn account "${cf##*/}: LIMIT_TTL='$ttl' is not <N>[smhd] or bare seconds"; bad=$((bad+1));;
      *) : ;;
    esac
  done
  [ "$bad" -eq 0 ] && pass account "$n subscription token(s) in ${acct_dir} — auto-failover armed (per-account windows honored)"
  # A BLIND pick (issue #2412): no login reads as usable and the quota cache has no
  # row, so every new session lands on account.active — at 99% as readily as at 1%,
  # with every dial above green. (A separated login is never blind: its credential
  # proxy picks the account per request.)
  blind=$(bash "$(dirname "$0")/fleet-account.sh" blind 2>/dev/null)
  [ -n "$blind" ] && warn account-pick "the account pick is BLIND — no login reads as usable ($blind) and the quota cache has no row, so every new session lands on account.active whatever it has left. \`fleet-account.sh list\`, then \`quota --refresh\`"
  # ccquota-driven PRE-EMPTIVE rotation (issue #513): with a hub URL + ccquota on
  # PATH the collector rotates at FLEET_ACCOUNT_CEILING before any banner. Report
  # what the collector would see: rows per pool label (unmapped labels = ccquota
  # names that don't match the fleet's — fix with `ccquota name <uuid> <label>` or
  # CCQUOTA_ACCOUNT=<uuid> in <label>.conf), or why it is running banner-only.
  if [ -n "${CCQUOTA_HUB_URL:-}" ]; then
    # Watch LIVENESS first (issue #551), BEFORE the --refresh below restamps the
    # cache: account.quota.ts is restamped by every fleet-quotawatch tick (even an
    # unreachable hub restamps), so its age says whether the watch is ticking at
    # all. Stale = the 70%/85% pre-emptive rotation is BLIND — that silent
    # fail-open cost a whole 5-hour window on 2026-09-11, so it is a FAIL.
    qst=$(bash "$(dirname "$0")/fleet-quotawatch.sh" --status 2>/dev/null)
    # state <TAB> how long it has held (s) <TAB> consecutive-empty-fetch streak.
    # carry/blind add why the reads come back empty, carry how long that has held.
    qstate=${qst%%	*}; qrest=${qst#*	}; qage=${qrest%%	*}; qrest=${qrest#*	}
    qstreak=${qrest%%	*}; qwhy=''; qwhyfor=0
    case "$qrest" in *'	'*) qrest=${qrest#*	}; qwhy=${qrest%%	*}; case "$qrest" in *'	'*) qwhyfor=${qrest#*	} ;; esac ;; esac
    case "$qage"    in ''|*[!0-9]*) qage=0 ;; esac
    case "$qstreak" in ''|*[!0-9]*) qstreak=0 ;; esac
    case "$qwhyfor" in ''|*[!0-9]*) qwhyfor=0 ;; esac
    qdur="$((qage/60))m"; [ "$qage" -lt 60 ] && qdur="${qage}s"
    # The three ways the hub gives nothing (issue #2465), in the words the alarm uses.
    qdetail=$(sed -n '1s/^[^	]*	[^	]*	//p' "${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash/global/account.quota.why" 2>/dev/null)
    case "$qwhy" in
      refused)     qwhyw="拒（401：入口拒绝额度读数${qdetail:+ — $qdetail}）" ;;
      unreachable) qwhyw="失联（入口联系不上${qdetail:+ — $qdetail}）" ;;
      empty)       qwhyw="盲（入口答空）" ;;
      *)           qwhyw="盲（入口答空）" ;;
    esac
    qrefuse_alarm="${FLEET_QUOTA_REFUSED_ALARM:-300}"; case "$qrefuse_alarm" in ''|*[!0-9]*) qrefuse_alarm=300 ;; esac
    case "$qstate" in
      carry)
        qcarry="沿用 $((qage/60)) 分钟前的读数 — the pick keeps ranking on it until it is FLEET_QUOTA_STALE_OK $(( ${FLEET_QUOTA_STALE_OK:-1800} / 60 ))m old, then clears it; a limit banner still benches"
        if [ "$qwhy" = refused ] && [ "$qwhyfor" -ge "$qrefuse_alarm" ]; then
          fail qwatch "$qwhyw for $((qwhyfor/60))m ($qstreak reads) — $qcarry. Fix the credential (\`fleet doctor\` cert / node rows, \`fleet login\`), then \`fleet-account.sh quota --refresh\`"
        else
          warn qwatch "$qwhyw, $qstreak read(s) — $qcarry (\`fleet-account.sh quota --refresh\`)"
        fi ;;
      stale) fail qwatch "quota cache last refreshed $((qage/60))m ago (> FLEET_ACCOUNT_QUOTA_STALE ${FLEET_ACCOUNT_QUOTA_STALE:-600}s) — pre-emptive rotation is BLIND; is com.claude-fleet.quotawatch loaded? (\`launchctl list | grep quotawatch\`; the collector falls back to running the watch first thing each tick once this unit stops ticking, issue #671 — check its heartbeat below)" ;;
      never) warn qwatch "quota cache never written — no fleet-quotawatch tick has run yet (install/kick com.claude-fleet.quotawatch, or run bin/fleet-quotawatch.sh once)" ;;
      blind) [ "$qwhy" = refused ] && qwhyw="$qwhyw — $(bash -c '. "$1/fleet-lib.sh" && fleet_hub_auth_fix' _ "$(dirname "$0")" 2>/dev/null)"
             fail qwatch "$qwhyw — quota cache is FRESH BUT EMPTY — the last $qstreak ccquota reads returned no rows ($qdur, ≥ FLEET_ACCOUNT_QUOTA_BLIND_STREAK ${FLEET_ACCOUNT_QUOTA_BLIND_STREAK:-3}). The watch IS ticking, so nothing here is stale; the 70%/85% pre-emptive rotation simply has nothing to act on, which is the same outage with every dial green (issue #684). Check the hub: \`ccquota budget --account all --json\`, then \`fleet-account.sh quota --refresh\`; the quota line below names any account ccquota cannot read" ;;
      fresh) pass qwatch "quota cache ${qage}s old and non-empty — the pre-emptive watch is ticking AND getting readings (\`fleet-quotawatch.sh --status\`)" ;;
    esac
    # …and whether the ticks that ARE happening finish their work (issue #698).
    # `--status` above answers "is it ticking", which a tick that winds down on
    # budget passes: it restamps the cache and exits 0. What it drops on the way —
    # a fleet not swept, an account not warned — lives in the heartbeat's over= and
    # skipped=, and would otherwise only ever be visible in the launchd log. Same
    # argument as the collector's line below, which #653 added for the same reason.
    qhb="${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash/global/quotawatch.heartbeat"
    if [ -f "$qhb" ]; then
      qhb_get() { sed -n "s/^$1=//p" "$qhb" | head -1; }
      qhb_dur=$(qhb_get dur); qhb_budget=$(qhb_get budget)
      qhb_over=$(qhb_get over); qhb_skipped=$(qhb_get skipped)
      if [ -n "$qhb_skipped" ] || [ -n "$qhb_over" ]; then
        qhb_detail=''
        [ -n "$qhb_over" ]    && qhb_detail="; over budget: $qhb_over"
        [ -n "$qhb_skipped" ] && qhb_detail="$qhb_detail; deferred to the next tick: $qhb_skipped"
        warn qwatch "last quotawatch tick took ${qhb_dur:-?}s against its ${qhb_budget:-?}s budget (FLEET_QUOTAWATCH_TICK_BUDGET)$qhb_detail — it wound down instead of overrunning, which is by design, but a tick that keeps deferring is one whose work no longer fits in 60s"
      fi
    fi
    # --- the per-fleet model-cap probe (issue #706) --------------------------
    # A cap probe that times out is not a slow tick, it is a BLIND fleet: the probe
    # is the only input to model-cap detection, which is the only trigger for
    # fleet-model-switch.sh --capped. And a walled worker fails in the ugliest way
    # there is — a capped turn never fires the Stop hook, so @claude_state stays
    # `working` forever and the sweep keeps deferring its own candidate as
    # "mid-turn". On 2026-09-15 one fleet had timed out on 788 of 1136 ticks, 18 of
    # the last 18, and nothing outside logs/quotawatch.launchd.log ever said so.
    # A single timeout is noise; the STREAK the watch keeps is the verdict.
    #
    # And the record must be CURRENT, not merely bad. A health file outlives the
    # fleet it describes — `fleet-down` removes the session, not this file — so
    # without an age gate a torn-down fleet would leave a doctor line that FAILs
    # forever about something that no longer exists, and the same goes for any
    # window in which the daemon itself is not ticking (which the staleness check
    # above already reports, once, in the right words). That is the #639/#658
    # lesson: a check that can cry wolf is worse than no check, because the next
    # real one gets scrolled past. FLEET_ACCOUNT_QUOTA_STALE is the horizon the
    # rest of this section already uses for "no tick has run".
    for qmf in "${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash/global/quotawatch.modelcap."*; do
      case "$qmf" in *'quotawatch.modelcap.*') continue ;; esac   # an unmatched glob
      [ -f "$qmf" ] || continue
      qmfleet=${qmf##*/quotawatch.modelcap.}
      qmstreak=$(sed -n 's/^streak=//p' "$qmf" | head -1)
      qmstep=$(sed -n 's/^step=//p' "$qmf" | head -1)
      qmlastok=$(sed -n 's/^lastok=//p' "$qmf" | head -1)
      qmat=$(sed -n 's/^at=//p' "$qmf" | head -1)
      case "$qmstreak" in ''|*[!0-9]*) qmstreak=0 ;; esac
      case "$qmlastok" in ''|*[!0-9]*) qmlastok=0 ;; esac
      case "$qmat" in ''|*[!0-9]*) qmat=0 ;; esac
      [ "$qmstreak" -ge "${FLEET_QUOTAWATCH_MODELCAP_STREAK:-3}" ] || continue
      [ $(( $(date +%s) - qmat )) -lt "${FLEET_ACCOUNT_QUOTA_STALE:-600}" ] || continue
      if [ "$qmlastok" -gt 0 ]; then qmago="last completed $(( ( $(date +%s) - qmlastok ) / 60 ))m ago"
      else qmago="it has never completed"; fi
      fail qwatch "$qmfleet: the model-cap probe has timed out $qmstreak ticks running (in step '${qmstep:-?}'; $qmago) — model-cap detection on that fleet is BLIND, so a worker walled on its model will sit at @claude_state=working forever and \`fleet-model-switch.sh --capped\` will never fire for it. The step name says where the budget went; raise FLEET_QUOTAWATCH_PROBE_BUDGET (${FLEET_QUOTAWATCH_PROBE_BUDGET:-20}s) only after reading it, and check \`bash bin/fleet-model-switch.sh --capped --dry-run --session $qmfleet\`"
    done
    if command -v "${FLEET_QUOTA_BIN:-ccquota}" >/dev/null 2>&1; then
      # NAME the binary on the other side of this contract (issue #668). ccquota
      # ships no tagged release (docs/INSTALL.md) — everyone installs it with
      # `go install …@latest`, so the builds DO drift between machines, and the
      # shape FAIL below is precisely the moment a human needs to know which one
      # answered: its advice can only say *"that build is probably newer than this
      # fleet"*, and until now there was no build named anywhere on the line.
      # `ccquota version` is a local print (cmd/ccquota/main.go); a build old
      # enough to predate the subcommand exits non-zero with usage on stderr, and
      # one that printed usage on STDOUT would hand us a sentence — so take one
      # whitespace-free token or nothing. Omitting the version is the graceful
      # path: it must never turn a quota verdict into an error of its own.
      # $qtag is the message subject everywhere below, so ALL FOUR verdicts
      # (PASS / both WARNs / FAIL) carry it, and degrade to today's bare
      # "ccquota" when the version can't be had.
      qver=$("${FLEET_QUOTA_BIN:-ccquota}" version 2>/dev/null | head -1 | tr -d '\r')
      qver=${qver#ccquota }                      # `ccquota <ver>` → <ver>
      case "$qver" in ''|*[[:space:]]*) qver='' ;; esac
      qtag="ccquota"; [ -n "$qver" ] && qtag="ccquota $qver"
      # Two calls on purpose (issue #628): the first FETCHES and is read for its
      # STDERR — quota_parse's only channel for "ccquota cannot read account X"
      # and "I do not understand this payload". Those accounts produce NO row, so
      # the rows alone cannot tell them apart from a label ccquota never knew, and
      # the advice differs. The second is cache-only (no second network hit).
      qdiag=$(bash "$(dirname "$0")/fleet-account.sh" quota --refresh 2>&1 >/dev/null)
      qrows=$(bash "$(dirname "$0")/fleet-account.sh" quota --cached 2>/dev/null); qn=$(printf '%s' "$qrows" | grep -c .)
      qshape=$(printf '%s\n' "$qdiag" | sed -n 's/^fleet-account: ccquota payload shape not recognized for \([^:]*\):.*/\1/p' | tr '\n' ' ')
      qnoread=$(printf '%s\n' "$qdiag" | sed -n 's/^fleet-account: ccquota has no reading for \([^ ]*\) .*/\1/p' | tr '\n' ' ')
      if [ -n "$qshape" ]; then
        # The contract itself broke: ccquota answered, the account is not flagged
        # unreadable, and yet neither window is there. Silence used to turn that
        # into `0% used` — a confident wrong number that never benches and
        # attracts every migrate. RED, not a warn: nobody is rotating on this.
        fail quota "$qtag payload shape not recognized for: ${qshape% } — neither five_hour nor seven_day in an account that is not flagged unavailable; those accounts get NO row (never benched, never a migrate target). That build is probably newer than this fleet — compare \`ccquota budget --account all --json\` with quota_parse in bin/fleet-account.sh"
      elif [ "$qn" -gt 0 ] && [ -s "${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash/global/account.quota.why" ]; then
        # The hub gave nothing this time; these rows are the last good reading,
        # carried (issue #2465) — the qwatch line above says why and how old.
        warn quota "$qtag → hub $CCQUOTA_HUB_URL gave no reading — $qn/$n pool accounts ranked on the carried one ($(printf '%s' "$qrows" | awk -F'\t' '{printf "%s%s %s%%/%s%%", (NR>1?", ":""), $1, $2, $3}')); see qwatch"
      elif [ "$qn" -gt 0 ] && [ "$qn" -eq "$n" ]; then
        pass quota "$qtag → hub $CCQUOTA_HUB_URL: $qn/$n pool accounts mapped — pre-emptive rotation at ${FLEET_ACCOUNT_CEILING:-85}% (warn ${FLEET_ACCOUNT_WARN_PCT:-70}%)"
      elif [ -n "$qnoread" ]; then
        # ccquota is explicit about this one (available:false) — expected while a
        # token is fresh or the hub has not seen the account yet. Fail-open, but
        # NAMED: it is invisible to the rotation for as long as it lasts.
        warn quota "$qtag has NO reading for: ${qnoread% } ($qn/$n pool labels have one) — those get no row: never benched at ${FLEET_ACCOUNT_CEILING:-85}%, and never picked as a migrate landing spot. Check \`ccquota budget --account all --json\` (\`available:false\` + its reason)"
      elif [ "$qn" -gt 0 ]; then
        warn quota "$qtag maps only $qn/$n pool labels — unmapped ones rotate banner-only (\`ccquota name\` must equal the fleet label, or set CCQUOTA_ACCOUNT= in <label>.conf)"
      else
        warn quota "$qtag → hub $CCQUOTA_HUB_URL unreachable or unknown — rotation is banner-driven only (fail-open)"
      fi
      # Per-MODEL headroom (issue #1073) — the Fable cap is its own weekly window
      # (7d_oi), invisible in 5h/7d. PASS/INFO only, never counted: without it
      # the fleet is exactly as it was before (banner-driven model caps).
      if [ "$qn" -gt 0 ]; then
        qmodels=$(bash "$(dirname "$0")/fleet-account.sh" model-quota 2>/dev/null)
        if [ -n "$qmodels" ]; then
          pass modelcap "$qtag per-model windows: $(printf '%s\n' "$qmodels" | awk -F'\t' '
            { u=($6=="-") ? "?" : $6"%"; s=$1" "$2" "u; if ($3=="capped") s=s" CAPPED"; o=o (o?" · ":"") s }
            END { print o }') — spawns prefer an account with headroom; capped ones launch on the fallback"
        else
          info modelcap "$qtag reports no per-model windows (\`models\` in \`budget --json\`, verkyyi/tokenledger#155) — a model cap (Fable) is still found only by its banner, after a session hits it"
        fi
      fi
    else
      warn quota "CCQUOTA_HUB_URL set but ccquota not on PATH — pre-emptive rotation off; install it with \`go install github.com/verkyyi/claude-fleet/tokenledger/cmd/ccquota@latest\` (needs Go 1.25+; the product is TokenLedger, tokenledger/ in the claude-fleet repo, the binary is still \`ccquota\`)"  # dist-ok: advice printed to a person, never fetched here
    fi
  else
    printf '        note: set CCQUOTA_HUB_URL (fleet.conf) for pre-emptive rotation via ccquota — today it rotates only after a limit banner.\n'
  fi
  if [ "$(uname)" = "Darwin" ]; then
    printf '        note: on macOS token files are the ONLY way to switch accounts (Keychain ignores CLAUDE_CONFIG_DIR).\n'
  fi
fi

# Report an optional daemon whose fleets have it enabled in conf. Turns what used
# to be an unconditional PASS (conf flag only) into a verdict that can actually
# fail — see bin/fleet-daemon-loaded.sh for why (issue #492).
daemon_verdict() {   # $1=tag $2=label $3=pass-msg $4=what-is-lost-when-missing
  tag="$1"; label="$2"; msg="$3"; lost="$4"
  sh "$(dirname "$0")/fleet-daemon-loaded.sh" "$label"
  case $? in
    0) pass "$tag" "$msg" ;;
    1) warn "$tag" "$label is NOT installed — $lost (conf says on, but nothing is running)" ;;
    # 3 (issue #1495): a system-shape login (LaunchDaemons with UserName) whose
    # plist is on disk, but neither the unprivileged `launchctl print system/…`
    # nor a passwordless sudo could confirm it is loaded — installed, unverified.
    3) pass "$tag" "$msg (system LaunchDaemon $(fleet_daemon_label "${label#com.claude-fleet.}" system) installed, not verified loaded — no passwordless sudo for this login)" ;;
    *) pass "$tag" "$msg (could not verify $label is loaded on this platform)" ;;
  esac
}

# --- mode (issue #1539): local or hub, per fleet ---------------------------------
# Which of the two modes each fleet on this login runs in — docs/LOCAL-AND-HUB.md
# is the matrix of what that decides. The login-wide value (environment ▸
# fleet.settings ▸ the install's fleet.conf, as the node line reads it) is every
# fleet's default; a fleet conf's own CCQUOTA_FLEET line wins (fleet_hub_on in
# fleet-lib.sh). A hub fleet also names where its new sessions open
# (FLEET_SPAWN_NODE, per fleet too). Advice only: an INFO line, never counted.
_mode_g=${CCQUOTA_FLEET:-}
[ -n "$_mode_g" ] || _mode_g=$(_xconf_val "$conf_dir/fleet.conf" CCQUOTA_FLEET)
[ -n "$_mode_g" ] || _mode_g=$(_xconf_val "$conf_dir/fleet.settings" CCQUOTA_FLEET)
[ -n "$_mode_g" ] || _mode_g=$(_xconf_val "$(dirname "$0")/../fleet.conf" CCQUOTA_FLEET)
_mode_sn_g=${FLEET_SPAWN_NODE:-}
[ -n "$_mode_sn_g" ] || _mode_sn_g=$(_xconf_val "$conf_dir/fleet.conf" FLEET_SPAWN_NODE)
[ -n "$_mode_sn_g" ] || _mode_sn_g=$(_xconf_val "$conf_dir/fleet.settings" FLEET_SPAWN_NODE)
[ -n "$_mode_sn_g" ] || _mode_sn_g=$(_xconf_val "$(dirname "$0")/../fleet.conf" FLEET_SPAWN_NODE)
_mode_out=''
if [ -d "$conf_dir" ]; then
  while IFS= read -r _cf; do
    [ -n "$_cf" ] || continue
    case "$_cf" in */fleets/*/conf) _ms=${_cf%/conf}; _ms=${_ms##*/} ;; *) _ms=$(basename "$_cf" .conf) ;; esac
    if grep -Eq '^[[:space:]]*(export[[:space:]]+)?CCQUOTA_FLEET[[:space:]]*=' "$_cf" 2>/dev/null; then
      _mv=$(_xconf_val "$_cf" CCQUOTA_FLEET)
    else _mv=$_mode_g; fi
    if [ "$_mv" = 1 ]; then
      _msn=$(_xconf_val "$_cf" FLEET_SPAWN_NODE); [ -n "$_msn" ] || _msn=${_mode_sn_g:-auto}
      _mm="hub (新会话 $_msn)"
    else _mm=local; fi
    _mode_out="${_mode_out:+$_mode_out · }$_ms $_mm"
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
fi
[ -n "$_mode_out" ] || { [ "$_mode_g" = 1 ] && _mode_out=hub || _mode_out=local; }
info mode "$_mode_out — 本机 / 联机各管什么: docs/LOCAL-AND-HUB.md"

# --- tools (issue #1774, #1784): can a PATH-less shell find claude and tmux? -----
# What a daemon, an ssh command or a restore sees — not this terminal's PATH. Asked
# the way fleet-claude.sh / fleet-restore.sh ask (fleet_find_tool: $FLEET_CLAUDE_BIN,
# PATH, ~/.local/bin, /opt/homebrew/bin, /usr/local/bin). A miss is a FAIL: every
# restore on this machine would park at a shell.
_tl_out=$(env -i HOME="$HOME" PATH=/usr/bin:/bin ${FLEET_CLAUDE_BIN:+FLEET_CLAUDE_BIN="$FLEET_CLAUDE_BIN"} \
  bash -c '. "$1/fleet-lib.sh" >/dev/null 2>&1; for t in claude tmux; do w=$(fleet_find_tool "$t" 2>/dev/null) || w=-; printf "%s=%s " "$t" "$w"; done' \
  _ "$(dirname "$0")" 2>/dev/null)
case "$_tl_out" in
  *=-\ *) fail tools "a bare shell (PATH=/usr/bin:/bin) cannot find: $(printf '%s' "$_tl_out" | tr ' ' '\n' | sed -n 's/=-$//p' | tr '\n' ' ')— install it, or set FLEET_CLAUDE_BIN" ;;
  *)       pass tools "$(printf '%s' "$_tl_out" | sed "s#$HOME#~#g")— found from a bare shell" ;;
esac

# --- socket (issue #1729): a fleet socket held by a dying tmux server ------------
# A server that is exiting but pinned by a client that never answers drops every
# new connection: each `tmux -L <fleet> …` says `server exited unexpectedly`, and
# fleet-up / restore cannot start the fleet until the socket file goes. FAIL while
# one is wedged; WARN for a week after fleet_socket_heal cleared one (that fleet's
# server died — `fleet-lib.sh` writes socket-heal.log). Neither → nothing printed.
# Inline copies of fleet_socket_path / fleet_socket_wedged — KEEP IN SYNC.
_sk_wedged=''
for _sk_cf in $(_fleet_confs "$conf_dir"); do
  case "$_sk_cf" in */conf) _sk_s=$(basename "$(dirname "$_sk_cf")") ;; *) _sk_s=$(basename "$_sk_cf" .conf) ;; esac
  _sk_td="${TMUX_TMPDIR:-/tmp}"; _sk_p="${_sk_td%/}/tmux-$(id -u)/$_sk_s"
  [ -S "$_sk_p" ] || continue
  case "$(tmux -L "$_sk_s" list-sessions 2>&1 >/dev/null)" in
    *'server exited unexpectedly'*) _sk_wedged="$_sk_wedged $_sk_p" ;;
  esac
done
if [ -n "$_sk_wedged" ]; then
  fail socket "held by a dying tmux server (every client gets \"server exited unexpectedly\"):$_sk_wedged — fleet-up.sh clears it and brings the fleet back (or rm it by hand)"
elif [ -f "$conf_dir/socket-heal.log" ]; then
  _sk_last=$(tail -1 "$conf_dir/socket-heal.log" 2>/dev/null)
  _sk_ts=${_sk_last%%"	"*}
  case "$_sk_ts" in ''|*[!0-9]*) _sk_ts=0 ;; esac
  if [ $(( $(date +%s) - _sk_ts )) -le 604800 ]; then
    warn socket "$(date -r "$_sk_ts" '+%m-%d %H:%M' 2>/dev/null || date -d "@$_sk_ts" '+%m-%d %H:%M' 2>/dev/null) cleared a stale socket for fleet $(printf '%s' "$_sk_last" | cut -f2) — its tmux server died then; if it happens again, compare with install-sync's apply time ($conf_dir/socket-heal.log)"  # portable-ok: BSD date -r || GNU date -d fallback on one line
  fi
fi

# --- tmuxconf (issue #1845): is the fleet layer live on every fleet server? -----
# A fleet server starts from conf/tmux-fleet-server.conf (fleet-up.sh), which
# loads the fleet layer before the person's ~/.tmux.conf and ends it with
# @fleet_conf_loaded. fleet_tmuxconf_check reads that marker, the reap hook and
# the rename guard off each live server: FAIL when the layer is not on one (a
# server started before this, from a ~/.tmux.conf that broke — fleet-ui-refresh
# or a restart loads it), WARN when one carries an older marker. No live fleet
# server → nothing printed.
if [ -f "$(dirname "$0")/fleet-lib.sh" ] && command -v bash >/dev/null 2>&1; then
  _tc_out=$(FLEET_CONF_DIR="$conf_dir" bash -c '. "$1" >/dev/null 2>&1
    for s in $(fleet_sockets); do printf "%s %s\n" "$s" "$(fleet_tmuxconf_check "$s")"; done' _ "$(dirname "$0")/fleet-lib.sh" 2>/dev/null)
  if [ -n "$_tc_out" ]; then
    _tc_bad=$(printf '%s\n' "$_tc_out" | awk '$2 == "missing"' | sed 's/ missing / 缺 /' | tr '\n' ';')
    _tc_old=$(printf '%s\n' "$_tc_out" | awk '$2 == "stale"' | tr '\n' ';')
    _tc_n=$(printf '%s\n' "$_tc_out" | grep -c .)
    if [ -n "$_tc_bad" ]; then
      fail tmuxconf "fleet 层没在服务器上生效：${_tc_bad%;} — 载入：bash $(cd "$(dirname "$0")" && pwd)/fleet-ui-refresh.sh --all --conf /dev/null $(cd "$(dirname "$0")/.." && pwd)/conf/tmux-attention.conf"
    elif [ -n "$_tc_old" ]; then
      warn tmuxconf "服务器载入的是旧版 fleet 配置：${_tc_old%;} — 同步后 fleet-ui-refresh 会重载"
    else
      pass tmuxconf "$_tc_n 个 fleet 服务器都载入了 fleet 层（$(printf '%s\n' "$_tc_out" | awk '{print $3; exit}')，回收 hook、改名保护在）"
    fi
  fi
fi

# --- hub-image (issue #1696): which commit the hub serves, vs the stable tag -----
# The hub image is deployed by hand, and its commit used to live only in the
# image tag (cluster access to read). bin/fleet-hub-image.sh reads the hub's
# public GET /version and compares it with refs/tags/stable: behind = WARN with
# the count (the hub hands out an older client than installs follow), anything
# else INFO with the sha. No hub URL configured prints nothing: the degenerate case.
_hi="$(dirname "$0")/fleet-hub-image.sh"
if [ -f "$_hi" ]; then
  _hi_dir="${FLEET_LIVE_DIR:-$HOME/.claude/fleet}"
  git -C "$_hi_dir" rev-parse --git-dir >/dev/null 2>&1 || _hi_dir="$(cd "$(dirname "$0")/.." && pwd)"
  _hi_out=$(sh "$_hi" --dir "$_hi_dir" 2>/dev/null)
  _hif() { printf '%s\n' "$_hi_out" | sed -n "s/^$1:  *//p"; }
  _hi_c=$(_hif commit); _hi_s=$(_hif stable); _hi_img=$(_hif image)
  case "$(_hif verdict)" in
    CURRENT)  info hub-image "入口镜像 $_hi_img (commit $_hi_c) — 与 stable 同一 commit" ;;
    BEHIND)   warn hub-image "入口镜像 commit $_hi_c 落后 stable ($_hi_s) $(_hif behind) 个 commit — 入口发的客户端比各机 install 旧；按 stable 重新发布入口镜像" ;;
    AHEAD)    info hub-image "入口镜像 commit $_hi_c 比 stable ($_hi_s) 新 $(_hif ahead) 个 commit" ;;
    DIVERGED) warn hub-image "入口镜像 commit $_hi_c 与 stable ($_hi_s) 分叉 — 镜像独有 $(_hif ahead) 个、stable 独有 $(_hif behind) 个 commit" ;;
    NOHUB|'') ;;
    *)        info hub-image "入口镜像的 commit 未知（不是「最新」）: $(_hif note)" ;;
  esac
fi

# --- sshtrust (issue #1626): no standing key from another fleet machine ----------
# Cross-machine ssh rides a five-minute certificate the hub signs per connection
# (fleet-peer-cert.sh); a key another fleet machine left in ~/.ssh/authorized_keys
# (`verkyyi@macmini`) admits it forever and the hub never hears of it. WARN with
# each entry (line, type, comment — never the key); PASS when there is none. A
# login that knows no other fleet machine prints nothing: the degenerate case.
_tr=$(bash "$(dirname "$0")/fleet-peer-trust.sh" 2>/dev/null); _tr_rc=$?
case "$_tr_rc" in
  0) warn sshtrust "$(printf '%s\n' "$_tr" | awk 'NF' | wc -l | tr -d ' ') 把其它 fleet 机器的钥匙留在 ~/.ssh/authorized_keys（永久互信）: $(printf '%s\n' "$_tr" | awk -F '\t' 'NF { printf "%s%s (第 %s 行)", s, $3, $1; s = ", " }') — 跨机已改走入口签发的 5 分钟证书（#1626），确认跨机照常后删掉这些行"
     ;;
  1) pass sshtrust "authorized_keys 里没有其它 fleet 机器的钥匙 — 跨机只认入口签发的 5 分钟证书" ;;
esac

# --- dist (issue #2776, EPIC #2770 C6): this login's new versions come from the
# hub only — bin/fleet-dist-source.sh judges (origin GitHub, FLEET_DIST_SOURCE=github,
# a client that follows GitHub ⇒ WARN with the fix; no hub ⇒ INFO; none ⇒ no row).
_d_out=$(FLEET_HUB_URL="$_hub_url" FLEET_CONF_DIR="$conf_dir" FLEET_INSTALL_HOME="$_cu_root" \
  sh "$(dirname "$0")/fleet-dist-source.sh" 2>/dev/null)
case "$_d_out" in
  PASS*) pass dist "${_d_out#*	}" ;;
  WARN*) warn dist "${_d_out#*	}" ;;
  INFO*) info dist "${_d_out#*	}" ;;
esac

# --- cert (issue #2457): this computer's connection certificate, as the hub sees it
# Its principals, how long it is valid, and one signed route-list read to ask the
# hub whether it accepts it — a principal the hub does not expect (#2437) is
# FAIL in the person's words. No certificate here prints nothing.
_cc=$(python3 "$(dirname "$0")/fleet-connect.py" --cert-check 2>/dev/null) && [ -n "$_cc" ] && case "$_cc" in
  PASS*) pass cert "${_cc#*	}" ;;
  WARN*) warn cert "${_cc#*	}" ;;
  *)     fail cert "${_cc#*	}" ;;
esac

# --- agent (issue #1525): every login's node agent on this machine vs stable ---
# Same reading as `fleet-node-upgrade.sh --status`: the bytes on disk AND the
# version the hub sees running (an agent upgraded on disk but never restarted is
# behind). A machine with no ccquota agent service prints no line at all — nor
# does a computer that hosts no sessions (承载 off, issue #2716): a client has no
# node agent of the fleet's to follow, and asking would only build one.
_nu="$(dirname "$0")/fleet-node-upgrade.sh"
if [ -f "$_nu" ] && [ "$_ho_on" = 1 ]; then
  _nuo=$(bash "$_nu" "${FLEET_DOCTOR_AGENT_TARGET:-stable}" --status 2>&1)
  _nus=$(printf '%s\n' "$_nuo" | sed -n 's/^summary: //p' | head -n 1)
  case "$_nus" in
    0/*)  _nun=${_nus#*/}; pass agent "${_nun%% *} login(s) on this machine run ${_nus##* } (disk + hub)" ;;
    ?*)   _nub=$(printf '%s\n' "$_nuo" | awk '$NF == "behind" {printf "%s%s", s, $1; s=", "}')
          warn agent "${_nus%% *} login(s) behind stable ${_nus##* }: $_nub — \`bash $_nu\` builds it, installs it and restarts them one by one (\`--dry-run\` first)" ;;
    *)    case "$_nuo" in
            *"no ccquota agent service"*|*"macOS (launchd) only"*) ;;
            *) info agent "could not compare the node agents with stable: $(printf '%s' "$_nuo" | tail -n 1)" ;;
          esac ;;
  esac
fi

# --- agentdup: one ccquota agent per login (issue #2663) --------------------------
# Two agents on one --state share the one node token: the hub's link goes to
# whichever said hello last, each hello with its own settings — placement flaps.
# The launcher (fleet-credsep-launch.py) stops the extras at every start; this
# names one it never saw. One agent (or none) ⇒ no row.
_ad_l="$(dirname "$0")/fleet-credsep-launch.py"
if [ -f "$_ad_l" ]; then
  _ad=$(python3 -I "$_ad_l" agents "$(id -un)" 2>/dev/null | awk '
    { n[$2]++; p[$2] = p[$2] (p[$2] == "" ? "" : ",") $1 }
    END { for (s in n) if (n[s] > 1) printf "%s%d on --state %s (pids %s)", (o++ ? "; " : ""), n[s], s, p[s] }')
  if [ -n "$_ad" ]; then
    if [ "$(uname)" = Darwin ]; then _ad_fix="sudo launchctl kickstart -k system/com.ccquota.agent.$(id -un)"
    else _ad_fix="sudo systemctl restart ccquota-agent-$(id -un).service"; fi
    if [ -f "$conf_dir/credsep.json" ]; then
      warn agentdup "ccquota agents of this login: $_ad — they replace each other's hub link; \`$_ad_fix\` restarts it through the launcher, which stops the extras"
    else
      warn agentdup "ccquota agents of this login: $_ad — they replace each other's hub link; stop all but the one your service runs"
    fi
  fi
fi

# --- autofill dispatcher (optional: auto-spawn `autofill`-labelled backlog, #70/#421) ---
# OFF unless a fleet's conf sets FLEET_AUTOFILL=1. When ON, the dispatch daemon
# auto-spawns eligible `autofill`-labelled backlog issues — which spends LLM tokens —
# so surface the armed fleets and the cost. A missing daemon/config is not a fault
# (opt-in), so this only speaks up when at least one fleet has enabled it.
if [ -d "$conf_dir" ]; then
  armed=0
  # here-doc (not a pipe) so the `while` runs in THIS shell and `armed` survives.
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    # FLEET_AUTOFILL=1, tolerating quotes/spaces (FLEET_AUTOFILL = "1").
    val=$(sed -n 's/^[[:space:]]*FLEET_AUTOFILL[[:space:]]*=[[:space:]]*//p' "$cf" | head -1 | tr -d "\"' 	")
    [ "$val" = 1 ] && armed=$((armed+1))
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
  # A multi-repo fleet may arm a single repo in its overlay (issue #799).
  for cf in "$conf_dir"/fleets/*/repos/*.conf; do
    [ -f "$cf" ] || continue
    val=$(sed -n 's/^[[:space:]]*FLEET_AUTOFILL[[:space:]]*=[[:space:]]*//p' "$cf" | head -1 | tr -d "\"' 	")
    [ "$val" = 1 ] && armed=$((armed+1))
  done
  if [ "$armed" -gt 0 ]; then
    if command -v gh >/dev/null 2>&1; then
      pass autofill "$armed fleet(s)/repo overlay(s) with FLEET_AUTOFILL=1 — dispatcher auto-spawns \`autofill\`-labelled issues (spends LLM tokens)"
    else
      warn autofill "$armed fleet(s)/repo overlay(s) set FLEET_AUTOFILL=1 but gh is missing — the dispatcher can't read the backlog"
    fi
    printf '        note: needs the com.claude-fleet.dispatch daemon installed + the `autofill` label on issues; each auto-spawn opens a real Claude session + PR.\n'
  fi
  # The seed repo (issue #1167): `fleet-up.sh --seed` brought the fleet up on a
  # starter repo that only LOOKS — dispatch + issue-bridge skip it whatever its
  # switches say. Said once per seeded repo; a fleet without FLEET_SEED says nothing.
  # compat-1v: 下一批删 (the old layout, below)
  # The mark lives in the seed's overlay (issue #1937), or — the old layout, read
  # for one version — in the fleet conf beside its own repo.
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    for sd_f in "$cf" "${cf%/conf}/repos"/*.conf; do
      [ -f "$sd_f" ] || continue
      [ "$(_conf_val "$sd_f" FLEET_SEED)" = 1 ] || continue
      info seed "$(_conf_val "$sd_f" FLEET_REPO) — 起步仓库，只读: no autofill, no issue-bridge (FLEET_SEED=1)"
    done
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
fi

# --- webhook daemon (optional: fresh ~1s PR/issue/CI status via gh webhook forward) ---
# OFF unless a hosted repo opts in with FLEET_WEBHOOK=1 (issue #315; per repo since
# #800). When ON it needs the cli/gh-webhook extension (registers the repo webhook
# against GitHub's hosted relay — no public endpoint) + gh + python3 (the localhost
# handler). Flag an armed setup missing any of them; the extension is the one
# that's easy to forget.
# The count is the daemon's OWN resolution (issue #1004): every hosted repo of every
# configured fleet whose FLEET_WEBHOOK resolves to 1 through fleet_repo_conf_get —
# its repos/<slug>.conf overlay, else the fleet conf, else the login-wide settings /
# the install's fleet.conf — deduped, exactly as `fleet-webhook.sh --desired` does.
# A grep of each fleet conf for a literal FLEET_WEBHOOK=1 missed both a global
# opt-in (the live install sets it there: no webhook line at all while the daemon
# forwarded) and an overlay-only one. KEEP IN SYNC with wh_opted_in_repos in
# bin/fleet-webhook.sh. Configured fleets, not live sockets: doctor runs anywhere.
if [ -d "$conf_dir" ] && [ -f "$(dirname "$0")/fleet-lib.sh" ] && command -v bash >/dev/null 2>&1; then
  wh_sessions=$(_fleet_confs "$conf_dir" | sed -e 's#/conf$##' -e 's#\.conf$##' -e 's#.*/##')
  wh_repos=''
  [ -n "$wh_sessions" ] && wh_repos=$(FLEET_CONF_DIR="$conf_dir" bash -c '
    . "$1" >/dev/null 2>&1 || exit 0; shift
    for s in "$@"; do
      fleet_repos "$s" | while IFS= read -r r; do
        [ -n "$r" ] || continue
        [ "$(fleet_repo_conf_get "$s" "$r" FLEET_WEBHOOK)" = 1 ] && printf "%s\n" "$r"
      done
    done' _ "$(dirname "$0")/fleet-lib.sh" $wh_sessions 2>/dev/null | awk 'NF && !seen[$0]++')
  whn=$(printf '%s\n' "$wh_repos" | grep -c .)
  if [ "$whn" -gt 0 ]; then
    whlist=$(printf '%s\n' "$wh_repos" | paste -sd, - | sed 's/,/, /g')
    if ! command -v gh >/dev/null 2>&1; then
      warn webhook "$whn repo(s) opt in (FLEET_WEBHOOK=1: $whlist) but gh is missing — nothing to forward"
    elif ! gh extension list 2>/dev/null | grep -q 'gh-webhook'; then
      warn webhook "$whn repo(s) opt in (FLEET_WEBHOOK=1: $whlist) but the cli/gh-webhook extension is missing — \`gh extension install cli/gh-webhook\`"
    elif ! command -v python3 >/dev/null 2>&1; then
      warn webhook "$whn repo(s) opt in (FLEET_WEBHOOK=1: $whlist) but python3 is missing — the localhost handler can't run"
    else
      pass webhook "$whn repo(s) forwarded ($whlist) — fresh ~1s PR/issue/CI status (no public endpoint)"
    fi
    printf '        note: needs com.claude-fleet.webhook installed (KeepAlive) + `gh extension install cli/gh-webhook`; polling (collector + pr-refresh) stays the backstop.\n'
  fi
fi

# --- session lifecycle emitter (optional: joins spend to outcome downstream) ---
# OFF unless a fleet's conf sets FLEET_EMIT_URL (issue #625). It is fire-and-forget
# over a bounded spool, which is exactly why it wants a doctor line: a dead endpoint
# is SILENT by design, so the only visible symptom is a spool that stops draining.
# A non-empty queue after the detached drain has had its chance means the endpoint
# is refusing or unreachable — nothing is broken in the fleet, but nothing is
# arriving downstream either, and that would otherwise go unnoticed for weeks.
if [ -d "$conf_dir" ]; then
  earmed=0
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    val=$(sed -n 's/^[[:space:]]*FLEET_EMIT_URL[[:space:]]*=[[:space:]]*//p' "$cf" | head -1 | tr -d "\"' 	")
    [ -n "$val" ] && earmed=$((earmed+1))
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
  if [ "$earmed" -gt 0 ]; then
    qd=$(bash "$(dirname "$0")/fleet-emit.sh" --queue-depth 2>/dev/null | tr -cd '0-9')
    [ -n "$qd" ] || qd=0
    if ! command -v curl >/dev/null 2>&1; then
      warn emit "$earmed fleet(s) set FLEET_EMIT_URL but curl is missing — nothing can be delivered"
    elif [ "$qd" -ge 50 ]; then
      warn emit "$earmed fleet(s) emitting, but $qd events are stuck in the spool — the endpoint is refusing or unreachable"
    elif [ "$qd" -gt 0 ]; then
      pass emit "$earmed fleet(s) emitting session lifecycle facts ($qd in flight)"
    else
      pass emit "$earmed fleet(s) emitting session lifecycle facts (spool drained)"
    fi
    printf '        note: session.start/bind/pr/end only — no prompt content, paths, titles or hostname leave the machine. See docs/EMIT.md.\n'
  fi
fi

# --- cleanup daemon (reaps worktrees + records the resume ledger after merges) ---
# ON by default per fleet (opt out with FLEET_CLEANUP=0). THIS DAEMON NEVER MERGES:
# the worker's /fleet-claim ship+land step merges its own PR (#441); this daemon reaps
# the leftover worktree/window/branch once a PR is final. It merges nothing, so there's no approval-gate warning
# — but it needs gh to read PR state, and it needs com.claude-fleet.cleanup installed.
if [ -d "$conf_dir" ]; then
  cleaning=0 optout=0
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    val=$(sed -n 's/^[[:space:]]*FLEET_CLEANUP[[:space:]]*=[[:space:]]*//p' "$cf" | head -1 | tr -d "\"' 	")
    # A repo overlay may switch cleanup back on for its repo (issue #978): the
    # fleet still needs the daemon then.
    case "$cf" in */fleets/*/conf)
      for rf in "${cf%/conf}/repos"/*.conf; do
        [ -f "$rf" ] && _conf_has "$rf" FLEET_CLEANUP && [ "$(_conf_val "$rf" FLEET_CLEANUP)" != 0 ] && val=1
      done ;;
    esac
    if [ "$val" = 0 ]; then optout=$((optout+1)); else cleaning=$((cleaning+1)); fi
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
  if [ "$cleaning" -gt 0 ]; then
    if ! command -v gh >/dev/null 2>&1; then
      warn cleanup "$cleaning fleet(s) rely on the cleanup daemon but gh is missing — it can't read PR state to reap"
    else
      daemon_verdict cleanup com.claude-fleet.cleanup \
        "$cleaning fleet(s) with the cleanup daemon on$([ "$optout" -gt 0 ] && printf ' (%s opted out)' "$optout") — worktrees reaped after merges" \
        "merged worktrees are NOT being reaped and landed sessions are NOT being recorded"
    fi
    printf '        note: needs com.claude-fleet.cleanup installed; this daemon merges nothing — the worker lands its own PR (#441) and this cleans up after it.\n'
  fi
fi

# --- ledger-watch daemon (indexes every closed worker session for resume) ------
# ON by default per fleet (opt out with FLEET_LEDGER_WATCH=0). Records a
# `closed-unlanded` history-ledger row when a worker window vanishes without
# landing, so a hand-closed/crashed/abandoned session stays resumable via
# /fleet-history. Pure tmux snapshot + a local ledger append (no gh/LLM) — so no
# tool-dependency warning; it just needs com.claude-fleet.ledger-watch installed.
if [ -d "$conf_dir" ]; then
  watching=0 lw_optout=0
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    val=$(sed -n 's/^[[:space:]]*FLEET_LEDGER_WATCH[[:space:]]*=[[:space:]]*//p' "$cf" | head -1 | tr -d "\"' 	")
    if [ "$val" = 0 ]; then lw_optout=$((lw_optout+1)); else watching=$((watching+1)); fi
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
  if [ "$watching" -gt 0 ]; then
    daemon_verdict ledger com.claude-fleet.ledger-watch \
      "$watching fleet(s) with the ledger-watch daemon on$([ "$lw_optout" -gt 0 ] && printf ' (%s opted out)' "$lw_optout") — every closed session indexed for resume" \
      "closed-unlanded sessions are NOT being indexed (invisible to /fleet-history, unresumable)"
    printf '        note: needs com.claude-fleet.ledger-watch installed; records closed-unlanded sessions into the history ledger (no merge, no reap).\n'
  fi
fi

# --- base-sync daemon (keeps the local base fast-forwarded to the remote) ------
# ON by default per fleet (opt out with FLEET_BASE_SYNC=0). Runs the same ff-only
# base pull the cleaner does, but on the clock — so a merge with no local reap (a
# web/collaborator merge, a direct push, another machine) still advances the base
# and fresh worktrees don't branch off stale code. Pure git fetch + pull --ff-only
# under the shared land lease (no gh/LLM) — so no tool-dependency warning; it just
# needs com.claude-fleet.base-sync installed.
if [ -d "$conf_dir" ]; then
  syncing=0 bs_optout=0
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    val=$(sed -n 's/^[[:space:]]*FLEET_BASE_SYNC[[:space:]]*=[[:space:]]*//p' "$cf" | head -1 | tr -d "\"' 	")
    if [ "$val" = 0 ]; then bs_optout=$((bs_optout+1)); else syncing=$((syncing+1)); fi
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
  if [ "$syncing" -gt 0 ]; then
    daemon_verdict basesync com.claude-fleet.base-sync \
      "$syncing fleet(s) with the base-sync daemon on$([ "$bs_optout" -gt 0 ] && printf ' (%s opted out)' "$bs_optout") — local base fast-forwarded to the remote (merge-independent)" \
      "the local base is NOT being fast-forwarded (new worktrees fork off a stale base)"
    printf '        note: needs com.claude-fleet.base-sync installed; fetches + pulls --ff-only the base under the shared land lease (no merge, no gh).\n'
  fi
fi

# --- quota-watch daemon (issue #551) ---------------------------------------------
# The ccquota pre-emptive rotation has its OWN 60s unit since #551 — the collector
# still runs the watch first thing each tick, so a missing unit degrades the
# cadence to the collector's (and to nothing if the collector is wedged) rather
# than switching the watch off: WARN, not FAIL. Only meaningful with a pool + hub.
if [ -d "$acct_dir" ] && [ -n "${CCQUOTA_HUB_URL:-}" ]; then
  daemon_verdict qwatch com.claude-fleet.quotawatch \
    "com.claude-fleet.quotawatch loaded — 60s pre-emptive rotation tick, independent of the collector" \
    "the quota watch only runs at the top of each collector tick (and not at all while the collector is wedged)"
  printf '        note: bin/fleet-quotawatch.sh — its own 60s unit; heartbeat in global/quotawatch.heartbeat, staleness on the status bar (✖ quota · stale) + above.\n'
fi

# --- collector heartbeat (issue #551) -------------------------------------------
# global/collect.heartbeat: key=value written at every phase boundary of a tick —
# last complete tick's end/dur/phases, or the phase a dying tick was in. A stale
# heartbeat means the dash caches (git/ctx/usage, and pre-#551 the quota watch)
# are not moving: wedged tick (past FLEET_COLLECT_DEADLINE it is killed + superseded
# by the next one) or an unloaded com.claude-fleet.collect.
hb="${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash/global/collect.heartbeat"
if [ -f "$hb" ]; then
  hb_now=$(date +%s)
  hb_get() { sed -n "s/^$1=//p" "$hb" | head -1; }
  hb_end=$(hb_get end); hb_start=$(hb_get start); hb_phase=$(hb_get phase); hb_dur=$(hb_get dur); hb_phases=$(hb_get phases)
  # over= / skipped= (issue #653): which phases spent their own budget, and which
  # the whole-tick budget truncated away. The heartbeat has always carried the
  # per-phase seconds, so "which phase ate the tick" was free information nobody
  # was printing — the last two times the bottleneck moved (git, then usage) it
  # cost a hand investigation to find that out. Say it here instead.
  hb_over=$(hb_get over); hb_skipped=$(hb_get skipped)
  case "$hb_start" in ''|*[!0-9]*) hb_start=0;; esac
  case "$hb_end"   in ''|*[!0-9]*) hb_end=0;;   esac
  hb_slow=$(printf '%s\n' "$hb_phases" | tr ' ' '\n' | sort -t= -k2 -nr | head -1)
  [ -n "$hb_slow" ] && hb_slow="${hb_slow}s"     # "usage=226" reads better as "usage=226s"
  hb_budget=''
  [ -n "$hb_over" ]    && hb_budget="; over budget: $hb_over"
  [ -n "$hb_skipped" ] && hb_budget="$hb_budget; deferred to the next tick: $hb_skipped"
  if [ "$hb_end" -gt 0 ]; then
    hb_age=$((hb_now - hb_end))
    if [ "$hb_age" -gt "${FLEET_COLLECT_DEADLINE:-600}" ]; then
      warn collect "last complete tick ended $((hb_age/60))m ago (took ${hb_dur:-?}s; slowest phase ${hb_slow:-?}$hb_budget) — dash caches are stale; is com.claude-fleet.collect loaded / a tick wedged in \`$hb_phase\`? (the status bar shows \`✖ dash · stale\`; bin/fleet-daemon-watch.sh self-heals, see below)"
    elif [ -n "$hb_skipped" ]; then
      # A truncated tick is working as designed (better a phase waits a round than
      # the whole tick drifting off its interval) but it is the signal that the
      # bottleneck has moved again — so name it rather than passing silently.
      warn collect "last tick ${hb_age}s ago took ${hb_dur:-?}s and hit its ${FLEET_COLLECT_TICK_BUDGET:-120}s budget (FLEET_COLLECT_TICK_BUDGET) — slowest phase ${hb_slow:-?}$hb_budget. Those caches refresh on a later tick (global/collect.phase.cursor resumes there); raise that phase's budget, or find out why it got slow"
    else
      pass collect "last tick ${hb_age}s ago, took ${hb_dur:-?}s (slowest phase ${hb_slow:-?}$hb_budget; tick budget ${FLEET_COLLECT_TICK_BUDGET:-120}s, deadline ${FLEET_COLLECT_DEADLINE:-600}s)"
    fi
  else
    hb_age=$((hb_now - hb_start))
    if [ "$hb_age" -gt "${FLEET_COLLECT_DEADLINE:-600}" ]; then
      warn collect "a tick started $((hb_age/60))m ago is still in phase \`$hb_phase\` and never finished — wedged (the next tick kills + supersedes it past the deadline); see logs/collect.launchd.log"
    else
      pass collect "a tick is running (phase \`$hb_phase\`, ${hb_age}s in)"
    fi
  fi
else
  printf '        note: no collector heartbeat yet (global/collect.heartbeat) — the collector has not completed a tick since #551; run bin/tmux-dash-collect.sh once or check com.claude-fleet.collect.\n'
fi

# --- interval-daemon liveness + self-heal (issues #636, #639) -------------------
# launchd can PEND a StartInterval unit for hours (`state = not running`, `pended
# nondemand spawn = interval`, `last exit code = 0`) — and #639 measured it doing
# that to EVERY interval unit in this user domain at once, every log freezing
# inside the same two minutes while the two KeepAlive units never missed a frame.
# Nothing errors and nothing empties: the collector just serves a two-hour-old
# world, cleanup stops reaping workers, dispatch stops autofilling, base-sync
# stops fast-forwarding the base, issue-bridge stops relaying comments,
# ledger-watch stops indexing closed sessions.
#
# So every unit is checked here, each against its OWN StartInterval rather than
# one absolute number — the failure is usually DEGRADATION, not a stop: the
# measured collector was running once per 7–14 minutes against a 60s interval and
# the old absolute 600s threshold called that `fresh` for hours.
#
# A unit that has NEVER ticked on this host is counted, not warned: that is a
# fresh install, or a unit this machine never had (#492 — ledger-watch was missing
# for months while the doctor printed PASS), and fleet-daemon-loaded.sh above is
# the check that answers "is it installed?".
#
# AND WHY THE PER-UNIT LINES ARE NOT ALWAYS THE RIGHT ANSWER (issue #711). On
# 2026-09-15 this section printed NINE of them at once — every interval unit on
# the host, each line true, the nine together false. The fleet's daemons were
# fine: the whole `gui/501` launchd domain had stopped spawning jobs, which a
# throwaway agent sharing nothing with the fleet proved in 40 seconds by never
# running once (not even its RunAtLoad), and which the SAME install on the SAME
# commit did not do on the other machine. Nine unit-shaped warnings send the
# operator to read plists, ProcessType and load — none of which is the fault, and
# none of which they can fix, because the remedy is to log out or reboot.
#
# So when the stall has the DOMAIN signature — see the two of them below the loop —
# the per-unit lines are held back and bin/fleet-launchd-probe.sh is asked the
# question one level up. A verdict is cached for FLEET_LAUNCHD_PROBE_TTL, so
# repeated doctor runs during an incident pay for the measurement once. Probing
# NEVER happens on a healthy host: the signature gate is checked first, and it
# needs a real stall — or a self-heal already working overtime — to open.
if command -v fleet_daemon_unit_names >/dev/null 2>&1; then
  d_root="$(dirname "$0")/.."
  d_over=0; d_never=0; d_fresh=0; d_names=''; d_lines=''
  for d_u in $(fleet_daemon_unit_names); do
    if [ "$(fleet_daemon_tick_ts "$d_u" "$d_root")" -le 0 ]; then d_never=$((d_never+1)); continue; fi
    d_age=$(fleet_daemon_overdue "$d_u" "$d_root")
    if [ -z "$d_age" ]; then d_fresh=$((d_fresh+1)); continue; fi
    d_over=$((d_over+1))
    d_names="${d_names:+$d_names,}$d_u"
    d_int=$(fleet_daemon_interval "$d_u"); d_thr=$(fleet_daemon_stale_secs "$d_u")
    d_f=$(fleet_daemon_kick_fails "$d_u" "$d_root")
    # A kickstart buys ONE execution, not restored scheduling (#639 measured six
    # units at ZERO runs over 27.8 min right after a hand-kick), so the count of
    # kicks that did NOT bring it back is the number worth reading: past
    # FLEET_DAEMON_RELOAD_AFTER the watch escalates to a real unload + reload, and
    # a unit still stalled after THAT is one only a human can fix.
    d_note=''
    if [ "$d_f" -gt 0 ]; then
      d_note=", self-healed ${d_f}× with no effect"
      [ "$d_f" -ge "$(fleet_daemon_reload_after)" ] && d_note="$d_note — escalated to unload+reload"
    fi
    # HELD, not printed: the domain check below decides whether these nine lines
    # are the finding or the symptom. Newline-joined in one variable — this doctor
    # is /bin/sh, so no arrays, and every message here is single-line by
    # construction.
    d_lines="$d_lines$(printf 'com.claude-fleet.%s last ticked %sm ago — %s× its own %ss StartInterval (alarms past %ss)%s. Nothing is scheduling it; bin/fleet-daemon-watch.sh drives the self-heal from the KeepAlive spinner (history: logs/daemon-kick.log)' \
      "$d_u" "$((d_age/60))" "$((d_age/d_int))" "$d_int" "$d_thr" "$d_note")
"
  done

  # --- domain signature → ask the probe ----------------------------------------
  # TWO signatures, because the obvious one stops working exactly when the
  # self-heal starts:
  #
  #   stalled-together — several units overdue AT ONCE, and at least half of the
  #     ones that have ever ticked here. One stalled unit is that unit's problem;
  #     eight of nine is not a coincidence. This is the shape #711 was filed from.
  #
  #   healed-together — several units KICKED inside the last hour. Each kick buys
  #     one execution, so a kicked unit reads fresh again for a whole interval and
  #     the first signature collapses to one or two units. Measured on the wedged
  #     host while the kicks were running: 1 overdue, 9 kicked in the previous two
  #     minutes, all nine logging the same `kick → stale → kick` cycle. Without
  #     this second test the doctor would go quiet on a machine whose every daemon
  #     is running at its self-heal cooldown instead of its StartInterval — the
  #     WORSE state, because nothing on screen says so.
  d_seen=$((d_over + d_fresh))
  d_domain=''
  d_probe="$(dirname "$0")/fleet-launchd-probe.sh"
  d_min="${FLEET_DAEMON_DOMAIN_MIN:-3}"
  case "$d_min" in ''|*[!0-9]*) d_min=3 ;; esac
  d_kicked=$(fleet_daemon_kicked_recently "$d_root" "${FLEET_DAEMON_DOMAIN_KICK_WINDOW:-3600}")
  d_sig=''
  if [ "$d_over" -ge "$d_min" ] && [ "$((d_over * 2))" -ge "$d_seen" ]; then
    d_sig="$d_over interval units are stalled together"
  elif [ "$d_kicked" -ge "$d_min" ]; then
    d_sig="$d_kicked interval units are only ticking because the self-heal kicks them"
  fi
  if [ -n "$d_sig" ] && [ -f "$d_probe" ]; then
    d_domain=$(fleet_daemon_probe_verdict "$d_root")
    if [ -z "$d_domain" ] && [ "${FLEET_LAUNCHD_PROBE:-1}" != 0 ] && command -v launchctl >/dev/null 2>&1; then
      printf '        note: %s — measuring whether launchd still spawns anything (~%ss)…\n' \
        "$d_sig" "${FLEET_LAUNCHD_PROBE_WINDOW:-40}"
      bash "$d_probe" --quiet >/dev/null 2>&1
      d_domain=$(fleet_daemon_probe_verdict "$d_root")
    fi
  fi

  case "$d_domain" in
    no-spawn|no-interval)
      # ONE line instead of $d_over. The units are listed, not warned about: they
      # are the symptom, and naming them keeps the old information without
      # reinstating the wrong diagnosis.
      if [ "$d_domain" = no-spawn ]; then
        d_what="spawns NOTHING automatically — a throwaway agent bootstrapped beside the fleet's never ran once, not even its RunAtLoad"
      else
        d_what="ran a throwaway agent at load but NEVER on its StartInterval — interval scheduling is pended domain-wide"
      fi
      # Say which of the two signatures brought us here. With the self-heal
      # working, `$d_over` is routinely 0 or 1 and the fleet is STILL crippled —
      # so a message written only for the stalled-together case would read as
      # though nothing much were wrong.
      d_who=''
      [ "$d_over" -gt 0 ] && d_who="$d_over interval unit(s) ($d_names) are stalled for that reason, and their plists/scripts are not the fault"
      if [ "$d_kicked" -ge "$d_min" ]; then
        d_who="${d_who:+$d_who; }$d_kicked unit(s) were kicked in the last hour, i.e. anything that does NOT read stale is ticking at its self-heal cooldown rather than its own StartInterval"
      fi
      [ -n "$d_who" ] || d_who="no unit is stale yet, but nothing here is being scheduled either"
      warn launchd "the gui/$(id -u) launchd domain $d_what. This is MACHINE state, not fleet state: $d_who. Nothing in the fleet can fix it — log out and back in, or reboot. Until then the self-heal's kicks are the only thing running these daemons (\`launchctl kickstart\` is an explicit command, so it bypasses the stuck spawn path). Re-measure: bin/fleet-launchd-probe.sh"
      d_pa=$(fleet_daemon_probe_age "$d_root")
      printf '        note: verdict `%s` measured %ss ago by bin/fleet-launchd-probe.sh (cached for %ss; --cached reads it without re-probing).\n' \
        "$d_domain" "${d_pa:-?}" "${FLEET_LAUNCHD_PROBE_TTL:-900}"
      ;;
    *)
      # Either the stall is not domain-shaped, or the probe says the domain is
      # fine (so these units really are individually stuck), or nothing could be
      # measured. All three want the per-unit detail — an UNMEASURED domain must
      # never be reported as a healthy one.
      # A here-doc, NOT a pipe: a `while` on the right of `|` runs in a subshell,
      # where every warn() would print correctly and increment a copy of $warns
      # that dies with it — the run would end "all good" under nine warnings.
      while IFS= read -r d_l; do
        [ -n "$d_l" ] && warn daemons "$d_l"
      done <<EOF
$d_lines
EOF
      if [ -n "$d_sig" ]; then
        printf '        note: %s — that is the DOMAIN-stall signature (#711), not a per-unit one. Before reading any plist, run bin/fleet-launchd-probe.sh: it settles machine-vs-fleet in ~%ss.\n' \
          "$d_sig" "${FLEET_LAUNCHD_PROBE_WINDOW:-40}"
      fi
      ;;
  esac

  # A green PASS under a red domain would be the same lie in the other direction:
  # with the self-heal keeping every unit inside its staleness window, "10 units
  # ticking" is TRUE and completely misleading — they are ticking once per
  # cooldown, not once per StartInterval.
  if [ "$d_over" = 0 ] && [ "$d_domain" != no-spawn ] && [ "$d_domain" != no-interval ]; then
    d_note=''
    # "Never seen" is not a complaint — see the note above — but it IS the number
    # that tells you whether this host is running the daemons you think it is.
    [ "$d_never" -gt 0 ] && d_note=" ($d_never never seen on this host)"
    pass daemons "$d_fresh interval unit(s) ticking inside ${FLEET_DAEMON_STALE_MULT:-5}× their own StartInterval$d_note"
  fi
  # A kick is not a problem solved: it is evidence a daemon stalled, so say so for
  # as long as the stamp is worth reading and point at the whole history.
  d_kick=$(fleet_daemon_recent_kick "$d_root")
  if [ -n "$d_kick" ]; then
    printf '        note: daemon self-heal last kicked a unit %sm ago — it had stopped being scheduled; per-unit history in logs/daemon-kick.log.\n' \
      "$(( d_kick / 60 ))"
  fi
fi

# --- machine load + orphaned runaways (issue #697) ------------------------------
# The blind spot #697 was filed about. On 2026-09-15 this screen printed a steady
# "1 warn" while the machine sat at load 108 with eight leaked PPID=1 CPU burners
# on it — `ps` and `uptime` were themselves timing out, both daemons were wedged,
# and the doctor had no line that could say any of it. Every other check here asks
# "is the fleet installed correctly"; this one asks "is the machine it runs on
# still usable", which is a different question and was nobody's.
#
# Severity is WARN, never FAIL, on purpose: the exit status gates an install
# (`sh fleet-doctor.sh && …`) and a runaway is a transient condition, not a
# missing dependency — failing here would block an install over something that
# clears on its own. What it must not be is SILENT.
mcores=$( { sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null; } \
          | head -1 | awk '{ n=$1+0; print (n>0 ? n : 1) }' )
mload=$( { sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' || awk '{print $1}' /proc/loadavg 2>/dev/null; } \
         | head -1 | awk '{ if (NF) printf "%.2f", $1+0 }' )
mper=$(awk -v l="${mload:-0}" -v c="$mcores" 'BEGIN{ printf "%.2f", (c>0 ? l/c : l) }')
mwarn="${FLEET_LOAD_WARN_PER_CORE:-4}"
# The orphan scan lives in the daemon that acts on it, so the doctor and the
# watchdog can never disagree about what counts as a runaway.
_dg="$(dirname "$0")/fleet-diskguard.sh"
hbf_m="$(dirname "$0")/../logs/spinner.heartbeat"
morph=''
[ -f "$_dg" ] && morph="$(bash "$_dg" --orphans 2>/dev/null)"
# awk, not `grep -c` (issue #709): `grep -c` on no match prints `0` AND exits 1,
# so the `|| echo 0` this was written with fired on top of grep's own output and
# glued the two into `0\n0` — which `[ "$morphn" -gt 0 ]` below then rejected with
# `integer expression expected` on stderr of every HEALTHY run. The verdict
# survived by luck (the error made the `elif` false, and false was the right
# answer when there are no orphans), so only stderr ever showed it. awk returns a
# single `0` on empty input and exits 0, with no fallback clause to get wrong.
morphn=$(printf '%s' "$morph" | awk 'NF{n++} END{print n+0}')

if [ -z "$mload" ]; then
  # Not a measurement bug to shrug at — "the load average would not come back" is
  # the machine answering the question by refusing to.
  warn machine "could not read the load average — on a healthy box this is instant, so a timeout here is itself the finding (\`uptime\`/\`ps\` were timing out at load 108 in issue #697)"
elif [ "$morphn" -gt 0 ]; then
  mtop=$(printf '%s\n' "$morph" | sort -t"$(printf '\t')" -k2,2nr | head -1)
  mpid=$(printf '%s' "$mtop" | cut -f1); mcpu=$(printf '%s' "$mtop" | cut -f2)
  met=$(printf '%s' "$mtop" | cut -f3)
  # awk's substr, not `cut -c`: an argv can hold multibyte bytes and cut would
  # slice one in half, and the "Illegal byte sequence" that follows would be the
  # only thing the operator ever saw of this line.
  # columns: pid / %cpu / etime / rssMB / argv (RSS joined at col 4 in #1292)
  mrss=$(printf '%s' "$mtop" | cut -f4)
  mcmd=$(printf '%s' "$mtop" | cut -f5 | awk '{ print substr($0,1,70) }')
  warn machine "load $mload on $mcores cores (${mper}/core) — and $morphn ORPHANED runaway(s): PPID=1, fleet-fingerprinted, burning CPU with no worktree or pane to reap them. Worst: pid $mpid at ${mcpu}%, ${mrss} MB, up $met — \`${mcmd}…\`. Full list: \`bin/fleet-diskguard.sh --orphans\`; a leaked load experiment stops with \`bin/fleet-loadgen.sh --stop\`; forensics land in \${FLEET_CONF_DIR:-~/.config/claude-fleet}/diskguard/incident-orphan-*.log"
elif awk -v p="$mper" -v w="$mwarn" 'BEGIN{ exit !(p>=w) }'; then
  warn machine "load $mload on $mcores cores = ${mper}/core, at or over the ${mwarn}/core line — every fleet on this box is sharing it. No fleet-fingerprinted orphan is responsible (\`bin/fleet-diskguard.sh --orphans\` is empty), so look at what else is running"
else
  pass machine "load $mload on $mcores cores (${mper}/core), no orphaned runaways"
fi

# --- the machine's one daemon (issue #2331, EPIC #2329 C3) ----------------------
# com.claude-fleet.node runs the machine-level work once for every login; its
# status is world-readable, so any login's doctor reads it. Not installed ⇒ no row
# (a machine that never had it reads byte for byte as before).
_nsup="$(dirname "$0")/fleet-node-supervisor.py"
if [ -f "$_nsup" ] && command -v python3 >/dev/null 2>&1; then
  nline=$(python3 "$_nsup" status --check 2>/dev/null); nrc=$?
  case "$nrc" in
    0) pass node "machine daemon com.claude-fleet.node: $nline" ;;
    3) warn node "machine daemon com.claude-fleet.node: $nline — the hub refuses that login's lane on the machine's node program (its token was reissued away or retired; issue #2501): \`sudo fleet-node-supervisor.py account adopt <login> --rejoin\`, or an admin: \`fleet hub accounts relogin\`; detail: \`fleet-node-supervisor.py status\`" ;;
    1) warn node "machine daemon com.claude-fleet.node is installed but not running — $nline. launchd's KeepAlive should bring it back within seconds; if it does not: \`sudo launchctl kickstart -k system/com.claude-fleet.node\`, log /var/log/fleet-node/supervisor.log, \`fleet-node-supervisor.py status\`" ;;
  esac
fi
# The registered background services and scheduled tasks (issue #2526, EPIC
# #2524 C2): the same table `fleet ls --services` prints — the hub's word for
# every machine of this person's (global/hub_services), this machine's daemon
# for the rest. A failed one (down · failed · invalid · no_login) is FAIL;
# a hand-written launchd plist of this login's the daemon's sweep found is
# WARN (issue #2530); nothing registered is INFO.
_nsvc="$(dirname "$0")/fleet-services.py"
if [ -f "$_nsvc" ] && command -v python3 >/dev/null 2>&1; then
  sline=$(python3 "$_nsvc" --doctor 2>/dev/null)
  case "$sline" in
    FAIL\ *) fail services "${sline#FAIL }" ;;
    WARN\ *) warn services "${sline#WARN }" ;;
    PASS\ *) pass services "${sline#PASS }" ;;
    INFO\ *) info services "${sline#INFO }" ;;
  esac
fi
# The machine's one updater (issue #2334): where the last tick left it. No
# update.json (the updater never ran here) ⇒ no row. WARN, never FAIL: the
# updater's own gate rolls a bad release back; this line only says it happened.
_nupd="$(dirname "$0")/fleet-node-update.py"
if [ -f "$_nupd" ] && [ -f "${FLEET_NODE_STATE:-/var/db/fleet-node}/update.json" ] && command -v python3 >/dev/null 2>&1; then
  uline=$(python3 "$_nupd" status --check 2>/dev/null); urc=$?
  case "$urc" in
    0) pass update "${uline#update  } — every part: \`fleet doctor --machine\`" ;;
    1) warn update "${uline#update  } — log /var/log/fleet-node/update.log; every part: \`fleet doctor --machine\`" ;;
  esac
fi

# --- fleet listeners exposed to the LAN (issue #1154) ---------------------------
# An agent's temp server (`python3 -m http.server`, a node dev server) binds `*` by
# default, and outlives its window: the 2026-09-24 audit found one serving the
# whole scratchpad root to the LAN for two days. The diskguard tick reaps the
# ORPHANED ones after FLEET_ORPHAN_LISTEN_SECS; this line names every exposed one
# NOW — orphaned or still owned by a live session — because the exposure is the
# finding either way. Only fleet/Claude-anchored cwds count (a scratchpad, a fleet
# worktree, ~/.claude): the operator's own apps (AirPlay, rapportd) are not ours.
# WARN, never FAIL, like every machine line: a condition, not a broken install.
lsn=''
[ -f "$_dg" ] && lsn="$(bash "$_dg" --listeners 2>/dev/null)"
lsnn=$(printf '%s' "$lsn" | awk 'NF{n++} END{print n+0}')
if [ "$lsnn" -gt 0 ]; then
  warn listen "$lsnn fleet process(es) listening on the LAN — a temp server bound to \`*\` serves its cwd to anyone on the network (issue #1154). Bind 127.0.0.1 (\`python3 -m http.server --bind 127.0.0.1\`); share with the operator through doc-preview. Orphans are reaped after \${FLEET_ORPHAN_LISTEN_SECS:-21600}s by the diskguard tick; \`bin/fleet-diskguard.sh --orphan-listeners\` lists them"
  printf '%s\n' "$lsn" | head -5 | while IFS="$(printf '\t')" read -r lpid laddr lage lcwd largv; do
    [ -n "$lpid" ] || continue
    lup=$(awk -v s="$lage" 'BEGIN{ s+=0; d=int(s/86400); h=int(s%86400/3600); m=int(s%3600/60)
      if (d) printf "%dd%dh", d, h; else if (h) printf "%dh%dm", h, m; else printf "%dm", m }')
    printf '        pid %s  %s  up %s  cwd=%s  %s\n' "$lpid" "$laddr" "$lup" "$lcwd" \
      "$(printf '%s' "$largv" | awk '{ print substr($0,1,60) }')"
  done
else
  pass listen "no fleet process listening on the LAN"
fi

# --- remote clients of this machine (issue #1907) ---------------------------------
# A shell / proxy client of this machine sits on a view session of its own
# (`<fleet>@view-<id>`, #1489): one on the FLEET session shows the node's status
# line under the client's header and leaves the node's prefix live — what a
# reconnect onto a half-dead attach did. An orphan is a registered attach whose
# tmux client the server no longer has (a dead line sshd never noticed); every
# attach reaps those, `fleet-remote-view.sh prune` on demand.
_rv="$(dirname "$0")/fleet-remote-view.sh"
if [ -f "$_rv" ]; then
  _rvh=$(bash "$_rv" health 2>/dev/null)
  _rvs=$(printf '%s' "$_rvh" | sed -n 's/.*shared=\([0-9]*\).*/\1/p'); _rvo=$(printf '%s' "$_rvh" | sed -n 's/.*orphans=\([0-9]*\).*/\1/p')
  if [ "${_rvs:-0}" -gt 0 ] || [ "${_rvo:-0}" -gt 0 ]; then
    warn rview "${_rvs:-0} remote client(s) on a fleet session (not their own view session — the node's status line and prefix are live for them), ${_rvo:-0} orphaned attach(es) (their tmux client is gone). Reconnecting the client fixes the first; \`bin/fleet-remote-view.sh prune\` reaps the second (issue #1907)"
  else
    pass rview "remote clients each on a view session of their own, no orphaned attach"
  fi
fi

# --- fleet-open: the operator's browser over their ssh (issue #1379) ------------
# bin/fleet-open.sh writes an iTerm2 Custom= escape signed with a shared secret the
# laptop side (#1380) reads over ssh; open.last is its last result. No secret yet
# is INFO (made on the first fleet-open); a secret others can read is a WARN — it
# is the only thing that stops any printed text from opening URLs on the laptop.
_os="$HOME/.config/claude-fleet/open.secret"; _ol="$HOME/.config/claude-fleet/open.last"
if [ ! -s "$_os" ]; then
  info open "no secret yet ($_os) — made on the first \`bin/fleet-open.sh\`; then install the laptop side (#1380)"
else
  _op=$(stat -c '%a' "$_os" 2>/dev/null || stat -f '%Lp' "$_os" 2>/dev/null)
  _olast="never used"
  if [ -s "$_ol" ]; then
    _olast=$(awk -F '\t' -v now="$(date +%s)" 'NR == 1 { a = now - $1; u = "s"
      if (a >= 86400) { a = int(a / 86400); u = "d" } else if (a >= 3600) { a = int(a / 3600); u = "h" } else if (a >= 60) { a = int(a / 60); u = "m" }
      printf "last: %s (%s) %d%s ago", $2, $3, a, u }' "$_ol")
  fi
  if [ "$_op" != 600 ]; then
    warn open "secret $_os is mode ${_op:-?}, not 0600 — \`chmod 600\` it (the next fleet-open does); $_olast"
  else
    pass open "secret 0600; $_olast"
  fi
fi

# --- machine pressure the load average cannot see (issue #889) -----------------
# On 2026-09-22 every new session froze 6-8s at spawn and it took an hour of
# manual digging to find three causes this screen could have named: macOS's
# fseventsd had grown to 2.9 GB, the spinner was forking tmux many times a second,
# and three fleets' caps added up to 35 sessions on a 10-core box. The load line
# above read fine through all of it. Each gets its own `machine` line — WARN, never
# FAIL, for the same reason as above: pressure is a condition, not a broken install.
#
# 1. fseventsd (macOS only; Linux prints nothing). Read through diskguard, the
#    daemon that reminds about it, so the two cannot disagree on the number.
fsev=''
[ -f "$_dg" ] && fsev="$(bash "$_dg" --fseventsd 2>/dev/null | head -1)"
if [ -n "$fsev" ]; then
  fmb=$(printf '%s' "$fsev" | cut -f1); fcpu=$(printf '%s' "$fsev" | cut -f2)
  fet=$(printf '%s' "$fsev" | cut -f3)
  fwmb="${FLEET_FSEVENTSD_WARN_MB:-$(_gconf_val FLEET_FSEVENTSD_WARN_MB)}"
  case "$fwmb" in ''|*[!0-9]*) fwmb=1024 ;; esac
  if awk -v m="$fmb" -v c="$fcpu" -v w="$fwmb" 'BEGIN{ exit !((m+0 >= w+0) || (c+0 >= 90)) }'; then
    warn machine "fseventsd at ${fmb} MB RSS, ${fcpu}% CPU, up ${fet} — over the ${fwmb} MB / 90% line; new sessions stall at spawn while it is bloated (issue #889). Fix: \`sudo killall fseventsd\` — launchd restarts it at once"
  else
    pass machine "fseventsd ${fmb} MB RSS, ${fcpu}% CPU, up ${fet}"
  fi
fi
# 1b. A Homebrew keg the other logins cannot read (issue #2283): brew pours with
#    the caller's umask, so a 077 owner's upgrade leaves 700 kegs that break every
#    other login's python ssl / tmux and say nothing. The diskguard tick repairs
#    them as the prefix's owner; this row WARNs with the owner and the one line to
#    run. One login on the machine (or no brew) prints nothing.
_bp="$(dirname "$0")/fleet-brew-perms.sh"
bperm=''
[ -f "$_bp" ] && bperm="$(bash "$_bp" --doctor 2>/dev/null | head -1)"
case "$bperm" in
  ok"	"*)   pass brew "${bperm#*	}" ;;
  warn"	"*) warn brew "${bperm#*	}" ;;
esac
# 2. tmux calls per second, as the spinner measures itself (issue #887). Loosely
#    coupled: a heartbeat without the field (a spinner predating it) shows nothing.
tcps=''
[ -f "$hbf_m" ] && tcps=$(sed -n 's/.*tmux_calls_per_s=\([0-9.]*\).*/\1/p' "$hbf_m" 2>/dev/null | head -1)
[ -n "$tcps" ] && pass machine "spinner forks ${tcps} tmux call(s)/s (logs/spinner.heartbeat)"
# 3. Session caps vs cores — STATED, never warned (issue #952). The ceiling that
#    matters is the one a spawn actually hits: the global cap, or the per-fleet
#    caps' sum when every fleet has one and they add up to less. #889 used to WARN
#    past 2 sessions per core and tell the operator to lower
#    FLEET_GLOBAL_MAX_SESSIONS; the operator owns both caps and fleet neither
#    advises nor changes them (#881 pt 16 → the epic preflight's `slots` line in
#    #895). So this line only reports the numbers, and an unbounded box is a fact
#    it names, not a finding it counts.
gmax="${FLEET_GLOBAL_MAX_SESSIONS:-$(_gconf_val FLEET_GLOBAL_MAX_SESSIONS)}"
case "$gmax" in ''|*[!0-9]*) gmax=0 ;; esac   # 0 = off by default since #1831
gfmax=$(_gconf_val FLEET_MAX_SESSIONS)
csum=0; cn=0; cunl=0
if [ -d "$conf_dir" ]; then
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    v=$(_conf_val "$cf" FLEET_MAX_SESSIONS); [ -n "$v" ] || v="$gfmax"
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    cn=$((cn+1))
    if [ "$v" -gt 0 ]; then csum=$((csum+v)); else cunl=$((cunl+1)); fi
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
fi
cceil=''
if [ "$gmax" -gt 0 ]; then
  cceil=$gmax
  [ "$cn" -gt 0 ] && [ "$cunl" -eq 0 ] && [ "$csum" -lt "$gmax" ] && cceil=$csum
elif [ "$cn" -gt 0 ] && [ "$cunl" -eq 0 ]; then
  cceil=$csum
fi
csumtxt="per-fleet caps sum to $csum across $cn fleet(s)"
[ "$cunl" -gt 0 ] && csumtxt="$csumtxt ($cunl uncapped)"
gtxt="global cap $gmax"; [ "$gmax" -gt 0 ] || gtxt="no global cap"
if [ -z "$cceil" ]; then
  pass machine "sessions: $gtxt, $csumtxt — unbounded on $mcores cores"
else
  cratio=$(awk -v n="$cceil" -v c="$mcores" 'BEGIN{ printf "%.1f", n/c }')
  pass machine "sessions: $gtxt, $csumtxt — up to $cceil concurrent on $mcores cores (${cratio}x)"
fi

# 4. Sessions across EVERY login on this box (issue #1301). Each login's collector
#    publishes `<count> <epoch>` to a machine-level dir (fleet_machine_sessions_*
#    in fleet-lib.sh — KEEP IN SYNC: dir, login files, stale bound); a file past
#    FLEET_MACHINE_SESSIONS_STALE (300s) counts 0. Stated, never warned: the cap
#    FLEET_MACHINE_MAX_SESSIONS defaults to 0 (unlimited) until the operator has
#    seen a week of peaks — this line is what they read to pick it.
if [ -n "${FLEET_MACHINE_SESSIONS_DIR:-}" ]; then msdir="$FLEET_MACHINE_SESSIONS_DIR"
elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then msdir=/Users/Shared/claude-fleet/sessions
else msdir=/var/tmp/claude-fleet/sessions; fi
mmax="${FLEET_MACHINE_MAX_SESSIONS:-$(_gconf_val FLEET_MACHINE_MAX_SESSIONS)}"
case "$mmax" in ''|*[!0-9]*) mmax=0 ;; esac
mstale="${FLEET_MACHINE_SESSIONS_STALE:-$(_gconf_val FLEET_MACHINE_SESSIONS_STALE)}"
case "$mstale" in ''|*[!0-9]*) mstale=300 ;; esac
mrows=''
if [ -d "$msdir" ]; then
  mnow=$(date +%s)
  # only a file its login owns (fleet_machine_sessions_owned, issue #2299 — KEEP IN SYNC)
  mfiles=$(if [ "${FLEET_MACHINE_SESSIONS_OWNER_CHECK:-1}" = 0 ]; then
      for mf in "$msdir"/*; do [ -f "$mf" ] && [ ! -L "$mf" ] && printf '%s\n' "$mf"; done
    else
      ls -l "$msdir" 2>/dev/null | awk '/^-/ { print $3, $NF }' | while read -r mo ml; do
        [ -n "$ml" ] || continue
        if [ "$mo" != "$ml" ]; then
          case "$mo" in (''|*[!A-Za-z0-9._-]*) continue ;; esac
          mh=$(eval "printf '%s' ~$mo" 2>/dev/null); [ "${mh##*/}" = "$ml" ] || continue
        fi
        printf '%s\n' "$msdir/$ml"
      done
    fi)
  for mf in $mfiles; do
    [ -f "$mf" ] || continue
    mrows="$mrows$(awk -v l="${mf##*/}" -v now="$mnow" -v st="$mstale" '
      NR == 1 { n = ($1 ~ /^[0-9]+$/) ? $1 : 0; ts = ($2 ~ /^[0-9]+$/) ? $2 : 0
                if (now - ts > st) printf "%s 0 stale\n", l; else printf "%s %d fresh\n", l, n; exit }' "$mf" 2>/dev/null)
"
  done
fi
mcap="no machine cap (FLEET_MACHINE_MAX_SESSIONS=0)"; [ "$mmax" -gt 0 ] && mcap="machine cap $mmax"
if [ -z "$(printf '%s' "$mrows" | tr -d '[:space:]')" ]; then
  info machine "sessions across logins: no login has published a count yet ($msdir) — each login's collector writes one a tick; $mcap"
else
  msum=$(printf '%s' "$mrows" | awk 'NF { t += $2; s = $1 " " $2; if ($3 == "stale") s = s " (stale)"; o = (o == "") ? s : o " · " s; k++ }
    END { printf "%d across %d login(s): %s", t, k, o }')
  pass machine "sessions across logins: $msum — $mcap"
fi

# 5. Admission — the ONLY capacity gate by default (issue #1831). The count caps
#    default to 0, so what a spawn meets is fleet_machine_admit: room for one more
#    session's measured cost above the kept-back floor, after paying for sessions
#    admitted but not yet in the memory reading. This row is that number, every
#    time — the operator should not learn the machine is full by being refused.
#    No gate at all (both counts off AND FLEET_ADMIT=0) is a WARN: nothing then
#    stops a spawn storm before the memory reading moves.
adm="${FLEET_ADMIT:-$(_gconf_val FLEET_ADMIT)}"; [ -n "$adm" ] || adm=1
if [ "$adm" = 0 ]; then
  if [ "$gmax" -eq 0 ] && [ "$mmax" -eq 0 ]; then
    warn admit "no capacity gate at all: FLEET_GLOBAL_MAX_SESSIONS=0, FLEET_MACHINE_MAX_SESSIONS=0 and FLEET_ADMIT=0 — a burst of spawns can take the machine before memory moves (issue #1831); drop FLEET_ADMIT=0, or set a count cap"
  else
    info admit "FLEET_ADMIT=0 — only the count cap gates new sessions"
  fi
else
  _ad_env=''
  for _k in FLEET_ADMIT_MEM_FREE_PCT FLEET_ADMIT_PRESSURE FLEET_ADMIT_LOAD_PER_CORE FLEET_ADMIT_RESERVE_MB \
            FLEET_ADMIT_HYST_MB FLEET_ADMIT_SESSION_MB FLEET_ADMIT_SESSION_MB_MIN FLEET_ADMIT_SESSION_GROWTH FLEET_ADMIT_SETTLE_SECS; do
    eval "_v=\${$_k:-}"; [ -n "$_v" ] || _v=$(_gconf_val "$_k")
    [ -n "$_v" ] && _ad_env="$_ad_env $_k=$_v"
  done
  # shellcheck disable=SC2086
  _ad=$(env $_ad_env bash -c '. "$1/fleet-lib.sh" >/dev/null 2>&1
    h=$(fleet_machine_headroom) || h=-; w=$(fleet_machine_admit --short) && w=ok
    who=$(fleet_admit_holders | paste -sd ";" - | sed "s/;/; /g"); printf "%s|%s|%s" "$h" "$w" "$who"' _ "$(dirname "$0")" 2>/dev/null)
  # <headroom>|<verdict>|<who holds a reservation> — each one named (issue #2502):
  # "admitted not yet counted" was a bare number, and finding the pool's phantoms
  # behind it took watching the directory by hand.
  _ad_h=${_ad%%|*}; _ad_w=${_ad#*|}; _ad_who=${_ad_w#*|}; _ad_w=${_ad_w%%|*}
  if [ -z "$_ad" ] || [ "$_ad_h" = - ]; then
    info admit "admission on, but this machine's memory is unreadable here — it admits by load alone"
  else
    # <room> <cost> <avail> <floor> <reserved> <hyst> <median> <agents>
    read -r _r _c _a _f _rs _hy _md _ag <<EOF
$_ad_h
EOF
    _ad_txt="room for ~$_r more session(s) now at ~$_c MB each (median $_md MB × growth over $_ag live agent(s)) — $_a MB available, $_f MB kept back"
    [ "$_hy" -gt 0 ] && _ad_txt="$_ad_txt + $_hy MB until it recovers"
    [ "$_rs" -gt 0 ] && _ad_txt="$_ad_txt, $_rs admitted not yet counted${_ad_who:+ ($_ad_who)}"
    if [ "$_ad_w" = ok ]; then pass admit "$_ad_txt"
    else warn admit "$_ad_w — $_ad_txt; running sessions are untouched, new ones wait (FLEET_ADMIT=0 overrides)"; fi
  fi
fi

# --- epic: which batches are being driven (issue #1846; one mark per batch, #2062) --
# /fleet-epic-run stamps global/epic-running.d/<repo>-<N> every tick
# (fleet-epic-heartbeat.sh), one file per batch. Every fresh mark is a batch in
# flight: ONE row names them all — they are what holds install-sync still. A
# lease that went stale while its EPIC is still OPEN means the loop's window went
# away (killed, its machine down) and nobody is driving the batch: WARN with the
# one way back, per batch. No mark → no row; a closed EPIC's leftover mark is history.
_ep_run=''
while IFS= read -r _ep_f; do
  [ -n "$_ep_f" ] || continue
  _ep=$(bash -c '. "$1/fleet-lib.sh" >/dev/null 2>&1; fleet_epic_running "$2"; printf "|%s" "$?"' _ "$(dirname "$0")" "$_ep_f" 2>/dev/null)
  _ep_rc=${_ep##*|}; _ep=${_ep%|*}
  [ "$_ep_rc" = 0 ] || [ "$_ep_rc" = 1 ] || continue
  _ep_n=$(printf '%s' "$_ep" | sed -n 's/.*epic=\([0-9][0-9]*\).*/\1/p')
  _ep_age=$(printf '%s' "$_ep" | sed -n 's/.*age=\([0-9][0-9]*\)s.*/\1/p')
  _ep_tick=$(printf '%s' "$_ep" | sed -n 's/.*tick=\([^ ]*\).*/\1/p')
  _ep_m=$(( ${_ep_age:-0} / 60 ))
  if [ "$_ep_rc" = 0 ]; then
    # #2247: a batch stamped live 0 + inflight 0 is idle and does not hold install-sync
    case "$_ep" in *' live=0 inflight=0') _ep_idle='，空转·不挡升级' ;; *) _ep_idle='' ;; esac
    _ep_run="${_ep_run:+$_ep_run · }#${_ep_n:-?}（第 ${_ep_tick:--} 拍，${_ep_m} 分钟前${_ep_idle}）"
    continue
  fi
  _ep_repo=$(sed -n 's/^repo: //p' "$_ep_f" 2>/dev/null | head -1); [ "$_ep_repo" = - ] && _ep_repo=''
  _ep_st=''
  if [ -n "$_ep_n" ]; then
    _ep_st=$(bash "$(dirname "$0")/fleet-gh.sh" issue view "$_ep_n" ${_ep_repo:+--repo "$_ep_repo"} --json state --max-age 600 2>/dev/null \
             | sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([A-Z]*\)".*/\1/p')
  fi
  case "$_ep_st" in
    OPEN) warn epic "批次 #$_ep_n 没有人在跑：它的心跳 ${_ep_m} 分钟前就停了（第 ${_ep_tick:--} 拍），EPIC 还开着 — 在 hub 里重新运行 /fleet-epic-run $_ep_n" ;;
    '')   info epic "批次 #${_ep_n:-?} 的心跳 ${_ep_m} 分钟前停了，EPIC 是否还开着读不到" ;;
    *)    pass epic "批次 #$_ep_n 已结束（EPIC ${_ep_st}）" ;;
  esac
done <<EP_MARKS
$(bash -c '. "$1/fleet-lib.sh" >/dev/null 2>&1; fleet_epic_running_marks' _ "$(dirname "$0")" 2>/dev/null)
EP_MARKS
_ep_cap=${FLEET_EPIC_HOLD_CAP_SECS:-7200}; case "$_ep_cap" in ''|*[!0-9]*) _ep_cap=7200 ;; esac
[ -n "$_ep_run" ] && pass epic "批次 $_ep_run 在跑 — 有活的批次挡住 install-sync（每个最多 $((_ep_cap / 60)) 分钟），空转的不挡"

# --- last crash + the record a crash would leave (issue #1294) -----------------
# The diskguard tick harvests the system's panic / Jetsam reports into
# machine/incident-*.md the first tick after a reboot (bin/fleet-crash-harvest.py),
# and appends a machine-metrics row every minute. This names the last crash (WARN
# for a day, so the reboot is seen; INFO after) and WARNs when the metrics stopped
# — a crash then would leave nothing to read.
mdir_m="$conf_dir/machine"
lc="$(ls "$mdir_m"/incident-*.md 2>/dev/null | sort | tail -1)"
if [ -n "$lc" ]; then
  lch="$(sed -n 's/^headline: //p' "$lc" 2>/dev/null | head -1)"
  lcn="${lc##*/incident-}"; lcn="${lcn%.md}"
  lcut="$(date -v-1d '+%Y%m%d-%H%M' 2>/dev/null || date -d '-1 day' '+%Y%m%d-%H%M' 2>/dev/null)"  # portable-ok: BSD/GNU both-ways
  if [ -n "$lcut" ] && awk -v a="$lcn" -v b="$lcut" 'BEGIN { exit !(a > b) }'; then
    warn last-crash "this machine crashed in the last day: ${lch:-see the summary} — summary: $lc"
  else
    info last-crash "${lch:-$lcn} — $lc"
  fi
else
  pass last-crash "no crash harvested (bin/fleet-diskguard.sh --harvest-crash --since <date> reads the system's reports on demand)"
fi
if [ -d "$mdir_m" ]; then
  mf="$(find "$mdir_m" -name 'metrics-*.tsv' -mmin -5 2>/dev/null | head -1)"
  if [ -n "$mf" ]; then
    pass metrics "machine metrics recording — $(grep -vc '^#' "$mf" 2>/dev/null) row(s) today in $mf"
  else
    warn metrics "no machine-metrics row in 5 min ($mdir_m/metrics-*.tsv) — the diskguard tick appends one a minute; a crash now would leave no record of the run-up (issue #1294)"
  fi
fi
# --- memory pressure, the file table, the pty table (issue #1293, EPIC #1291) ---
# 2026-10-03 the kernel was killing background processes for a dozen minutes
# before the mini froze and rebooted, while this screen still read clean: nothing
# here looked at memory, and the two kernel tables a big fleet can exhaust (open
# files, terminals) were nobody's either. Read through diskguard --resources —
# the same rows its --watch tick notifies on — so the two cannot disagree. WARN,
# never FAIL, like every machine line; a reading the machine will not give (a
# Linux CI box without vm_stat, a sandbox) is INFO, never a WARN.
res=''
[ -f "$_dg" ] && res="$(bash "$_dg" --resources 2>/dev/null)"
rmem=$(printf '%s\n' "$res" | awk '$1 == "mem" { print $2, $3, $4, $5; exit }')
if [ -z "$rmem" ]; then
  info memory "no memory-pressure reading on this machine (vm_stat/sysctl or /proc/meminfo unavailable)"
else
  read -r rlvl ravl rcmp rswp <<EOF
$rmem
EOF
  case "$rlvl" in 4) rword=critical ;; 2) rword=warn ;; *) rword=normal ;; esac
  rtop=$(printf '%s\n' "$res" | awk -F'\t' '$1 ~ /^top / { sub(/^top /, "", $1)
    printf "%s%s %s MB (pid %s)", (k++ ? ", " : ""), $3, $2, $1 }')
  rtxt="pressure $rword · ${ravl}% available · compressor ${rcmp}% · swap ${rswp} MB · fleet RSS top: ${rtop:-none}"
  if [ "$rlvl" -ge 2 ] 2>/dev/null; then
    warn memory "$rtxt — the kernel is reclaiming memory; on 2026-10-03 this went on for minutes before the machine froze (issue #1293). \`bin/fleet-memguard.sh --once --dry-run\` names what memguard would stop"
  else
    pass memory "$rtxt"
  fi
fi
for rk in files pty; do
  rrow=$(printf '%s\n' "$res" | awk -v k="$rk" '$1 == k { print $2, $3; exit }')
  if [ "$rk" = files ]; then
    rw="${FLEET_FILES_WARN_PCT:-$(_gconf_val FLEET_FILES_WARN_PCT)}"; rwhat="open files (kern.num_files / kern.maxfiles; Linux fs/file-nr)"
  else
    rw="${FLEET_PTY_WARN_PCT:-$(_gconf_val FLEET_PTY_WARN_PCT)}"; rwhat="terminals in use (ptys / kern.tty.ptmx_max; Linux /dev/pts)"
  fi
  case "$rw" in ''|*[!0-9]*) rw=80 ;; esac
  if [ -z "$rrow" ]; then
    info "$rk" "no reading of $rwhat on this machine"
    continue
  fi
  read -r ruse rmax <<EOF
$rrow
EOF
  rpct=$(awk -v u="$ruse" -v m="$rmax" 'BEGIN{ printf "%d", (m > 0 ? u * 100 / m : 0) }')
  if [ "$rpct" -ge "$rw" ]; then
    warn "$rk" "$ruse / $rmax $rwhat = ${rpct}%, at or over the ${rw}% line — when it fills no session can open a file or a pane and the whole machine stalls (EPIC #1291 ④)"
  else
    pass "$rk" "$ruse / $rmax $rwhat (${rpct}%)"
  fi
done

# --- codex CLI version vs the rollout format fleet reads (issue #1079) ---
# fleet reads a Codex worker's context% out of Codex's session file (rollout),
# an upstream INTERNAL format verified only on the versions pinned in
# bin/fleet-codex-runtime.py (SUPPORTED_ROLLOUT_VERSIONS). An upgrade can change
# it and the dash would show a wrong number with no error anywhere — so name the
# drift here. Cross-platform, so it sits OUTSIDE the macOS-only host section
# below (and after _gconf_val is defined). Not installed = INFO (Codex is
# optional). WARN, not FAIL: a newer Codex may well be compatible; the line says
# how to pin and how to silence it (FLEET_CODEX_VERSION_CHECK=0).
cvchk="${FLEET_CODEX_VERSION_CHECK:-$(_gconf_val FLEET_CODEX_VERSION_CHECK)}"
cvrt="$(dirname "$0")/fleet-codex-runtime.py"
if [ "$cvchk" != 0 ]; then
  if ! command -v codex >/dev/null 2>&1; then
    info codex "not installed — optional (FLEET_AGENT=codex workers)"
  elif [ -f "$cvrt" ] && command -v python3 >/dev/null 2>&1; then
    cvout=$(python3 "$cvrt" version-check 2>&1); cvrc=$?
    case "$cvrc" in
      0) pass codex "$cvout" ;;
      1) warn codex "$cvout" ;;
      *) info codex "$cvout" ;;
    esac
  fi
fi

# --- mcp: what each fleet's sessions carry in MCP servers (issue #891) ---------
# An MCP server is per SESSION: every live claude boots its own copy of each one,
# so the cost multiplies by the session count and nothing else put the number on
# screen (measured 2026-09: 76 node/python children, 1.3 GB RSS under the
# sessions, one fleet with no allowlist inheriting the host's whole MCP set).
# One row per fleet: its allowlist (FLEET_MCP_CONFIG, resolved the way a spawn
# resolves it — install fleet.conf, then fleet.settings, then the fleet conf, then
# any repo overlay that sets the key; see bin/fleet-claude.sh) and, when its tmux
# server is up, what its live claude processes carry right now: the direct
# children of each claude that are not a tool shell, their whole subtree counted
# (npm exec → node). Unset allowlist → WARN, the only counted verdict; the census
# is a number, never a fault. Read-only: changes no config. Cross-platform (ps +
# tmux only), so it sits outside the macOS host section. FLEET_DOCTOR_MCP=0
# (env or fleet.settings) silences it.
mcpchk="${FLEET_DOCTOR_MCP:-$(_gconf_val FLEET_DOCTOR_MCP)}"
if [ "$mcpchk" != 0 ] && [ -d "$conf_dir" ] && [ -n "$(_fleet_confs "$conf_dir")" ]; then
  mcp_inst="$(dirname "$0")/../fleet.conf"
  # _mcp_eff <fleet conf> [overlay] → the effective FLEET_MCP_CONFIG (a bash
  # subshell: confs are shell, and an inline-JSON value's quotes must survive).
  _mcp_eff() {
    bash -c 'unset FLEET_MCP_CONFIG
      for f in "$@"; do [ -f "$f" ] && . "$f" >/dev/null 2>&1; done
      printf "%s" "${FLEET_MCP_CONFIG-}"' _ "$mcp_inst" "$conf_dir/fleet.settings" "$conf_dir/fleet.conf" "$@" 2>/dev/null
  }
  # _mcp_count <value> → how many servers it allows ("?" if unreadable).
  _mcp_count() {
    [ "$1" = none ] && { echo 0; return; }
    python3 - "$1" 2>/dev/null <<'PY' || echo '?'
import json, os, sys
v = sys.argv[1].strip()
d = json.loads(v) if v.startswith('{') else json.load(open(os.path.expanduser(v)))
print(len(d.get('mcpServers') or {}))
PY
  }
  # Servers every unlisted session inherits: ~/.claude.json's user-scope set
  # (plugin and remote connectors come on top and are not counted here).
  mcp_host=$(python3 - "$HOME/.claude.json" 2>/dev/null <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1])).get('mcpServers') or {}))
PY
)
  [ -n "$mcp_host" ] || mcp_host='?'
  # One process snapshot for every fleet: pid ppid rss(KB) comm (comm may hold spaces).
  mcp_ps=$(ps -Ao pid=,ppid=,rss=,comm= 2>/dev/null)
  mcp_ts=0; mcp_tp=0; mcp_tk=0
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    case "$cf" in */fleets/*/conf) sess=${cf%/conf}; sess=${sess##*/} ;; *) sess=$(basename "$cf" .conf) ;; esac
    # allowlist: the fleet's own value, then each repo overlay that sets the key.
    mv=$(_mcp_eff "$cf")
    unl=""; lst=""
    if [ -z "$mv" ]; then unl="fleet"; else lst="$(_mcp_count "$mv") server(s) via FLEET_MCP_CONFIG=$mv"; fi
    for ov in "$conf_dir/fleets/$sess/repos"/*.conf; do
      [ -f "$ov" ] && _conf_has "$ov" FLEET_MCP_CONFIG || continue
      ovn=$(basename "$ov" .conf); ovv=$(_mcp_eff "$cf" "$ov")
      if [ -z "$ovv" ]; then unl="${unl:+$unl, }repo $ovn"
      else lst="${lst:+$lst; }repo $ovn: $(_mcp_count "$ovv") server(s)"; fi
    done
    # live census: this fleet's panes → the claude in each → its non-shell children.
    live=""
    if tmux -L "$sess" has-session -t "$sess" 2>/dev/null; then
      pids=$(tmux -L "$sess" list-panes -s -t "$sess" -F '#{pane_pid}' 2>/dev/null | tr '\n' ' ')
      live=$(printf '%s\n' "$mcp_ps" | awk -v roots="$pids" '
        function base(c) { sub(/^.*\//, "", c); return c }
        function isclaude(c) { return base(c) == "claude" || c ~ /\/claude\/versions\// }
        function isshell(c,  b) { b = base(c); sub(/^-/, "", b)
          return b ~ /^(sh|bash|zsh|dash|fish|caffeinate|claude)$/ }
        function sub_tree(p,  i) { np++; rss += r[p]; for (i = 1; i <= nk[p]; i++) sub_tree(k[p, i]) }
        function find(p,  i, j) {
          if (isclaude(c[p])) { ns++
            for (i = 1; i <= nk[p]; i++) { j = k[p, i]; if (!isshell(c[j])) { nsrv++; sub_tree(j) } }
            return }
          for (i = 1; i <= nk[p]; i++) find(k[p, i])
        }
        { pid = $1; pp = $2; r[pid] = $3; $1 = $2 = $3 = ""; sub(/^ +/, ""); c[pid] = $0
          nk[pp]++; k[pp, nk[pp]] = pid }
        END { n = split(roots, rt, " "); for (i = 1; i <= n; i++) find(rt[i])
              printf "%d %d %d %d\n", ns, nsrv, np, rss }')
    fi
    ltxt=""
    if [ -n "$live" ]; then
      read -r lns lnv lnp lnk <<EOF2
$live
EOF2
      ltxt="; live: $lns claude session(s) carry $lnp MCP process(es) ($lnv server(s)), $((lnk/1024)) MB RSS"
      mcp_ts=$((mcp_ts+lns)); mcp_tp=$((mcp_tp+lnp)); mcp_tk=$((mcp_tk+lnk))
    fi
    if [ -n "$unl" ]; then
      warn mcp "$sess: no MCP allowlist ($unl) — its sessions inherit every MCP server in ~/.claude.json ($mcp_host, plus plugins + remote connectors), one copy per session (bin/fleet-claude.sh, FLEET_MCP_CONFIG)${lst:+; $lst}$ltxt. Fix: FLEET_MCP_CONFIG=~/.claude/fleet/conf/mcp-worker.json in the fleet conf. Silence: FLEET_DOCTOR_MCP=0"   # wrap-ok: a message, not a launch
    else
      pass mcp "$sess: $lst$ltxt"
    fi
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
  [ "$mcp_ts" -gt 0 ] && info mcp "all fleets: $mcp_ts claude session(s) carry $mcp_tp MCP process(es), $((mcp_tk/1024)) MB RSS"
fi

# --- host: a machine that works only for its sessions (EPIC #1074) --------------
# Checks on the HOST itself — things that burn this machine's CPU/IO on work no
# session asked for, which no other line here can see. macOS only: the whole
# section is skipped on Linux, silently (there is no Spotlight, no pmset). Each
# line is report-only — the doctor NEVER changes system state; it names the
# command and says how to silence the line. Later members append rows here and
# sections to docs/HOST.md; pinned by bin/fleet-doctor-host-selftest.sh. The
# `network` row (#1081) sits just after the section: Linux has that fact too.
if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then

# 1. spotlight (issue #1075). On 2026-09-23 the busiest process on the fleet's
#    Mac mini was not a session but mds_stores: 71 CPU-minutes in 4.5h of uptime,
#    74% at the instant, re-indexing worktrees that live for minutes. An unattended
#    host has nobody to search it, so the first host recommendation is to turn
#    indexing off (docs/HOST.md#spotlight). WARN, not FAIL: it is a cost, not a
#    broken install. FLEET_DOCTOR_SPOTLIGHT=0 (env or fleet.settings) silences it.
spchk="${FLEET_DOCTOR_SPOTLIGHT:-$(_gconf_val FLEET_DOCTOR_SPOTLIGHT)}"
if [ "$spchk" != 0 ] && command -v mdutil >/dev/null 2>&1; then
  spvol=/System/Volumes/Data; [ -d "$spvol" ] || spvol=/
  spout=$(mdutil -s "$spvol" 2>&1 | tr '\n' ' ')
  case "$spout" in
    *"Indexing enabled"*)
      warn spotlight "Spotlight is still indexing $spvol — an unattended host should turn it off: \`sudo mdutil -a -i off\` (undo: \`sudo mdutil -a -i on\`; see docs/HOST.md#spotlight). Silence: FLEET_DOCTOR_SPOTLIGHT=0" ;;
    *disabled*)
      pass spotlight "Spotlight indexing off on $spvol" ;;
    *)
      info spotlight "could not read Spotlight state for $spvol (mdutil -s: $(printf '%s' "$spout" | cut -c1-120)) — see docs/HOST.md#spotlight" ;;
  esac
fi

# 2. wtroot — the lighter alternative to turning Spotlight off host-wide.
# FLEET_WORKTREE_ROOT exists to get the fleet's short-lived worktrees (and their
# dependency trees) out of the Spotlight index; Spotlight skips a directory whose
# name ends in `.noindex`, so a root without that suffix is moved but still indexed.
# Advice, not a fault — some roots are excluded another way (Privacy list, a volume
# with indexing off) — so it is INFO. Unset = the sibling layout, nothing to say.
if [ -d "$conf_dir" ]; then
  groot=$(_gconf_val FLEET_WORKTREE_ROOT)
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    case "$cf" in */fleets/*/conf) sess=${cf%/conf}; sess=${sess##*/} ;; *) sess=$(basename "$cf" .conf) ;; esac
    wroot=$(_conf_val "$cf" FLEET_WORKTREE_ROOT)   # per-fleet, else the global line
    [ -n "$wroot" ] || wroot="$groot"
    [ -n "$wroot" ] || continue
    case "${wroot%/}" in
      *.noindex) pass wtroot "$sess: worktrees under $wroot (Spotlight skips *.noindex)" ;;
      *) info wtroot "$sess: FLEET_WORKTREE_ROOT=$wroot does not end in .noindex — Spotlight still indexes every worktree there; rename it (e.g. ~/projects/.fleet-worktrees.noindex) unless it is excluded another way" ;;
    esac
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
fi

# 3. nofile (issue #1080). launchd starts every job at the machine's default file
#    limit — 256 on macOS unless someone raised it — and a long-lived network
#    daemon that hits it just stops receiving events, with nothing in any log.
#    The fleet's own always-on daemons (hub, webhook, spinner) carry
#    NumberOfFiles 65536 in their plists and log `nofile=<n>` at every start, so
#    this row is ADVICE for every other LaunchAgent on the host: INFO, uncounted.
if command -v launchctl >/dev/null 2>&1; then
  nfsoft=$(launchctl limit maxfiles 2>/dev/null | awk '$1 == "maxfiles" { print $2; exit }')
  case "$nfsoft" in
    ''|*[!0-9]*) ;;   # unreadable (or "unlimited"): nothing useful to say
    *) if [ "$nfsoft" -lt 4096 ]; then
         info nofile "system default file limit is $nfsoft (launchctl limit maxfiles); fleet daemons raise their own to 65536 (see nofile= in their logs), other LaunchAgents: docs/HOST.md#nofile"
       else
         pass nofile "system default file limit is $nfsoft (launchctl limit maxfiles)"
       fi ;;
  esac
fi

# 4. sleep (issue #1076). A host that sleeps is a host whose sessions stop
#    mid-turn, whose daemons miss their ticks and whose SSH drops — with nobody
#    at the keyboard to wake it. `pmset -g` prints the ACTIVE power profile; its
#    `sleep` line is idle-minutes-until-sleep (0 = never). Non-zero → WARN naming
#    the fix, `sudo pmset -a sleep 0`, with the two companions that keep an
#    unattended box coming back (autorestart 1 after a power cut, womp 1 for
#    wake-on-LAN) read from the same output and shown on the row. Report-only:
#    the doctor never runs `pmset -a`. FLEET_DOCTOR_SLEEP=0 silences it.
slchk="${FLEET_DOCTOR_SLEEP:-$(_gconf_val FLEET_DOCTOR_SLEEP)}"
if [ "$slchk" != 0 ] && command -v pmset >/dev/null 2>&1; then
  pmout=$(pmset -g 2>/dev/null)
  slval=$(printf '%s\n' "$pmout" | awk '$1=="sleep"{print $2; exit}')
  arval=$(printf '%s\n' "$pmout" | awk '$1=="autorestart"{print $2; exit}')
  wompval=$(printf '%s\n' "$pmout" | awk '$1=="womp"{print $2; exit}')
  slnote=""
  [ -n "$arval" ] && slnote="$slnote autorestart=$arval"
  [ -n "$wompval" ] && slnote="$slnote womp=$wompval"
  [ -n "$slnote" ] && slnote=" (${slnote# })"
  slhint=""
  [ "$arval" = 0 ] && slhint="$slhint; autorestart is 0 — after a power cut the box stays down: \`sudo pmset -a autorestart 1\`"
  [ "$wompval" = 0 ] && slhint="$slhint; womp is 0 — no wake-on-LAN: \`sudo pmset -a womp 1\`"
  case "$slval" in
    0)
      pass sleep "never sleeps: pmset sleep 0$slnote$slhint${slhint:+ (see docs/HOST.md#headless)}" ;;
    ''|*[!0-9]*)
      info sleep "could not read the sleep setting (pmset -g: $(printf '%s' "$pmout" | tr '\n' ' ' | cut -c1-120)) — see docs/HOST.md#headless" ;;
    *)
      warn sleep "host sleeps after $slval min idle — an unattended host should never sleep: \`sudo pmset -a sleep 0 autorestart 1 womp 1\` (undo: \`sudo pmset -a sleep $slval\`; see docs/HOST.md#headless)$slnote. Silence: FLEET_DOCTOR_SLEEP=0" ;;
  esac
fi

# 5. siri (issue #1076). Siri on keeps a family of helpers resident for the
#    console user — sirittsd, siriactionsd, assistantd, siriknowledged, Siri AI —
#    ~400 MB measured on 2026-09-24 on a host nobody talks to. It is a per-user
#    setting: `defaults read com.apple.assistant.support "Assistant Enabled"` is
#    1 while on; 0, or no key at all (never enabled), while off. INFO, not WARN:
#    it costs memory, not CPU, and the fix is a Settings toggle
#    (docs/HOST.md#headless). Read-only — never `defaults write`.
#    FLEET_DOCTOR_SIRI=0 silences it.
sichk="${FLEET_DOCTOR_SIRI:-$(_gconf_val FLEET_DOCTOR_SIRI)}"
if [ "$sichk" != 0 ] && command -v defaults >/dev/null 2>&1; then
  sival=$(defaults read com.apple.assistant.support "Assistant Enabled" 2>/dev/null | tr -d '[:space:]')
  case "$sival" in
    1)
      info siri "Siri is on — its helpers (sirittsd, siriactionsd, assistantd, Siri AI) stay resident (~400 MB for the speech service alone) on a host nobody talks to; turn it off: System Settings → Apple Intelligence & Siri → Siri off (see docs/HOST.md#headless). Silence: FLEET_DOCTOR_SIRI=0" ;;
    0)
      pass siri "Siri off" ;;
    '')
      pass siri "Siri off (never enabled — no Assistant Enabled key)" ;;
    *)
      info siri "could not read the Siri setting (Assistant Enabled=$sival) — see docs/HOST.md#headless" ;;
  esac
fi

# 6. icloud (issue #1076). Signed into iCloud, the host runs the sync daemons for
#    an account no session uses: bird (iCloud Drive), cloudd (CloudKit) and
#    fileproviderd (the File Provider host iCloud Drive syncs through). On
#    2026-09-24 contactsd alone had 4.5 CPU-minutes syncing a server's contacts.
#    INFO, not WARN: a signed-in account can be deliberate (Find My, Screen
#    Sharing sign-in), and signing out is a Settings decision
#    (docs/HOST.md#headless). The row names which daemons are alive so a partial
#    sign-out (iCloud Drive off, account kept) reads as progress.
#    FLEET_DOCTOR_ICLOUD=0 silences it.
icchk="${FLEET_DOCTOR_ICLOUD:-$(_gconf_val FLEET_DOCTOR_ICLOUD)}"
if [ "$icchk" != 0 ] && command -v pgrep >/dev/null 2>&1; then
  iclive=""
  for icd in bird cloudd fileproviderd; do
    pgrep -x "$icd" >/dev/null 2>&1 && iclive="$iclive $icd"
  done
  if [ -n "$iclive" ]; then
    info icloud "iCloud sync daemons resident:$iclive — they sync an account no session uses; sign out of iCloud, or turn off iCloud Drive + Contacts: System Settings → Apple Account → iCloud (see docs/HOST.md#headless). Silence: FLEET_DOCTOR_ICLOUD=0"
  else
    pass icloud "no iCloud sync daemon resident (bird / cloudd / fileproviderd)"
  fi
fi

fi  # Darwin host section

# 7. network (issue #1081). The one host row that is NOT macOS-only: Linux reads
#    the same fact off `ip route`. On 2026-09-23 the fleet's Mac mini had been on
#    wired AND Wi-Fi for weeks — two interfaces on one subnet, two default routes
#    to one gateway — so a connection could come in on one interface and its
#    replies leave by the other: "connected, but nothing answers", from the phone
#    and the laptop alike. The signature is one gateway reached as the default
#    route through 2+ interfaces. A `link#N` / interface-only default (a VM
#    bridge, a VPN utun) names no gateway and is not counted. WARN names the Wi-Fi
#    switch-off (the wired link is the one an unattended host keeps). Read-only.
#    FLEET_DOCTOR_NETWORK=0 silences it.
nwchk="${FLEET_DOCTOR_NETWORK:-$(_gconf_val FLEET_DOCTOR_NETWORK)}"
if [ "$nwchk" != 0 ]; then
  nwos=$(uname -s 2>/dev/null); nwroutes=""
  # One "<gateway> <interface>" line per default route that names an IPv4 gateway.
  if [ "$nwos" = Darwin ] && command -v netstat >/dev/null 2>&1; then
    nwroutes=$(netstat -rn -f inet 2>/dev/null | awk '$1=="default" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $2, $4 }')
  elif command -v ip >/dev/null 2>&1; then
    nwroutes=$(ip -4 route show default 2>/dev/null | awk '{ g=""; d=""; for (i=1; i<NF; i++) { if ($i=="via") g=$(i+1); if ($i=="dev") d=$(i+1) } if (g != "" && d != "") print g, d }')
  fi
  nwroutes=$(printf '%s\n' "$nwroutes" | awk 'NF==2' | sort -u)
  # The first gateway reached through 2+ interfaces, and those interfaces.
  nwdup=$(printf '%s\n' "$nwroutes" | awk 'NF==2 { n[$1]++; ifs[$1]=ifs[$1] " " $2 } END { for (g in n) if (n[g] > 1) { print g ifs[g]; exit } }')
  if [ -n "$nwdup" ]; then
    nwgw=${nwdup%% *}; nwifs=${nwdup#* }
    nwwifi=""
    if [ "$nwos" = Darwin ]; then
      nwwifi=$(networksetup -listallhardwareports 2>/dev/null | awk '/^Hardware Port: (Wi-Fi|AirPort)$/ { w=1; next } w && /^Device:/ { print $2; exit }')
    else
      for nwif in $nwifs; do case "$nwif" in wl*) nwwifi=$nwif; break ;; esac; done
    fi
    case " $nwifs " in *" $nwwifi "*) ;; *) nwwifi="" ;; esac
    if [ -n "$nwwifi" ] && [ "$nwos" = Darwin ]; then
      nwfix="keep only the wired link: \`networksetup -setairportpower $nwwifi off\` (undo: \`networksetup -setairportpower $nwwifi on\`)"
    elif [ -n "$nwwifi" ]; then
      nwfix="keep only the wired link: \`nmcli radio wifi off\` (undo: \`nmcli radio wifi on\`)"
    else
      nwfix="keep only one of them connected"
    fi
    warn network "default route to $nwgw through $(printf '%s' "$nwifs" | sed 's/ / + /g') — two interfaces on one subnet: replies can leave by a different interface than the connection came in on (\"connected, but nothing answers\"); $nwfix; see docs/HOST.md#network. Silence: FLEET_DOCTOR_NETWORK=0"
  elif [ -n "$nwroutes" ]; then
    nwn=$(printf '%s\n' "$nwroutes" | grep -c .)
    pass network "$nwn default route(s), no gateway shared by two interfaces: $(printf '%s\n' "$nwroutes" | awk '{ printf "%s%s via %s", (NR>1 ? ", " : ""), $1, $2 }')"
  fi
fi

# --- ingress: is the PUBLIC SSH entry reachable from OUTSIDE, and is it this host? (#1196) --
# Opening victor's login (EPIC #1190) the public entry could not be verified from
# this machine or from a laptop beside it — NAT hairpin, same subnet — and only a
# box on the far side of the internet showed that the entry was port 22022. So
# this row asks a PROBE host — FLEET_SSH_PROBE_HOST, an ssh destination that
# reaches this machine only over the public internet (an alias in ~/.ssh/config
# with key auth) — to `ssh-keyscan` the public entry FLEET_SSH_PUBLIC_HOST :
# FLEET_SSH_PUBLIC_PORT (the two keys the welcome letter uses, #1195) and compares
# the ed25519 host key it gets with the one sshd presents on 127.0.0.1 here: the
# entry is open AND lands on THIS machine, not on whatever the router forwards
# to today. Unset host or probe ⇒ no row (nothing to check). WARN, never FAIL: a
# closed entry, one forwarded elsewhere, or a probe that cannot be reached is a
# condition of the network, not a broken install. Every ssh / keyscan is bounded
# — ConnectTimeout + keyscan -T under one wall-clock cap (`timeout`, else a perl
# alarm armed in the child BEFORE the exec, which the kernel keeps across execve:
# the #697 pattern, so a stalled link cannot stall the doctor) — and the verdict
# is cached in global/ingress.probe: a PASS for FLEET_INGRESS_TTL (1h), a WARN
# for at most 5 min so a fix shows on the next run; FLEET_INGRESS_TTL=0 re-probes
# now. Cross-platform (macOS + Linux). FLEET_DOCTOR_INGRESS=0 silences it.
igchk="${FLEET_DOCTOR_INGRESS:-$(_gconf_val FLEET_DOCTOR_INGRESS)}"
ighost="${FLEET_SSH_PUBLIC_HOST:-$(_gconf_val FLEET_SSH_PUBLIC_HOST)}"
igport="${FLEET_SSH_PUBLIC_PORT:-$(_gconf_val FLEET_SSH_PUBLIC_PORT)}"; igport=${igport:-22}
igprobe="${FLEET_SSH_PROBE_HOST:-$(_gconf_val FLEET_SSH_PROBE_HOST)}"
# _ig_bounded <secs> <cmd…> — run <cmd> under a hard wall-clock cap; 124 on expiry.
_ig_bounded() {
  _igb=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$_igb" "$@"
  elif command -v perl >/dev/null 2>&1; then
    # The child arms its own alarm before exec (kept across execve); perl waits
    # with a one-second-later backstop and exits 124 itself, so the shell never
    # sees a signalled child (bash would print "Alarm clock" to stderr).
    perl -e '
      my $t = shift @ARGV; my $pid = fork; defined $pid or exit 127;
      if ($pid == 0) { alarm $t; exec @ARGV; exit 127 }
      $SIG{ALRM} = sub { kill "TERM", $pid; exit 124 }; alarm $t + 1;
      waitpid $pid, 0; my $st = $?; exit(($st & 127) ? 124 : $st >> 8)' "$_igb" "$@"
  else "$@"; fi
}
if [ "$igchk" != 0 ] && [ -n "$ighost" ] && [ -n "$igprobe" ]; then
  igttl="${FLEET_INGRESS_TTL:-$(_gconf_val FLEET_INGRESS_TTL)}"; case "$igttl" in ''|*[!0-9]*) igttl=3600 ;; esac
  igto="${FLEET_INGRESS_TIMEOUT:-$(_gconf_val FLEET_INGRESS_TIMEOUT)}"; case "$igto" in ''|*[!0-9]*|0) igto=20 ;; esac
  igkey="$ighost:$igport@$igprobe"; igcache="$conf_dir/global/ingress.probe"
  ignow=$(date +%s); igst=''; igmsg=''; igage=''
  # 1. The cache: line 1 `<epoch> <host:port@probe> <pass|warn>`, line 2 the
  #    message. Honoured for the same entry + probe only, inside its TTL.
  if [ "$igttl" -gt 0 ] && [ -f "$igcache" ]; then
    igc1=$(sed -n 1p "$igcache" 2>/dev/null)
    igc_ts=${igc1%% *}; igc_rest=${igc1#* }; igc_key=${igc_rest%% *}; igc_st=${igc_rest#* }
    case "$igc_ts" in ''|*[!0-9]*) igc_ts=0 ;; esac
    case "$igc_st" in pass) igc_max=$igttl ;; warn) igc_max=$igttl; [ "$igc_max" -gt 300 ] && igc_max=300 ;; *) igc_max=0 ;; esac
    igc_age=$((ignow - igc_ts))
    if [ "$igc_key" = "$igkey" ] && [ "$igc_age" -ge 0 ] && [ "$igc_age" -lt "$igc_max" ]; then
      igst=$igc_st; igmsg=$(sed -n 2p "$igcache" 2>/dev/null); igage=$igc_age
    fi
  fi
  # 2. No usable cache: probe. Both scans are bounded; a hung link is a WARN, not
  #    a hung doctor.
  if [ -z "$igst" ] && ! printf '%s' "$igport" | grep -Eq '^[0-9]{1,5}$'; then
    igst=warn; igmsg="FLEET_SSH_PUBLIC_PORT is not a port number: '$igport' — fix it in ~/.config/claude-fleet/fleet.settings (prefix+c); nothing probed"
  elif [ -z "$igst" ] && { ! command -v ssh >/dev/null 2>&1 || ! command -v ssh-keyscan >/dev/null 2>&1; }; then
    igst=warn; igmsg="ssh / ssh-keyscan not on PATH — cannot probe the public entry $ighost:$igport from $igprobe; install OpenSSH client tools. Silence: FLEET_DOCTOR_INGRESS=0"
  elif [ -z "$igst" ]; then
    # The key sshd presents HERE: 127.0.0.1 on ssh's own port, else on the public
    # port (a host whose sshd listens on the public port directly, no NAT).
    iglocal=$(_ig_bounded $((igto + 5)) ssh-keyscan -t ed25519 -T 5 127.0.0.1 2>/dev/null | awk '$2=="ssh-ed25519" { print $2, $3; exit }')
    [ -n "$iglocal" ] || [ "$igport" = 22 ] || iglocal=$(_ig_bounded $((igto + 5)) ssh-keyscan -t ed25519 -T 5 -p "$igport" 127.0.0.1 2>/dev/null | awk '$2=="ssh-ed25519" { print $2, $3; exit }')
    # The key the ENTRY presents to the probe host. BatchMode: never a prompt — a
    # probe that wants a password or whose host key is unknown is a WARN naming it.
    igcap=$((igto * 2 + 10))
    igrem=$(_ig_bounded "$igcap" ssh -o BatchMode=yes -o ConnectTimeout="$igto" -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$igprobe" \
      "ssh-keyscan -t ed25519 -T $igto -p $igport $ighost 2>&1" 2>&1); igrc=$?
    igrkey=$(printf '%s\n' "$igrem" | awk '$2=="ssh-ed25519" { print $2, $3; exit }')
    # Everything that is neither a key line nor a keyscan `#` comment is the reason.
    igwhy=$(printf '%s\n' "$igrem" | grep -v '^#' | awk '$2!="ssh-ed25519" && NF' | head -2 | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    [ -n "$igwhy" ] || { [ "$igrc" -eq 124 ] && igwhy="timed out after ${igcap}s"; }
    igfix="check the router / firewall forward for port $igport and that sshd (Remote Login) is on; the probe is \`ssh $igprobe ssh-keyscan -p $igport $ighost\` (docs/HOST.md#ingress). Silence: FLEET_DOCTOR_INGRESS=0"
    if [ -n "$igrkey" ] && [ -z "$iglocal" ]; then
      igst=warn; igmsg="public entry $ighost:$igport answers from $igprobe, but no sshd answers on 127.0.0.1 here (port 22 or $igport) — cannot tell whether that is this host; turn on Remote Login (System Settings → General → Sharing) and re-run. Silence: FLEET_DOCTOR_INGRESS=0"
    elif [ -n "$igrkey" ] && [ "$igrkey" = "$iglocal" ]; then
      igst=pass; igmsg="public entry $ighost:$igport reachable from $igprobe and is THIS host (ed25519 host key matches sshd on 127.0.0.1) — what a newcomer's \`ssh -p $igport <login>@$ighost\` reaches"
    elif [ -n "$igrkey" ]; then
      igst=warn; igmsg="public entry $ighost:$igport answers from $igprobe with a DIFFERENT host key than sshd on 127.0.0.1 — the entry lands on ANOTHER machine (the router forwards port $igport elsewhere?); $igfix"
    elif [ "$igrc" -eq 255 ]; then
      igst=warn; igmsg="probe host $igprobe unreachable (${igwhy:-ssh exit 255}) — nothing can be said about the public entry; fix the probe (a ~/.ssh/config alias with key auth and its host key already known, on a machine OUTSIDE this network) or point FLEET_SSH_PROBE_HOST elsewhere. Silence: FLEET_DOCTOR_INGRESS=0"
    else
      igst=warn; igmsg="public entry $ighost:$igport NOT reachable from $igprobe (${igwhy:-keyscan returned nothing, exit $igrc}) — a newcomer's \`ssh -p $igport <login>@$ighost\` will not connect; $igfix"
    fi
    mkdir -p "$conf_dir/global" 2>/dev/null && printf '%s %s %s\n%s\n' "$ignow" "$igkey" "$igst" "$igmsg" > "$igcache.tmp.$$" 2>/dev/null && mv -f "$igcache.tmp.$$" "$igcache" 2>/dev/null
  fi
  [ -n "$igage" ] && igmsg="$igmsg (cached ${igage}s ago; FLEET_INGRESS_TTL=0 re-probes)"
  if [ "$igst" = pass ]; then pass ingress "$igmsg"; else warn ingress "$igmsg"; fi
fi

# --- status line (optional: conf/statusline.sh is jq-gated) ---
# The Claude Code status line (conf/statusline.sh, wired install-time into
# settings.json's statusLine — docs/INSTALL.md step 8b) prints nothing since #1452
# and stamps the context % / model / effort / rate limits onto the pane's window;
# while the key is there Claude Code keeps one blank row at the bottom of every
# pane. Since #1459 the fleet mod feeds the same script from inside the session,
# so a login whose every Claude window carries the mod can drop the key
# (`bin/fleet-statusline.sh off`) — this row says where that stands: how many
# Claude windows the mod feeds, and (statusLine off) whether any is left with no
# reporter at all. The Claude path exits silently without jq, so a wired-but-
# jq-less status line stamps nothing — soft-warn (never fail). A personal status
# line (not ours) is never flagged.
settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
sl_sum=$(bash "$(dirname "$0")/fleet-statusline.sh" status --porcelain 2>/dev/null | head -1)
case "$sl_sum" in
  wired=*)
    sl_tab=$(printf '\t')
    sl_kind=${sl_sum#wired=}; sl_kind=${sl_kind%%"$sl_tab"*}
    sl_n=$(printf '%s' "$sl_sum" | tr '\t' '\n' | sed -n 's/^windows=\([0-9]*\)$/\1/p')
    sl_fed=$(printf '%s' "$sl_sum" | tr '\t' '\n' | sed -n 's/^fed=\([0-9]*\)$/\1/p')
    sl_blind=$(printf '%s' "$sl_sum" | tr '\t' '\n' | sed -n 's/^blind=\([0-9]*\)$/\1/p')
    sl_mod=${sl_sum##*mod=}
    case "$sl_kind" in
      fleet)
        if ! command -v jq >/dev/null 2>&1; then
          warn statusln "settings.json wires statusline.sh but jq is missing — the Claude path stamps nothing (\`brew install jq\`); the mod feeds ${sl_fed:-0}/${sl_n:-0} windows"
        elif [ "$sl_mod" = on ] && [ "${sl_blind:-1}" = 0 ]; then
          pass statusln "wired (one blank row per pane) · the mod feeds all ${sl_n:-0} Claude windows — \`fleet-statusline.sh off\` 省掉底部空行"
        else
          pass statusln "wired (one blank row per pane) · the mod feeds ${sl_fed:-0}/${sl_n:-0} Claude windows — ${sl_blind:-0} would go blind if turned off"
        fi ;;
      none)
        if [ "${sl_blind:-0}" -gt 0 ] && [ "$sl_mod" = on ]; then
          warn statusln "statusLine off, but ${sl_blind} Claude window(s) have no mod heartbeat — no context %, no @model, no auto-handoff there (cycle them, or \`fleet-statusline.sh on\`)"
        elif [ "$sl_mod" = on ]; then
          pass statusln "off — the mod feeds the bus (${sl_fed:-0}/${sl_n:-0} Claude windows); no blank row at the bottom"
        fi ;;
    esac ;;
  *)
    # fleet-statusline.sh missing (an older install): the pre-#1459 check.
    if [ -f "$settings" ] && grep -q 'statusline\.sh' "$settings" 2>/dev/null; then
      if command -v jq >/dev/null 2>&1; then
        pass statusln "wired + jq present (the measurement bus behind the pane header)"
      else
        warn statusln "settings.json wires statusline.sh but jq is missing — it exits silently, so nothing is stamped (\`brew install jq\`)"
      fi
    fi ;;
esac

# --- hook table: every fleet hook wired exactly once (issue #818) ---
# The sync used to append the table and de-dup on the command STRING, so a
# changed interpreter path left the old guard beside the new one and every Bash /
# Edit / Artifact call ran it twice — found only because a worker happened to
# look. The identity rule — (event, matcher, script basename) — lives in ONE
# place, bin/fleet-hooks-merge.py, which both the sync merge and this line use.
# With the plugin installed the plugin wires the table, so any fleet entry left in
# settings.json is itself the duplicate.
_hm="$(dirname "$0")/fleet-hooks-merge.py"
if [ -f "$_hm" ] && command -v python3 >/dev/null 2>&1; then
  _hplug=''; [ "${plug:-0}" = 1 ] && _hplug=--plugin
  _hout="$(python3 "$_hm" check $_hplug --settings "$settings" 2>&1)"; _hrc=$?
  if [ "$_hrc" = 0 ]; then
    pass hooks "${_hout#ok }"
  else
    warn hooks "settings.json hook table off — $(printf '%s' "$_hout" | awk '{print $1, $2, $3}' | paste -sd ';' - | sed 's/;/; /g') (fix: python3 $_hm merge)"
  fi
fi

# --- default Claude settings: what the sync fills on every login (issue #1558) ---
# conf/claude-settings.default.json is the ONE default Claude configuration for a
# managed machine's logins: the sync (fleet-install-apply.sh's `settings` pass)
# fills each key a login lacks into ~/.claude/settings.json
# (permissions.defaultMode=bypassPermissions, effort, output style, theme, …) and
# into Claude Code's GLOBAL config ~/.claude.json (leftArrowOpensAgents=false,
# #1528 — the only place that key is read). Fill only: a value the login set is
# never overwritten, and ~/.claude/settings.fleet-override.json lists keys never
# written at all. This row counts the keys that differ from the defaults — on
# 2026-10-04 m4's verkyyi login had 8 (no defaultMode, so every spawned session
# ran in auto mode while m5's ran bypass). FLEET_KEEP_AGENTS_KEY=1 (env or
# fleet.settings) leaves leftArrowOpensAgents to the login.
_dj="$(dirname "$0")/../conf/claude-settings.default.json"
if [ -f "$_hm" ] && [ -f "$_dj" ] && command -v python3 >/dev/null 2>&1; then
  _kcfg="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
  _kkeep="${FLEET_KEEP_AGENTS_KEY:-$(_gconf_val FLEET_KEEP_AGENTS_KEY)}"
  _kskip=''; [ "$_kkeep" = 1 ] && _kskip='--skip leftArrowOpensAgents'
  # shellcheck disable=SC2086  # $_kskip is two words or none
  _sout="$(python3 "$_hm" defaults-check --defaults "$_dj" --settings "$settings" --config "$_kcfg" $_kskip 2>&1)"; _src=$?
  if [ "$_src" = 0 ]; then
    pass settings "${_sout#ok } (conf/claude-settings.default.json)"
  else
    warn settings "$(printf '%s\n' "$_sout" | head -1) — $(printf '%s\n' "$_sout" | sed '1d; s/  */ /g' | paste -sd ';' - | sed 's/;/; /g') (fix: a missing key is filled by the next sync, or now: python3 $_hm defaults; a differing key is this login's — keep it by listing it in $(dirname "$settings")/settings.fleet-override.json, or delete it to take the default)"
  fi
fi

# --- Claude Code's first-run questions answered (issue #2401) ---
# A login's first Claude start asks things a fleet pane has nobody to answer: the
# onboarding, and on 2.1.29x "Make auto mode your default permission mode?" — on
# 2026-10-08 the new `verky` logins on m5 and m4 sat on that one for good, their
# `guide` session a stuck row. The answers are two ~/.claude.json keys
# (hasCompletedOnboarding, hasSeenAutoDefaultNudge); a new login gets them from
# fleet-login-bootstrap.sh's onboard step before its first start, an existing one
# from the settings pass above (which never creates a .claude.json Claude did not
# write — so a login with none at all is named here). Codex's two (the update
# picker, the trust question) are answered by fleet-codex.sh on every launch.
_od="$(dirname "$0")/fleet-onboard-defaults.py"
if [ -f "$_od" ] && [ -f "$_dj" ] && command -v python3 >/dev/null 2>&1; then
  _fout="$(python3 "$_od" --check "${CLAUDE_CONFIG_DIR:-$HOME}" 2>&1)"; _frc=$?
  if [ "$_frc" = 0 ]; then
    pass firstrun "${_fout#ok }"
  else
    warn firstrun "$(printf '%s\n' "$_fout" | head -1)$(printf '%s\n' "$_fout" | sed -n '2,$p' | sed 's/  */ /g' | paste -sd ';' - | sed 's/^/ — /; s/;/; /g') (fix: python3 $_od \$HOME — fills only what is missing)"
  fi
fi

# --- agent defaults: ONE MCP + Codex-posture + doc-block package for BOTH agents (issue #1559) ---
# conf/agent-defaults/ is the one source the sync (fleet-install-apply.sh's `agents`
# pass) fills into every login: the user-scope MCP servers context7 / playwright /
# github / fetch (~/.claude.json AND every known $CODEX_HOME/config.toml), Codex's
# approval_policy=never / sandbox_mode=danger-full-access / model_reasoning_effort,
# and one fleet block in ~/.claude/CLAUDE.md / $CODEX_HOME/AGENTS.md; the repo's
# skills/ are counted here (the skills passes install them). Fill only — an item
# listed in ~/.config/claude-fleet/agent-overrides.json is never written and stops
# counting. 2026-10-04 reading: 15 missing across m5 + m4 (Claude 4 each; Codex m5
# 1, m4 6). A Codex home that does not exist reads n/a — Codex is not set up on
# that login. The trailing hint names what a default server still needs on PATH:
# `fetch` runs on uvx (`brew install uv`), `github` on github-mcp-server
# (`brew install github-mcp-server`; the npx server stands in until then).
_ad="$(dirname "$0")/fleet-agent-defaults.py"
if [ -f "$_ad" ] && [ -d "$(dirname "$0")/../conf/agent-defaults" ] && command -v python3 >/dev/null 2>&1; then
  _aout="$(FLEET_CONF_DIR="$conf_dir" python3 "$_ad" check --root "$(dirname "$0")/.." \
             --claude-config "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" \
             --claude-md "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CLAUDE.md" --claude-skills "$skills_dir" \
             --override "$conf_dir/agent-overrides.json" 2>&1)"; _arc=$?
  _arun=''
  command -v uvx >/dev/null 2>&1 || command -v pipx >/dev/null 2>&1 || _arun='fetch needs uvx (brew install uv)'
  command -v github-mcp-server >/dev/null 2>&1 || _arun="${_arun:+$_arun; }github runs via npx until brew install github-mcp-server"
  _ahead="$(printf '%s\n' "$_aout" | head -1)"
  # The team layer (issue #1726): the version applied here, from
  # agent-effective.json — nothing at all when this login never had one.
  _ateam=''
  [ -f "$(dirname "$0")/fleet-agent-team.py" ] \
    && _ateam="$(FLEET_CONF_DIR="$conf_dir" python3 "$(dirname "$0")/fleet-agent-team.py" status --short 2>/dev/null)"
  [ -n "$_ateam" ] && _ahead="$_ahead · $_ateam"
  case "$_arc" in
    0) pass agents "${_ahead#ok } (conf/agent-defaults)${_arun:+ — $_arun}" ;;
    1) warn agents "$_ahead — $(printf '%s\n' "$_aout" | sed '1d; s/^missing *//; s/  */ /g' | paste -sd ';' - | sed 's/;/; /g') (fix: the next sync fills them, or now: python3 $_ad apply; keep one for this login by listing it in $conf_dir/agent-overrides.json)${_arun:+ — $_arun}" ;;
    *) warn agents "fleet-agent-defaults.py check: $(printf '%s\n' "$_aout" | tail -1)" ;;
  esac
fi

# --- team: the hub's team version vs this login's (issue #1899) ---
# The node agent runs fleet-agent-team.py sync on the hub's push and records it;
# the row reads 入口 v<N> · 本机 v<M> · 拉到 <when>. WARN when the hub pushed a
# version this login has not applied for FLEET_TEAM_PUSH_WARN_SECS. No team layer
# here (never fetched, never pushed) → no row at all.
if [ -f "$(dirname "$0")/fleet-agent-team.py" ] && command -v python3 >/dev/null 2>&1; then
  _tline="$(FLEET_CONF_DIR="$conf_dir" python3 "$(dirname "$0")/fleet-agent-team.py" status --team 2>/dev/null)"; _trc=$?
  case "$_trc" in
    0) pass team "$_tline" ;;
    1) warn team "$_tline (fix: python3 $(dirname "$0")/fleet-agent-team.py sync; the node agent retries every beat)" ;;
  esac
fi

# --- agentcfg: the configuration a session is launched with (issue #1782) ---
# bin/fleet-claude.sh / fleet-codex.sh compose fleet default < team < local at
# every launch and stamp the fingerprint as @agent_cfg. A LOCKED item
# (conf/agent-locked.list: the mod, the fleet hooks, the fleet's MCP servers) that
# this login overrides is listed here: under FLEET_AGENT_LOCK=warn (the default)
# the login's value is used, under enforce it is ignored at launch. Prints the
# fingerprint a fresh Claude session gets, the one global/agent-cfg.expected holds.
_at="$(dirname "$0")/fleet-agent-team.py"
if [ -f "$_at" ] && command -v python3 >/dev/null 2>&1; then
  _alock="${FLEET_AGENT_LOCK:-$(_gconf_val FLEET_AGENT_LOCK)}"
  _amod="${FLEET_MOD:-$(_gconf_val FLEET_MOD)}"
  _amodf=''; [ "$_amod" = 0 ] && _amodf=--mod-off
  # shellcheck disable=SC2086  # $_amodf is one word or none
  _cout="$(FLEET_CONF_DIR="$conf_dir" python3 "$_at" check --root "$(dirname "$0")/.." \
             --claude-config "${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" --claude-settings "$settings" \
             --override "$conf_dir/agent-overrides.json" --lock "${_alock:-warn}" $_amodf 2>&1)"; _crc=$?
  # …and how many open sessions still run an OLDER configuration than that one
  # (issue #1783): marked 配置旧 on the sidebar, reopened once idle
  # (fleet-cfg-restart.sh, FLEET_CFG_RESTART) — counted apart from those on the
  # same configuration but an older fleet version (待换新, issue #1895), reopened
  # alike. Neither is a WARN on its own — right after a sync every session is
  # stale until its idle reopen. The third count (issue #2076) IS: 会坏·需重开, a
  # session whose start names something this install no longer has (a hook
  # script, a mod tool's handler, an MCP script — fleet-oldcfg-check.sh --sweep's
  # list); it fails every turn until reopened, and a looping one is never
  # reopened for you.
  _cst=$(FLEET_CONF_DIR="$conf_dir" bash "$(dirname "$0")/fleet-cfg-restart.sh" --counts 2>/dev/null)
  _cold=${_cst%% *}; _cnew=${_cst#* }
  case "$_cnew" in *' '*) _cbrk=${_cnew#* }; _cnew=${_cnew%% *} ;; *) _cbrk=0 ;; esac   # 2 numbers = an older tick
  case "$_cold" in ''|*[!0-9]*) _cold=0 ;; esac
  case "$_cnew" in ''|*[!0-9]*) _cnew=0 ;; esac
  case "$_cbrk" in ''|*[!0-9]*) _cbrk=0 ;; esac
  if [ "$_cold" != 0 ] || [ "$_cnew" != 0 ] || [ "$_cbrk" != 0 ]; then
    _cout="$_cout · 会坏 $_cbrk · 待换新 $_cnew · 配置旧 $_cold / $_cbrk session(s) this install BREAKS, $_cnew on an older fleet version, $_cold on an old configuration"
  fi
  if [ "$_cbrk" != 0 ] && [ "$_crc" = 0 ]; then
    warn agentcfg "${_cout#ok } (fix: reopen the broken ones — \`$(dirname "$0")/fleet-oldcfg-check.sh --sweep --list\` names each (window · repo · issue · state · what is gone); an idle one the cfg-restart tick reopens itself, a looping scheduler you reopen by hand (/fleet-handoff), issue #2076)"
    _crc=-1
  fi
  unset _cst _cold _cnew _cbrk
  case "$_crc" in
    -1) ;;
    0) pass agentcfg "${_cout#ok }" ;;
    1) warn agentcfg "$_cout (fix: drop the login's own value, or remove it from $conf_dir/agent-overrides.json — these are what fleet itself runs on)" ;;
    *) warn agentcfg "fleet-agent-team.py check: $(printf '%s\n' "$_cout" | tail -1)" ;;
  esac
fi

# --- roles: a person's layer over a role's definition (issue #2783) ---
# A local layer ($FLEET_CONF_DIR/roles/<role>.md) is for development and
# emergencies — it holds this computer only — and a layer that was not used
# (written badly) leaves its last good copy standing. Either is said here; with
# neither there is no row.
if [ -f "$(dirname "$0")/fleet-role.py" ]; then
  _rl=$(python3 "$(dirname "$0")/fleet-role.py" doctor 2>/dev/null)
  [ -n "$_rl" ] && warn roles "${_rl#*	}"
  unset _rl
fi

# --- orch: the person has ONE orchestrating session (issue #2117) ---
# The client's refresh loop writes orch_multi_<sess> when more than one machine
# still answers with one (fleet-hub-sessions.sh); the hub names the holder and
# every other machine closes its own on the next tick, so a lasting line here is
# a machine that cannot ask (no node token, an old hub) or FLEET_ORCHESTRATOR
# forced on in two places. Silent when there is no client cache here.
for _of in "${FLEET_STATUS_G:-${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash/global}"/orch_multi_*; do
  [ -s "$_of" ] || continue
  _om=$(awk -F '\037' '{ printf "%s%s(%s)", (NR > 1 ? " " : ""), $1, $2 }' "$_of")
  warn orch "${_of##*/orch_multi_}: 不止一个编排会话 — $_om (fix: 每台的 \`fleet-orchestrator.sh where <fleet>\` 应只有一台 here；不能问入口的那台补 node token，或去掉它的 FLEET_ORCHESTRATOR=1)"
done

# --- orch: the orchestrator / steward on an older fleet version (issue #2733) ---
# Their own `ensure` renews them at a quiet moment (fleet_role_renew_why) and
# stamps @renew_since while it waits for one; pending is an INFO (待换新), pending
# past FLEET_ORCH_RESTART_WAIT (2 h) a WARN — the tick never forces the switch.
_rw=${FLEET_ORCH_RESTART_WAIT:-$(_gconf_val FLEET_ORCH_RESTART_WAIT)}
case "$_rw" in ''|*[!0-9]*) _rw=7200 ;; esac
_rl=$(FLEET_CONF_DIR="$conf_dir" bash -c '. "$1"; for s in $(fleet_sockets); do
        tmux -L "$s" list-windows -t "=$s" -F "$s #{@fleet_role} #{@renew_since} #{window_id}" 2>/dev/null; done' \
        _ "$(dirname "$0")/fleet-lib.sh" 2>/dev/null \
      | awk -v now="$(date +%s)" '($2 == "orchestrator" || $2 == "steward") && $3 ~ /^[0-9]+$/ {
          printf "%s%s:%s %s(%dm)", (n++ ? " " : ""), $1, $2, $4, (now - $3) / 60; if (now - $3 > m) m = now - $3 }
          END { if (n) printf "|%d\n", m }')
if [ -n "$_rl" ]; then
  _rage=${_rl##*|}; _rl=${_rl%|*}
  if [ "$_rage" -ge "$_rw" ]; then
    warn orch "待换新 等了 $((_rage / 60)) 分钟仍没换上新版本 — $_rl (fix: 它一直不安静：看它是不是一直在跑或在问；要立刻换就让它 /exit，下一拍 ensure 原地续开同一对话)"
  else
    info orch "待换新 — ${_rl}：下一个安静时刻原地续开到装的版本（issue #2733）"
  fi
fi
unset _rw _rl _rage

# --- auto-handoff nudge: does the Stop hook SEE the threshold? (issue #561) ---
# FLEET_AUTO_HANDOFF_PCT=60 sat in the global fleet.conf for weeks while the Stop
# hook (bin/set-claude-state.sh) read the knob from its ENVIRONMENT — which nothing
# exports — so the nudge never fired once (#561; the #472 class: a conf key only a
# launcher could see). The hook now resolves it through bin/fleet-hook-conf.sh
# (global conf → per-fleet overlay). Evaluate it HERE the same way, per fleet, and
# compare with what the conf files literally say — so "configured 60, hook sees 0"
# is a WARN on this screen instead of a silent no-op. Probed through a LIVE worker
# pane when the fleet is up ($TMUX + $TMUX_PANE — exactly the hook's inputs, so the
# pane→session→conf hop is exercised too), else resolved by session name.
#
# The row also shows the LADDER the hook will actually use (issue #1317): a line
# set in tokens (FLEET_*_TOKENS) is printed as "<tokens> tok → <pct>% of <window>"
# against the probed pane's @ctx_limit — the same rounded-up, clamped-to-100
# arithmetic as fleet_ctx_line in fleet-lib.sh (this /bin/sh doctor cannot source
# it; ctx-token-line-selftest.sh pins the lockstep) — and the order
# compact-prep < handoff < Claude's own auto-compaction is checked: a token line
# that converts to 100% can never fire, and a prep line at/over the handoff line
# leaves the compact band empty. Claude's point: CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
# (env, else settings.json env), else ~95 (approximate, not measured).
_ctx_line() {   # <tokens> <limit> → % (KEEP IN SYNC with fleet_ctx_line)
  case "$1$2" in *[!0-9]*|'') return 1 ;; esac
  [ "$1" -gt 0 ] && [ "$2" -gt 0 ] || return 1
  _cl=$(( ($1 * 100 + $2 - 1) / $2 )); [ "$_cl" -gt 100 ] && _cl=100
  printf '%s' "$_cl"
}
acp="${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-}"
[ -n "$acp" ] || acp=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("env",{}).get("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE",""))' "$settings" 2>/dev/null)
case "$acp" in ''|*[!0-9]*) acp=95; acp_src="~95, Claude default" ;; *) acp_src="CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" ;; esac
hc="$(dirname "$0")/fleet-hook-conf.sh"
if [ ! -f "$hc" ]; then
  warn handoff "bin/fleet-hook-conf.sh missing — the Stop hook cannot read FLEET_AUTO_HANDOFF_PCT from the conf, so the auto-handoff nudge is inert (#561); run /fleet-sync-install"
elif [ -d "$conf_dir" ]; then
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    case "$cf" in */fleets/*/conf) sess=${cf%/conf}; sess=${sess##*/} ;; *) sess=$(basename "$cf" .conf) ;; esac
    # what the operator SET: the per-fleet line, else the global one, else off.
    want=$(_conf_val "$cf" FLEET_AUTO_HANDOFF_PCT)
    [ -n "$want" ] || want=$(_gconf_val FLEET_AUTO_HANDOFF_PCT)
    case "$want" in ''|*[!0-9]*) want=0 ;; esac
    wantt=$(_conf_val "$cf" FLEET_AUTO_HANDOFF_TOKENS)
    [ -n "$wantt" ] || wantt=$(_gconf_val FLEET_AUTO_HANDOFF_TOKENS)
    case "$wantt" in ''|*[!0-9]*) wantt=0 ;; esac
    lim=
    # what the HOOK SEES: the same resolver the hook runs.
    via="session name (fleet not running)"
    hkeys="FLEET_AUTO_HANDOFF_PCT FLEET_HANDOFF_DEFER_SECS FLEET_COMPACT_PREP_PCT FLEET_AUTO_HANDOFF_TOKENS FLEET_COMPACT_PREP_TOKENS FLEET_COMPACT_MAX"
    kv=$(bash "$hc" --session "$sess" $hkeys 2>/dev/null)
    sock=$(tmux -L "$sess" display-message -p '#{socket_path}' 2>/dev/null)
    if [ -n "$sock" ]; then
      # any pane the nudge applies to: an issue-bound worker (@issue) or a scratch (@raw)
      pane=$(tmux -L "$sess" list-panes -s -t "$sess" -F '#{pane_id} i=#{@issue} r=#{@raw}' 2>/dev/null \
             | awk '$2!="i=" || $3=="r=1" {print $1; exit}')
      if [ -n "$pane" ]; then
        kv=$(TMUX="$sock,0,0" TMUX_PANE="$pane" bash "$hc" $hkeys 2>/dev/null)
        via="live pane $pane"
        lim=$(tmux -L "$sess" display-message -p -t "$pane" '#{@ctx_limit}' 2>/dev/null)
      else
        via="session name (fleet up, no worker/scratch pane to probe)"
      fi
    fi
    sees=$(printf '%s\n' "$kv" | sed -n 1p)
    # the operator-typing hold (issue #571) rides the same resolver: unset ⇒ 30s, 0 ⇒ off
    dsees=$(printf '%s\n' "$kv" | sed -n 2p)
    csees=$(printf '%s\n' "$kv" | sed -n 3p)
    tsees=$(printf '%s\n' "$kv" | sed -n 4p)
    ctsees=$(printf '%s\n' "$kv" | sed -n 5p)
    msees=$(printf '%s\n' "$kv" | sed -n 6p)
    # the hook's unset defaults (issue #1571): handoff 80, compact-prep 55, cap 3 —
    # only while its conf path is intact (fleet-lib.sh beside it); else OFF, as the
    # hook fails open. KEEP IN SYNC with bin/set-claude-state.sh.
    if [ -f "$(dirname "$0")/fleet-lib.sh" ]; then d_h=80 d_c=55 d_m=3; else d_h=0 d_c=0 d_m=0; fi
    case "$sees" in '') sees=$d_h ;; *[!0-9]*) sees=0 ;; esac
    case "$dsees" in ''|*[!0-9]*) dsees=30 ;; esac
    case "$csees" in '') csees=$d_c ;; *[!0-9]*) csees=0 ;; esac
    case "$msees" in '') msees=$d_m ;; *[!0-9]*) msees=0 ;; esac
    case "$tsees" in ''|*[!0-9]*) tsees=0 ;; esac
    case "$ctsees" in ''|*[!0-9]*) ctsees=0 ;; esac
    case "$lim" in ''|*[!0-9]*) lim=0 ;; esac
    if [ "$dsees" -gt 0 ]; then defer="defer ${dsees}s"; else defer="defer off"; fi
    # the ladder the hook uses: a token line converted against the window, else the %
    hpct=$sees; hdesc="${sees}%"
    if [ "$tsees" -gt 0 ]; then
      if [ "$lim" -gt 0 ]; then hpct=$(_ctx_line "$tsees" "$lim"); hdesc="$tsees tok → ${hpct}% of $lim"
      else hdesc="$tsees tok (window size unknown → falls back to ${sees}%)"; fi
    fi
    hsees=$sees; [ "$tsees" -gt 0 ] && hsees="$tsees tok"
    cpct=$csees; cdesc="${csees}%"
    if [ "$ctsees" -gt 0 ]; then
      if [ "$lim" -gt 0 ]; then cpct=$(_ctx_line "$ctsees" "$lim"); cdesc="$ctsees tok → ${cpct}% of $lim"
      else cdesc="$ctsees tok (window size unknown → falls back to ${csees}%)"; fi
    fi
    [ "$cpct" -gt 0 ] && ladder="compact-prep $cdesc" || ladder="compact-prep off"
    if [ "$cpct" -gt 0 ]; then
      if [ "$msees" -gt 0 ]; then ladder="$ladder ×$msees then handoff"; else ladder="$ladder (no cap)"; fi
    fi
    # ordering faults (issue #1317): compact-prep < handoff < Claude's auto-compaction
    lwarn=''
    if [ "$tsees" -gt 0 ] && [ "$lim" -gt 0 ] && [ "$hpct" -ge 100 ]; then
      lwarn="FLEET_AUTO_HANDOFF_TOKENS=$tsees is at/over the $lim-token window — the handoff line can never fire"
    elif [ "$ctsees" -gt 0 ] && [ "$lim" -gt 0 ] && [ "$cpct" -ge 100 ]; then
      lwarn="FLEET_COMPACT_PREP_TOKENS=$ctsees is at/over the $lim-token window — the compact-prep line can never fire"
    elif [ "$hpct" -gt 0 ] && [ "$cpct" -gt 0 ] && [ "$cpct" -ge "$hpct" ]; then
      lwarn="compact-prep (${cpct}%) is not below the handoff line (${hpct}%) — the compact-in-place band is empty"
    elif [ "$hpct" -ge "$acp" ]; then
      lwarn="the handoff line (${hpct}%) is not below Claude's own auto-compaction (${acp}%, $acp_src) — Claude compacts first"
    elif [ "$hpct" -eq 0 ] && [ "$cpct" -ge "$acp" ]; then
      lwarn="compact-prep (${cpct}%) is not below Claude's own auto-compaction (${acp}%, $acp_src)"
    fi
    if [ "$want" -gt 0 ] && [ "$sees" -ne "$want" ]; then
      warn handoff "$sess: conf says FLEET_AUTO_HANDOFF_PCT=$want but the Stop hook sees $sees via $via — nudge inert (#561); check bin/fleet-lib.sh + the fleet.conf beside bin/"
    elif [ "$wantt" -gt 0 ] && [ "$tsees" -ne "$wantt" ]; then
      warn handoff "$sess: conf says FLEET_AUTO_HANDOFF_TOKENS=$wantt but the Stop hook sees $tsees via $via — nudge inert (#561); check bin/fleet-lib.sh + the fleet.conf beside bin/"
    elif [ -n "$lwarn" ]; then
      warn handoff "$sess: $lwarn · auto-handoff $hdesc · $ladder (via $via)"
    elif [ "$hpct" -gt 0 ]; then
      pass handoff "$sess: auto-handoff at $hdesc · $ladder (hook sees $hsees via $via) · $defer while the operator types at the pane"
    else
      pass handoff "$sess: auto-handoff OFF (FLEET_AUTO_HANDOFF_PCT=0, no _TOKENS; hook sees $sees) · $ladder"
    fi
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
fi

# --- the floor under auto-handoff: spinner alive + the timeout invariant (#677) ---
# /fleet-handoff's auto-cycle waits for @claude_state to leave `working` and ABORTS
# WITHOUT CLEARING if it never does. For the case that matters most — a turn that
# emitted no Stop hook at all (a model cap #580, a crash) — the ONLY thing that can
# ever open that gate is the spinner's stuck-working demotion (#101). So auto-handoff
# rests on two things nobody was checking: that the demoter is RUNNING, and that it
# lands before the cycle gives up (FLEET_STUCK_WORKING_SECS + 2 sweeps < the wait-idle
# ceiling). Shipped, the margin was 40s across two files that had never heard of each
# other. Both failures are SILENT — an overnight loop just fills its context and stops
# — which is exactly the shape that belongs on this screen.
hbf="$(dirname "$0")/../logs/spinner.heartbeat"
inv="$(dirname "$0")/fleet-handoff-invariant.sh"
hb_age=''
if [ -f "$hbf" ]; then
  hb=$(cat "$hbf" 2>/dev/null)
  hb=${hb%% *}   # `<epoch> tmux_calls_per_s=…` since #887 — the epoch is the first token
  case "$hb" in ''|*[!0-9]*) ;; *) hb_age=$(( $(date +%s 2>/dev/null || echo 0) - hb )) ;; esac
fi
# Cadence is ~20-30s: HB_CHECK_SECS is converted to a FRAME count, so like every
# other throttle in that loop it tracks what a frame actually costs (measured 27s on
# a live fleet), and a busy machine stretches it further (#653). The spinner keeps
# stamping while no fleet is up, so silence is never just "nothing to do". 180s is
# therefore ~6 missed writes at nominal cadence — a stopped or wedged loop, not a
# slow one — and deliberately loose: a false "your demoter is dead" on this screen
# would send the operator chasing the wrong thing.
if [ -z "$hb_age" ]; then
  if sh "$(dirname "$0")/fleet-daemon-loaded.sh" com.claude-fleet.spinner 2>/dev/null; then
    warn handoff "com.claude-fleet.spinner is loaded but stamps no heartbeat — an install predating #677; run /fleet-sync-install, then \`launchctl kickstart -k gui/\$UID/com.claude-fleet.spinner\`"
  else
    warn handoff "no spinner heartbeat and com.claude-fleet.spinner is not loaded — nothing demotes a window pinned at \`working\` by a turn that never emitted Stop (#580), so auto-handoff can only ever time out (#101/#677)"
  fi
elif [ "$hb_age" -gt 180 ]; then
  warn handoff "spinner heartbeat is ${hb_age}s old (stamps every ~20-30s) — the stuck-working demoter is stopped or wedged, so auto-handoff has no floor under it (#677); check logs/spinner.launchd.log"
else
  pass handoff "stuck-working demoter alive (heartbeat ${hb_age}s ago)"
fi
# --- state reconcile (issue #806) — the native-truth floor under the demoter ------
# The sleep daemon's 60s tick runs bin/fleet-state-reconcile.py first: a `working`
# window whose Claude session registry says idle (or whose bound Codex thread is
# idle) past the grace, with an equally old working stamp, is demoted to done —
# a Stop that never fired, or a classifier misread promoted after the TUI had
# already stopped. Unlike the activity
# heuristic above it is not fooled by an idle TUI repainting its footer, and it does
# not share the spinner's process, so a wedged spinner no longer means `working`
# forever. Silence here means com.claude-fleet.sleep itself is not ticking.
rhb="${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash/global/reconcile.heartbeat"
rhb_age=''
if [ -f "$rhb" ]; then
  rhb_at=$(sed -n 's/^at=//p' "$rhb" | head -n1)
  case "$rhb_at" in ''|*[!0-9]*) ;; *) rhb_age=$(( $(date +%s 2>/dev/null || echo 0) - rhb_at )) ;; esac
fi
if [ -z "$rhb_age" ]; then
  warn state "no state-reconcile heartbeat (global/reconcile.heartbeat) — bin/fleet-sleep-daemon.sh has not run bin/fleet-state-reconcile.py yet (#806); a \`working\` window whose Stop never fired is caught only by the spinner's activity heuristic"
elif [ "$rhb_age" -gt 180 ]; then
  warn state "state reconcile last ran ${rhb_age}s ago (the sleep daemon's 60s tick runs it) — check com.claude-fleet.sleep and logs/sleep.launchd.log (#806)"
else
  rhb_get() { sed -n "s/^$1=//p" "$rhb" | head -n1; }
  rhb_note=''
  [ -n "$(rhb_get skipped)" ] && rhb_note="; skipped: $(rhb_get skipped)"
  # Contradicting state signals (#1270): a `working` hook on a silent pane the
  # registry calls idle/gone/busy. Counted from the (trimmed) reconcile.log, and
  # `contested` is how many still contradict on the latest tick.
  rlog="$(dirname "$0")/../logs/reconcile.log"
  rung_n=$(grep -c ' rung_health ' "$rlog" 2>/dev/null) || rung_n=0
  rung_live=$(rhb_get contested); rung_live=${rung_live:-0}
  # Where each window's state came from (issue #2537, EPIC #2535 C2): the agent's
  # own OSC 7501 report is the primary source; `primary=a/b` is how many live
  # Claude windows carry a state it said itself, `src=` every source's count.
  # Per window: global/reconcile.sources. An older heartbeat has neither: no clause.
  rhb_pri=$(rhb_get primary); rhb_src=$(rhb_get src); rhb_cov=''
  case "$rhb_pri" in
    */*) _pa=${rhb_pri%/*}; _pb=${rhb_pri#*/}
         case "$_pa$_pb" in *[!0-9]*|'') ;; *)
           if [ "$_pb" -gt 0 ]; then rhb_cov="; 主来源 7501 覆盖 $_pa/$_pb ($(( _pa * 100 / _pb ))%)"
           else rhb_cov="; 主来源 7501 覆盖 0/0"; fi
           [ -n "$rhb_src" ] && rhb_cov="$rhb_cov · 来源 $rhb_src" ;;
         esac ;;
  esac
  pass state "state reconcile ${rhb_age}s ago — $(rhb_get working) working window(s) checked against native idle, $(rhb_get demoted) demoted; rung_health: ${rung_n} contradiction(s) in reconcile.log, ${rung_live} live$rhb_cov$rhb_note"
fi
# The sleep-judgment distribution over the last hour (#837). Every scan record now
# carries an `at` timestamp (#838), so the histogram the 2026-09-19 analysis built
# by hand is a line here: without the number, the next approach to the ceiling is a
# manual hunt across the whole log (the same reasoning as `over=` in #653). Info
# only — a distribution is never a pass/fail (one exception: a `wrong fleet`
# majority, issue #2622); the read is tail-bounded. FLEET_DOCTOR_SINCE=<epoch>
# (install-sync's doctor after a switch, issue #2655) moves the window's start up
# to then: what the OLD version's sleep judge wrote is not the new one's verdict.
slog="$(dirname "$0")/../logs/sleep.log"
_dsince="${FLEET_DOCTOR_SINCE:-}"; case "$_dsince" in *[!0-9]*) _dsince='' ;; esac
if [ -f "$slog" ] && command -v python3 >/dev/null 2>&1; then
  sdist=$(tail -n 6000 "$slog" 2>/dev/null | FLEET_DOCTOR_SINCE="$_dsince" python3 -c '
import os, sys, json, time, collections
since = max(time.time() - 3600, float(os.environ.get("FLEET_DOCTOR_SINCE") or 0))
cut = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(since))
c = collections.Counter(); n = 0
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"): continue
    try: d = json.loads(line)
    except ValueError: continue
    if d.get("at", "") < cut: continue           # pre-#838 records have no `at`
    c[d.get("skip") or ("state:" + d.get("state", "?"))] += 1; n += 1
if n:
    top = ", ".join("%s x%d" % (k[:44], v) for k, v in c.most_common(5))
    # issue #2622: a majority of `wrong fleet` is the judge refusing the fleet
    # itself (a view session misread as another fleet), never a distribution.
    print(("FAIL " if 2 * c["wrong fleet"] > n else "") + "%d judgments/hr across %d reasons; top: %s" % (n, len(c), top))
' 2>/dev/null)
  case "$sdist" in
    "FAIL "*) fail state "sleep judgments (${_dsince:+since the switch, }last hour): ${sdist#FAIL } — most windows judged \`wrong fleet\`: the sleep judge cannot see this fleet's windows, nothing can sleep" ;;
    ?*) pass state "sleep judgments (${_dsince:+since the switch, }last hour): $sdist" ;;
  esac
fi
# Trips back to the hub over the last day, per fleet, with the top two causes
# (issue #897 — the meter EPIC #894 is judged by). Info only, like the line above:
# a count is never a pass/fail. Silent until a hub-visits log exists.
while IFS="$(printf '\t')" read -r hvs hvn hvtop; do
  [ -n "$hvs" ] && pass hub "$hvs: $hvn trip(s) to the hub in 24h; top: $hvtop (table: bin/fleet-hub-visits.sh --session $hvs)"
done <<EOF
$(FLEET_HUB_VISITS_LOGDIR="$(dirname "$0")/../logs" bash "$(dirname "$0")/fleet-hub-visits.sh" --brief --all --since 24h 2>/dev/null </dev/null)
EOF
# Who the sidebar asks the cross-machine hub as (issue #1475): your connection
# certificate, else the viewer token, else nobody — and then no other machine's
# session ever shows. Only with the hub module on; a one-machine fleet says nothing.
_hub_on="${CCQUOTA_FLEET:-}"
# the conf spells it `export CCQUOTA_FLEET=1`, which _conf_val's anchor does not take
[ -n "$_hub_on" ] || [ ! -f "$(dirname "$0")/../fleet.conf" ] \
  || _hub_on=$(sed -n 's/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}CCQUOTA_FLEET[[:space:]]*=[[:space:]]*\([^#]*\).*/\2/p' "$(dirname "$0")/../fleet.conf" | tail -1 | tr -d "\"' 	")
if [ "$_hub_on" = 1 ] && [ -x "$(dirname "$0")/fleet-hub-sessions.sh" ]; then
  _hid=$(CCQUOTA_FLEET=1 bash "$(dirname "$0")/fleet-hub-sessions.sh" --identity 2>/dev/null </dev/null)
  case "$_hid" in
    cert\ *)  pass hub "sidebar asks the hub with your connection certificate (${_hid#cert }) — your own machines, no token" ;;
    token\ *) pass hub "sidebar asks the hub with the viewer token (${_hid#token }) — the operator's view; a colleague runs \`fleet login\` for a certificate of their own" ;;
    node\ *)  pass hub "sidebar asks the hub with this login's node token (${_hid#node }) — its owner's machines, no certificate to expire (#2630)" ;;
    cmd\ *)   pass hub "sidebar reads the hub through FLEET_HUB_SESSIONS_CMD" ;;
    *)        warn hub "sidebar cannot ask the hub: ${_hid#none } — no other machine's sessions will show (bin/fleet-hub-sessions.sh --identity)" ;;
  esac
  # The refresh loop itself (issue #1596): the collector re-starts it every tick,
  # sidebar or not — a dead loop or an old cache means the other machines' rows
  # stopped while nobody was looking.
  # A cache past FLEET_HUB_SESSIONS_FAIL_SECS (600) is a FAIL (issue #2630): the
  # rows on the sidebar, the children's remote state and peer-send's locator are
  # that old — 5 hours of it once read as a WARN nobody acted on.
  if _hst=$(CCQUOTA_FLEET=1 bash "$(dirname "$0")/fleet-hub-sessions.sh" --status 2>/dev/null </dev/null); then
    pass hub-sessions "$_hst"
  else
    _hsfail="${FLEET_HUB_SESSIONS_FAIL_SECS:-600}"; case "$_hsfail" in ''|*[!0-9]*) _hsfail=600 ;; esac
    _hsage=$(printf '%s' "$_hst" | sed -n 's/.*cache \([0-9][0-9]*\)s.*/\1/p')
    case "$_hst" in "loop none"*) _hsfix="the loop is not running — \`bash bin/fleet-hub-sessions.sh --ensure\` starts it (the collector does every tick; \`--status\` names the lock holder)" ;;
                    *) _hsfix="the loop runs but no round stands — see the \`hubauth\` row and \`bash bin/fleet-hub-sessions.sh --refresh\`" ;; esac
    # FLEET_DOCTOR_SINCE (issue #2655): a cache whose last round predates the
    # switch is the OLD loop's age — no round since yet is a WARN, never the FAIL.
    if [ -n "$_hsage" ] && [ "$_hsage" -gt "$_hsfail" ] && [ -n "$_dsince" ] \
       && [ "$_hsage" -gt $(( $(date +%s) - _dsince )) ]; then
      warn hub-sessions "$_hst — no round since the switch yet (the cache is the old version's); $_hsfix"
    elif [ -n "$_hsage" ] && [ "$_hsage" -gt "$_hsfail" ]; then
      fail hub-sessions "$_hst — the other machines' sessions are $((_hsage/60))m old (> ${_hsfail}s); $_hsfix"
    else
      warn hub-sessions "${_hst:-no answer} — the other machines' sessions are not refreshing; $_hsfix"
    fi
    unset _hsfail _hsage _hsfix
  fi
  unset _hid _hst
fi
# --- hubauth (issue #2630): every node-side hub READ the hub refused, one line
# per reader (fleet_hub_auth_note → global/hub_auth_fail). Refused past
# FLEET_HUB_AUTH_FAIL_SECS (1800) is a FAIL with the fix; younger, a WARN.
# No file = nothing refused = no row (a one-machine fleet prints nothing).
_haf="${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash/global/hub_auth_fail"
if [ -s "$_haf" ]; then
  _hamax="${FLEET_HUB_AUTH_FAIL_SECS:-1800}"; case "$_hamax" in ''|*[!0-9]*) _hamax=1800 ;; esac
  _hanow=$(date +%s); _haold=0; _halist=''
  while IFS='	' read -r _har _has _hal _hawhy; do
    [ -n "$_har" ] || continue
    case "$_has" in ''|*[!0-9]*) _has=$_hanow ;; esac
    [ $((_hanow - _has)) -gt "$_hamax" ] && _haold=1
    _halist="${_halist}${_halist:+; }$_har refused $(( (_hanow - _has) / 60 ))m (${_hawhy:-401})"
  done < "$_haf"
  _hafix=$(bash -c '. "$1/fleet-lib.sh" && fleet_hub_auth_fix' _ "$(dirname "$0")" 2>/dev/null)
  if [ "$_haold" = 1 ]; then fail hubauth "$_halist — ${_hafix:-check node.env / \`fleet login\`}"
  else warn hubauth "$_halist — ${_hafix:-check node.env / \`fleet login\`}"; fi
  unset _hamax _hanow _haold _halist _har _has _hal _hawhy _hafix
fi
unset _haf
# The invariant itself, per fleet — FLEET_HANDOFF_IDLE_TIMEOUT takes a per-fleet
# overlay (FLEET_STUCK_WORKING_SECS is global-only: one spinner serves the machine).
if [ -x "$inv" ]; then
  _inv_line() {
    _s="$1"; _lbl="$2"
    _out=$(sh "$inv" ${_s:+--session "$_s"} --oneline 2>&1); _rc=$?
    case "$_rc" in
      0) pass handoff "$_lbl$_out" ;;
      1) warn handoff "$_lbl$_out" ;;
      *) warn handoff "$_lbl could not evaluate the handoff timeout invariant — $_out (#677)" ;;
    esac
  }
  _any=0
  if [ -d "$conf_dir" ]; then
    while IFS= read -r cf; do
      [ -n "$cf" ] || continue
      case "$cf" in */fleets/*/conf) sess=${cf%/conf}; sess=${sess##*/} ;; *) sess=$(basename "$cf" .conf) ;; esac
      _any=1; _inv_line "$sess" "$sess: "
    done <<EOF
$(_fleet_confs "$conf_dir")
EOF
  fi
  [ "$_any" = 0 ] && _inv_line '' ''
fi

# --- context: the compaction / handoff ladder, from its ledger (issue #1320) ----
# Every step of an in-place compaction (#1269) and of a handoff writes one row to
# logs/context-ladder.log (bin/fleet-ladder-log.sh; columns in its `#` header).
# This row only READS it: the last 24h's completed compactions (`restored`, with
# the `compacting` starts beside them) and handoffs (`handoff-complete`, with the
# nudges beside them), then the live window highest on the ladder right now — its
# context %, the step it is at, and how often it has been compacted. Info, never a
# verdict: a count is not pass/fail.
ldir="${FLEET_HANDOFF_LOG_DIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/logs}"
lf="$ldir/context-ladder.log"
lc=$(awk -F '\t' -v cut=$(( $(date +%s) - 86400 )) '
  /^#/ || $1 !~ /^[0-9]+$/ || $1 < cut { next }
  { n[$3]++ }
  $3 == "native-precompact" && $9 ~ / (saved|kept)$/ { n["native-saved"]++ }
  END { printf "%d %d %d %d %d %d", n["restored"], n["compacting"], n["handoff-complete"], n["handoff-nudge"], n["native-precompact"], n["native-saved"] }
' "$lf" 2>/dev/null)
read -r lc_r lc_c lc_h lc_n lc_x lc_xs <<EOF
${lc:-0 0 0 0 0 0}
EOF
if [ "$lc_r$lc_c$lc_h$lc_n$lc_x" = 00000 ]; then
  lmsg="近 24h 无压缩 / 交接 (${lf})"
else
  lmsg="近 24h 压缩 ${lc_r} 次（发起 ${lc_c}）、交接 ${lc_h} 次（提示 ${lc_n}）(${lf})"
fi
# Claude Code's own compaction (issue #1321): how often it beat the fleet's ladder,
# and how many of those bin/precompact-hook.sh had already saved a map for.
[ "${lc_x:-0}" -gt 0 ] && lmsg="${lmsg} · 自带压缩 ${lc_x} 次（已提前存档 ${lc_xs}）"
# The live ladder, every fleet on this login: one tab row per window.
lwin=''
if [ -d "$conf_dir" ]; then
  lwin=$(while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    case "$cf" in (*/fleets/*/conf) sess=${cf%/conf}; sess=${sess##*/} ;; (*) sess=$(basename "$cf" .conf) ;; esac
    tmux -L "$sess" list-windows -t "$sess" \
      -F "#{@ctx_pct}	$sess	#{@handoff_armed}	#{@compact_stage}	#{@compact_count}	#{window_name}" 2>/dev/null
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
)
fi
ltop=$(printf '%s\n' "$lwin" | awk -F '\t' '$1 ~ /^[0-9]+$/ && ($1 + 0) > best { best = $1 + 0; row = $0 }
  END { if (row == "") exit
        split(row, f, "\t")
        st = (f[3] == "1") ? "handoff-nudge" : (f[4] != "" ? f[4] : "—")
        printf "%s:%s %s%% @ %s, 压过 %d 次", f[2], f[6], f[1], st, f[5] + 0 }')
# A fleet compaction nobody resumed (issue #1441): a `restored fleet` row older than
# 5 minutes with no `resumed` row for that pane after it — the session sat idle
# after /compact. Only rows newer than the ledger's first `resumed` row count, so a
# log written before the resume sender existed does not WARN for a day. Any
# `resumed` row settles it, by design: `mod` / `send-keys` (sent), `late:<via>` (a
# stale `working` settled idle and the turn was sent then, #1572) and every
# `skip:<why>` — `self-continued` is the harness going on by itself (queued input
# lands the moment the compaction does; it is NOT a stall), `needs` / `typing` /
# `codex` / `transfer` / `stage` are a pane that is someone else's to move, `stale`
# is a pane that could not be read. A watch still running (a stale `working` not
# yet settled) has no row yet and WARNs past 5 minutes, which is the point.
lstuck=''
if [ "${FLEET_COMPACT_RESUME:-1}" != 0 ]; then
  lstuck=$(awk -F '\t' -v cut=$(( $(date +%s) - 86400 )) -v old=$(( $(date +%s) - 300 )) '
    /^#/ || $1 !~ /^[0-9]+$/ { next }
    $3 == "resumed" { if (first == "") first = $1; last[$4 SUBSEP $5] = $1; next }
    $3 == "restored" && $9 == "fleet" && $1 >= cut && $1 <= old { n++; ep[n] = $1; key[n] = $4 SUBSEP $5; who[n] = $4 ":" $6 }
    END { if (first == "") exit
          for (i = 1; i <= n; i++) if (ep[i] >= first && !((key[i]) in last && last[key[i]] >= ep[i])) { c++; w = who[i] }
          if (c) printf "%d %s", c, w }
  ' "$lf" 2>/dev/null)
fi
if [ -n "$lstuck" ]; then
  warn context "${lmsg} · ${lstuck%% *} 次压缩后没有续跑（最近 ${lstuck#* }）— 见 context-ladder.log 的 resumed 行 / FLEET_COMPACT_RESUME"
else
  pass context "${lmsg}${ltop:+ · 当前最高 ${ltop}}"
fi

# --- mod: the in-session fleet extension, per Claude window (issue #1335) --------
# bin/fleet-claude.sh loads mod/fleet/ into every Claude session it opens while
# FLEET_MOD is on (default 1). The mod writes @mod_state (on | off:version),
# @mod_ver and a heartbeat @mod_alive every 15s; fleet_mod_alive (fleet-lib.sh)
# reads a beat within FLEET_MOD_ALIVE_SECS (45) as alive. This row counts, over
# every fleet on this login, which of the two paths each Claude window is on and
# why: alive = the mod's; off:version = Claude Code outside the mod's supported
# range; stale = loaded once, beat stopped; none = launched before the mod (or
# while FLEET_MOD was 0). The last three all run today's path, which stays.
# Read-only; a count, never a verdict — WARN only for a switched-on mod whose
# plugin folder is missing from the install.
mod_on="${FLEET_MOD:-$(_gconf_val FLEET_MOD)}"
mod_dir="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/mod/fleet"
mod_rng=$(sed -n "s/.*SUPPORTED = { min: '\([^']*\)', below: '\([^']*\)' }.*/\1 ≤ v < \2/p" "$mod_dir/hooks/version.ts" 2>/dev/null)
mod_max="${FLEET_MOD_ALIVE_SECS:-45}"; case "$mod_max" in ''|*[!0-9]*) mod_max=45 ;; esac
mwin=''
if [ -d "$conf_dir" ]; then
  mwin=$(while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    case "$cf" in (*/fleets/*/conf) sess=${cf%/conf}; sess=${sess##*/} ;; (*) sess=$(basename "$cf" .conf) ;; esac
    tmux -L "$sess" list-windows -t "$sess" \
      -F "#{window_name}	#{@cc_agent}	#{@cc_model}#{@claude_state}	#{@mod_state}	#{@mod_alive}" 2>/dev/null
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
)
fi
# A Claude window: not a panel, not codex, and stamped by the launcher (@cc_model)
# or the state hooks (@claude_state). Columns: total alive off:version stale none.
mcount=$(printf '%s\n' "$mwin" | awk -F '\t' -v now="$(date +%s)" -v max="$mod_max" '
  NF < 5 || $1 == "dash" || $1 == "plan" || $1 == "backlog" || $1 == "home" || $2 == "codex" || $3 == "" { next }
  { n++
    if ($5 ~ /^[0-9]+$/ && now - $5 <= max) a++
    else if ($4 == "off:version") v++
    else if ($4 != "") s++
    else x++ }
  END { printf "%d %d %d %d %d", n, a, v, s, x }')
read -r m_n m_a m_v m_s m_x <<EOF
${mcount:-0 0 0 0 0}
EOF
m_tail="扩展存活 ${m_a}/${m_n} 个 Claude 窗口"
[ "$m_v" -gt 0 ] && m_tail="${m_tail} · 版本不在区间 ${m_v}"
[ "$m_s" -gt 0 ] && m_tail="${m_tail} · 心跳停了 ${m_s}"
[ "$m_x" -gt 0 ] && m_tail="${m_tail} · 未加载 ${m_x}"
if [ "$mod_on" = 0 ]; then
  info mod "关 (FLEET_MOD=0) — 新会话不带扩展，全部走旧路径；${m_tail}"
elif [ ! -f "$mod_dir/.claude-plugin/plugin.json" ]; then
  warn mod "FLEET_MOD 开着但 ${mod_dir} 不在 — 新会话不带扩展，全部走旧路径（同步安装后补上）"
else
  pass mod "${m_tail}；其余走旧路径 (支持 Claude Code ${mod_rng:-?})"
fi

# --- shared deps: is the base's node_modules current with its lockfiles? (#961) --
# With shared deps on (fleet_base_deps_on: FLEET_BASE_DEPS=1, or the stock
# fleet-deps-link hook), every new worktree borrows the base checkout's
# node_modules — and fleet-deps-link refuses a tree whose `.fleet-lock-sha` stamp
# does not match its lockfile, so a stale / unstamped base silently turns every
# spawn back into a full install. Count them per fleet.
dl_sh="$(dirname "$0")/fleet-deps-link.sh"
# _deps_row <label> <main> [<base-branch>] — one verdict for one base checkout
_deps_row() {
  bd_sum=$("$dl_sh" --base-status "$2" 2>/dev/null | sed -n 's/^summary //p')
  [ -n "$bd_sum" ] || return 0
  # Issue #1044: "fresh" means fresh against the CHECKED-OUT tree — say which one
  # when it is not the base branch, and never pass it.
  bd_off=""
  if [ -n "${3:-}" ]; then
    bd_cur=$(git -C "$2" symbolic-ref --quiet --short HEAD 2>/dev/null) || bd_cur="detached HEAD"
    [ "$bd_cur" = "$3" ] || bd_off=" [against $bd_cur, not $3 — see the checkout row]"
  fi
  bd_get() { printf '%s\n' "$bd_sum" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
  bd_f=$(bd_get fresh); bd_s=$(( $(bd_get stale) + $(bd_get installing) )); bd_u=$(bd_get unstamped); bd_n=$(bd_get not-installed)
  bd_x=$(bd_get failing); bd_x=${bd_x:-0}; bd_since=$(bd_get failing-since)
  # failing (issue #1026) ≠ unstamped: the install ran and failed on the repo's
  # side, so it is parked until its lockfile moves — --prime-base would only fail
  # it again. The oldest failure says how long worktrees have gone unlinked.
  # Which kind of failing (issue #1028): a transient one retries itself with
  # backoff, a parked one waits for its lockfile — say which, and why.
  bd_t=$(bd_get failing-transient); bd_t=${bd_t:-0}; bd_p=$((bd_x - bd_t))
  bd_next=$(bd_get next-retry); bd_why=$(bd_get parked-causes | tr ',-' '/ ')
  bd_cls=""
  if [ "$bd_t" -gt 0 ]; then
    [ "$bd_next" = next-tick ] && bd_next="next tick"
    bd_cls="transient, retry at ${bd_next:-?}"; [ "$bd_p" -gt 0 ] && bd_cls="$bd_t $bd_cls"
  fi
  if [ "$bd_p" -gt 0 ]; then
    bd_c="parked: ${bd_why:-unknown}"; [ "$bd_t" -gt 0 ] && bd_c="$bd_p $bd_c"
    bd_cls="$bd_cls${bd_cls:+; }$bd_c"
  fi
  bd_txt="$1: base deps $bd_f fresh / $bd_s stale / $bd_x failing / $bd_u unstamped / $bd_n not installed"
  [ "$bd_x" -gt 0 ] && bd_txt="$bd_txt (failing: $bd_cls; since ${bd_since:-?})"
  bd_txt="$bd_txt$bd_off"
  if [ "$bd_s" -gt 0 ] || [ "$bd_u" -gt 0 ]; then
    warn deps "$bd_txt — worktrees there install from zero instead of linking; fix: $(dirname "$0")/fleet-deps-link.sh --prime-base '$2' (per dir: --base-status)"
  elif [ "$bd_x" -gt 0 ] && [ "$bd_p" = 0 ]; then
    warn deps "$bd_txt — a transient install failure (network / npm cache); it retries itself with backoff, nothing to do unless it parks (log: logs/base-deps.log)"
  elif [ "$bd_x" -gt 0 ]; then
    warn deps "$bd_txt — the install fails on the repo's side and is not retried until its lockfile changes; see logs/base-deps.log, fix the repo, then: $(dirname "$0")/fleet-deps-link.sh --refresh-base '$2' <dir> (which: --base-status)"
  elif [ -n "$bd_off" ]; then
    warn deps "$bd_txt — new worktrees link deps built from the wrong branch's lockfiles; fix: git -C '$2' checkout $3"
  else
    pass deps "$bd_txt — new worktrees link the base's current tree"
  fi
}
if [ -d "$conf_dir" ] && [ -x "$dl_sh" ]; then
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    case "$cf" in */fleets/*/conf) sess=${cf%/conf}; sess=${sess##*/} ;; *) sess=$(basename "$cf" .conf) ;; esac
    bd_on=$(_conf_val "$cf" FLEET_BASE_DEPS); [ -n "$bd_on" ] || bd_on=$(_gconf_val FLEET_BASE_DEPS)
    bd_ws=$(_conf_val "$cf" FLEET_WORKTREE_SETUP); [ -n "$bd_ws" ] || bd_ws=$(_gconf_val FLEET_WORKTREE_SETUP)
    case "$bd_on:$bd_ws" in 1:*|:*fleet-deps-link*)
      main=$(sh -c '. "$1" 2>/dev/null; printf %s "${FLEET_MAIN:-}"' _ "$cf")
      bd_b=$(sh -c '. "$1" 2>/dev/null; printf %s "${FLEET_BASE_BRANCH:-master}"' _ "$cf")
      [ -d "$main" ] && _deps_row "$sess" "$main" "$bd_b" ;;
    esac
    # Each hosted repo keeps its own setup (issue #978): an overlay's
    # FLEET_BASE_DEPS / FLEET_WORKTREE_SETUP win for its base, else the fleet's.
    for rf in "$conf_dir/fleets/$sess/repos"/*.conf; do
      [ -f "$rf" ] || continue
      # Set at all (even to "") ⇒ the overlay's; `FLEET_WORKTREE_SETUP=""` turns it off.
      r_on=$bd_on; _conf_has "$rf" FLEET_BASE_DEPS && r_on=$(_conf_val "$rf" FLEET_BASE_DEPS)
      r_ws=$bd_ws; _conf_has "$rf" FLEET_WORKTREE_SETUP && r_ws=$(_conf_val "$rf" FLEET_WORKTREE_SETUP)
      case "$r_on:$r_ws" in 1:*|:*fleet-deps-link*) ;; *) continue ;; esac
      main=$(sh -c '. "$1" 2>/dev/null; printf %s "${FLEET_MAIN:-}"' _ "$rf")
      bd_b=$(sh -c '. "$1" 2>/dev/null; printf %s "${FLEET_BASE_BRANCH:-master}"' _ "$rf")
      [ -d "$main" ] && _deps_row "$sess [$(basename "$rf" .conf)]" "$main" "$bd_b"
    done
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
fi

# --- hosted repos: one block per repo every fleet hosts (issue #801) -------------
# A fleet hosts one or more repos (#788): the fleet conf's FLEET_REPO first, then
# each fleets/<sess>/repos/<slug>.conf overlay. Each repo gets its own block —
#   main    FLEET_MAIN exists, is a git checkout, and its origin IS the repo
#   base    FLEET_BASE_BRANCH is the repo's GitHub default (#603) and exists locally
#   checkout  FLEET_MAIN is ON that base branch, and no other worktree holds it (#1044)
#   trust   Claude Code's trust pre-grant for FLEET_MAIN (#563)
#   deploy  FLEET_DEPLOY_REF / FLEET_DEPLOY_CHECK are usable (#541)
#   labels  the canonical fleet label set is seeded on the repo (#333)
# — because the check used to read the fleet conf alone, so a broken checkout or a
# missing trust grant for any OTHER hosted repo went unnoticed until a spawn hung.
#
# Resolution mirrors fleet_repos / fleet_load_repo_conf in fleet-lib.sh (doctor is
# /bin/sh and cannot source it — KEEP IN SYNC): the conf's own repo takes the conf's
# repo-scoped keys with its overlay (if any) on top; every other repo takes them from
# its overlay ONLY (the conf repo's are dropped, so they never leak across). Keys are
# read the way sourcing does (a subshell), so a `$HOME/…` FLEET_MAIN expands.
# Why the trust fault matters: Claude Code keys per-directory trust on the resolved
# project root — a linked worktree resolves to its MAIN checkout — with an exact
# lookup in ~/.claude.json (`projects[<root>].hasTrustDialogAccepted === true`); with
# it missing every dispatched worker parks on the dialog with nobody to answer
# (macmini, 2026-09-12: 7+ minutes, slot "filled", nothing logged). The launcher
# pre-trusts at spawn since #563, but a live install that predates it, or an
# opted-out fleet (FLEET_PRETRUST=0), still stalls.
# Why the base fault matters: when FLEET_BASE_BRANCH is wrong nothing looks broken —
# workers claim, branch, push, CI passes, PRs merge — onto a branch nobody ships
# from (2026-09-12: fleet-ccquota sat on 'dashboard-redesign' for a whole round).
tr_sh="$(dirname "$0")/fleet-trust.sh"
lib_sh="$(dirname "$0")/fleet-lib.sh"
_REPO_SCOPED="FLEET_REPO FLEET_MAIN FLEET_BASE_BRANCH FLEET_DEPLOY_REF FLEET_DEPLOY_CHECK FLEET_REPO_SHORT"

# _norm_repo <url-or-slug> → owner/name (fleet_norm_repo, single-line case)
_norm_repo() {
  printf '%s' "$1" | sed -E 's#^git@[^:]*:##; s#^[a-z]+://[^/]*/##; s#\.git$##; s#/+$##'
}
# _repo_slug <owner/name> → the overlay basename (fleet_slug)
_repo_slug() { printf '%s' "$1" | tr '/' '-' | tr -cd '[:alnum:]._-'; }
# _repo_key <fleet-conf> <overlay|''> <own:1|0> <KEY> → KEY as fleet_load_repo_conf
# leaves it for that repo.
_repo_key() {
  sh -c '. "$1" >/dev/null 2>&1
         [ "$3" = 1 ] || unset '"$_REPO_SCOPED"'
         [ -n "$2" ] && [ -f "$2" ] && . "$2" >/dev/null 2>&1
         eval "printf %s \"\${$4:-}\""' _ "$1" "$2" "$3" "$4"
}

# The canonical label names, read from fleet-lib.sh (the one taxonomy, #333).
canon_labels=''
[ -f "$lib_sh" ] && command -v bash >/dev/null 2>&1 \
  && canon_labels=$(bash -c '. "$1" >/dev/null 2>&1 && fleet_labels_allowed' _ "$lib_sh" 2>/dev/null)

# _repo_block <sess> <fleet-conf> <repo> <overlay|''> <own:1|0> — one repo's block
_repo_block() {
  rb_sess=$1 rb_cf=$2 r=$3 rb_ov=$4 rb_own=$5
  rb_src=$rb_cf; [ -n "$rb_ov" ] && rb_src=$rb_ov   # where a fix for THIS repo goes
  printf '  %s── %s · %s%s\n' "$B" "$rb_sess" "$r" "$Z"
  main=$(_repo_key "$rb_cf" "$rb_ov" "$rb_own" FLEET_MAIN)
  bbase=$(_repo_key "$rb_cf" "$rb_ov" "$rb_own" FLEET_BASE_BRANCH)
  dref=$(_repo_key "$rb_cf" "$rb_ov" "$rb_own" FLEET_DEPLOY_REF)
  dchk=$(_repo_key "$rb_cf" "$rb_ov" "$rb_own" FLEET_DEPLOY_CHECK)

  # main — the checkout every worktree for this repo branches from
  main_ok=0; rb_bad=''   # rb_bad: this repo's failing items, for the `repos` row
  if [ -z "$main" ]; then
    warn main "$r: no FLEET_MAIN — a spawn for this repo has no checkout to branch from; set it in $rb_src"
    rb_bad="main"
  elif [ ! -d "$main" ]; then
    warn main "$r: FLEET_MAIN $main does not exist — every spawn for this repo fails; clone it there or fix FLEET_MAIN in $rb_src"
  elif ! git -C "$main" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    warn main "$r: FLEET_MAIN $main is not a git checkout — no worktree can be cut from it"
  else
    morigin=$(_norm_repo "$(git -C "$main" remote get-url origin 2>/dev/null)")
    if [ -z "$morigin" ]; then
      warn main "$r: $main has no origin remote — workers cannot push or open a PR"
    elif [ "$morigin" != "$r" ]; then
      warn main "$r: $main's origin is $morigin, not $r — its workers push to the wrong repo; fix FLEET_MAIN in $rb_src"
    else
      main_ok=1
      pass main "$r: $main (origin matches)"
    fi
  fi
  [ -n "$main" ] && [ "$main_ok" = 0 ] && rb_bad="main"

  # base + labels — one gh read: the default branch, then every label name
  if [ -z "$bbase" ]; then
    warn base "$r: no FLEET_BASE_BRANCH — the tooling has to guess this repo's trunk; set it in $rb_src"
    rb_bad="${rb_bad:+$rb_bad, }base"
  fi
  gh_out=''
  command -v gh >/dev/null 2>&1 \
    && gh_out=$(gh repo view "$r" --json defaultBranchRef,labels -q '.defaultBranchRef.name, .labels[].name' 2>/dev/null)
  bdef=$(printf '%s\n' "$gh_out" | sed -n 1p)
  if [ -n "$bbase" ]; then
    if [ "$main_ok" = 1 ] && ! git -C "$main" rev-parse --verify -q "refs/heads/$bbase" >/dev/null 2>&1 \
         && ! git -C "$main" rev-parse --verify -q "refs/remotes/origin/$bbase" >/dev/null 2>&1; then
      warn base "$r: base \"$bbase\" does not exist in $main — no worktree can branch from it"
      rb_bad="${rb_bad:+$rb_bad, }base"
    elif [ -z "$bdef" ]; then
      printf '        note: %s: could not read the default branch (gh missing/unauthed/offline) — base "%s" left unverified.\n' "$r" "$bbase"
    elif [ "$bbase" = "$bdef" ]; then
      pass base "$r: base \"$bbase\" is the repo default"
    else
      warn base "$r: base \"$bbase\" is NOT the repo's default branch (\"$bdef\") — every worker here branches from and merges into \"$bbase\", so the trunk never moves; fix: set FLEET_BASE_BRANCH=\"$bdef\" in $rb_src, or keep it deliberately if \"$bbase\" really is this repo's trunk"
    fi
  fi

  # checkout — the base checkout must SIT ON the base branch (issue #1044): every
  # base-mover pulls whatever is checked out, so a base left on a side branch reads
  # "already current" forever while its shared deps install from a stale tree
  # (2026-09-23: the monorepo base sat 834 commits behind for 10 days, doctor green).
  if [ "$main_ok" = 1 ] && [ -n "$bbase" ]; then
    bcur=$(git -C "$main" symbolic-ref --quiet --short HEAD 2>/dev/null) || bcur="detached HEAD"
    bbehind=$(git -C "$main" rev-list --count "HEAD..refs/remotes/origin/$bbase" 2>/dev/null)
    if [ "$bcur" != "$bbase" ]; then
      warn checkout "$r: base checkout $main is on $bcur, not \"$bbase\"${bbehind:+ ($bbehind commit(s) behind origin/$bbase)} — base-sync will not pull it and its shared deps follow the wrong tree; fix: git -C '$main' checkout $bbase"
    else
      [ "${bbehind:-0}" = 0 ] && bbehind=""
      pass checkout "$r: $main is on \"$bbase\"${bbehind:+ ($bbehind behind origin/$bbase — base-sync catches it up)}"
    fi
    # Another worktree holding the base branch refuses that checkout ("already
    # checked out at …") — e.g. a stale one in a dead session's scratchpad.
    bholders=$(git -C "$main" worktree list --porcelain 2>/dev/null | awk -v m="$(cd "$main" && pwd -P)" -v b="refs/heads/$bbase" '
      /^worktree / { p = substr($0, 10); pr = 0; next }
      /^prunable/  { pr = 1; next }
      /^branch /   { if (substr($0, 8) == b) hold = p; next }
      /^$/         { if (hold != "" && hold != m) print hold (pr ? " (prunable)" : ""); hold = "" }
      END          { if (hold != "" && hold != m) print hold (pr ? " (prunable)" : "") }')
    # a here-doc, not a pipe: warn() must count in THIS shell
    while IFS= read -r wh; do
      [ -n "$wh" ] || continue
      warn checkout "$r: worktree $wh holds \"$bbase\" — the base checkout cannot switch back to it while it does; fix: git -C '$main' worktree remove --force '${wh% (prunable)}' (or git -C '$main' worktree prune if prunable)"
    done <<EOF
$bholders
EOF
  fi

  # trust — the verdict comes from bin/fleet-trust.sh itself
  if [ -n "$main" ] && [ -f "$tr_sh" ]; then
    pretrust=$(_conf_val "$rb_cf" FLEET_PRETRUST); [ -n "$pretrust" ] || pretrust=$(_gconf_val FLEET_PRETRUST)
    verdict=$(sh "$tr_sh" check "$main" 2>/dev/null)
    case "$verdict" in
      trusted)
        pass trust "$r: $main is trusted in $(sh "$tr_sh" file) — workers skip the trust dialog" ;;
      untrusted)
        rb_bad="${rb_bad:+$rb_bad, }trust"
        if [ "$pretrust" = 0 ]; then
          warn trust "$r: $main is NOT trusted and FLEET_PRETRUST=0 — every spawned worker will hang at Claude Code's \"trust this folder?\" dialog; fix: sh $tr_sh grant --main '$main'"
        else
          warn trust "$r: $main is NOT trusted in $(sh "$tr_sh" file) — a worker spawned by a pre-#563 launcher hangs at the \"trust this folder?\" dialog; the current launcher pre-trusts at spawn; fix now: sh $tr_sh grant --main '$main'"
        fi ;;
      *)
        if [ ! -d "$main" ]; then
          :   # already a `main` warning — nothing to trust
        elif ! command -v python3 >/dev/null 2>&1; then
          warn trust "$r: cannot read $(sh "$tr_sh" file) without python3 — trust unknown; pre-trust at spawn is also inert"
        else
          printf '        note: %s: no %s yet (claude has never run here?) — the first spawn creates it with %s trusted.\n' "$r" "$(sh "$tr_sh" file)" "$main"
        fi ;;
    esac
  fi

  # deploy — merged ≠ live (#541); REF wins over CHECK when both are set
  if [ -n "$dref" ]; then
    case "$dref" in \~/*) dref="$HOME/${dref#\~/}" ;; esac
    if git -C "$dref" rev-parse --verify -q HEAD >/dev/null 2>&1; then
      pass deploy "$r: FLEET_DEPLOY_REF $dref — a merged PR reads live once its sha reaches that HEAD"
    else
      warn deploy "$r: FLEET_DEPLOY_REF $dref is not a git checkout — every merged PR's deploy state stays unknown; fix it in $rb_src"
    fi
  elif [ "$dchk" = actions ]; then
    pass deploy "$r: FLEET_DEPLOY_CHECK=actions — live once the merge sha's post-merge Actions runs go green"
  elif [ -n "$dchk" ]; then
    warn deploy "$r: FLEET_DEPLOY_CHECK=\"$dchk\" is not a mode the fleet knows (only \`actions\`) — deploy state stays off; fix it in $rb_src"
  else
    pass deploy "$r: no deploy state configured — MERGED ≡ done"
  fi

  # labels — the filer rejects any label outside the canonical set, and gh starts empty
  if [ -n "$canon_labels" ] && [ -n "$bdef" ]; then
    have=$(printf '%s\n' "$gh_out" | sed 1d)
    # `repo view` returns the first 100 labels only; page the full list past that
    [ "$(printf '%s\n' "$have" | grep -c .)" -ge 100 ] \
      && have=$(gh label list --repo "$r" --limit 1000 --json name -q '.[].name' 2>/dev/null)
    missing=''
    for l in $canon_labels; do
      printf '%s\n' "$have" | grep -qxF "$l" || missing="$missing $l"
    done
    if [ -z "$missing" ]; then
      pass labels "$r: every fleet label is seeded"
    else
      warn labels "$r: missing fleet labels:$missing — filing an issue with one fails; fix: $(dirname "$0")/fleet-labels-seed.sh --repo $r"
    fi
  fi

  rs_n=$((rs_n + 1))
  if [ -z "$rb_bad" ]; then rs_list="${rs_list:+$rs_list · }$r ✓"
  else rs_list="${rs_list:+$rs_list · }$r ✗ ($rb_bad)"; rs_bad=1; fi
}

# _repos_row <sess> <fleet-count> — the one-line `repos` summary (issue #1104): every
# repo the fleet hosts, and whether its checkout (exists, origin matches), base
# branch (set, exists) and trust are healthy — the one line that answers "which
# repos does this fleet run, and are they all usable". A one-repo fleet shows it
# too. The failing items were each already reported (and counted) as their own
# row in the block above, so a WARN here names them without counting again.
_repos_row() {
  rr_tag=''; [ "$2" -gt 1 ] && rr_tag=" ($1)"
  if [ "$rs_n" = 0 ]; then
    pass repos "0 hosted$rr_tag — a fleet with no repo yet (fleet-repo.sh add <owner/repo>)"
  elif [ "$rs_bad" = 0 ]; then
    pass repos "$rs_n hosted$rr_tag: $rs_list"
  else
    printf '  %sWARN%s  %-8s %s\n' "$Y" "$Z" repos "$rs_n hosted$rr_tag: $rs_list"
  fi
}

if [ ! -f "$tr_sh" ]; then
  warn trust "bin/fleet-trust.sh missing — spawns cannot pre-trust the checkout; a worker may park on Claude Code's \"trust this folder?\" dialog (#563); run /fleet-sync-install"
fi
# --- 信任框 (issue #2282): does this machine pre-trust WIDE? — one line, why ------
# A trusted node pre-answers the folder-trust dialog for every hosted repo and for a
# fleet-opened no-repo session's $HOME; otherwise only the window's repo (#563).
# The verdict is fleet-trust.sh node's, the launcher's own reader. Advice: INFO.
if [ -f "$tr_sh" ] && grep -q '^  node)' "$tr_sh" 2>/dev/null; then
  _pt=$(_gconf_val FLEET_PRETRUST)
  _pt_v=$(FLEET_CONF_DIR="$conf_dir" sh "$tr_sh" node 2>/dev/null); _pt_rc=$?
  _pt_why=$(printf '%s' "$_pt_v" | cut -f2-)
  if [ "$_pt" = 0 ]; then
    info 信任框 "不预信任：FLEET_PRETRUST=0 — 新会话都会停在「是否信任此文件夹」"
  elif [ "$_pt_rc" = 0 ]; then
    pass 信任框 "放宽：这台是可信节点（${_pt_why}）— 新会话预信任每个托管仓库的 checkout + worktree，及 fleet 开的无仓库会话的 \$HOME（#2282）"
  else
    info 信任框 "不放宽：这台不算可信节点（${_pt_why:-判不出}）— 只预信任窗口所在仓库的 checkout + worktree（#563）；无仓库会话、编排会话仍会停在「是否信任此文件夹」"
  fi
  unset _pt _pt_v _pt_rc _pt_why
fi
if [ -d "$conf_dir" ]; then
  rs_fleets=$(_fleet_confs "$conf_dir" | grep -c .)
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    case "$cf" in */fleets/*/conf) sess=${cf%/conf}; sess=${sess##*/} ;; *) sess=$(basename "$cf" .conf) ;; esac
    own=$(_norm_repo "$(_conf_val "$cf" FLEET_REPO)")
    seen=' '; rs_n=0; rs_bad=0; rs_list=''
    # compat-1v: 下一批删
    # An old-layout conf still names its first repo (read for one version, issue
    # #1937); a new one names none — every repo is an overlay below.
    if [ -n "$own" ]; then
      ov="$conf_dir/fleets/$sess/repos/$(_repo_slug "$own").conf"; [ -f "$ov" ] || ov=''
      _repo_block "$sess" "$cf" "$own" "$ov" 1
      seen=" $own "
    fi
    for ov in "$conf_dir/fleets/$sess/repos"/*.conf; do
      [ -f "$ov" ] || continue
      r=$(_norm_repo "$(sh -c 'unset FLEET_REPO; . "$1" >/dev/null 2>&1; printf %s "${FLEET_REPO:-}"' _ "$ov")")
      case "$r" in ?*/?*) ;; *) warn repo "$sess: $ov names no FLEET_REPO — that overlay hosts nothing"; continue ;; esac
      case "$seen" in *" $r "*) continue ;; esac
      seen="$seen$r "
      _repo_block "$sess" "$cf" "$r" "$ov" 0
    done
    _repos_row "$sess" "$rs_fleets"
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
fi

# --- alerts (issue #1238): what the status bar counts, READ off the one
# producer's file ($G/alerts.ndjson, bin/fleet-alerts.sh) — the doctor computes
# none of it again. An alarm is a WARN; warnings and needs are listed, not counted.
_af="${TMPDIR:-/tmp/claude-fleet-$(id -u)}/.claude-dash/global/alerts.ndjson"
if [ -f "$_af" ] && command -v bash >/dev/null 2>&1; then
  _fa="$(dirname "$0")/fleet-alerts.sh"
  # shellcheck disable=SC2046
  set -- $(bash "$_fa" counts 2>/dev/null) 0 0 0
  if [ "$1" -gt 0 ]; then
    warn alerts "✖ $1 alarm(s), ▲ $2 warning(s), ● $3 waiting — prefix ! on the status bar lists them"
  else
    pass alerts "no alarm (▲ $2 warning(s), ● $3 waiting)"
  fi
  bash "$_fa" list --plain 2>/dev/null | cut -f2- | sed 's/^/        /'
fi

# --- fleet-open, the laptop half (issue #1380): is extras/iterm2/fleet_open.py
# installed on the operator's computer, and the same version as this checkout's?
# Only when FLEET_OPEN_LAPTOP names that computer's ssh alias (env, or the login
# settings / install fleet.conf). Read over ssh with tight timeouts; a laptop that
# is asleep or off-network is a `?`, never a warning — it is supposed to come and go.
_ol="${FLEET_OPEN_LAPTOP:-$(_gconf_val FLEET_OPEN_LAPTOP)}"
if [ -n "$_ol" ]; then
  _ow=$(sed -n 's/^FLEET_OPEN_VERSION = "\([0-9]*\)".*/\1/p' "$(dirname "$0")/../extras/iterm2/fleet_open.py" 2>/dev/null)
  # shellcheck disable=SC2016  # $HOME expands on the laptop
  if _oh=$(ssh -o BatchMode=yes -o ConnectTimeout=3 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 "$_ol" \
      'f="$HOME/Library/Application Support/iTerm2/Scripts/AutoLaunch/fleet_open.py"; if [ -f "$f" ]; then printf "v%s\n" "$(sed -n "s/^FLEET_OPEN_VERSION = \"\([0-9]*\)\".*/\1/p" "$f")"; else echo none; fi' 2>/dev/null); then
    case "$_oh" in
      none) warn laptop "fleet_open.py not installed on $_ol — from here: ssh $_ol 'bash -s -- --mini <this-mini-alias>' < extras/iterm2/install.sh" ;;
      "v$_ow") pass laptop "fleet_open.py v$_ow installed on $_ol (iTerm2 AutoLaunch)" ;;
      *) warn laptop "fleet_open.py ${_oh:-v?} on $_ol, this checkout has v${_ow:-?} — rerun extras/iterm2/install.sh there" ;;
    esac
  else
    info laptop "? $_ol unreachable over ssh (asleep / off-network) — fleet_open.py not checked"
  fi
fi

# --- compose: ↵ → 能打字 over the last 20 sends (issue #2238, EPIC #2230) ----------
# fleet-compose-latency.sh's one-line summary. No send recorded yet (or none that
# reached 能打字) is no warning — the bar is the batch's 3 s, and only a max past
# it is one. The breakdown is `fleet-compose-latency.sh --last 20`.
if _cs=$(bash "$(dirname "$0")/fleet-compose-latency.sh" --last 20 --summary 2>/dev/null) && [ -n "$_cs" ]; then
  _cn=$(printf '%s' "$_cs" | sed -n 's/.*n=\([0-9]*\).*/\1/p')
  _cr=$(printf '%s' "$_cs" | sed -n 's/.*ready=\([0-9]*\).*/\1/p')
  _cp=$(printf '%s' "$_cs" | sed -n 's/.*p50=\([0-9-]*\).*/\1/p')
  _cm=$(printf '%s' "$_cs" | sed -n 's/.*max=\([0-9-]*\).*/\1/p')
  if [ "${_cr:-0}" -eq 0 ] || [ "$_cm" = - ]; then
    info compose "↵ → 能打字: no measured send yet (${_cn:-0} recorded) — fleet-compose-latency.sh"
  else
    _cmsg=$(awk -v n="$_cr" -v p="$_cp" -v m="$_cm" 'BEGIN { printf "↵ → 能打字 over %d sends: p50 %.1fs · max %.1fs", n, p / 1000, m / 1000 }')
    if [ "$_cm" -gt 3000 ]; then
      warn compose "$_cmsg (> 3s) — fleet-compose-latency.sh --last 20 shows which segment"
    else
      pass compose "$_cmsg"
    fi
  fi
fi

# --- perl Time::HiRes (soft: dash spinner sub-second frames) ---
if command -v perl >/dev/null 2>&1 && perl -MTime::HiRes -e1 >/dev/null 2>&1; then
  pass perl "Time::HiRes present (sub-second spinner)"
else
  warn perl "Time::HiRes missing — dash spinner falls back to whole-second frames"
fi

printf '\n'
if [ "$fails" -gt 0 ]; then
  printf '%s%d fail%s, %d warn — fix the fails before installing.\n' "$R" "$fails" "$Z" "$warns"
elif [ "$warns" -gt 0 ]; then
  printf '%s%d warn%s — usable; the noted features degrade.\n' "$Y" "$warns" "$Z"
else
  printf '%sall good.%s\n' "$G" "$Z"
fi
exit "$fails"
