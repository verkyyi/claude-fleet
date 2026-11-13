#!/bin/bash
# fleet-client-lib.sh — write to the operator's OWN terminal through the tmux client
# they are using (sourced; issues #1367/#1371, shared with fleet-open by #1379).
#
# Two scripts put an iTerm2 escape on the operator's terminal: bin/fleet-show.sh
# (OSC 1337 MultipartFile — a file) and bin/fleet-open.sh (OSC 1337 Custom — a
# link for their machine to open). Both need the same two things, and this is the
# ONE copy of each:
#
#   WHICH client — the one the operator is USING: the most recent
#     #{client_activity} of this pane's session, whose #{client_termtype} must
#     match the terminal regex (FLEET_SHOW_TERM_RE, default ^iTerm2). A newer
#     non-iTerm2 client does NOT fall back to an older iTerm2 one (#1371: that sent
#     the file to a stale iTerm2 at home while the operator read the fleet from a
#     phone). An empty termtype (tmux < 3.4, or no XTVERSION answer) is not iTerm2.
#     `--client <tty>` names one outright and skips the match.
#
#   HOW it is written — `tmux lock-client` with the session's lock-command swapped
#     for one lock: the CLIENT process leaves tmux mode and runs the sender as the
#     only writer on its tty, so no tmux frame lands inside the escape (see
#     fleet-show.sh's header for the measurements). The previous lock-command is
#     restored right after the lock is issued. One send per session at a time.
#
# Functions set FC_* globals; a failure sets FC_WHY (operator-facing) and returns 1.
#   fc_session                 → FC_SESS (this pane's session)
#   fc_pick <client> <re>      → FC_CLIENT FC_TERMTYPE FC_GEOM (cols,rows,cw,ch) FC_CSESS
#                                (the client's own session: a view session's name for a 看台)
#   fc_lock                    → FC_LOCKDIR held (needs FC_SESS); fc_unlock frees it
#   fc_run <cmd>               → lock-client FC_CLIENT running <cmd> (needs FC_SESS)
#   fc_wait <status> <secs>    → 0 once <status> holds a `done` line
#
# And the client's one dependency (issue #1629), shared by the two installers —
# bin/fleet-install.sh (sources this file once it is downloaded) and
# bin/fleet-node-join.sh (run as `curl … | bash`, so it carries a copy of
# fc_tmux_ok that fleet-install-selftest.sh leg F holds byte-identical to this
# one). Both are POSIX sh — the installer runs under dash on Linux:
#   fc_tmux_ok                 → 0 iff tmux ≥ 3.2 on PATH; FC_TMUX_V its version
#   fc_pkg_install <pkg>       → install with Homebrew (macOS; never installs
#                                Homebrew itself) or apt-get / dnf / yum / apk
#                                as root or through `sudo -n` (Linux; never a
#                                password prompt). 0 ran · 1 the install failed
#                                · 2 no way to install here; FC_WHY says which,
#                                FC_HOW the one command to run. Seams: FC_OS
#                                (darwin|linux), FC_SUDO (default `sudo -n`),
#                                FC_BREW_DIRS (where else to look for brew),
#                                FC_LOG (the package manager's output)
#
# And what the client package only SERVES (issue #4826, EPIC #4823 C3): a
# fleetclient/manifest line tagged `served` is on the hub but not installed —
# the node join / install, the release scripts 承载 starts from, the admin's
# commands. The road that needs one fetches it first. POSIX sh:
#   fc_served <root> <path>…   → each <root>/<path> here, or fetched: from where
#                                this client came from (<root>/.client-version):
#                                the hub's stable copy of its commit, else the
#                                hub's own /install, else (不接) GitHub's raw
#                                at that commit; put in place by one rename.
#                                Checked against the installed version's
#                                signed manifest (kept with the version by the
#                                client update, with the verified tree the
#                                file is then taken from; else the hub's, by
#                                the pinned release key) — none with a key
#                                pinned, a path it lacks or other bytes →
#                                refused; no key: the hub's X-Ccquota-Sha256,
#                                required. 0 all here · 1 a fetch failed or was
#                                refused · 2 nowhere to fetch from; FC_WHY says
#                                which. Seams:
#                                FLEET_SERVED_FROM (the one source, a URL or
#                                file://), FLEET_STABLE_RAW
#
# And the client's own record (issue #2896, EPIC #2889 C7; docs/dev/CLIENT-LOGS.md):
#   fleet_clientlog <kind> <event> [machine] [route] [ms] [result] [reason]
#                              → one TSV line in <logs>/<kind>.log (connect ·
#                                place · keeper · login), rotated to .1 past
#                                FLEET_CLIENT_LOG_MAX (512 KiB), the reason cut
#                                at 2000 bytes and passed through
#                                conf/secret-shapes.list. The sh twin of
#                                bin/fleet_clientlog.py, held byte for byte to it
#                                by bin/client-log-selftest.sh; never fails. POSIX
#                                sh. The table is found at FLEET_SECRET_SHAPES,
#                                else $BIN/../conf (the sourcing script's BIN).
# shellcheck disable=SC2034  # the FC_* globals are read by the sourcing script

fc_session() {
  FC_SESS=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{?#{session_group},#{session_group},#{session_name}}' 2>/dev/null)
  [ -n "$FC_SESS" ] || { FC_WHY='cannot resolve this pane'"'"'s tmux session'; return 1; }
}
# fc_clients <fmt> — `list-clients -F <fmt>` for every client of FC_SESS, its view
# sessions' included (`<fleet>@view-<id>`, issue #1489: a shell or proxy sits on
# one of those, and it is the newest client fleet-open must find). The row is
# asked for as `$sid:<fleet>\t<fmt>` and the prefix split off again; a row without
# that shape (a selftest's fake tmux printing canned lines) passes through as it is.
fc_clients() {
  tmux list-clients -F "#{session_id}:#{?#{session_group},#{session_group},#{session_name}}	$1" 2>/dev/null \
    | awk -F '\t' -v s="$FC_SESS" '$1 !~ /^\$[0-9]+:/ { print; next }
                               { k = $1; sub(/^[^:]*:/, "", k); if (k != s) next; sub(/^[^\t]*\t/, ""); print }'
}

fc_pick() {  # <client tty, or empty> <termtype ERE>
  local want="$1" re="$2" rows pick _tty _tt
  FC_CLIENT=""; FC_TERMTYPE=""; FC_GEOM="0,0,0,0"; FC_CSESS=""
  # activity <TAB> tty <TAB> termtype <TAB> cols,rows,cell-w,cell-h <TAB> its own session
  rows=$(fc_clients '#{client_activity}	#{client_tty}	#{client_termtype}	#{client_width},#{client_height},#{client_cell_width},#{client_cell_height}	#{client_session}')
  if [ -n "$want" ]; then
    pick=$(printf '%s\n' "$rows" | awk -F '\t' -v c="$want" '$2 == c { print $2 "\t" $3 "\t" $4 "\t" $5; exit }')
    [ -n "$pick" ] || { FC_WHY="$want is not a client of session '$FC_SESS'"; return 1; }
  else
    # The newest client is the one the operator is at — it must BE iTerm2 (#1371).
    pick=$(printf '%s\n' "$rows" | awk -F '\t' 'NF >= 2' | sort -t '	' -k1,1nr | head -n 1 \
      | awk -F '\t' '{ print $2 "\t" $3 "\t" $4 "\t" $5 }')
    [ -n "$pick" ] || { FC_WHY="no client is attached to session '$FC_SESS'"; return 1; }
    _tty="${pick%%	*}"; _tt="${pick#*	}"; _tt="${_tt%%	*}"
    [ -n "$_tt" ] || { FC_WHY="当前活跃 client ${_tty} 的终端类型未知（tmux < 3.4，或终端没回应 XTVERSION），不是 iTerm2"; return 1; }
    printf '%s\n' "$_tt" | grep -Eq -- "$re" \
      || { FC_WHY="当前活跃 client ${_tty} 是 ${_tt}，不是 iTerm2（/${re}/）"; return 1; }
  fi
  # sliced, never `read`: a tab is IFS whitespace, so an empty termtype would shift the rest
  FC_CLIENT="${pick%%	*}"; _tt="${pick#*	}"
  [ "$_tt" != "$pick" ] || _tt=''
  FC_TERMTYPE="${_tt%%	*}"; FC_GEOM="${_tt#*	}"
  [ "$FC_GEOM" != "$_tt" ] || FC_GEOM=''
  FC_CSESS="${FC_GEOM#*	}"; [ "$FC_CSESS" != "$FC_GEOM" ] || FC_CSESS=''
  FC_GEOM="${FC_GEOM%%	*}"
  case "$FC_GEOM" in *[!0-9,]*|'') FC_GEOM="0,0,0,0" ;; esac
  return 0
}

fc_lock() {
  local _
  FC_LOCKDIR="${TMPDIR:-/tmp}/fleet-show.$(id -u).$(printf '%s' "$FC_SESS" | tr -c 'A-Za-z0-9._-' '_').lock"
  for _ in $(seq 1 100); do
    mkdir "$FC_LOCKDIR" 2>/dev/null && return 0
    # a holder killed mid-send leaves the dir: stale after 5 min
    if [ -n "$(find "$FC_LOCKDIR" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then rmdir "$FC_LOCKDIR" 2>/dev/null; continue; fi
    sleep 0.2
  done
  FC_WHY='another fleet-show / fleet-open is sending in this session'
  return 1
}
fc_unlock() { [ -n "${FC_LOCKDIR:-}" ] && rmdir "$FC_LOCKDIR" 2>/dev/null; return 0; }

fc_sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

fc_run() {  # <cmd> — swap the session's lock-command for one lock, then put back
  # exactly what was there (a session value, or none — the global default shows through).
  # The CLIENT's own session (issue #3005): a client on a view session
  # (`<fleet>@view-<id>`, a thin 看台) runs that session's lock-command, not the
  # fleet session's — FC_CSESS, the same name for any other client.
  local cmd="$1" prev_set prev_val lrc ls="${FC_CSESS:-$FC_SESS}"
  prev_set=$(tmux show-options -q -t "$ls" lock-command 2>/dev/null)
  prev_val=$(tmux show-options -qv -t "$ls" lock-command 2>/dev/null)
  tmux set-option -t "$ls" lock-command "$cmd" 2>/dev/null || { FC_WHY='cannot set lock-command'; return 1; }
  tmux lock-client -t "$FC_CLIENT" 2>/dev/null; lrc=$?
  if [ -n "$prev_set" ]; then tmux set-option -t "$ls" lock-command "$prev_val" 2>/dev/null
  else tmux set-option -u -t "$ls" lock-command 2>/dev/null; fi
  [ "$lrc" = 0 ] || { FC_WHY="tmux lock-client -t $FC_CLIENT failed"; return 1; }
}

fc_wait() {  # <status file> <limit seconds>
  local stfile="$1" limit="$2" waited=0
  while ! grep -qx 'done' "$stfile" 2>/dev/null; do
    [ "$waited" -ge $(( limit * 5 )) ] && break
    sleep 0.2; waited=$(( waited + 1 ))
  done
  grep -qx 'done' "$stfile" 2>/dev/null
}

# fc_tmux_ok — tmux ≥ 3.2 on PATH (the shell's key tables and `-e` need it); an
# older one counts as none. FC_TMUX_V = what `tmux -V` said, minus "tmux ".
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

fc_brew_bin() {
  for _fc_b in "$(command -v brew 2>/dev/null)" ${FC_BREW_DIRS-/opt/homebrew/bin /usr/local/bin}; do
    case "$_fc_b" in '') continue ;; */brew) ;; *) _fc_b="$_fc_b/brew" ;; esac
    [ -x "$_fc_b" ] && { echo "$_fc_b"; return 0; }
  done
  return 1
}

# fc_priv <cmd…> — root, or passwordless sudo, or nothing: never a password prompt.
fc_priv() {
  if [ "$(id -u)" = 0 ]; then "$@"; return; fi
  [ -n "${FC_SUDO-sudo -n}" ] || return 1
  # shellcheck disable=SC2086
  ${FC_SUDO-sudo -n} "$@"
}

fc_pkg_install() {  # <pkg>
  FC_WHY=""; FC_HOW=""
  _fc_log="${FC_LOG:-/dev/null}"
  _fc_os="${FC_OS:-$(uname -s | tr '[:upper:]' '[:lower:]')}"
  if [ "$_fc_os" = darwin ]; then
    FC_HOW="brew install $1"
    _fc_brew=$(fc_brew_bin) || { FC_WHY="没有 Homebrew（不替你装）：先装 https://brew.sh，再 $FC_HOW"; return 2; }
    eval "$("$_fc_brew" shellenv 2>/dev/null)"
    "$_fc_brew" install "$1" >>"$_fc_log" 2>&1 || { FC_WHY="$FC_HOW 失败：$(tail -n 2 "$_fc_log" 2>/dev/null | tr '\n' ' ')"; return 1; }
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then FC_HOW="sudo apt-get install -y $1"
  elif command -v dnf >/dev/null 2>&1; then FC_HOW="sudo dnf install -y $1"
  elif command -v yum >/dev/null 2>&1; then FC_HOW="sudo yum install -y $1"
  elif command -v apk >/dev/null 2>&1; then FC_HOW="sudo apk add $1"
  else FC_WHY="没有 apt-get / dnf / yum / apk：用这台机器的包管理器装 $1"; return 2; fi
  fc_priv true >/dev/null 2>&1 </dev/null || { FC_WHY="装 $1 要 root 或免密 sudo（不弹密码框）：自己执行 $FC_HOW"; return 2; }
  case "$FC_HOW" in
    *apt-get*) fc_priv env DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$_fc_log" 2>&1 </dev/null
               fc_priv env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$1" >>"$_fc_log" 2>&1 </dev/null ;;
    *dnf*) fc_priv dnf install -y "$1" >>"$_fc_log" 2>&1 </dev/null ;;
    *yum*) fc_priv yum install -y "$1" >>"$_fc_log" 2>&1 </dev/null ;;
    *) fc_priv apk add --no-cache "$1" >>"$_fc_log" 2>&1 </dev/null ;;
  esac || { FC_WHY="${FC_HOW#sudo } 失败：$(tail -n 2 "$_fc_log" 2>/dev/null | tr '\n' ' ')"; return 1; }
  return 0
}

# ── what the package only serves (issue #4826) ────────────────────────────────
# fc_served_hub <root> — the hub this client came from ('' none): .client-version's
# hub=, else FLEET_HUB_URL, else fleet.conf's
fc_served_hub() {
  _fsh=$(sed -n 's/^hub=//p' "$1/.client-version" 2>/dev/null | head -n 1)
  [ -n "$_fsh" ] || _fsh=${FLEET_HUB_URL:-}
  [ -n "$_fsh" ] || _fsh=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}FLEET_HUB_URL=//p' \
    "${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}/fleet.conf" 2>/dev/null | tail -n 1 | tr -d "\"' ")
  printf '%s\n' "${_fsh%/}"
}
# fc_served_version <root> — the installed version, when it is a 40-hex commit
fc_served_version() {
  _fsv=$(sed -n 's/^version=//p' "$1/.client-version" 2>/dev/null | head -n 1)
  case $_fsv in *[!0-9a-f]*|'') return 0 ;; esac
  [ ${#_fsv} = 40 ] && printf '%s\n' "$_fsv"
  return 0
}
# fc_served_from <root> — the URLs to try, best first, one per line
fc_served_from() {
  if [ -n "${FLEET_SERVED_FROM:-}" ]; then printf '%s\n' "${FLEET_SERVED_FROM%/}"; return 0; fi
  _fs40=$(fc_served_version "$1")
  _fsh=$(fc_served_hub "$1")
  if [ -n "$_fsh" ]; then
    [ -z "$_fs40" ] || printf '%s/install/stable/%s\n' "$_fsh" "$_fs40"
    printf '%s/install\n' "$_fsh"
  elif [ -n "$_fs40" ]; then
    _fsr=${FLEET_STABLE_RAW:-https://raw.githubusercontent.com/verkyyi/claude-fleet}   # dist-ok: 不接 only
    printf '%s/%s\n' "${_fsr%/}" "$_fs40"
  fi
}
fc_sha256() {  # <file> — its sha256
  python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null
}
# fc_manifest_sum <manifest.json> <version> <path> — the sha256 a release
# manifest names for <path>. rc 1: <path> is not in it · 2: the manifest is
# unreadable or of another version
fc_manifest_sum() {
  python3 -c 'import json, re, sys
try:
    m = json.load(open(sys.argv[1], "rb"))
except (OSError, ValueError):
    sys.exit(2)
if not isinstance(m, dict) or m.get("sha") != sys.argv[2]:
    sys.exit(2)
for f in m.get("files") or []:
    if isinstance(f, dict) and f.get("path") == sys.argv[3] and re.match(r"^[0-9a-f]{64}$", str(f.get("sha256") or "")):
        print(f["sha256"])
        sys.exit(0)
sys.exit(1)' "$1" "$2" "$3" 2>/dev/null
}
# fc_served_manifest <root> <hub> <version> <pubkey> <out> — the hub's signed manifest of
# <version>, checked against the pinned key by this client's own
# bin/fleet-release-fetch.py (the client update's check: SSHSIG or the ed25519
# signature, the key chain, the revocations), written to <out>. rc 1: the
# reason on stdout
fc_served_manifest() {
  [ -f "$1/bin/fleet-release-fetch.py" ] && [ -f "$1/bin/fleet-release-verify.py" ] \
    || { echo "这台没有 bin/fleet-release-fetch.py 可用来核对（重跑一次安装命令）"; return 1; }
  python3 -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("fleet_release_fetch", sys.argv[1])
F = importlib.util.module_from_spec(spec)
spec.loader.exec_module(F)
try:
    mb = F.Fetch(sys.argv[2], sys.argv[3], 30).manifest(sys.argv[4])[1]
except Exception as e:
    print(str(e).splitlines()[-1] if str(e) else type(e).__name__)
    sys.exit(1)
with open(sys.argv[5], "wb") as f:
    f.write(mb)' "$1/bin/fleet-release-fetch.py" "$2" "$4" "$3" "$5" 2>&1 </dev/null
}
# fc_served <root> <path>… — each one here, or put in place (see the top).
# The installed version's signed manifest decides when there is one: the one
# the client update kept with this version (<root>/.release-tree, beside the
# verified tree's files), else — a release key pinned ($FLEET_CONF_DIR/
# release.pub) — the hub's, its signature checked. The bytes come from that
# kept tree (no download) or a download, and must match the sha256 the
# manifest names; a path it does not name, a manifest that cannot be had or
# checked, or bytes that do not match → refused. No key pinned: a download
# from a hub must carry X-Ccquota-Sha256 and match it; a file:// source
# (FLEET_SERVED_FROM) and GitHub's raw at the installed commit (不接) are taken
# as fetched.
fc_served() {  # <root> <path>…
  FC_WHY=''
  _fsr0=$1; shift
  _fsl=$(fc_served_from "$_fsr0")
  _fsver=$(fc_served_version "$_fsr0")
  _fshub=$(fc_served_hub "$_fsr0")
  _fspub="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}/release.pub"
  _fskt="$_fsr0/.release-tree"
  _fsmt=''       # a fetched manifest's temp file
  _fsman=''      # the signed manifest in use
  if [ -n "$_fsver" ] && [ -f "$_fskt/.release/manifest.json" ]; then
    fc_manifest_sum "$_fskt/.release/manifest.json" "$_fsver" bin/fleet >/dev/null
    [ $? = 2 ] || _fsman="$_fskt/.release/manifest.json"
  fi
  for _fsp in "$@"; do
    [ -f "$_fsr0/$_fsp" ] && continue
    case $_fsp in bin/*|conf/*) ;; *) FC_WHY="不认识的路径 $_fsp"; _fs_done; return 1 ;; esac
    case $_fsp in *..*|*//*) FC_WHY="不认识的路径 $_fsp"; _fs_done; return 1 ;; esac
    if [ -z "$_fsl" ] && { [ -z "$_fsman" ] || [ ! -f "$_fskt/$_fsp" ]; }; then
      FC_WHY="这台不知道从哪取 ${_fsp}（没有入口地址，也没有 .client-version）"; _fs_done; return 2
    fi
    if [ -z "$_fsman" ] && [ -s "$_fspub" ]; then
      if [ -z "$_fsver" ] || [ -z "$_fshub" ]; then
        FC_WHY="核对不了 ${_fsp}：这台记着发布签名钥匙，却不知道该比对哪个已签名的版本（.client-version 里没有入口或版本）"
        _fs_done; return 1
      fi
      _fsmt="${TMPDIR:-/tmp}/fleet-served-manifest.$$"
      if ! _fso=$(fc_served_manifest "$_fsr0" "$_fshub" "$_fsver" "$_fspub" "$_fsmt"); then
        FC_WHY="核对不了 ${_fsp}：取不到 $(printf '%.7s' "$_fsver") 的已签名发布清单（$(printf '%s' "$_fso" | tail -n 1 | cut -c1-160)）"
        _fs_done; return 1
      fi
      _fsman=$_fsmt
    fi
    _fswant=''
    if [ -n "$_fsman" ]; then
      _fswant=$(fc_manifest_sum "$_fsman" "$_fsver" "$_fsp")
      case $? in
        0) ;;
        1) FC_WHY="已签名的发布 $(printf '%.7s' "$_fsver") 里没有 ${_fsp}，不装"; _fs_done; return 1 ;;
        *) FC_WHY="核对不了 ${_fsp}：已签名发布清单读不了"; _fs_done; return 1 ;;
      esac
    fi
    mkdir -p "$_fsr0/$(dirname "$_fsp")" 2>/dev/null || { FC_WHY="写不进 $_fsr0"; _fs_done; return 1; }
    _fst="$_fsr0/$_fsp.fetch.$$"
    _fsok=0; _fsbad=''
    # the verified tree kept with this version: no download
    if [ -n "$_fswant" ] && [ -f "$_fskt/$_fsp" ] && cp "$_fskt/$_fsp" "$_fst" 2>/dev/null; then
      [ "$(fc_sha256 "$_fst")" = "$_fswant" ] && _fsok=1 || rm -f "$_fst"
    fi
    if [ "$_fsok" != 1 ]; then
      for _fsu in $_fsl; do
        rm -f "$_fst" "$_fst.hdr"
        curl -fsSL --connect-timeout 10 --max-time 120 -D "$_fst.hdr" "$_fsu/$_fsp" -o "$_fst" 2>/dev/null || continue
        [ -s "$_fst" ] || continue
        if [ -n "$_fswant" ]; then
          [ "$(fc_sha256 "$_fst")" = "$_fswant" ] || { _fsbad="与已签名发布清单的 SHA-256 对不上"; continue; }
        else
          case $_fsu in
            file://*) ;;                     # a local tree named as the source
            *) if [ -n "$_fshub" ] || [ -n "${FLEET_SERVED_FROM:-}" ]; then
                 _fsw=$(tr -d '\r' <"$_fst.hdr" | awk 'tolower($1)=="x-ccquota-sha256:"{print $2}' | tail -n 1)
                 [ -n "$_fsw" ] || { _fsbad="回应里没有 X-Ccquota-Sha256"; continue; }
                 [ "$(fc_sha256 "$_fst")" = "$_fsw" ] || { _fsbad="SHA-256 与 X-Ccquota-Sha256 对不上"; continue; }
               fi ;;                         # else 不接: GitHub's raw at the installed commit
          esac
        fi
        _fsok=1; break
      done
    fi
    rm -f "$_fst.hdr"
    if [ "$_fsok" != 1 ]; then
      rm -f "$_fst"
      FC_WHY="取不到 ${_fsp}（$(printf '%s' "$_fsl" | head -n 1 | sed 's/?.*//')${_fsbad:+：$_fsbad}）"
      _fs_done; return 1
    fi
    case $_fsp in bin/*) chmod 755 "$_fst" ;; *) chmod 644 "$_fst" ;; esac
    mv -f "$_fst" "$_fsr0/$_fsp" || { rm -f "$_fst"; FC_WHY="放不进 $_fsr0/$_fsp"; _fs_done; return 1; }
    # the fleet's file (issue #4827): on installed.list, so a later upgrade
    # drops it rather than carrying it along as the person's
    if [ -f "$_fsr0/installed.list" ]; then
      printf '%s\t%s\n' "$_fsp" "$(fc_sha256 "$_fsr0/$_fsp")" >> "$_fsr0/installed.list" 2>/dev/null
    fi
  done
  _fs_done
  return 0
}
_fs_done() { [ -z "${_fsmt:-}" ] || rm -f "$_fsmt"; }

# ── the client's own record (issue #2896) ─────────────────────────────────────
fleet_clientlog_dir() {
  if [ -n "${FLEET_CLIENT_LOG_DIR:-}" ]; then printf '%s\n' "$FLEET_CLIENT_LOG_DIR"; return 0; fi
  printf '%s/logs\n' "${FLEET_SHELL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-fleet/shell}"
}
# fleet_clientlog_redact — stdin → stdout: flatten, cut, every shape replaced
fleet_clientlog_redact() {
  _fcl_sh=${FLEET_SECRET_SHAPES:-${BIN:-.}/../conf/secret-shapes.list}
  _fcl_t=$(tr '\t\r\n' '   ')
  if [ "$(printf '%s' "$_fcl_t" | wc -c | tr -d ' ')" -gt 2000 ]; then
    # a cut mid-character drops that character (python's decode "ignore")
    if command -v iconv >/dev/null 2>&1; then
      _fcl_t=$(printf '%s' "$_fcl_t" | head -c 2000 | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)
    else
      _fcl_t=$(printf '%s' "$_fcl_t" | head -c 2000)
    fi
  fi
  printf '%s\n' "$_fcl_t" | LC_ALL=C awk -v SH="$_fcl_sh" '
    BEGIN { while ((getline l < SH) > 0) {
              i = index(l, "\t"); if (l ~ /^#/ || i == 0) continue
              n++; nm[n] = substr(l, 1, i - 1); re[n] = substr(l, i + 1) } }
    { for (k = 1; k <= n; k++) gsub(re[k], "<redacted:" nm[k] ">"); print }'
}
fleet_clientlog() {
  [ "${FLEET_CLIENT_LOG:-}" = 0 ] && return 0
  case "${1:-}" in connect|place|keeper|login) ;; *) return 0 ;; esac
  (
    d=$(fleet_clientlog_dir); f="$d/$1.log"
    umask 077; mkdir -p "$d" 2>/dev/null || exit 0
    sz=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
    [ "${sz:-0}" -ge "${FLEET_CLIENT_LOG_MAX:-524288}" ] 2>/dev/null && mv -f "$f" "$f.1" 2>/dev/null
    fl() { printf '%s' "$1" | tr '\t\r\n' '   '; }
    r=$(printf '%s' "${7:-}" | fleet_clientlog_redact)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(fl "$2")" "$(fl "${3:-}")" \
      "$(fl "${4:-}")" "$(fl "${5:-}")" "$(fl "${6:-}")" "$r" >> "$f"
  ) 2>/dev/null
  return 0
}
