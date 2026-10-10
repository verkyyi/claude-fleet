#!/bin/bash
# fleet-debug-drill.sh check [--hub <url>]
# fleet-debug-drill.sh run <tls|cap|conn|all> --yes [--hub <url>] [--host <machine>] [--login drill<x>]
#                      [--python <python3>] [--proxy <url>] [--follow] [--out <dir>] [--keep]
# fleet-debug-drill.sh teardown --out <dir>
#   — today's three faults, played again on one Mac (claude-fleet#2895, EPIC #2889
#     C6): a colleague's computer that cannot log in (the certificate), finds no
#     machine that will take it (the busy gate) and hangs on 「正在连接」 (the
#     proxy) — each time the drill only does what the client tells it to, and
#     reads whether the diagnosis page gives the right fix.
#
# Every scenario is four steps, each a PASS / FAIL / SKIP line and a row of
# steps.md (看到什么 · 按了什么 · 用时 · 要人帮), every screen kept:
#
#   布置  arrange the fault, nothing of the person's touched — a SANDBOX on this
#         computer (a fresh HOME, /usr/bin:/bin PATH, its own TMPDIR and tmux
#         socket; fleet-onboard-clock.sh's way, never a new OS login) and a
#         drill person (fleet-drill.sh invite, deleted at 复原), fake credentials
#         of every shape planted where the bundle collects (the leak count):
#     tls   python.org's python3 first on the sandbox's PATH and recorded as the
#           install's (FLEET_INSTALL_PYTHON) — no certifi, no keychain — with
#           fleet_tls.py's own sources off (FLEET_TLS_SYSTEM_ROOTS / _CERTIFI /
#           _DEFAULTS=0): the client as it was before #2878, without rolling the
#           client back (a pre-#2878 client has no fleet-debug to send with).
#           No python.org one: /usr/bin/python3 with an empty SSL_CERT_FILE (近似).
#     cap   this machine's own CPU-busy gate at 0.01 (machine.env
#           FLEET_MAX_CPU_BUSY, #2882; its node agent restarted to read it) —
#           needs an admin login (sudo -n); the drill person's login is on this
#           machine only (--host), so no machine takes its session.
#     conn  a proxy in front of the hub (the sandbox's HTTPS_PROXY / ALL_PROXY):
#           --proxy <url> (the person's Clash), else the drill's own on
#           127.0.0.1 that cuts each tunnel after 1 s, then 11 s, alternating.
#   触发  `curl -fsSL <hub>/install | sh` typed into the sandbox's terminal; its
#         questions answered with Enter, the login confirmed as the drill person,
#         `fleet claude` run again each time the person is back at the prompt —
#         until the client asks 「要不要让远端看一眼」 (C5; 「按 d」 on a stuck
#         connect page) and the drill answers y / d. Then fleet-debug's
#         「已上传」 line and the short link (…/s/<id>) — t_upload.
#   读页  GET /v1/fleet/debug/<id> until 「已出结论」 (t_concluded, ≤ 5 min), the
#         page (/s/<id>) kept as page.html: four sections (是什么问题 · 证据 ·
#         请你做 · 要我们改的), 是什么问题 matched against the day's real cause
#         (机判; 人判 is the person's column in report.md), and with --follow the
#         1–3 commands of 请你做 typed into the sandbox's terminal, then the
#         failing step again — the fault must be gone. The bundle the client left
#         is scanned for every planted credential (命中 must be 0).
#   复原  the fault taken back (machine.env from its copy + agent restarted ·
#         the proxy stopped · the sandbox gone), the drill person deleted; FAIL
#         past 15 minutes from 布置 (共同约定 8).
#
# report.md: the four steps per scenario and the EPIC's five readings — 3 / 3
# 给对修法 (机判), the longest 已上传 → 已出结论 (≤ 300 s), their sum (≤ 600 s),
# 漏掉的密码 (0), 群里来回 (0 when the client asked by itself, else 2).
#
# check: what each scenario needs, PASS / FAIL per member, nothing changed —
# red until C1–C5 and C7 land (wave 1 of the EPIC writes this drill to watch it
# red). run refuses while check is red.
#
# A run changes this machine's network / Python / gate only at a time the
# person confirmed: run needs --yes. What it armed is written to <out>/armed as
# it goes, so `teardown --out <dir>` puts it back after a run that was killed;
# a run cut short (INT / TERM / HUP) restores first, then reads ABORTED and
# exits 128+signal. teardown also deletes each uploaded report on the hub
# (DELETE /v1/fleet/debug/<id>, the operator's CCQUOTA_VIEWER_TOKEN) and checks
# /s/<id> is gone.
#
# Exit: 0 every step passed · 1 a step failed / check red · 2 usage / preflight
# Env: FLEET_DEBUG_DRILL_STEP_SECS (180, any wait) · FLEET_DEBUG_DRILL_PAGE_SECS
#      (300, uploaded → concluded) · FLEET_DEBUG_DRILL_POLL (1) ·
#      FLEET_DEBUG_DRILL_TRIES (5, `fleet claude` runs before the prompt) ·
#      FLEET_DEBUG_DRILL_MACHINE_ENV (/var/db/fleet-node/machine.env) ·
#      FLEET_DEBUG_DRILL_CAP_ARM / _CAP_DISARM (commands replacing the
#      machine.env edit — selftests) · FLEET_DEBUG_DRILL_ROOT (the tree check
#      reads, default this one)
set -u

PROG=fleet-debug-drill
BIN="$(cd "$(dirname "$0")" && pwd -P)"
ROOT=${FLEET_DEBUG_DRILL_ROOT:-$BIN/..}
usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die2() { printf '%s: %s\n' "$PROG" "$1" >&2; exit 2; }

STEP_SECS=${FLEET_DEBUG_DRILL_STEP_SECS:-180}
PAGE_SECS=${FLEET_DEBUG_DRILL_PAGE_SECS:-300}
POLL=${FLEET_DEBUG_DRILL_POLL:-1}
TRIES=${FLEET_DEBUG_DRILL_TRIES:-5}
MACHINE_ENV=${FLEET_DEBUG_DRILL_MACHINE_ENV:-/var/db/fleet-node/machine.env}
RESTORE_SECS=900   # 共同约定 8: every machine back within 15 minutes

# --- what the drill reads off screens and pages (the seams below test these) ----
ASK_RE='要不要让远端看一眼|让远端看一眼|[Ll]et (us|the remote|someone) take a look'
ASK_D_RE='按 ?d ?让远端看一眼|[Pp]ress d'
UPLOADED_RE='已上传|[Uu]ploaded'
SHORT_RE='https?://[^[:space:]]+/s/[A-Za-z0-9]{8}'
DEBUG_FAIL_RE='票过期|票无效|今天次数用完|入口连不上|脱敏后仍有命中|ticket (expired|invalid)|rate.?limited'
CLIENT_UP='新任务|[Nn]ew task|⌘N|⌘P'
SECTIONS='是什么问题|证据|请你做|要我们改的'
cause_re() {
  case "$1" in
    tls)  printf '%s' '证书|CERTIFICATE|[Cc]ertifi|钥匙串|[Kk]eychain|CA|SSL|TLS' ;;
    cap)  printf '%s' '繁忙|CPU|cpu_busy|门槛|负载|[Ll]oad|没有机器' ;;
    conn) printf '%s' '代理|[Pp]roxy|Clash|断开|挂断|1 ?秒|11 ?秒|中转|[Rr]elay|出口' ;;
  esac
}

# page_text <section regex> (page.html on stdin): the text under the first heading
# matching it, up to the next heading — plain lines
page_section() {
  python3 -c '
import html, re, sys
doc = sys.stdin.read()
parts = re.split(r"(?is)<h[1-4][^>]*>(.*?)</h[1-4]>", doc)
for i in range(1, len(parts), 2):
    if re.search(sys.argv[1], re.sub(r"<[^>]+>", "", parts[i])):
        body = parts[i + 1] if i + 1 < len(parts) else ""
        if sys.argv[2] == "code":
            for c in re.findall(r"(?is)<code[^>]*>(.*?)</code>", body):
                c = html.unescape(re.sub(r"<[^>]+>", "", c)).strip()
                if c: print(c)
        else:
            t = html.unescape(re.sub(r"<[^>]+>", " ", body))
            print(re.sub(r"[ \t]+", " ", t).strip())
        break' "$1" "${2:-text}"
}
# page_sections (page.html on stdin): which of the four headings it has, one per line
page_sections() {
  python3 -c '
import re, sys
heads = [re.sub(r"<[^>]+>", "", h) for h in re.findall(r"(?is)<h[1-4][^>]*>(.*?)</h[1-4]>", sys.stdin.read())]
for want in sys.argv[1].split("|"):
    if any(want in h for h in heads): print(want)' "$SECTIONS"
}
# cause_ok <scenario> (page.html on stdin): PASS when 是什么问题 names the day's cause
cause_ok() {
  local t
  t=$(page_section '是什么问题')
  if [ -n "$t" ] && printf '%s\n' "$t" | grep -Eq -- "$(cause_re "$1")"; then echo PASS; else echo FAIL; fi
}
# leak_count <dir> <planted file>: how many planted values appear in any file
# under <dir> (tarballs opened first) — the bundle the client left
leak_count() {
  python3 - "$1" "$2" <<'PY'
import os, sys, tarfile, io
root, planted = sys.argv[1], [l.rstrip("\n") for l in open(sys.argv[2]) if l.strip()]
hits = 0
def scan(name, data):
    global hits
    for p in planted:
        if p.encode() in data:
            hits += 1
            sys.stderr.write("leak: %s carries a planted %s…\n" % (name, p[:6]))
for d, _, fs in os.walk(root):
    for f in fs:
        fp = os.path.join(d, f)
        try:
            if f.endswith((".tar.gz", ".tgz", ".tar")):
                with tarfile.open(fp) as t:
                    for m in t.getmembers():
                        if m.isfile():
                            scan("%s:%s" % (f, m.name), t.extractfile(m).read())
            else:
                scan(fp, open(fp, "rb").read())
        except (OSError, tarfile.TarError):
            pass
print(hits)
PY
}
# plant <home> <planted file>: one fake credential of every shape the bundle
# must never carry, where a collector would look; the values go to <planted>
plant() {
  local h=$1 out=$2 r
  r=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 24)
  mkdir -p "$h/.config/claude-fleet" "$h/.ssh" "$h/.cache/claude-fleet/shell/logs" || return 1
  {
    printf 'ghp_drill%sAAAAAAAAAAAA\n' "$r"
    printf 'sk-ant-drill-%s\n' "$r"
    printf 'hubtok-drill-%s\n' "$r"
    printf 'secret-drill-%s\n' "$r"
    printf 'bearer-drill-%s\n' "$r"
    printf 'qtok-drill-%s\n' "$r"
    printf 'pemkey-drill-%s\n' "$r"
  } > "$out"
  chmod 600 "$out"
  printf '{"url": "https://hub.invalid", "token": "hubtok-drill-%s"}\n' "$r" > "$h/.config/claude-fleet/hub.json"
  printf 'export FLEET_HUB_TOKEN=secret-drill-%s\nexport GITHUB_TOKEN=ghp_drill%sAAAAAAAAAAAA\n' "$r" "$r" \
    > "$h/.config/claude-fleet/secrets.env"
  printf 'ANTHROPIC_API_KEY=sk-ant-drill-%s\n' "$r" >> "$h/.config/claude-fleet/secrets.env"
  printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\npemkey-drill-%s\n-----END OPENSSH PRIVATE KEY-----\n' "$r" > "$h/.ssh/id_drill"
  printf '%s\tconnect\tdrill\trelay\t10\tfail\tAuthorization: Bearer bearer-drill-%s https://hub.invalid/x?token=qtok-drill-%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$r" "$r" > "$h/.cache/claude-fleet/shell/logs/connect.log"
  chmod 600 "$h/.config/claude-fleet/hub.json" "$h/.config/claude-fleet/secrets.env" "$h/.ssh/id_drill"
}
# readings <out dir>: report.md's reading table from <out>/results.tsv
# (scenario 布置 触发 读页 复原 upload_s concluded_s cause leaks asked)
readings() {
  awk -F '\t' '
    NR == 1 { next }
    { n++; s[n] = $1; st[n] = $2 " · " $3 " · " $4 " · " $5
      d = ($6 != "" && $7 != "") ? $7 - $6 : ""; dur[n] = d
      if (d != "") { sum += d; if (d > max) max = d; nd++ }
      cause[n] = $8; if ($8 == "PASS") ok++
      lk[n] = $9; if ($9 != "") { leaks += $9; nl++ }
      rt[n] = ($10 == "1") ? 0 : 2; if (rt[n] > rtmax) rtmax = rt[n] }
    END {
      print "| 场景 | 布置 · 触发 · 读页 · 复原 | 已上传→已出结论 | 是什么问题（机判） | 人判 | 包里命中 | 群里来回 |"
      print "|---|---|---|---|---|---|---|"
      for (i = 1; i <= n; i++)
        printf "| %s | %s | %s | %s |  | %s | %d |\n", s[i], st[i], (dur[i] == "" ? "—" : dur[i] "s"), cause[i], (lk[i] == "" ? "—" : lk[i]), rt[i]
      print ""
      print "| 指标 | 读数 | 目标 |"
      print "|---|---|---|"
      printf "| 诊断页给对修法（机判） | %d / %d | 3 / 3 |\n", ok, n
      printf "| 已上传 → 已出结论（最长） | %s | ≤ 300s |\n", (nd ? max "s" : "—")
      printf "| 三次合计 | %s | ≤ 600s |\n", (nd ? sum "s" : "—")
      printf "| 包里漏掉的密码 | %s | 0 |\n", (nl ? leaks : "—")
      printf "| 群里来回（最多的一次） | %d | ≤ 2 |\n", rtmax
    }' "$1/results.tsv"
}

# --- arguments ----------------------------------------------------------------------
CMD=${1:-}; [ $# -gt 0 ] && shift
case "$CMD" in
  --sections) page_sections; exit 0 ;;                                    # seam: page.html on stdin
  --section)  [ $# -ge 1 ] || usage; page_section "$1" "${2:-text}"; exit 0 ;;  # seam
  --cause)    [ $# -ge 1 ] || usage; cause_ok "$1"; exit 0 ;;             # seam: page.html on stdin
  --leaks)    [ $# -ge 2 ] || usage; leak_count "$1" "$2"; exit 0 ;;      # seam: <dir> <planted>
  --plant)    [ $# -ge 2 ] || usage; plant "$1" "$2"; exit ;;             # seam: <home> <planted>
  --readings) [ $# -ge 1 ] || usage; readings "$1"; exit 0 ;;             # seam: <out dir>
  check|run|teardown) ;;
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  '') usage ;;
  *) die2 "unknown command: $CMD (check | run | teardown)" ;;
esac
SCEN='' HUB='' HOST='' LOGIN='' PYTHON='' PROXY='' FOLLOW=0 OUT='' KEEP=0 YES=0
if [ "$CMD" = run ]; then
  [ $# -ge 1 ] || usage
  SCEN=$1; shift
  case "$SCEN" in tls|cap|conn) ;; all) SCEN='tls cap conn' ;; *) die2 "scenario: tls, cap, conn or all (got '$SCEN')" ;; esac
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --hub)    [ $# -ge 2 ] || usage; HUB=$2; shift 2 ;;
    --host)   [ $# -ge 2 ] || usage; HOST=$2; shift 2 ;;
    --login)  [ $# -ge 2 ] || usage; LOGIN=$2; shift 2 ;;
    --python) [ $# -ge 2 ] || usage; PYTHON=$2; shift 2 ;;
    --proxy)  [ $# -ge 2 ] || usage; PROXY=$2; shift 2 ;;
    --out)    [ $# -ge 2 ] || usage; OUT=$2; shift 2 ;;
    --follow) FOLLOW=1; shift ;;
    --keep)   KEEP=1; shift ;;
    --yes)    YES=1; shift ;;
    *) die2 "unknown argument: $1" ;;
  esac
done
for v in "STEP_SECS=$STEP_SECS" "PAGE_SECS=$PAGE_SECS" "TRIES=$TRIES"; do
  printf '%s' "${v#*=}" | grep -Eq '^[0-9]+$' || die2 "${v%%=*}: not a number: '${v#*=}'"
done
[ -z "$LOGIN" ] || printf '%s' "$LOGIN" | grep -Eq '^drill[a-z0-9]{1,11}$' || die2 "--login: drill + up to 11 lowercase letters/digits (got '$LOGIN')"
case "$HUB" in
  prod|'') HUB=$(sed -n 's/^export FLEET_HUB_URL="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' \
                   "${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/fleet.conf" 2>/dev/null | head -n 1) ;;
esac
[ "$CMD" = teardown ] && [ -z "$HUB" ] && [ -n "$OUT" ] && [ -f "$OUT/hub" ] && HUB=$(cat "$OUT/hub")
case "$HUB" in http://*|https://*) HUB=${HUB%/} ;; *) die2 'no hub: --hub https://<入口> (or the FLEET_HUB_URL in your fleet.conf)' ;; esac
VIEWER=${CCQUOTA_VIEWER_TOKEN:-${FLEET_HUB_TOKEN:-}}

# --- check: what each member gives the drill, nothing changed -----------------------
CHK_FAIL=0
chk() {  # chk <PASS|FAIL|WARN> <member> <what>
  [ "$1" = FAIL ] && CHK_FAIL=$((CHK_FAIL + 1))
  printf '  %-4s  %-4s %s\n' "$1" "$2" "$3"
}
hub_code() { local o=$1; shift; curl -s -m 10 -o "$o" -w '%{http_code}' "$@" 2>/dev/null; }  # hub_code <out> <curl args…>
run_check() {
  local man tmp c
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fleet-debug-drill-check.XXXXXX") || die2 'mktemp failed'
  printf '%s check  hub=%s\n' "$PROG" "$HUB"
  c=$(curl -s -m 10 -o "$tmp/manifest" -w '%{http_code}' "$HUB/install/manifest" 2>/dev/null)
  man=$tmp/manifest; [ "$c" = 200 ] || : > "$man"
  # C1: the bundle — its collect list and the shared shape table go with the client
  if grep -q '^conf/secret-shapes.list' "$man" && grep -q '^conf/debug-collect.list' "$man"; then
    chk PASS C1 'the client carries conf/secret-shapes.list + conf/debug-collect.list (fleet doctor --bundle)'
  else chk FAIL C1 "the hub's client has no conf/secret-shapes.list / conf/debug-collect.list (#2890)"; fi
  # C2: a ticket is issued with no identity
  c=$(printf '{"fp":"drill-check","client":"drill"}' | curl -s -m 10 -o "$tmp/ticket" -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' --data-binary @- "$HUB/v1/fleet/debug/ticket" 2>/dev/null)
  case "$c" in 200|201|429) chk PASS C2 "POST /v1/fleet/debug/ticket answers ($c)" ;;
               *) chk FAIL C2 "POST /v1/fleet/debug/ticket answers $c — no ticket (#2891)" ;; esac
  # C3: fleet-debug, with the client and alone (curl <hub>/debug | sh)
  if grep -Eq '^bin/fleet-debug([[:space:]]|$)' "$man"; then
    chk PASS C3 'the client carries bin/fleet-debug'
  else chk FAIL C3 "the hub's client has no bin/fleet-debug (#2892)"; fi
  c=$(hub_code "$tmp/debug.sh" "$HUB/debug")
  if [ "$c" = 200 ] && head -n 1 "$tmp/debug.sh" | grep -q '^#!'; then chk PASS C3 'GET /debug serves the script'
  else chk FAIL C3 "GET /debug answers $c — no stand-alone fleet-debug (#2892)"; fi
  # C4: the page and its debugger — the role ships with the node
  if [ -f "$ROOT/agents/debugger.md" ]; then chk PASS C4 'agents/debugger.md (the debugger role)'
  else chk FAIL C4 "no agents/debugger.md in $ROOT (#2893)"; fi
  # a hub without the route answers its generic 「viewer token」 401; C4's says how to get a ticket
  c=$(hub_code "$tmp/status" -H 'Authorization: FleetDebug drill-check' "$HUB/v1/fleet/debug/drillchk")
  case "$c" in
    401|403|404) if grep -q 'viewer token' "$tmp/status"; then chk FAIL C4 "GET /v1/fleet/debug/<id> is not routed — no report status (#2893)"
                 else chk PASS C4 "GET /v1/fleet/debug/<id> is routed ($c without a good ticket)"; fi ;;
    *) chk FAIL C4 "GET /v1/fleet/debug/<id> answers $c — no report status (#2893)" ;;
  esac
  # C5: the client asks by itself
  c=$(hub_code "$tmp/lang" "$HUB/install/bin/fleet-ui-lang.sh")
  if [ "$c" = 200 ] && grep -Eq -- "$ASK_RE" "$tmp/lang"; then chk PASS C5 'the client asks 「要不要让远端看一眼」'
  else chk FAIL C5 "the hub's client never asks 「要不要让远端看一眼」 (#2894)"; fi
  # C7: the client keeps its own logs
  if grep -q '^bin/fleet_clientlog.py' "$man"; then chk PASS C7 'the client carries bin/fleet_clientlog.py'
  else chk FAIL C7 "the hub's client keeps no logs of its own (bin/fleet_clientlog.py, #2896)"; fi
  # this computer
  local t miss=''
  for t in curl python3 tar ssh-keygen; do command -v "$t" >/dev/null 2>&1 || miss="$miss $t"; done
  find_tmux >/dev/null || miss="$miss tmux"
  [ -f "$BIN/fleet-drill.sh" ] || miss="$miss fleet-drill.sh"
  if [ -z "$miss" ]; then chk PASS here 'curl python3 tar ssh-keygen tmux fleet-drill.sh'
  else chk FAIL here "missing:$miss"; fi
  if t=$(find_pyorg); then chk PASS tls "python.org python3: $t"
  else chk WARN tls 'no python.org python3 — tls runs /usr/bin/python3 with an empty CA file (近似); --python <path>'; fi
  if sudo -n true >/dev/null 2>&1; then chk PASS cap 'sudo -n (machine.env)'
  else chk WARN cap '需要管理员登录（有 sudo）— cap edits machine.env; tls and conn run without'; fi
  rm -rf "$tmp"
  if [ "$CHK_FAIL" -gt 0 ]; then printf 'RED — %s missing: the drill cannot run yet\n' "$CHK_FAIL"; return 1; fi
  printf 'READY\n'; return 0
}
find_tmux() {
  local t
  t=$(command -v tmux 2>/dev/null) && { printf '%s' "$t"; return 0; }
  for t in /opt/homebrew/bin/tmux /usr/local/bin/tmux; do [ -x "$t" ] && { printf '%s' "$t"; return 0; }; done
  return 1
}
find_pyorg() {
  local p
  [ -n "$PYTHON" ] && { [ -x "$PYTHON" ] && printf '%s' "$PYTHON" && return 0; return 1; }
  for p in /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 \
           /Library/Frameworks/Python.framework/Versions/3.1[0-9]/bin/python3; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

if [ "$CMD" = check ]; then run_check; exit; fi

# --- restore: what a run armed, from <out>/armed (also after a killed run) --------
# armed lines: cap <machine.env> · proxy <pid> · sandbox <dir> · person <approve file>
cap_disarm() {
  if [ -n "${FLEET_DEBUG_DRILL_CAP_DISARM:-}" ]; then sh -c "$FLEET_DEBUG_DRILL_CAP_DISARM"; return; fi
  sudo -n test -f "$1.drill-bak" || return 0
  sudo -n mv -f "$1.drill-bak" "$1" && agent_restart
}
agent_restart() {  # the supervisor's node-agent child reads machine.env at start
  sudo -n pkill -f 'ccquota agent --machine' >/dev/null 2>&1
  local i=0
  while [ "$i" -lt 30 ]; do pgrep -f 'ccquota agent --machine' >/dev/null 2>&1 && return 0; sleep 1; i=$((i + 1)); done
  return 1
}
restore_armed() {  # restore_armed <out>: undo every armed line, newest first; prints what it did
  local f=$1/armed kind arg rc=0
  [ -f "$f" ] || return 0
  while read -r kind arg; do
    case "$kind" in
      cap)     if cap_disarm "$arg"; then echo "restored $arg"; else echo "FAILED to restore $arg"; rc=1; fi ;;
      proxy)   kill "$arg" 2>/dev/null; echo "stopped proxy $arg" ;;
      sandbox) sandbox_rm "$arg"; echo "removed sandbox $arg" ;;
      person)  person_rm "$arg" && echo 'deleted the drill person' ;;
    esac
  done < <(sed -n '1!G;h;$p' "$f")
  rm -f "$f"
  return "$rc"
}
sandbox_rm() {
  local sb=$1 s
  [ -d "$sb" ] || return 0
  for s in "$sb"/t/tmux-*/* "$sb/drill.sock"; do [ -S "$s" ] && TMUX='' "$TMUXB" -S "$s" kill-server 2>/dev/null; done
  pkill -f "$sb/" 2>/dev/null; sleep 0.3; pkill -9 -f "$sb/" 2>/dev/null
  [ "$KEEP" = 1 ] && return 0
  chmod -R u+w "$sb" 2>/dev/null; rm -rf "$sb"
}
person_rm() {  # person_rm <file holding the approve code>: the drill person deletes itself
  [ -f "$1" ] || return 1
  local c
  c=$(printf '{"approve_code":"%s"}' "$(cat "$1")" | curl -s -m 10 -o /dev/null -w '%{http_code}' \
        -X DELETE -H 'Content-Type: application/json' --data-binary @- "$HUB/v1/self" 2>/dev/null)
  rm -f "$1"
  case "$c" in 200|204) return 0 ;; *) echo "⚠ the drill person was not deleted (HTTP $c) — it lapses with its ttl"; return 1 ;; esac
}
TMUXB=$(find_tmux) || TMUXB=tmux

if [ "$CMD" = teardown ]; then
  [ -n "$OUT" ] && [ -d "$OUT" ] || die2 'teardown needs --out <the run dir>'
  rc=0
  restore_armed "$OUT" || rc=1
  if [ -f "$OUT/reports.tsv" ]; then
    while IFS="$(printf '\t')" read -r _ id url; do
      [ -n "$id" ] || continue
      c=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X DELETE ${VIEWER:+-H "Authorization: Bearer $VIEWER"} \
            "$HUB/v1/fleet/debug/$id" 2>/dev/null)
      g=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$HUB/s/$id" 2>/dev/null)
      if [ "$g" = 404 ]; then echo "report $id: gone (DELETE $c)"; else echo "report $id: still there (DELETE $c, /s/ $g)"; rc=1; fi
    done < "$OUT/reports.tsv"
  fi
  # no OS login of the drill's: the sandbox makes none, and none named drill* may be left
  if command -v dscl >/dev/null 2>&1 && [ -f "$OUT/logins" ]; then
    while read -r l; do dscl . -read "/Users/$l" >/dev/null 2>&1 && { echo "OS login $l still exists"; rc=1; }; done < "$OUT/logins"
  fi
  exit "$rc"
fi

# --- run ------------------------------------------------------------------------------
[ "$YES" = 1 ] || die2 '改真机网络 / Python / 门槛只在发起人确认的时间做 — 确认了再加 --yes（check 不改任何东西）'
[ "$(id -u)" != 0 ] || die2 'run this as the admin login, not under sudo'
[ -n "$OUT" ] && [ -f "$OUT/armed" ] && die2 "$OUT/armed is left from a run that did not restore — $0 teardown --out $OUT first"
run_check || exit 1
case " $SCEN " in *' cap '*)
  [ -n "${FLEET_DEBUG_DRILL_CAP_ARM:-}" ] || sudo -n true >/dev/null 2>&1 \
    || die2 "需要管理员登录（有 sudo）— cap edits $MACHINE_ENV (run 'sudo -v' first; this script never prompts)"
  [ -n "${FLEET_DEBUG_DRILL_CAP_ARM:-}" ] || sudo -n test -f "$MACHINE_ENV" \
    || die2 "no $MACHINE_ENV — cap runs on a managed machine (sudo fleet node install)" ;;
esac
[ -n "$OUT" ] || OUT=$(mktemp -d "${TMPDIR:-/tmp}/fleet-debug-drill.XXXXXX") || die2 'mktemp failed'
mkdir -p "$OUT" && chmod 700 "$OUT" || die2 "cannot write $OUT"
printf '%s\n' "$HUB" > "$OUT/hub"
printf 'scenario\t布置\t触发\t读页\t复原\tupload_s\tconcluded_s\tcause\tleaks\tasked\n' > "$OUT/results.tsv"
STEPS=$OUT/steps.md
printf '| 场景 | # | 看到什么 | 按了什么 | 用时 | 要人帮 |\n|---|---|---|---|---|---|\n' > "$STEPS"
printf '%s run  hub=%s  scenarios=%s  out %s\n' "$PROG" "$HUB" "$SCEN" "$OUT"

NFAIL=0 TS=$SECONDS SC=''
line() { printf '%-4s  %-5s %-4s %s\n' "$1" "$SC" "$2" "$3"; [ "$1" = FAIL ] && NFAIL=$((NFAIL + 1)); return 0; }
row() {  # row <看到> <按了> <要人帮>
  local n
  n=$(grep -c "^| $SC |" "$STEPS")
  printf '| %s | %s | %s | %s | %ss | %s |\n' "$SC" "$((n + 1))" "$1" "$2" "$((SECONDS - TS))" "$3" >> "$STEPS"
  TS=$SECONDS
}
armed() { printf '%s %s\n' "$1" "$2" >> "$OUT/armed"; }
on_signal() {
  printf '\n%s: %s — restoring what was armed\n' "$PROG" "$1" >&2
  restore_armed "$OUT" >&2
  printf 'ABORTED (%s) — no reading; steps so far in %s\n' "$1" "$STEPS"
  case "$1" in INT) exit 130 ;; HUP) exit 129 ;; *) exit 143 ;; esac
}
trap 'on_signal INT' INT; trap 'on_signal TERM' TERM; trap 'on_signal HUP' HUP

# the drill's own proxy: each tunnel cut after 1 s, then 11 s, alternating
flaky_proxy() {  # flaky_proxy <port file>: runs in the background, prints the port
  python3 - "$1" <<'PY' &
import socket, sys, threading, itertools, time
cuts = itertools.cycle([1, 11])
lock = threading.Lock()
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0)); srv.listen(32)
open(sys.argv[1], "w").write(str(srv.getsockname()[1]))
def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d: break
            b.sendall(d)
    except OSError: pass
def serve(c):
    try:
        req = b""
        while b"\r\n\r\n" not in req:
            d = c.recv(4096)
            if not d: return
            req += d
        host, _, port = req.split(b" ")[1].decode().partition(":")
        up = socket.create_connection((host, int(port or 443)), timeout=10)
        c.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        with lock: cut = next(cuts)
        for x, y in ((c, up), (up, c)): threading.Thread(target=pipe, args=(x, y), daemon=True).start()
        time.sleep(cut)
        for s in (c, up):
            try: s.shutdown(socket.SHUT_RDWR)
            except OSError: pass
    except Exception: pass
    finally: c.close()
while True:
    c, _ = srv.accept()
    threading.Thread(target=serve, args=(c,), daemon=True).start()
PY
  printf '%s' "$!"
}
cap_arm() {
  if [ -n "${FLEET_DEBUG_DRILL_CAP_ARM:-}" ]; then sh -c "$FLEET_DEBUG_DRILL_CAP_ARM"; return; fi
  local me=$MACHINE_ENV mode
  mode=$(sudo -n stat -f %Lp "$me") || return 1
  sudo -n cp -p "$me" "$me.drill-bak" || return 1
  # the token stays where it is: the file is rewritten in place, root's, its mode kept
  sudo -n sh -c 'umask 077; { grep -v "^FLEET_MAX_CPU_BUSY=" "$1.drill-bak"; echo FLEET_MAX_CPU_BUSY=0.01; } > "$1.drill-tmp" \
                 && chmod "$2" "$1.drill-tmp" && mv -f "$1.drill-tmp" "$1"' _ "$me" "$mode" || return 1
  agent_restart
}
# debug_auth <home>: the two headers fleet-debug sends (C2), one per line
debug_auth() {
  local h=$1 tf fp
  for tf in "$h/.local/share/claude-fleet/debug-ticket" "$h/.claude/fleet/debug-ticket"; do [ -s "$tf" ] && break; done
  [ -s "$tf" ] || return 1
  fp=$(printf '%s|%s|%s' "$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/{print $4}')" \
         "$(id -un)" "$h/.local/share/claude-fleet" | shasum -a 256 | cut -d' ' -f1)
  printf 'Authorization: FleetDebug %s\nX-Fleet-FP: %s\n' "$(head -n 1 "$tf")" "$fp"
}

# scenario_steps: 布置 · 触发 · 读页 of run_scenario — sets ITS locals (bash's
# dynamic scope), returns early on a step that cannot go on
scenario_steps() {
  # --- 布置
  sb=$(mktemp -d /tmp/fdd.XXXXXX) || { line FAIL 布置 'mktemp failed'; return; }
  armed sandbox "$sb"
  mkdir -p "$sb/home" "$sb/tmp" "$sb/t" "$sb/shim" "$sb/admin"; chmod 700 "$sb/t"
  plant "$sb/home" "$sb/planted" || { line FAIL 布置 'could not plant the fake credentials'; return; }
  login=${LOGIN:-drill$(date +%d%H%M)$(printf '%s' "$SC" | cut -c1)}
  printf '%s\n' "$login" >> "$OUT/logins"
  d=$(bash "$BIN/fleet-drill.sh" invite ${HOST:+--host "$HOST"} --login "$login" --ttl 30m --json 2>"$sb/mint.err") \
    || { line FAIL 布置 "fleet drill invite failed: $(tail -n 1 "$sb/mint.err")"; row "invite 被拒" 'fleet drill invite' '是 — 入口不给演练身份'; return; }
  approve=$(printf '%s' "$d" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("approve_code",""))' 2>/dev/null)
  [ -n "$approve" ] || { line FAIL 布置 'fleet drill invite answered no approve code'; return; }
  ( umask 077; printf '%s' "$approve" > "$sb/approve" ); armed person "$sb/approve"
  cat > "$sb/shim/open" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$sb/opened.tmp" && mv "$sb/opened.tmp" "$sb/opened"
EOF
  chmod +x "$sb/shim/open"
  pth="$sb/shim:/usr/bin:/bin:/usr/sbin:/sbin"
  case "$SC" in
    tls)
      local py
      if py=$(find_pyorg); then
        ln -s "$py" "$sb/shim/python3"; extra=(FLEET_INSTALL_PYTHON="$py"); why="python.org $py"
      else
        : > "$sb/empty-ca.pem"; extra=(FLEET_INSTALL_PYTHON=none SSL_CERT_FILE="$sb/empty-ca.pem"); why='/usr/bin/python3 + empty CA (近似)'
      fi
      extra+=(FLEET_TLS_SYSTEM_ROOTS=0 FLEET_TLS_CERTIFI=0 FLEET_TLS_DEFAULTS=0) ;;
    cap)
      if cap_arm; then armed cap "$MACHINE_ENV"; why="FLEET_MAX_CPU_BUSY=0.01 in $MACHINE_ENV"
      else line FAIL 布置 "could not arm the gate in $MACHINE_ENV"; row '门槛没改成' 'machine.env' '是 — 要管理员'; return; fi ;;
    conn)
      local px
      if [ -n "$PROXY" ]; then px=$PROXY; why="the person's proxy $PROXY"
      else
        local pid port=''
        pid=$(flaky_proxy "$sb/proxy.port"); armed proxy "$pid"
        for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$sb/proxy.port" ] && break; sleep 0.3; done
        port=$(cat "$sb/proxy.port" 2>/dev/null)
        [ -n "$port" ] || { line FAIL 布置 'the drill proxy did not start'; return; }
        px="http://127.0.0.1:$port"; why="drill proxy $px (cuts 1 s / 11 s)"
      fi
      extra=(HTTPS_PROXY="$px" https_proxy="$px" ALL_PROXY="$px" all_proxy="$px") ;;
  esac
  r_arm=PASS; line PASS 布置 "$why"; row "故障已布置：$why" '—' '否'
  # --- 触发
  dt() { TMUX='' "$TMUXB" -S "$sb/drill.sock" "$@"; }
  dt -f /dev/null new-session -d -s drill -x 160 -y 48 \
    env -i HOME="$sb/home" PATH="$pth" TERM=xterm-256color LANG=zh_CN.UTF-8 LC_CTYPE=zh_CN.UTF-8 \
      SHELL=/bin/zsh USER="$(id -un)" LOGNAME="$(id -un)" TMPDIR="$sb/tmp" TMUX_TMPDIR="$sb/t" \
      FLEET_LOGIN_BROWSER=1 FLEET_DEVICE_NAME="debugdrill-$SC-$$" FLEET_NODE_JOIN_ARGS='--service detached' \
      ${extra[@]+"${extra[@]}"} PS1='newcomer% ' /bin/zsh -f \
    || { line FAIL 触发 'the drill terminal did not start'; return; }
  sleep 0.5
  dt send-keys -t drill -l "curl -fsSL $HUB/install | sh"; dt send-keys -t drill Enter
  row '一个空终端' "粘贴 curl -fsSL <入口>/install | sh" '否'
  local deadline=$((SECONDS + STEP_SECS * 3)) quiet=$SECONDS
  last_p=''
  while :; do
    p=$(dt capture-pane -p -t drill 2>/dev/null)
    if [ "$p" != "$last_p" ]; then
      shot=$((shot + 1)); printf '%s\n' "$p" > "$OUT/$SC-screen-$(printf '%03d' "$shot").txt"; last_p=$p; quiet=$SECONDS
    fi
    if [ -z "$url" ] && printf '%s\n' "$p" | grep -Eq -- "$DEBUG_FAIL_RE"; then
      why=$(printf '%s\n' "$p" | grep -E -- "$DEBUG_FAIL_RE" | tail -n 1)
      line FAIL 触发 "fleet-debug: $why"; row "$why" '—' '是 — 送不上去'; break
    fi
    if [ -z "$t_up" ] && printf '%s\n' "$p" | grep -Eq -- "$UPLOADED_RE"; then t_up=$(date +%s); fi
    if [ -z "$url" ] && printf '%s\n' "$p" | grep -Eq -- "$SHORT_RE"; then
      url=$(printf '%s\n' "$p" | grep -Eo -- "$SHORT_RE" | tail -n 1); id=${url##*/s/}
      [ -n "$t_up" ] || t_up=$(date +%s)
      printf '%s\t%s\t%s\n' "$SC" "$id" "$url" >> "$OUT/reports.tsv"
      r_trig=PASS; line PASS 触发 "$url (after $tries runs of fleet claude)"; row "已上传 · $url" '—' '否'; break
    fi
    # the client asks: y — or d on a stuck connect page (C5)
    if [ "$asked" = 0 ] && printf '%s\n' "$p" | tail -n 4 | grep -Eq -- "$ASK_RE|$ASK_D_RE"; then
      asked=1
      if printf '%s\n' "$p" | tail -n 4 | grep -Eq -- "$ASK_D_RE"; then dt send-keys -t drill d; row '「按 d 让远端看一眼」' 'd' '否'
      else dt send-keys -t drill y Enter; row '「要不要让远端看一眼」' 'y ↵' '否'; fi
      sleep "$POLL"; continue
    fi
    # the login: the drill person's hand, as fleet-onboard-clock confirms it
    if [ -z "$opened" ] && [ -s "$sb/opened" ]; then
      opened=$(cat "$sb/opened"); code=$(printf '%s' "$opened" | grep -Eo 'code=[A-Z]{4}-[A-Z]{4}' | head -n 1 | cut -d= -f2)
    fi
    [ -z "$code" ] && printf '%s\n' "$p" | grep -q '用手机扫码' && code=$(printf '%s\n' "$p" | grep -Eo '[A-Z]{4}-[A-Z]{4}' | head -n 1)
    if [ -n "$code" ] && [ -z "$hand" ]; then
      env -i PATH="$PATH" HOME="$sb/admin" FLEET_CONF_DIR="$sb/admin/conf" FLEET_HUB_URL="$HUB" \
        FLEET_DRILL_INVITE="$approve" bash "$BIN/fleet-drill.sh" approve "$code" >"$sb/approve.out" 2>&1 \
        && row '登录的验证码' '（演练身份确认签发）' '本人'
      hand=1
    fi
    # a question the installer asks: Enter (its default)
    if printf '%s\n' "$p" | tail -n 3 | grep -Eq '回车 = [0-9]+ ›|按回车继续|Press Enter' && [ $((SECONDS - quiet)) -ge 3 ]; then
      dt send-keys -t drill Enter; quiet=$SECONDS
    fi
    # back at the prompt with no question: run the client again, as the person would
    if printf '%s\n' "$p" | grep -v '^ *$' | tail -n 1 | grep -q '^newcomer% *$' && [ $((SECONDS - quiet)) -ge 5 ]; then
      if [ "$tries" -ge "$TRIES" ]; then
        line FAIL 触发 "the client never asked after $tries runs: $(printf '%s\n' "$p" | grep -v '^ *$' | tail -n 2 | head -n 1)"
        row '失败了也没人问' "fleet claude ×$tries" '是 — 没有提示'; break
      fi
      tries=$((tries + 1)); dt send-keys -t drill -l 'fleet claude'; dt send-keys -t drill Enter; quiet=$SECONDS
      row "$(printf '%s\n' "$p" | grep -v '^ *$' | tail -n 2 | head -n 1 | cut -c1-80)" 'fleet claude' '否'
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      line FAIL 触发 "deadline: $(printf '%s\n' "$p" | grep -v '^ *$' | tail -n 1 | cut -c1-120)"; row '等不到' '—' '是 — 卡住'; break
    fi
    sleep "$POLL"
  done
  # the bundle: fleet-debug --dry-run packs what it sent (same list, same scrub) into
  # the sandbox's TMPDIR / cache; none of the planted values may be in it
  fd="$sb/home/.local/share/claude-fleet/bin/fleet-debug"
  if [ -f "$fd" ]; then
    env -i HOME="$sb/home" PATH="$pth" TMPDIR="$sb/tmp" LANG=zh_CN.UTF-8 ${extra[@]+"${extra[@]}"} \
      sh "$fd" report --dry-run > "$OUT/$SC-dry-run.txt" 2>&1
    local dd n
    leaks=0
    for dd in "$sb/tmp" "$sb/home/Library/Caches/fleet-debug" "$sb/home/.cache/fleet-debug"; do
      [ -d "$dd" ] || continue
      n=$(leak_count "$dd" "$sb/planted" 2>>"$OUT/$SC-leaks.txt"); leaks=$((leaks + ${n:-0}))
    done
  fi
  # --- 读页
  if [ -n "$id" ]; then
    local hdr=() h got=0
    while IFS= read -r h; do hdr+=(-H "$h"); got=1; done < <(debug_auth "$sb/home")
    [ "$got" = 0 ] && [ -n "$VIEWER" ] && hdr+=(-H "Authorization: Bearer $VIEWER")
    deadline=$((t_up + PAGE_SECS)); st=''
    while [ "$(date +%s)" -lt "$deadline" ]; do
      st=$(curl -s -m 10 ${hdr[@]+"${hdr[@]}"} "$HUB/v1/fleet/debug/$id" 2>/dev/null)
      printf '%s' "$st" | grep -Eq '已出结论|concluded' && { t_done=$(date +%s); break; }
      printf '%s' "$st" | grep -Eq '没看完|unfinished' && break
      sleep 5
    done
    if [ -z "$t_done" ]; then
      line FAIL 读页 "not concluded within ${PAGE_SECS}s: $(printf '%s' "$st" | head -c 160)"; row '诊断页没出结论' '等' '是 — 诊断没看完'
    else
      curl -s -m 20 ${hdr[@]+"${hdr[@]}"} -o "$OUT/$SC-page.html" "$HUB/s/$id" 2>/dev/null
      sec=$(page_sections < "$OUT/$SC-page.html" | wc -l | tr -d ' ')
      cause=$(cause_ok "$SC" < "$OUT/$SC-page.html")
      page_section '是什么问题' < "$OUT/$SC-page.html" > "$OUT/$SC-cause.txt"
      page_section '请你做' code < "$OUT/$SC-page.html" > "$OUT/$SC-steps.txt"
      row "已出结论（$((t_done - t_up))s）：$(head -c 120 "$OUT/$SC-cause.txt")" '打开短链接' '否'
      if [ "$sec" != 4 ]; then line FAIL 读页 "the page has $sec of the four sections"
      elif [ "$cause" != PASS ]; then line FAIL 读页 "是什么问题 does not name the day's cause: $(head -c 120 "$OUT/$SC-cause.txt")"
      elif [ "$FOLLOW" = 1 ]; then
        local c ok=0
        while IFS= read -r c; do
          dt send-keys -t drill -l "$c"; dt send-keys -t drill Enter; row "请你做：$c" '照打' '否'; sleep 20
        done < "$OUT/$SC-steps.txt"
        dt send-keys -t drill -l 'fleet claude'; dt send-keys -t drill Enter
        deadline=$((SECONDS + STEP_SECS))
        while [ "$SECONDS" -lt "$deadline" ]; do
          p=$(dt capture-pane -p -t drill 2>/dev/null)
          printf '%s\n' "$p" | grep -Eq -- "$CLIENT_UP" && { ok=1; break; }
          sleep "$POLL"
        done
        printf '%s\n' "$p" > "$OUT/$SC-after.txt"
        if [ "$ok" = 1 ]; then r_page=PASS; line PASS 读页 "concluded in $((t_done - t_up))s; the fix worked"; row '客户端起来了' 'fleet claude' '否'
        else line FAIL 读页 'followed 请你做, the fault is still there'; row '照做了还是不行' 'fleet claude' '是 — 修法不对'; fi
      else
        r_page=PASS; line PASS 读页 "concluded in $((t_done - t_up))s; 是什么问题 matches (--follow to try 请你做)"
      fi
    fi
  else
    line SKIP 读页 'nothing was uploaded'
  fi
}

# run_scenario <tls|cap|conn>: the four steps; one row of results.tsv
run_scenario() {
  SC=$1
  local sb login approve d t0_arm p last_p shot=0 tries=0 asked=0 url='' id='' t_up='' t_done=''
  local r_arm=FAIL r_trig=FAIL r_page=FAIL r_rest=FAIL cause='' leaks='' code='' opened='' hand=''
  local pth st sec why
  local extra=() fd=''
  TS=$SECONDS t0_arm=$SECONDS
  printf '\n== %s ==\n' "$SC"
  scenario_steps   # 布置 · 触发 · 读页 — any of them may stop early; 复原 always runs
  # --- 复原
  restore_armed "$OUT" > "$OUT/$SC-restore.txt" 2>&1
  if grep -q FAILED "$OUT/$SC-restore.txt"; then line FAIL 复原 "$(grep FAILED "$OUT/$SC-restore.txt" | head -n 1)"
  elif [ $((SECONDS - t0_arm)) -gt "$RESTORE_SECS" ]; then line FAIL 复原 "restored after $((SECONDS - t0_arm))s (> ${RESTORE_SECS}s)"
  else r_rest=PASS; line PASS 复原 "$(tr '\n' ';' < "$OUT/$SC-restore.txt" | sed 's/;$//')"; fi
  row "复原：$(tr '\n' ' ' < "$OUT/$SC-restore.txt" | cut -c1-120)" '—' '否'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$SC" "$r_arm" "$r_trig" "$r_page" "$r_rest" \
    "$t_up" "$t_done" "${cause:-—}" "$leaks" "$asked" >> "$OUT/results.tsv"
}

for s in $SCEN; do run_scenario "$s"; done
trap - INT TERM HUP
readings "$OUT" > "$OUT/report.md"
printf '\n'; cat "$OUT/report.md"
printf '\nsteps: %s · report: %s · teardown: %s teardown --out %s\n' "$STEPS" "$OUT/report.md" "$0" "$OUT"
[ "$NFAIL" = 0 ]
