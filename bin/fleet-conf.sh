#!/bin/bash
# fleet-conf.sh — this machine's ONE fleet config file (issue #1623).
#
#   fleet-conf.sh path                   print it ($FLEET_CONF_DIR/fleet.conf)
#   fleet-conf.sh host [--why]           1 | 0 — does this machine 承载 (host) sessions? FLEET_HOST, else inferred
#   fleet-conf.sh set-host 1|0           write FLEET_HOST (creates the file; drops an old FLEET_ROLE line)
#   fleet-conf.sh migrate [--dry-run] [--quiet]   fold the old files into it (each kept as .bak);
#                                        fills CCQUOTA_FLEET / FLEET_HUB_URL from node.env (#2116);
#                                        moves the role knobs into the person's layer (#2788)
#   fleet-conf.sh set-hub <url> [--host] write FLEET_HUB_URL (+ FLEET_HOST=1 with --host)
#   fleet-conf.sh line <KEY>             print KEY's assignment line(s) as written (exit 1 = none)
#   fleet-conf.sh set-line <KEY> <line>  put <line> where KEY's line is, else under [common] (#2134)
#   fleet-conf.sh drop-line <KEY>        delete KEY's assignment line(s) — the undo of a set-line that added one
#   fleet-conf.sh set-client <KEY> <line> put <line> where KEY's line is in [client], else first in it (#2260)
#   fleet-conf.sh role [--why] · add-role client|node · set-hub … --role client|node — the
#                                        FLEET_ROLE spellings, read for ONE more version (issue #1806)
#
# A machine used to spread its settings over up to five files — the install's
# fleet.conf, $FLEET_CONF_DIR/fleet.settings (#979), fleets/<sess>/conf, the
# shell's shell.conf (#1484) and hub.json's url — and the shell had to run from a
# conf-free mirror of bin/ so a node's settings never reached it. Now there is
# one, in three sections:
#
#   [common]  FLEET_HOST, FLEET_HUB_URL (the hub address, written ONLY here), and
#             the secrets.env include — read by everything
#   [client]  what the shell (fleet / fleet-shell.sh) needs — was shell.conf —
#             inside an `if [ "${FLEET_SHELL:-0}" = 1 ]` guard: only the shell
#   [node]    everything a node's fleet runs on — inside the opposite guard,
#             so the shell skips it wherever the file is sourced, with no
#             mirror and no reader change
#
# Credentials never enter it (issue #1623): a *TOKEN / *SECRET / *PASSWORD
# assignment found in an old file moves to $FLEET_CONF_DIR/secrets.env (0600),
# which the [common] section sources, so every reader resolves it as before.
# node.env (the node token), hub.json's token, ~/.ssh/fleet-cert stay where they
# are, each 0600 on its own.
#
# `migrate` is idempotent and runs on its own: fleet-install-apply.sh (a node's
# sync) and fleet-shell.sh (a client's every start) call it with --quiet. Every value
# resolves exactly as before — the old read order was install fleet.conf <
# fleet.settings < the fleet conf, and the sections keep that order — and each old
# file is kept as <file>.bak; every reader still reads the old paths for one
# version (decision 11 of EPIC #1615), so a machine that never migrates loads byte
# for byte as it did. The fleet conf is folded only when the login has exactly one
# fleet, and keeps its identity (FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH /
# FLEET_SEED) — which migrate_repos then moves into repos/<slug>.conf like every
# other repo (issue #1937).
#
# One capability key (issue #1806, EPIC #1813 C4): every machine has the fleet —
# the part everyone has — and FLEET_HOST=1 says it also 承载 (hosts) sessions. It
# replaces FLEET_ROLE="client|node|client,node": `node` in the old list is
# FLEET_HOST=1, `client` is the fleet itself and needs no key. `migrate` rewrites
# an old FLEET_ROLE line in place (an existing file too), and every reader still
# reads FLEET_ROLE where no FLEET_HOST is written — for one version. The hub's
# protocol keeps its own word, node (node.env, /v1/node/*): docs/TERMS.md.
#
# Exit 0 ok (or nothing to do), 1 failed, 2 usage.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
# The old files are what we read here — never let the lib source them first.
FLEET_SKIP_GLOBAL_CONF=1 . "$BIN/fleet-lib.sh"

die()   { echo "fleet-conf: $*" >&2; exit 1; }
usage() { sed -n '4,14p' "$0" | sed 's/^# //' >&2; exit 2; }

CD="$FLEET_CONF_DIR"
MC="$CD/fleet.conf"
INST="$(cd "$BIN/.." && pwd)/fleet.conf"
CLIENT_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/claude-fleet"
SECRET_RE='^[[:space:]]*(export[[:space:]]+)?[A-Z0-9_]*(TOKEN|SECRET|PASSWORD)='
HUB_RE='^[[:space:]]*(export[[:space:]]+)?(CCQUOTA_HUB_URL|FLEET_HUB_URL)='
COMMON_RE='^[[:space:]]*(export[[:space:]]+)?(FLEET_UI_LANG|FLEET_NODE_ALIASES)='
ROLE_RE='^[[:space:]]*(export[[:space:]]+)?FLEET_ROLE='
HOST_RE='^[[:space:]]*(export[[:space:]]+)?FLEET_HOST='
NODE_OPEN='if [ "${FLEET_SHELL:-0}" != 1 ]; then'
NODE_CLOSE='fi  # ---- [node] end ----'
CLIENT_OPEN='if [ "${FLEET_SHELL:-0}" = 1 ]; then'
CLIENT_CLOSE='fi  # ---- [client] end ----'

# ---- role ---------------------------------------------------------------------
# _role_has <roles> <one> — is <one> in the comma list?
_role_has() { case ",$1," in *",$2,"*) return 0 ;; esac; return 1; }

# _role_norm <roles> → the canonical spelling: client before node, no repeats.
_role_norm() {
  local out=''
  _role_has "$1" client && out=client
  _role_has "$1" node && out="${out:+$out,}node"
  printf '%s' "$out"
}

# _role_file → FLEET_ROLE as the file spells it ('' with no file / no line).
_role_file() {
  [ -f "$MC" ] || return 0
  grep -E "$ROLE_RE" "$MC" 2>/dev/null | tail -n1 | sed -E 's/^[^=]*=//; s/[[:space:]]+#.*$//' | tr -d "\"' "
}

# _role_infer → what this machine IS, from what it holds. A node runs a fleet
# (a fleet conf) or a hub agent (node.env); a client has signed in to a hub
# (hub.json / the 12-hour certificate), kept a shell.conf, or has the `fleet`
# client installed. Prints <role>\\t<why>; '' role = neither: nothing to configure.
_role_infer() {
  local r='' WHY_C='' WHY_N=''
  if [ -f "$CD/hub.json" ]; then WHY_C='hub.json'
  elif [ -f "$CD/shell.conf" ]; then WHY_C='shell.conf'
  elif [ -f "$HOME/.ssh/fleet-cert-cert.pub" ]; then WHY_C="the fleet-cert certificate"
  elif [ -x "$CLIENT_HOME/bin/fleet" ]; then WHY_C="${CLIENT_HOME/#$HOME/~}/bin/fleet"
  fi
  if [ -n "$(fleet_each_conf)" ]; then WHY_N='a fleet conf'
  elif [ -f "$(fleet_node_env_file)" ]; then WHY_N='node.env'
  fi
  [ -n "$WHY_C" ] && r=client
  [ -n "$WHY_N" ] && r="${r:+$r,}node"
  printf '%s\t%s' "$r" "${WHY_C:+client: $WHY_C}${WHY_C:+${WHY_N:+ · }}${WHY_N:+node: $WHY_N}"
}

# ---- host (issue #1806) ----------------------------------------------------------
# _host_file → FLEET_HOST as the file spells it ('' with no file / no line).
_host_file() {
  [ -f "$MC" ] || return 0
  grep -E "$HOST_RE" "$MC" 2>/dev/null | tail -n1 | sed -E 's/^[^=]*=//; s/[[:space:]]+#.*$//' | tr -d "\"' "
}

# _host_of_role <roles> → 1 when the old list says this machine runs sessions.
# `node` alone is not enough: a computer joined only to COORDINATE (issue #1719 —
# node.env CCQUOTA_FLEET_COMPUTE=0, no fleet of its own, the install line's
# --no-fleet join) is a node that hosts nothing — 承载 未开. Whether it hosts is
# _hosts_here's to say.
_host_of_role() {
  _role_has "$1" node || { printf 0; return 0; }
  _hosts_here
}

# _hosts_here → 1 | 0: does this machine really 承载 sessions (issue #1887)?
#   node.env says it: CCQUOTA_FLEET_COMPUTE=0 → 0, any other value → 1, and no
#     COMPUTE line → 1 (a node from before #1719, which the hub places on).
#   no node.env: a fleet conf alone is not enough — fleet-up (or an older sync)
#     leaves one on a laptop that only coordinates. Its fleet must run HERE: a
#     live server on its socket, or the session daemons installed (cleanup — gui
#     LaunchAgent, a guest login's LaunchDaemon, or the systemd timer).
_hosts_here() {
  if [ -r "$(fleet_node_env_file)" ]; then
    case "$(_fleet_node_env_val CCQUOTA_FLEET_COMPUTE 2>/dev/null | tr -d "\"' ")" in 0) printf 0 ;; *) printf 1 ;; esac
    return 0
  fi
  [ -n "$(fleet_each_conf)" ] || { printf 0; return 0; }
  if [ -n "$(fleet_sockets 2>/dev/null)" ] || _session_daemons; then printf 1; else printf 0; fi
}

_session_daemons() {
  [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/claude-fleet-cleanup.timer" ] && return 0
  [ -f "$BIN/fleet-daemon-lib.sh" ] || return 1
  ( . "$BIN/fleet-daemon-lib.sh" 2>/dev/null
    for sh in gui system; do [ -f "$(fleet_daemon_plist cleanup "$sh")" ] && exit 0; done
    exit 1 )
}

# _host_now → <1|0>\t<how>: FLEET_HOST, else the old FLEET_ROLE (one version),
# else inferred from what the machine holds (a fleet conf / node.env = it hosts).
_host_now() {
  local h r ri
  h=$(_host_file)
  case "$h" in
    1|0) printf '%s\tFLEET_HOST' "$h"; return 0 ;;
    '') ;;
    *) printf '0\tFLEET_HOST=%s 不认识，按 0' "$h"; return 0 ;;
  esac
  r=$(_role_file)
  if [ -n "$r" ]; then printf '%s\tFLEET_ROLE=%s（旧键）' "$(_host_of_role "$r")" "$r"; return 0; fi
  # Nothing written yet: a read, as it always was — a node with a fleet conf
  # here, or one the hub may place on, hosts. What a migration WRITES is
  # _hosts_here's stricter answer (issue #1887).
  local why h1=0
  ri=$(_role_infer); r=${ri%%	*}; why=''
  case "${ri#*	}" in *node:*) why=" — ${ri#*node: }" ;; esac
  if _role_has "$r" node && { [ -n "$(fleet_each_conf)" ] || [ "$(_fleet_node_env_val CCQUOTA_FLEET_COMPUTE 2>/dev/null)" != 0 ]; }; then h1=1; fi
  printf '%s\tinferred%s' "$h1" "$why"
}

# _migrate_key — an old FLEET_ROLE line becomes FLEET_HOST, in place (the line's
# position and every other line kept). Prints what it did; nothing when there was
# nothing to do. A file with both keeps FLEET_HOST and drops the old one.
_migrate_key() {
  local r h tmp
  [ -f "$MC" ] || return 0
  r=$(_role_file)
  [ -n "$r" ] || grep -Eq "$ROLE_RE" "$MC" || return 0
  _bak_mc >/dev/null || return 1
  h=$(_host_file)
  if [ -n "$h" ]; then
    _drop_role || return 1
  else
    h=$(_host_of_role "$r")
    _set_common "$MC" FLEET_ROLE "FLEET_HOST=$h" || return 1
  fi
  printf 'FLEET_ROLE="%s" → FLEET_HOST=%s' "$r" "$h"
}

_drop_role() {
  local tmp="$MC.tmp.$$"
  grep -Ev "$ROLE_RE" "$MC" > "$tmp" \
    && { chmod "$(stat -c '%a' "$MC" 2>/dev/null || stat -f '%Lp' "$MC")" "$tmp" 2>/dev/null; mv -f "$tmp" "$MC"; } \
    || { rm -f "$tmp"; return 1; }
}

# _bak_mc → keep fleet.conf as it is now, before a migration rewrites it (issue
# #1887): fleet.conf.bak-<YYYYmmdd-HHMMSS>, 0600 like the file. Prints its path.
_bak_mc() {
  local b
  [ -f "$MC" ] || return 0
  b="$MC.bak-$(date +%Y%m%d-%H%M%S)"
  [ -e "$b" ] || cp -p "$MC" "$b" || return 1
  printf '%s' "$b"
}

# _host_mark <why> — the one line under FLEET_HOST that says the correction below
# has run: it never runs twice. (A person's `fleet host on` needs no mark — it
# turns compute on or installs the session daemons, which _hosts_here reads as 1.)
# Replaces an earlier mark.
HOST_MARK='# FLEET_HOST checked'
_host_mark() {
  local tmp="$MC.tmp.$$"
  awk -v mark="$HOST_MARK" -v line="$HOST_MARK $(date '+%Y-%m-%d %H:%M:%S') — $1 (issue #1887)" -v re="$HOST_RE" '
    index($0, mark) == 1 { next }
    { print }
    $0 ~ re && !done { print line; done = 1 }
  ' "$MC" > "$tmp" && { chmod "$(stat -c '%a' "$MC" 2>/dev/null || stat -f '%Lp' "$MC")" "$tmp" 2>/dev/null; mv -f "$tmp" "$MC"; } \
    || { rm -f "$tmp"; return 1; }
}

# _host_correct [dry] — a FLEET_HOST=1 a MIGRATION wrote (the file's «Migrated by»
# header, no mark) on a machine that does not host (_hosts_here = 0) goes to 0,
# once: before #1887 FLEET_ROLE=client,node and a leftover fleet conf both read as
# 承载. The old file is kept (.bak-<time>) and the mark records it. Prints what it
# did (or would do); nothing when there was nothing to do.
_host_correct() {
  local b
  [ -f "$MC" ] && [ "$(_host_file)" = 1 ] || return 0
  grep -q '^# Migrated by fleet-conf\.sh' "$MC" || return 0
  grep -q "^$HOST_MARK" "$MC" && return 0
  [ "$(_hosts_here)" = 0 ] || return 0
  if [ "${1:-0}" = 1 ]; then printf 'would correct FLEET_HOST 1 → 0 (this machine hosts no sessions)'; return 0; fi
  b=$(_bak_mc) || return 1
  _set_common "$MC" FLEET_HOST "FLEET_HOST=0" || return 1
  _host_mark 'migrated as 1, corrected to 0: no compute, no fleet running here' || return 1
  printf 'FLEET_HOST 1 → 0 — this machine hosts no sessions (no compute, no fleet running here); was kept as %s' "${b##*/}"
}

set_host() {   # $1 1|0
  _ensure_file "$1" || die "cannot write $MC"
  if grep -Eq "$HOST_RE" "$MC"; then
    _set_common "$MC" FLEET_HOST "FLEET_HOST=$1" || die "cannot write $MC"
    _drop_role || die "cannot write $MC"
  elif grep -Eq "$ROLE_RE" "$MC"; then
    _set_common "$MC" FLEET_ROLE "FLEET_HOST=$1" || die "cannot write $MC"
  else
    _set_common "$MC" FLEET_HOST "FLEET_HOST=$1" || die "cannot write $MC"
  fi
}

# ---- editing the file -----------------------------------------------------------
# _skeleton <host 1|0> <hub> — a fresh file: header, the three sections, nothing else.
_skeleton() {
  printf "# claude-fleet — this machine's ONE config file (issue #1623). Assignments only.\n"
  printf '# Credentials never live here: node.env, hub.json (its token), secrets.env and\n'
  printf '# ~/.ssh/fleet-cert are separate, each 0600. FLEET_HOST=1: this machine also 承载\n'
  printf '# (hosts) sessions (issue #1806); the shell (FLEET_SHELL=1) reads [common] + [client];\n'
  printf '# everything else [common] + [node].\n'
  printf '\n# ---- [common] ----\n'
  printf 'FLEET_HOST=%s\n' "$1"
  [ -n "$2" ] && printf 'export FLEET_HUB_URL="%s"\n' "$2"
  printf '_fcs="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/secrets.env"; [ -f "$_fcs" ] && . "$_fcs"; unset _fcs\n'
  printf '\n# ---- [client] — only the shell (FLEET_SHELL=1) reads this section ----\n'
  printf '%s\n:\n%s\n' "$CLIENT_OPEN" "$CLIENT_CLOSE"
  printf '\n# ---- [node] — the shell (FLEET_SHELL=1) does not read this section ----\n'
  printf '%s\n:\n%s\n' "$NODE_OPEN" "$NODE_CLOSE"
}

# _set_common <file> <KEY> <assignment-line> — replace KEY's line where it is,
# else add it right under the [common] header (else at the end). Atomic (tmp +
# mv), mode kept.
_set_common() {
  local f="$1" key="$2" line="$3" tmp="$1.tmp.$$" had=0
  grep -Eq "^[[:space:]]*(export[[:space:]]+)?$key=" "$f" && had=1
  awk -v key="$key" -v line="$line" -v done="$had" '
    BEGIN { re = "^[[:space:]]*(export[[:space:]]+)?" key "="; put = 0 }
    $0 ~ re { if (!put) print line; put = 1; next }
    { print }
    /^# ---- \[common\] ----$/ && !done { print line; done = 1; put = 1 }
    END { if (!done && !put) print line }
  ' "$f" > "$tmp" && { chmod "$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f")" "$tmp" 2>/dev/null; mv -f "$tmp" "$f"; } \
    || { rm -f "$tmp"; return 1; }
}

# _set_client <file> <KEY> <assignment-line> — replace KEY's line inside the
# [client] guard, else add it first inside it (a file with no guard gets one at
# its end). Atomic, mode kept — FLEET_CLIENT_LAYOUT (#2260) is the shell's only.
_set_client() {
  local f="$1" key="$2" line="$3" tmp="$1.tmp.$$" had=0
  awk -v key="$key" -v open="$CLIENT_OPEN" 'BEGIN { re = "^[[:space:]]*(export[[:space:]]+)?" key "=" }
    $0 == open { inside = 1; next } inside && /^fi  # ---- \[client\] end/ { inside = 0 }
    inside && $0 ~ re { found = 1 } END { exit found ? 0 : 1 }' "$f" && had=1
  awk -v key="$key" -v line="$line" -v open="$CLIENT_OPEN" -v cclose="$CLIENT_CLOSE" -v had="$had" '
    BEGIN { re = "^[[:space:]]*(export[[:space:]]+)?" key "=" }
    $0 == open { print; inside = 1; seen = 1; if (!had) { print line; put = 1 }; next }
    inside && $0 == cclose { inside = 0 }
    inside && $0 ~ re { if (!put) print line; put = 1; next }
    { print }
    END { if (!seen) { print ""; print open; print line; print cclose } }
  ' "$f" > "$tmp" && { chmod "$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f")" "$tmp" 2>/dev/null; mv -f "$tmp" "$f"; } \
    || { rm -f "$tmp"; return 1; }
}

_ensure_file() {   # $1 FLEET_HOST (1|0) to start a new file with
  [ -f "$MC" ] && return 0
  mkdir -p "$CD" || return 1
  ( umask 077; _skeleton "$1" '' > "$MC.tmp.$$" ) && mv -f "$MC.tmp.$$" "$MC"
}

# add_role client|node — the old spelling (one version): node = FLEET_HOST=1;
# client = the fleet itself, which every file has — it only makes sure there is
# one (and turns an old FLEET_ROLE line into FLEET_HOST). Never turns hosting off.
add_role() {
  if [ "$1" = node ]; then set_host 1; return; fi
  _ensure_file 0 || die "cannot write $MC"
  _migrate_key >/dev/null || die "cannot write $MC"
}

# ---- migrate -------------------------------------------------------------------
# _bak <file> — keep the old file beside itself as .bak (never clobber an older one).
_bak_path() { if [ -e "$1.bak" ]; then printf '%s.bak.%s' "$1" "$(date +%Y%m%d%H%M%S)"; else printf '%s.bak' "$1"; fi; }

# _hub_of <file> — the hub URL its LAST CCQUOTA_HUB_URL / FLEET_HUB_URL line sets
# ('' if none), evaluated in a subshell: the confs are trusted assignments.
_hub_of() {
  local l
  [ -f "$1" ] || return 0
  l=$(grep -E "$HUB_RE" "$1" | tail -n1)
  [ -n "$l" ] || return 0
  ( unset CCQUOTA_HUB_URL FLEET_HUB_URL; eval "$l" >/dev/null 2>&1; printf '%s' "${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-}}" )
}

# _body <file> <drop-ERE> — the file's lines minus our own fleet-up header, the
# hub lines, the secrets, FLEET_ROLE / FLEET_HOST and <drop-ERE> (if not empty).
_body() {
  local ourhdr='^# (claude-fleet: fleet .* written by fleet-up\.sh|Overlays the global fleet\.conf|FLEET_\* keys \(see fleet\.conf\.example\))'
  local drop="${2:-^\$^}"
  grep -Ev "$HUB_RE" "$1" | grep -Ev "$SECRET_RE" | grep -Ev "$ROLE_RE" | grep -Ev "$HOST_RE" | grep -Ev "$ourhdr" | grep -Ev "$drop"
}

# _carry <old> <new> — every assignment <old> makes in its [common] / [client] /
# [node] section whose key <new>'s same section does not set goes into <new>, at
# that section's end (issue #1887). <new> is edited in place; mode kept.
_carry() {
  local tmp="$2.carry.$$"
  awk -v co="$CLIENT_OPEN" -v cc="$CLIENT_CLOSE" -v no="$NODE_OPEN" -v nc="$NODE_CLOSE" '
    function sect(l) {
      if (l == "# ---- [common] ----") { cur = "common"; return 1 }
      if (l == co) { cur = "client"; return 1 }
      if (l == no) { cur = "node"; return 1 }
      if (l == cc || l == nc) { cur = ""; return 1 }
      if (cur == "common" && l ~ /^# ---- \[/) cur = ""
      return 0
    }
    function key(l,   k) {
      if (l !~ /^[ \t]*(export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/) return ""
      k = l; sub(/^[ \t]*(export[ \t]+)?/, "", k); sub(/=.*/, "", k); return k
    }
    FNR == 1 { cur = "" }
    NR == FNR { if (sect($0) || cur == "") next
                k = key($0); if (k == "") next
                if (!((cur, k) in old)) { order[cur] = order[cur] SUBSEP k; }
                old[cur, k] = $0; next }
    { line[++n] = $0; if (!sect($0) && cur != "" && (k = key($0)) != "") have[cur, k] = 1
      if ($0 == cc) hascl = 1; if ($0 == nc) hasnd = 1 }
    function extra(s,   m, i, ks, o) {
      o = ""; m = split(substr(order[s], 2), ks, SUBSEP)
      for (i = 1; i <= m; i++) if (!((s, ks[i]) in have)) o = o old[s, ks[i]] "\n"
      return o
    }
    END {
      ec = extra("common"); el = extra("client"); en = extra("node")
      if (!hasnd) { ec = ec en; en = "" }
      if (!hascl) { ec = ec el; el = "" }
      cur = ""
      for (i = 1; i <= n; i++) {
        l = line[i]
        if (cur == "common" && ec != "" && l == "" && line[i + 1] ~ /^# ---- \[/) { printf "%s", ec; ec = "" }
        prev = cur; sect(l)
        if (prev == "common" && cur != "common" && ec != "") { printf "%s", ec; ec = "" }
        if (l == cc && el != "") { printf "%s", el; el = "" }
        if (l == nc && en != "") { printf "%s", en; en = "" }
        print l
      }
      printf "%s", ec
    }
  ' "$1" "$2" > "$tmp" && sh -n "$tmp" 2>/dev/null \
    && { chmod "$(stat -c '%a' "$2" 2>/dev/null || stat -f '%Lp' "$2")" "$tmp" 2>/dev/null; mv -f "$tmp" "$2"; } \
    || { rm -f "$tmp"; return 1; }
}

# _keep_scoped <old conf> <new conf> — the trimmed conf keeps the old one's other
# repo-scoped lines (deploy, short name) beside its identity.
_keep_scoped() {
  grep -E "^[[:space:]]*(export[[:space:]]+)?(FLEET_DEPLOY_REF|FLEET_DEPLOY_CHECK|FLEET_REPO_SHORT)[[:space:]]*=" "$1" >> "$2"
  return 0
}

migrate() {
  local DRY="$1" QUIET="$2"
  local SET="$CD/fleet.settings" SH="$CD/shell.conf" HJ="$CD/hub.json"
  if [ -f "$MC" ]; then
    # the one-key rename (issue #1806) runs on a file that is already one
    local mk hc
    if [ "$DRY" = 1 ]; then
      grep -Eq "$ROLE_RE" "$MC" && { echo "fleet-conf: would rewrite FLEET_ROLE=\"$(_role_file)\" as FLEET_HOST=$(_host_of_role "$(_role_file)") in $MC"; return 0; }
      hc=$(_host_correct 1); [ -n "$hc" ] && { echo "fleet-conf: $hc ($MC)"; return 0; }
    else
      mk=$(_migrate_key) || die "cannot rewrite FLEET_ROLE in $MC"
      hc=$(_host_correct) || die "cannot correct FLEET_HOST in $MC"
      [ -n "$mk" ] && echo "fleet-conf: $mk ($MC)"
      [ -n "$hc" ] && echo "fleet-conf: $hc ($MC)"
      [ -n "$mk$hc" ] && return 0
    fi
    [ "$QUIET" = 1 ] || echo "fleet-conf: already one file — $MC"
    return 0
  fi
  local role; role=$(_role_infer); role=${role%%	*}
  [ -f "$INST" ] || INST=''
  [ -f "$SET" ] || SET=''
  [ -f "$SH" ] || SH=''
  # The fleet conf folds only for a login with exactly ONE fleet (the rule since
  # #980); several stay per fleet, untouched.
  local sess='' FC='' rc
  sess=$(fleet_login_fleet); rc=$?
  [ "$rc" = 0 ] && FC=$(fleet_conf_file "$sess")
  [ -n "$FC" ] && [ -f "$FC" ] || FC=''
  if [ -z "$role" ] && [ -z "$INST$SET$SH$FC" ]; then
    [ "$QUIET" = 1 ] || echo "fleet-conf: nothing to migrate — this login is neither a client nor a node yet"
    return 0
  fi
  [ -n "$role" ] || role=node     # settings with no fleet / hub sign-in: a node's
  local host; host=$(_host_of_role "$role")

  # The hub address — written once. Precedence is the old read order (the fleet
  # conf over fleet.settings over the install file), then what the shell and the
  # client used, then the node agent's copy.
  local hub='' src hubexp=0
  for src in "$FC" "$SET" "$INST"; do
    [ -n "$src" ] || continue
    [ -n "$hub" ] || hub=$(_hub_of "$src")
    grep -Eq '^[[:space:]]*(export[[:space:]]+)?CCQUOTA_HUB_URL=' "$src" && hubexp=1
  done
  local hub_sh; hub_sh=$( [ -n "$SH" ] && _hub_of "$SH" )
  [ -n "$hub" ] || hub="$hub_sh"
  local hub_json=''
  [ -f "$HJ" ] && hub_json=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("url") or "")
except Exception: print("")' "$HJ" 2>/dev/null)
  [ -n "$hub" ] || hub="$hub_json"
  [ -n "$hub" ] || hub=$(_fleet_node_env_val CCQUOTA_HUB_URL 2>/dev/null)

  # The node section takes the old files in their old read order; the fleet conf
  # loses its identity (it stays there) and any global-only key (its copy there
  # was never read — fleet_load_conf strips it, #237).
  # identity = every repo-scoped key (_FLEET_REPO_SCOPED): it describes the conf's
  # repo, so it stays with it — migrate_repos then moves it into repos/ (#1937).
  # A machine-wide FLEET_DEPLOY_REF would apply to no repo there.
  local identity="^[[:space:]]*(export[[:space:]]+)?(${_FLEET_REPO_SCOPED// /|})[[:space:]]*="
  local globals="^[[:space:]]*(export[[:space:]]+)?(${_FLEET_GLOBAL_ONLY// /|})="
  local tmp="$MC.tmp.$$"
  local nodesec=node; _role_has "$role" node || nodesec=common
  {
    printf "# claude-fleet — this machine's ONE config file (issue #1623). Assignments only.\n"
    printf '# Migrated by fleet-conf.sh %s from: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" \
      "$(printf '%s ' ${INST:+"${INST/#$HOME/~}"} ${SET:+fleet.settings} ${FC:+"${FC#$CD/}"} ${SH:+shell.conf} ${hub_json:+hub.json(url)} | sed 's/ $//; s/^$/nothing — a new file/')"
    printf '# Credentials never live here: node.env, hub.json (its token), secrets.env and\n'
    printf '# ~/.ssh/fleet-cert are separate, each 0600. FLEET_HOST=1: this machine also 承载\n'
    printf '# (hosts) sessions (issue #1806); the shell (FLEET_SHELL=1) reads [common] + [client];\n'
    printf '# everything else [common] + [node].\n'
    printf '\n# ---- [common] ----\n'
    printf 'FLEET_HOST=%s\n' "$host"
    if [ -n "$hub" ]; then
      printf 'export FLEET_HUB_URL="%s"\n' "$hub"
      # The node's scripts read CCQUOTA_HUB_URL; it is FLEET_HUB_URL, not a copy.
      [ "$hubexp" = 1 ] && printf 'export CCQUOTA_HUB_URL="$FLEET_HUB_URL"\n'
    fi
    printf '_fcs="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/secrets.env"; [ -f "$_fcs" ] && . "$_fcs"; unset _fcs\n'
    for src in "$INST" "$SET" "$FC"; do
      [ -n "$src" ] || continue
      grep -E "$COMMON_RE" "$src"
    done
    printf '\n# ---- [client] — only the shell (FLEET_SHELL=1) reads this section ----\n'
    printf '%s\n:\n' "$CLIENT_OPEN"
    if [ -n "$SH" ]; then
      # A shell.conf hub line that names another hub than the one above stays,
      # as it was: it only ever applied to the shell.
      if [ -n "$hub_sh" ] && [ "$hub_sh" != "$hub" ]; then
        printf '# shell.conf named a different hub than [common] — kept for the shell only\n'
        grep -E "$HUB_RE" "$SH" | tail -n1
      fi
      _body "$SH" ""
    fi
    printf '%s\n' "$CLIENT_CLOSE"
    if [ "$nodesec" = node ]; then
      printf '\n# ---- [node] — the shell (FLEET_SHELL=1) does not read this section ----\n'
      printf '%s\n:\n' "$NODE_OPEN"
    fi
    if [ -n "$INST" ]; then
      printf '# ---- was %s ----\n' "${INST/#$HOME/~}"; _body "$INST" "$COMMON_RE"
    fi
    if [ -n "$SET" ]; then
      printf '# ---- was fleet.settings ----\n'; _body "$SET" "$COMMON_RE"
    fi
    if [ -n "$FC" ]; then
      printf '# ---- was %s (fleet %s) ----\n' "${FC#$CD/}" "$sess"
      _body "$FC" "$COMMON_RE" | grep -Ev "$identity" | grep -Ev "$globals"
    fi
    if [ "$nodesec" = node ]; then printf '%s\n' "$NODE_CLOSE"; fi
  } > "$tmp" || { rm -f "$tmp"; die "failed to build $MC"; }

  # Secrets, in the old read order (last wins, as sourcing did).
  local stmp="$CD/secrets.env.tmp.$$" nsec=0
  ( umask 077
    for src in "$INST" "$SET" "$FC" "$SH"; do
      [ -n "$src" ] || continue
      grep -E "$SECRET_RE" "$src"
    done > "$stmp" )
  nsec=$(grep -c . "$stmp" 2>/dev/null); nsec=${nsec:-0}

  # The file must parse in every shell that sources it.
  if ! sh -n "$tmp" 2>/dev/null; then
    rm -f "$tmp" "$stmp"; die "the merged file does not parse — nothing changed (sh -n $tmp)"
  fi

  if [ "$DRY" = 1 ]; then
    printf 'fleet-conf: would write %s (FLEET_HOST=%s):\n' "$MC" "$host"
    sed 's/^/  | /' "$tmp"
    [ "$nsec" -gt 0 ] && printf 'fleet-conf: would move %s credential line(s) to %s (0600): %s\n' "$nsec" "$CD/secrets.env" \
      "$(sed -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Z0-9_]+)=.*/\2/' "$stmp" | tr '\n' ' ')"
    for src in "$INST" "$SET" "$SH"; do [ -n "$src" ] && printf 'fleet-conf: would keep %s as .bak and stop using it\n' "$src"; done
    [ -n "$FC" ] && printf 'fleet-conf: would trim %s to its identity (FLEET_REPO / FLEET_MAIN / FLEET_BASE_BRANCH)\n' "$FC"
    [ -n "$hub_json" ] && printf 'fleet-conf: would drop url from %s (its token stays)\n' "$HJ"
    rm -f "$tmp" "$stmp"; return 0
  fi

  # Order: the secrets and the new file land first, so an interruption leaves at
  # worst a key set twice to the same value, never a lost one.
  chmod 600 "$tmp" 2>/dev/null
  if [ "$nsec" -gt 0 ]; then
    if [ -f "$CD/secrets.env" ]; then cat "$CD/secrets.env" "$stmp" > "$stmp.2" && mv -f "$stmp.2" "$stmp"; fi
    chmod 600 "$stmp" && mv -f "$stmp" "$CD/secrets.env" || { rm -f "$tmp" "$stmp"; die "failed to write $CD/secrets.env"; }
  else
    rm -f "$stmp"
  fi
  # A fleet.conf that appeared since the check above (another start, a sync) is
  # never clobbered: it is kept as .bak-<time> and every key it set that the new
  # file does not, in [common] [client] [node], is carried over (issue #1887).
  local kept=''
  if [ -f "$MC" ]; then
    kept=$(_bak_mc) || { rm -f "$tmp"; die "cannot keep $MC"; }
    _carry "$MC" "$tmp" || { rm -f "$tmp"; die "cannot carry $MC's keys"; }
  fi
  mv -f "$tmp" "$MC" || { rm -f "$tmp"; die "failed to write $MC"; }
  local moved=''
  [ -n "$kept" ] && moved=" fleet.conf(kept as ${kept##*/}, its keys carried)"
  for src in "$INST" "$SET" "$SH"; do
    [ -n "$src" ] || continue
    mv -f "$src" "$(_bak_path "$src")" && moved="$moved ${src##*/}"
  done
  if [ -n "$FC" ]; then
    local repo main base seed
    repo=$( . "$FC" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
    main=$( . "$FC" >/dev/null 2>&1; printf '%s' "${FLEET_MAIN:-}" )
    base=$( . "$FC" >/dev/null 2>&1; printf '%s' "${FLEET_BASE_BRANCH:-}" )
    seed=$( . "$FC" >/dev/null 2>&1; printf '%s' "${FLEET_SEED:-}" )
    cp -p "$FC" "$(_bak_path "$FC")"
    rm -f "$FC.new.$$"
    fleet_write_conf "$FC.new.$$" "$sess" "$repo" "$main" "$base" "$(date '+%Y-%m-%d %H:%M:%S')" \
      && { [ "$seed" != 1 ] || fleet_conf_set "$FC.new.$$" FLEET_SEED 1; } \
      && _keep_scoped "$FC" "$FC.new.$$" \
      && mv -f "$FC.new.$$" "$FC" || { rm -f "$FC.new.$$"; die "wrote $MC but could not trim $FC"; }
    moved="$moved ${FC#$CD/}(trimmed)"
  fi
  if [ -n "$hub_json" ]; then
    cp -p "$HJ" "$(_bak_path "$HJ")"
    python3 - "$HJ" <<'PY' || die "wrote $MC but could not drop url from $HJ"
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
d.pop("url", None)
if d:
    t = p + ".tmp"
    fd = os.open(t, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(d, f)
    os.replace(t, p)
else:
    os.remove(p)   # it held only the url: nothing of it is left to keep (the .bak has it)
PY
    moved="$moved hub.json(url)"
  fi
  [ "$QUIET" = 1 ] || {
    echo "fleet-conf: one file — $MC (FLEET_HOST=$host)"
    echo "fleet-conf: folded in:${moved:- nothing}; each old file kept as .bak"
    [ "$nsec" -gt 0 ] && echo "fleet-conf: $nsec credential line(s) moved to $CD/secrets.env (0600)"
  }
  [ "$QUIET" = 1 ] && [ -n "$moved" ] && echo "fleet-conf: migrated to $MC (FLEET_HOST=$host):$moved"
  return 0
}

# ---- the hub switch the node agent has and fleet.conf lost (issue #2116) ----------
# The agent reads node.env (CCQUOTA_FLEET=1, CCQUOTA_HUB_URL) and keeps using the
# hub, while every fleet script reads fleet.conf — and a migrate that ran after the
# install's fleet.conf had already gone to .bak (the stable link switch, a second
# run) folded neither key in. Then fleet-relay-cred.sh / fleet-node-trust.sh /
# fleet-mcp.py --cred all said "the hub module is off". hub_fill writes what
# node.env says into [common] — fill only: a CCQUOTA_FLEET line anywhere in the
# file (even =0, the operator's word) or any hub URL line is left as it is.
# FLEET_HUB_URL is the address only — a URL carrying user:pass@ is not written.
# No node.env (a client) ⇒ nothing read, nothing written.
hub_fill() {
  local DRY="$1" QUIET="$2" on url did=''
  [ -f "$MC" ] || return 0
  [ -r "$(fleet_node_env_file)" ] || [ -r "$CD/node.pub.env" ] || return 0
  on=$(_fleet_node_env_val CCQUOTA_FLEET 2>/dev/null | tr -d "\"' ")
  url=$(_fleet_node_env_val CCQUOTA_HUB_URL 2>/dev/null | tr -d "\"' ")
  if [ "$on" = 1 ] && ! grep -Eq '^[[:space:]]*(export[[:space:]]+)?CCQUOTA_FLEET[[:space:]]*=' "$MC"; then
    did="$did CCQUOTA_FLEET=1"
    [ "$DRY" = 1 ] || _set_common "$MC" CCQUOTA_FLEET 'export CCQUOTA_FLEET=1' || die "cannot write CCQUOTA_FLEET into $MC"
  fi
  if [ -n "$url" ] && ! grep -Eq "$HUB_RE" "$MC"; then
    case "$url" in
      *://*@*) echo "fleet-conf: node.env's CCQUOTA_HUB_URL carries credentials — FLEET_HUB_URL not written; set it by hand (fleet-conf.sh set-hub <url>)" >&2 ;;
      *) did="$did FLEET_HUB_URL"
         [ "$DRY" = 1 ] || _set_common "$MC" FLEET_HUB_URL "export FLEET_HUB_URL=\"$url\"" || die "cannot write FLEET_HUB_URL into $MC" ;;
    esac
  fi
  [ -n "$did" ] || return 0
  if [ "$DRY" = 1 ]; then echo "fleet-conf: would add to $MC [common] from node.env:$did"
  else echo "fleet-conf: added to $MC [common] from node.env:$did"; fi
  return 0
}

# ---- a machine config stranded as fleet `fleet` (issue #2059) ---------------------
# Before #1887 the layout migrator took $FLEET_CONF_DIR/fleet.conf — the machine's
# ONE file — for the legacy flat conf of a fleet named `fleet` and moved it to
# fleets/fleet/conf. The next migrate found no fleet.conf and wrote an empty one,
# so every setting in the stranded file stopped applying, and fleet_each_conf
# listed a phantom fleet `fleet` (#1937 then moved its trailing FLEET_REPO into
# fleets/fleet/repos/: the phantom "hosted" that repo and bridged it, while the
# real fleet's repos went unbridged). rescue_stranded carries the stranded file's
# keys into fleet.conf — fill only, section by section (_carry): a key fleet.conf
# already sets keeps its value — and retires the phantom's directory to
# fleets/.stranded-machine-conf-<time>/ (a dot dir: no fleet glob lists it). Never
# while a live tmux server answers to `fleet`. Idempotent: nothing stranded, nothing done.
STRANDED_HDR="# claude-fleet — this machine's ONE config file"
rescue_stranded() {
  local DRY="$1" QUIET="$2" d="$CD/fleets/fleet" sc l src dst
  sc="$d/conf"
  [ -f "$sc" ] || return 0
  IFS= read -r l < "$sc" || true
  case "$l" in "$STRANDED_HDR"*) ;; *) return 0 ;; esac
  if tmux -L "$(fleet_socket fleet)" has-session 2>/dev/null; then
    echo "fleet-conf: $sc is a stranded machine config, but a live fleet \`fleet\` is running — left as it is" >&2
    return 0
  fi
  dst="$CD/fleets/.stranded-machine-conf-$(date +%Y%m%d-%H%M%S)"
  if [ "$DRY" = 1 ]; then
    echo "fleet-conf: would carry the machine config stranded in ${sc#$CD/} into $MC (fill only) and retire ${d#$CD/}/ as ${dst#$CD/}/"
    return 0
  fi
  src="$MC.stranded.$$"
  # FLEET_ROLE / FLEET_HOST belong to fleet.conf as it is; a credential never enters it.
  grep -Ev "$ROLE_RE" "$sc" | grep -Ev "$HOST_RE" | grep -Ev "$SECRET_RE" > "$src" || true
  _ensure_file 1 || { rm -f "$src"; die "cannot write $MC"; }
  _bak_mc >/dev/null || { rm -f "$src"; die "cannot keep $MC"; }
  _carry "$src" "$MC" || { rm -f "$src"; die "cannot carry ${sc#$CD/}'s keys into $MC — nothing moved"; }
  rm -f "$src"
  mv "$d" "$dst" || die "carried ${sc#$CD/}'s keys into $MC but could not retire ${d#$CD/}/"
  echo "fleet-conf: the machine config stranded in ${sc#$CD/} is back in $MC (keys it lacked carried); ${d#$CD/}/ retired as ${dst#$CD/}/"
  return 0
}

# ---- every repo in repos/ (issue #1937) -----------------------------------------
# A fleet conf used to hold its first repo (FLEET_REPO / FLEET_MAIN / … ); every
# repo now lives in fleets/<sess>/repos/<slug>.conf. Every fleet on this login —
# not only a one-fleet login's — gets its conf's repo moved there by
# fleet_conf_repo_migrate (identity frozen first, both files kept as .bak, the repo
# first in repos/.order so fleet_repos lists what it did). Idempotent; readers
# still read the old place for one version.
migrate_repos() {
  local DRY="$1" QUIET="$2" s c out rc moved=''
  while IFS=$'\t' read -r s c; do
    [ -n "$s" ] && [ -f "$c" ] || continue
    grep -Eq '^[[:space:]]*(export[[:space:]]+)?FLEET_REPO[[:space:]]*=' "$c" || continue
    if [ "$DRY" = 1 ]; then
      printf 'fleet-conf: would move fleet %s'\''s repo %s out of %s into repos/\n' "$s" \
        "$( unset FLEET_REPO; . "$c" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-?}" )" "${c#$CD/}"
      continue
    fi
    out=$(fleet_conf_repo_migrate "$s"); rc=$?
    case "$rc" in
      0) [ -n "$out" ] && moved="$moved $s:${out#moved }" ;;
      2) echo "fleet-conf: fleet $s's conf names a FLEET_REPO that is not owner/name — left where it is" >&2 ;;
      *) die "could not move fleet $s's repo out of $c into repos/ — nothing half-moved" ;;
    esac
  done <<EOF
$(fleet_each_conf)
EOF
  [ -n "$moved" ] && echo "fleet-conf: every repo in repos/ —$moved (each conf kept as .bak)"
  return 0
}

# ---- the role knobs move into the person's layer (issue #2788) -------------------
# FLEET_ORCH_MODEL / _EFFORT, FLEET_STEWARD_MODEL / _EFFORT and FLEET_MODEL were
# each a launcher's own knob; a role's definition (agents/<role>.md) and the
# person's layer over it now say the same, and while fleet.conf still sets one it
# wins over both (compat-1v). fleet-role.py migrate-conf moves every value that
# differs from the built-in into the person's layer (one PUT, note 「从 <机器> 的
# fleet.conf 迁入」) and comments the lines out (fleet.conf.bak-<time> kept);
# the switches (FLEET_ORCHESTRATOR / FLEET_STEWARD), beats, caps and park
# thresholds are this machine's and stay. Idempotent: no active line, nothing
# done. The hub away leaves the lines that need it — they still win, as before.
migrate_roles() {
  local DRY="$1" dr='' out
  [ -f "$MC" ] || return 0
  [ "$DRY" = 1 ] && dr=--dry-run
  grep -Eq '^[[:space:]]*(export[[:space:]]+)?(FLEET_ORCH_MODEL|FLEET_ORCH_EFFORT|FLEET_STEWARD_MODEL|FLEET_STEWARD_EFFORT|FLEET_MODEL)=' "$MC" || return 0
  out=$(python3 "$BIN/fleet-role.py" migrate-conf "$MC" $dr)
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# ---- dispatch ------------------------------------------------------------------
cmd="${1:-}"; [ -n "$cmd" ] || usage; shift
case "$cmd" in
  path) printf '%s\n' "$MC" ;;
  host)
    hn=$(_host_now)
    if [ "${1:-}" = --why ]; then printf '%s\n' "$hn"; else printf '%s\n' "${hn%%	*}"; fi ;;
  set-host)
    case "${1:-}" in 1|0) set_host "$1" ;; on) set_host 1 ;; off) set_host 0 ;; *) usage ;; esac ;;
  role)   # the old word, one version (issue #1806): FLEET_HOST=1 reads client,node
    r=$(_role_file); how='FLEET_ROLE'
    if [ -z "$r" ]; then
      h=$(_host_file)
      case "$h" in
        1) r=client,node; how='FLEET_HOST=1' ;;
        0) r=client; how='FLEET_HOST=0' ;;
        *) ri=$(_role_infer); r=${ri%%	*}; why=${ri#*	}; how="inferred${why:+ — $why}" ;;
      esac
    fi
    r=$(_role_norm "$r")
    if [ "${1:-}" = --why ]; then printf '%s\t%s\n' "${r:-none}" "$how"; else printf '%s\n' "${r:-none}"; fi ;;
  migrate)
    DRY=0 QUIET=0
    while [ $# -gt 0 ]; do
      case "$1" in --dry-run) DRY=1 ;; --quiet) QUIET=1 ;; *) usage ;; esac; shift
    done
    migrate "$DRY" "$QUIET"
    rescue_stranded "$DRY" "$QUIET"
    hub_fill "$DRY" "$QUIET"
    migrate_repos "$DRY" "$QUIET"
    migrate_roles "$DRY" "$QUIET" ;;
  add-role)
    case "${1:-}" in client|node) add_role "$1" ;; *) usage ;; esac ;;
  set-hub)
    url="${1:-}"; [ -n "$url" ] || usage; shift
    r=client
    case "${1:-}" in
      --host) r=node ;;
      --role) r="${2:-}"; case "$r" in client|node) ;; *) usage ;; esac ;;
    esac
    # a client signing in again on an older layout folds that in first
    [ -f "$MC" ] || migrate 0 1 >/dev/null
    add_role "$r"
    _set_common "$MC" FLEET_HUB_URL "export FLEET_HUB_URL=\"$url\"" || die "cannot write $MC" ;;
  line)   # issue #2134: what fleet-cred-rollout.sh records before it edits
    k="${1:-}"; case "$k" in ''|*[!A-Za-z0-9_]*) usage ;; esac
    [ -f "$MC" ] || exit 1
    grep -E "^[[:space:]]*(export[[:space:]]+)?$k=" "$MC" || exit 1 ;;
  set-line)
    k="${1:-}"; case "$k" in ''|*[!A-Za-z0-9_]*) usage ;; esac
    [ $# -ge 2 ] || usage
    [ -f "$MC" ] || die "no $MC (fleet-conf.sh migrate makes one)"
    _set_common "$MC" "$k" "$2" || die "cannot write $MC" ;;
  set-client)
    k="${1:-}"; case "$k" in ''|*[!A-Za-z0-9_]*) usage ;; esac
    [ $# -ge 2 ] || usage
    _ensure_file 0 || die "cannot write $MC"
    _set_client "$MC" "$k" "$2" || die "cannot write $MC" ;;
  drop-line)
    k="${1:-}"; case "$k" in ''|*[!A-Za-z0-9_]*) usage ;; esac
    [ -f "$MC" ] || exit 0
    tmp="$MC.tmp.$$"
    grep -Ev "^[[:space:]]*(export[[:space:]]+)?$k=" "$MC" > "$tmp"
    [ $? -le 1 ] && { chmod "$(stat -c '%a' "$MC" 2>/dev/null || stat -f '%Lp' "$MC")" "$tmp" 2>/dev/null; mv -f "$tmp" "$MC"; } \
      || { rm -f "$tmp"; die "cannot write $MC"; } ;;
  -h|--help) usage ;;
  *) usage ;;
esac
