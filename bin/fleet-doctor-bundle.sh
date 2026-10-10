#!/bin/sh
# fleet-doctor-bundle.sh — `fleet doctor --bundle <dir>`: everything a diagnosis
# needs from this computer, in one directory, with every credential taken out
# (issue #2890, EPIC #2889 C1).
#
#   fleet doctor --bundle <dir>        (bin/fleet-doctor.sh on a node, bin/fleet with
#                                       only the client — both exec this script)
#
# Writes <dir>/:
#   doctor.txt     the doctor, in full (this machine's — node or client-only)
#   doctor.json    its rows, `fleet doctor --json`'s shape (needs python3)
#   system.txt     OS, kernel, CPU, memory, disk left
#   tools.txt      every python3 on PATH (version, CA paths, certifi), ssh, tmux, curl, the client
#   route.txt      the hub: DNS, the TLS handshake, the system proxy, *_PROXY (set? host:port
#                  only), the egress IP three times over 20 s (the hub's own echo), fleet connect's
#                  pick and its direct probe
#   ssh-v.txt      one `ssh -v -o BatchMode=yes … true` on the picked route, the last 200 lines
#   logs/          the files conf/debug-collect.list names, each its last N lines
#   manifest.json  {v, collected_at, client_version, doctor_rc, redactor, files[], missing[],
#                   redactions{total, by_shape}} — C3's upload and C4's reader read it
#
# Rules (共同约定第 1 条): a file is read only when conf/debug-collect.list names
# it; every file passes conf/secret-shapes.list (bin/fleet_redact.py, else
# bin/fleet-redact.awk) on its way in; then the WHOLE bundle is scanned again,
# and any hit means no bundle: exit 3, the files named.
#
# Exit: 0 the bundle is there (whatever the doctor said) · 2 usage · 3 a credential
# survived — nothing written.
#
# Seams (tests): FLEET_REDACT=python|awk · FLEET_BUNDLE_DOCTOR_CMD (instead of the
# doctor) · FLEET_BUNDLE_NET=0 (no hub, no ssh) · FLEET_BUNDLE_WHOAMI_GAP (10 s).
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
SHAPES="$root/conf/secret-shapes.list"
LIST="$root/conf/debug-collect.list"

usage() { echo "usage: fleet doctor --bundle <dir>" >&2; exit 2; }
[ "${1:-}" = --bundle ] && shift
[ $# -eq 1 ] && [ -n "$1" ] || usage
out=$1
case $out in /*) ;; *) out="$(pwd)/$out" ;; esac
if [ -e "$out" ] && [ ! -f "$out/manifest.json" ] && [ -n "$(ls -A "$out" 2>/dev/null)" ]; then
  echo "fleet doctor --bundle · $out 已存在且不是诊断包：换一个目录" >&2; exit 2
fi
for f in "$SHAPES" "$LIST"; do
  [ -f "$f" ] || { echo "fleet doctor --bundle · 缺 ${f}（随安装带的，重装一次）" >&2; exit 2; }
done

# the redactor: python3 when it runs, else awk — the same bytes either way
red=${FLEET_REDACT:-}
if [ -z "$red" ]; then
  if [ -f "$here/fleet_redact.py" ] && python3 -c 'import re' >/dev/null 2>&1; then red=python; else red=awk; fi
fi
redact() {  # redact <in> <out> <stats>
  if [ "$red" = python ]; then python3 "$here/fleet_redact.py" --table "$SHAPES" --stats "$3" < "$1" > "$2"
  else LC_ALL=C awk -v table="$SHAPES" -v stats="$3" -f "$here/fleet-redact.awk" < "$1" > "$2"; fi
}
check() {  # check <file>… → file<TAB>shape per hit; 1 on any
  if [ "$red" = python ]; then python3 "$here/fleet_redact.py" --table "$SHAPES" --check "$@"
  else LC_ALL=C awk -v table="$SHAPES" -v mode=check -f "$here/fleet-redact.awk" "$@"; fi
}

raw=$(mktemp -d "${TMPDIR:-/tmp}/fleet-bundle.XXXXXX") || exit 2
stage="$out.tmp.$$"
trap 'rm -rf "$raw" "$stage"' EXIT
trap 'exit 130' INT TERM
chmod 700 "$raw"
rm -rf "$stage"; mkdir -p "$stage/logs" "$raw/logs"
: > "$raw/.sources"; : > "$raw/.missing"

say() { printf '%s\n' "$*"; }
sec() { printf '\n== %s ==\n' "$*"; }
src() { printf '%s\t%s\n' "$1" "$2" >> "$raw/.sources"; }   # src <bundle path> <where it came from>
nonet() { [ "${FLEET_BUNDLE_NET:-1}" = 0 ]; }
os=$(uname -s 2>/dev/null)

printf 'fleet doctor --bundle · 收集中（体检、系统、工具、去入口的路线、连接记录）…\n' >&2

# --- doctor.txt -----------------------------------------------------------------
if [ -n "${FLEET_BUNDLE_DOCTOR_CMD:-}" ]; then
  sh -c "$FLEET_BUNDLE_DOCTOR_CMD" > "$raw/doctor.txt" 2>&1 </dev/null; drc=$?
  src doctor.txt "FLEET_BUNDLE_DOCTOR_CMD"
elif [ -f "$here/fleet-doctor.sh" ]; then
  sh "$here/fleet-doctor.sh" > "$raw/doctor.txt" 2>&1 </dev/null; drc=$?
  src doctor.txt "fleet-doctor.sh"
else
  sh "$here/fleet" doctor > "$raw/doctor.txt" 2>&1 </dev/null; drc=$?
  src doctor.txt "fleet doctor (client)"
fi

# --- system.txt -----------------------------------------------------------------
{
  sec os
  if command -v sw_vers >/dev/null 2>&1; then sw_vers 2>&1; fi
  [ -r /etc/os-release ] && grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release
  uname -a 2>&1
  sec cpu
  if [ "$os" = Darwin ]; then
    sysctl -n machdep.cpu.brand_string 2>/dev/null
    printf 'cores %s · arch %s\n' "$(sysctl -n hw.ncpu 2>/dev/null)" "$(uname -m)"
  else
    grep -m1 'model name' /proc/cpuinfo 2>/dev/null
    printf 'cores %s · arch %s\n' "$(getconf _NPROCESSORS_ONLN 2>/dev/null)" "$(uname -m)"
  fi
  printf 'load %s\n' "$(uptime 2>/dev/null | sed 's/.*load average[s]*: *//')"
  sec memory
  if [ "$os" = Darwin ]; then
    printf 'total %s MB\n' "$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))"
    vm_stat 2>/dev/null | head -n 6
  else
    grep -E '^(MemTotal|MemAvailable):' /proc/meminfo 2>/dev/null
  fi
  sec disk
  df -h "$HOME" "${TMPDIR:-/tmp}" 2>&1
} > "$raw/system.txt" 2>&1
src system.txt "sw_vers · uname · sysctl · df"

# --- tools.txt ------------------------------------------------------------------
{
  sec python3
  seen=' '
  oifs=$IFS; IFS=:
  for d in $PATH; do
    p="$d/python3"
    [ -x "$p" ] || continue
    case $seen in *" $p "*) continue ;; esac
    seen="$seen$p "
    printf -- '- %s\n' "$p"
    "$p" -c '
import ssl, sys
print("  version  %s" % sys.version.split()[0])
print("  ssl      %s" % ssl.OPENSSL_VERSION)
v = ssl.get_default_verify_paths()
print("  cafile   %s · capath %s" % (v.cafile, v.capath))
try:
    import certifi
    print("  certifi  %s" % certifi.where())
except Exception:
    print("  certifi  无")' 2>&1 | head -n 8
  done
  IFS=$oifs
  [ "$seen" = ' ' ] && say "PATH 上没有 python3"
  sec ssh
  ssh -V 2>&1
  sec tmux
  if command -v tmux >/dev/null 2>&1; then tmux -V 2>&1; else say "没有 tmux"; fi
  sec curl
  curl -V 2>&1 | head -n 2
  sec client
  v=''
  [ -f "$root/.client-version" ] && v=$(sed -n 's/^version=//p' "$root/.client-version" | head -n 1)
  [ -n "$v" ] || v=$(git -C "$root" rev-parse --short HEAD 2>/dev/null)
  case $root in *.versions/*) [ -n "$v" ] || v=${root##*.versions/} ;; esac
  printf 'version %s\nroot    %s\n' "${v:-?}" "$root"
} > "$raw/tools.txt" 2>&1
src tools.txt "PATH python3 · ssh -V · tmux -V · curl -V"
client_version=$(sed -n 's/^version //p' "$raw/tools.txt" | head -n 1)

# --- route.txt + ssh-v.txt ------------------------------------------------------------
hub=${FLEET_HUB_URL:-}
cf="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/fleet.conf"
if [ -z "$hub" ] && [ -f "$cf" ]; then
  hub=$(sed -n 's/^[[:space:]]*\(export[[:space:]]*\)\{0,1\}FLEET_HUB_URL=//p' "$cf" | tail -n 1 | sed 's/ #.*//; s/^["'\'']//; s/["'\'']$//')
fi
hub=${hub%/}
host=$(printf '%s' "$hub" | sed 's#^[a-z]*://##; s#[/?].*##; s#^.*@##; s#:[0-9]*$##')
{
  printf 'hub %s\n' "${hub:-无（没有 FLEET_HUB_URL）}"
  sec proxy
  for v in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY all_proxy NO_PROXY no_proxy; do
    eval "val=\${$v:-}"
    if [ -z "$val" ]; then printf '%-12s 未设置\n' "$v"; continue; fi
    case $v in [Nn][Oo]_*) printf '%-12s 已设置\n' "$v"; continue ;; esac
    hp=$(printf '%s' "$val" | sed 's#^[a-zA-Z0-9+.-]*://##; s#/.*##; s#^.*@##')
    printf '%-12s 已设置 %s\n' "$v" "$hp"
  done
  if command -v scutil >/dev/null 2>&1; then
    say "scutil --proxy:"
    scutil --proxy 2>&1 | grep -E 'Enable|Proxy |Port|Exceptions|PAC|AutoDiscovery' | sed 's/^ */  /'
  fi
  if nonet; then
    sec network
    say "跳过（FLEET_BUNDLE_NET=0）"
  elif [ -z "$host" ]; then
    sec network
    say "跳过：没有入口地址"
  else
    sec dns
    if python3 -c 'import socket' >/dev/null 2>&1; then
      python3 -c '
import socket, sys
try:
    print("\n".join(sorted({"%s %s" % (socket.AddressFamily(a[0]).name, a[4][0]) for a in socket.getaddrinfo(sys.argv[1], 443)})))
except Exception as e:
    print("解析失败: %s" % e)' "$host" 2>&1
    elif command -v host >/dev/null 2>&1; then host "$host" 2>&1 | head -n 6
    else nslookup "$host" 2>&1 | tail -n 6; fi
    sec tls
    curl -sv --connect-timeout 10 -m 20 -o /dev/null "$hub/" 2>&1 \
      | grep -E '^\* +(Trying|Connected|Connection|SSL|ALPN|TLS|Server certificate|subject|start date|expire date|issuer|subjectAltName|Closing|Failed|.*error|.*timed out)|^< HTTP' | head -n 30
    sec egress
    gap=${FLEET_BUNDLE_WHOAMI_GAP:-10}
    for i in 1 2 3; do
      r=$(curl -s -m 10 -w '\n%{http_code}' "$hub/v1/fleet/debug/whoami" 2>&1)
      code=$(printf '%s\n' "$r" | tail -n 1)
      body=$(printf '%s\n' "$r" | sed '$d' | head -n 1 | cut -c 1-200)
      printf '%s  %s  %s\n' "$(date -u +%H:%M:%S)" "$code" "$body"
      [ "$i" = 3 ] || sleep "$gap"
    done
  fi
} > "$raw/route.txt" 2>&1
src route.txt "env *_PROXY (host:port) · scutil --proxy · DNS · curl -sv $hub · $hub/v1/fleet/debug/whoami"

if nonet || [ ! -f "$here/fleet-connect.py" ] || ! python3 -c 'import json' >/dev/null 2>&1; then
  printf '无（%s）\n' "$(if nonet; then echo 'FLEET_BUNDLE_NET=0'; elif [ ! -f "$here/fleet-connect.py" ]; then echo '没有 fleet-connect.py'; else echo '没有能用的 python3'; fi)" > "$raw/ssh-v.txt"
  src ssh-v.txt "跳过"
else
  {
    sec "fleet connect --print -v"
    cmd=$(python3 "$here/fleet-connect.py" --print -v </dev/null 2>"$raw/connect.err"); crc=$?
    cat "$raw/connect.err"
    printf 'rc=%s\n%s\n' "$crc" "$cmd"
    last=$(python3 -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("fc", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.load_cache().get("last") or "")' "$here/fleet-connect.py" 2>/dev/null)
    sec "fleet connect --probe-direct ${last:-?}"
    if [ -n "$last" ]; then
      python3 "$here/fleet-connect.py" --probe-direct "$last" 2>&1; printf 'rc=%s\n' "$?"
    else say "无（还没连过任何机器）"; fi
  } >> "$raw/route.txt" 2>&1
  case $cmd in
    'ssh '*)
      eval "set -- $cmd"; shift
      ssh -v -o BatchMode=yes "$@" true < /dev/null > "$raw/ssh-v.full" 2>&1; sshrc=$?
      { tail -n 200 "$raw/ssh-v.full"; printf 'rc=%s\n' "$sshrc"; } > "$raw/ssh-v.txt"
      src ssh-v.txt "ssh -v -o BatchMode=yes <fleet connect --print> true" ;;
    *)
      printf '无（fleet connect 没给出 ssh 命令：%s）\n' "$(printf '%s' "$cmd" | head -n 1)" > "$raw/ssh-v.txt"
      src ssh-v.txt "跳过" ;;
  esac
fi

# --- logs/: conf/debug-collect.list, and nothing else ----------------------------------
shell_cache=${FLEET_SHELL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/claude-fleet/shell}
conf_dir=${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}
tab=$(printf '\t')
while IFS="$tab" read -r bp sp nl; do
  case $bp in ''|'#'*) continue ;; esac
  case $bp in logs/*) ;; *) echo "fleet doctor --bundle · $LIST: $bp 不在 logs/ 下，跳过" >&2; continue ;; esac
  case $bp in *..*|*/) continue ;; esac
  case $nl in ''|*[!0-9]*) nl=200 ;; esac
  case $sp in
    '~/'*) p="$HOME/${sp#\~/}" ;;
    '$SHELL_CACHE/'*) p="$shell_cache/${sp#\$SHELL_CACHE/}" ;;
    '$CONF_DIR/'*) p="$conf_dir/${sp#\$CONF_DIR/}" ;;
    *) p=$sp ;;
  esac
  if [ -f "$p" ] && [ -r "$p" ]; then
    mkdir -p "$raw/$(dirname "$bp")" "$stage/$(dirname "$bp")"
    tail -n "$nl" "$p" > "$raw/$bp"
    src "$bp" "$sp (last $nl lines)"
  else
    printf '%s\t%s\n' "$bp" "$sp" >> "$raw/.missing"
  fi
done < "$LIST"

# --- redact every file into the stage -------------------------------------------------
: > "$raw/.stats"
while IFS="$tab" read -r bp sp; do
  redact "$raw/$bp" "$stage/$bp" "$raw/.st" || { echo "fleet doctor --bundle · 去密码失败：$bp" >&2; exit 2; }
  while IFS="$tab" read -r nm c; do printf '%s\t%s\t%s\n' "$bp" "$nm" "$c" >> "$raw/.stats"; done < "$raw/.st"
done < "$raw/.sources"

# doctor.json — fleet-doctor.sh --json's parse (KEEP IN SYNC), on the redacted text
if python3 -c 'import json' >/dev/null 2>&1; then
  python3 -c '
import json, re, sys
rows = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines():
    m = re.match(r"^  (PASS|WARN|FAIL|INFO)  (\S+)\s+(.*)$", line)
    if m:
        rows.append({"level": m.group(1), "row": m.group(2), "msg": m.group(3).rstrip()})
    elif rows and line.startswith("    ") and line.strip():
        rows[-1]["msg"] += "\n" + line.strip()
n = lambda lv: sum(1 for r in rows if r["level"] == lv)
print(json.dumps({"v": 1, "rc": int(sys.argv[2]), "fails": n("FAIL"), "warns": n("WARN"), "rows": rows},
                 ensure_ascii=False))' "$stage/doctor.txt" "$drc" > "$stage/doctor.json" 2>/dev/null \
    && src doctor.json "doctor.txt (parsed)" || rm -f "$stage/doctor.json"
fi
[ -f "$stage/doctor.json" ] || printf 'doctor.json\t没有能用的 python3\n' >> "$raw/.missing"

# --- manifest.json ------------------------------------------------------------------
jstr() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037'; }
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
total=0
{
  printf '{\n  "v": 1,\n  "collected_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "client_version": "%s",\n  "doctor_rc": %s,\n  "redactor": "%s",\n  "files": [' \
    "$(jstr "${client_version:-?}")" "${drc:-0}" "$red"
  sep=''
  while IFS="$tab" read -r bp sp; do
    [ -f "$stage/$bp" ] || continue
    n=$(awk -F "$tab" -v f="$bp" '$1 == f { s += $3 } END { print s + 0 }' "$raw/.stats")
    printf '%s\n    {"path": "%s", "source": "%s", "lines": %s, "sha256": "%s", "redactions": %s}' \
      "$sep" "$(jstr "$bp")" "$(jstr "$sp")" "$(wc -l < "$stage/$bp" | tr -d ' ')" "$(sha "$stage/$bp")" "$n"
    sep=,
  done < "$raw/.sources"
  printf '\n  ],\n  "missing": ['
  sep=''
  while IFS="$tab" read -r bp sp; do
    printf '%s\n    {"path": "%s", "source": "%s"}' "$sep" "$(jstr "$bp")" "$(jstr "$sp")"; sep=,
  done < "$raw/.missing"
  total=$(awk -F "$tab" '{ s += $3 } END { print s + 0 }' "$raw/.stats")
  printf '\n  ],\n  "redactions": {"total": %s, "by_shape": {' "$total"
  awk -F "$tab" '{ c[$2] += $3; if (!($2 in o)) { o[$2] = ++k; nm[k] = $2 } }
    END { for (i = 1; i <= k; i++) printf "%s\"%s\": %d", (i > 1 ? ", " : ""), nm[i], c[nm[i]] }' "$raw/.stats"
  printf '}}\n}\n'
} > "$stage/manifest.json"

# --- the whole bundle, once more ------------------------------------------------------
hits=$(cd "$stage" && find . -type f | sed 's#^\./##' | sort | while IFS= read -r f; do check "$f"; done)
if [ -n "$hits" ]; then
  {
    echo "fleet doctor --bundle · 去掉密码以后仍有命中，不出包："
    printf '%s\n' "$hits" | sed 's/^/  /'
  } >&2
  exit 3
fi

rm -rf "$out"
mv "$stage" "$out" || exit 2
{
  printf 'fleet doctor --bundle · 包好了：%s\n' "$out"
  printf '  收了：'
  (cd "$out" && find . -type f | sed 's#^\./##' | sort | tr '\n' ' ')
  printf '\n  去掉了 %s 处密码或令牌' "$total"
  [ "$total" -gt 0 ] && printf '（%s）' "$(awk -F "$tab" '{ c[$2] += $3; if (!($2 in o)) { o[$2] = ++k; nm[k] = $2 } }
    END { for (i = 1; i <= k; i++) printf "%s%s %d", (i > 1 ? " · " : ""), nm[i], c[nm[i]] }' "$raw/.stats")"
  printf '\n'
  if [ -s "$raw/.missing" ]; then
    printf '  没有的：%s\n' "$(cut -f1 "$raw/.missing" | tr '\n' ' ')"
  fi
  printf '  体检：%s\n' "$(if [ "${drc:-0}" = 0 ]; then echo '没有 FAIL'; else echo "${drc} 处 FAIL（见 doctor.txt）"; fi)"
}
exit 0
