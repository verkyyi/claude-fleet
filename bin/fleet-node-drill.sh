#!/bin/bash
# fleet-node-drill.sh — rehearse a managed machine end to end on real hardware
# and read EPIC #2329's five numbers off it (issue #2336, EPIC #2329 C8).
#
#   sudo fleet-node-drill.sh run --to <sha> --fail <sha> [--hub <url>] [--join-file <f>] [--logins a,b]
#   fleet-node-drill.sh count            the five numbers, now (no root needed)
#   sudo fleet-node-drill.sh unblock     take a leftover GitHub block out of /etc/hosts
#
# Run ON the machine being drilled (m4 first — 共同约定 6). Every step that
# touches the machine asks first (y = do it · n = skip, recorded SKIP · q = stop);
# --yes answers y to all (sandbox only). Each step is timed and marked 人 (a
# person does it) or 自动 (the fleet does it); the run ends with two tables —
# the steps, and the five numbers before / after against their targets — printed
# and kept in <state>/drill/<UTC>/report.md for the EPIC report page.
#
# Steps:
#   基线      the five numbers before (count)
#   加入码    人: 入口「机器」页「添加机器」— the code is read from --join-file
#             (deleted once the install succeeds — a failed install leaves it for
#             the rerun) or typed at a hidden prompt; never printed, never logged.
#             --hub (default: $FLEET_HUB_URL, else machine.env's) goes to the install
#   安装      人: the one command — fleet-node-install.sh --join <码> (C1)
#   迁账号    自动, one login at a time (共同约定 5): fleet-node-supervisor.py
#             account adopt <login> from `current`; a failure stops the run and
#             prints the one-command way back (account release)
#   升级      人 moves stable (or the machine's desired release) to --to; the
#             updater (C6) must reach `committed` with current = --to — 自动
#   回退      人 moves it to --fail (a trunk commit that adds conf/drill-fail, so its
#             doctor adds a FAIL — fleet-node-update.py DRILL_FAIL; the next commit
#             removes it, so every install moves FORWARD off it, never back);
#             the updater must reach `rolled-back` with current back on --to — 自动
#   复查      fleet doctor --machine + versions + the five numbers after
#   断GitHub  github.com & co. → 0.0.0.0 in /etc/hosts for the step, then the
#             install converges again (all 跳过) and the current release is
#             fetched from the hub alone; the block is always taken out again
#   回话      人: the machine's sessions answer and the hub can place one here (y/n)
#
# Exit: 0 every step PASS (or SKIP) · 1 a step FAILED · 2 usage · 3 stopped (q)
# Seams (bin/fleet-node-drill-selftest.sh): FLEET_NODE_STATE · FLEET_NODE_ROOT ·
#   FLEET_NODE_DAEMON_DIR · FLEET_NODE_USERS · FLEET_DRILL_HOSTS (/etc/hosts) ·
#   FLEET_DRILL_INSTALL · FLEET_DRILL_SUPERVISOR · FLEET_DRILL_UPDATE (the three
#   scripts; default: beside this one, then `current`) · FLEET_DRILL_FETCH (a
#   command run as `<cmd> <sha> <dir>`; default ccquota release fetch) ·
#   FLEET_DRILL_WAIT (1800 s per updater wait) · FLEET_DRILL_POLL (10 s) ·
#   FLEET_NODE_TEST=1 (no root needed)
set -uo pipefail

PROG=fleet-node-drill
PY="${FLEET_NODE_PYTHON:-/usr/bin/python3}"
STATE="${FLEET_NODE_STATE:-/var/db/fleet-node}"
ROOT="${FLEET_NODE_ROOT:-/Library/Application Support/claude-fleet}"
DDIR="${FLEET_NODE_DAEMON_DIR:-/Library/LaunchDaemons}"
UDIR="${FLEET_NODE_USERS:-/Users}"
HOSTS="${FLEET_DRILL_HOSTS:-/etc/hosts}"
WAIT="${FLEET_DRILL_WAIT:-1800}"
POLL="${FLEET_DRILL_POLL:-10}"
MARK="# fleet-node-drill github block"
GH_HOSTS="github.com api.github.com codeload.github.com objects.githubusercontent.com raw.githubusercontent.com"
export FLEET_NODE_STATE="$STATE" FLEET_NODE_ROOT="$ROOT" FLEET_NODE_DAEMON_DIR="$DDIR" \
  FLEET_NODE_USERS="$UDIR" FLEET_NODE_RUNTIME="$ROOT/current"

here="$(cd "$(dirname "$0")" && pwd -P)"
usage() { sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# script <name> <seam value> — the seam, else beside this one, else `current`'s
script() {
  if [ -n "$2" ]; then printf '%s' "$2"; return; fi
  if [ -f "$ROOT/current/bin/$1" ]; then printf '%s' "$ROOT/current/bin/$1"; return; fi
  printf '%s' "$here/$1"
}
SUP() { "$PY" "$(script fleet-node-supervisor.py "${FLEET_DRILL_SUPERVISOR:-}")" "$@"; }
UPD() { "$PY" "$(script fleet-node-update.py "${FLEET_DRILL_UPDATE:-}")" "$@"; }

# ---------------------------------------------------------------- the five numbers
# count → KEY=VALUE lines: services · machine · kinds · github · parts · accounts
count() {
  local doc=""
  [ -e "$ROOT/current" ] && doc="$(UPD doctor 2>/dev/null)"
  DOC="$doc" "$PY" -I - "$DDIR" "$UDIR" "$STATE/accounts.json" <<'PY'
import json, os, re, sys
ddir, udir, acc = sys.argv[1:4]
live = re.compile(r"^com\.(claude-fleet|ccquota)\..+\.plist$")
left = re.compile(r"\.(bak|pre-move|retired|disabled)")
def ls(d):
    try:
        return [f for f in sorted(os.listdir(d)) if live.match(f) and not left.search(f)]
    except OSError:
        return []
try:
    managed = {k for k, v in json.load(open(acc)).items() if (v or {}).get("managed")}
except (OSError, ValueError):
    managed = set()
users = [u for u in (sorted(os.listdir(udir)) if os.path.isdir(udir) else [])
         if not u.startswith(".") and u != "Shared" and os.path.isdir(os.path.join(udir, u))]
daemons = ls(ddir)
units = {u: set() for u in users}
owned = set()
for f in daemons:
    base = f[:-len(".plist")]
    for u in users:
        if base.startswith("com.claude-fleet.%s." % u):
            units[u].add(base[len("com.claude-fleet.%s." % u):]); owned.add(f)
        elif base in ("com.ccquota.agent.%s" % u, "com.claude-fleet.credsep.%s" % u):
            units[u].add(base.split(".")[-2]); owned.add(f)
agents = 0
for u in users:
    for f in ls(os.path.join(udir, u, "Library", "LaunchAgents")):
        agents += 1
        units[u].add("agent:" + f[:-len(".plist")].split(".")[-1])
kinds = set()
github = 0
for u in users:
    s = units[u]
    if u in managed:
        kinds.add(("守护代跑",) + tuple(sorted(s)))
    elif s:
        kinds.add(tuple(sorted(s)))
    if u not in managed and ("install-sync" in s or "agent:install-sync" in s):
        github += 1
rows = {}
for line in os.environ.get("DOC", "").splitlines():
    p = line.split(None, 2)
    if len(p) >= 2 and p[0] in ("PASS", "WARN", "FAIL"):   # not the closing INFO summary
        rows[p[1]] = p[0]
parts = ("runtime", "ccquota", "claude", "codex", "tmux", "cache")
notup = sum(1 for p in parts if rows.get(p) != "PASS") if rows else len(parts)
print("services=%d" % (len(daemons) + agents))
print("machine=%d" % (len(daemons) - len(owned)))
print("kinds=%d" % len(kinds))
print("github=%d" % github)
print("parts=%d" % notup)
print("accounts=%s" % ",".join(u for u in users if units[u] or u in managed))
PY
}

val() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

# ---------------------------------------------------------------- the GitHub block
unblock() {
  [ -f "$HOSTS" ] && grep -qF "$MARK" "$HOSTS" || return 0
  local tmp="$HOSTS.drill.$$"
  grep -vF "$MARK" "$HOSTS" >"$tmp" && cat "$tmp" >"$HOSTS"   # keep the inode, mode, owner
  rm -f "$tmp"
  command -v dscacheutil >/dev/null 2>&1 && [ "$HOSTS" = /etc/hosts ] && dscacheutil -flushcache
  echo "GitHub 不再被挡（${HOSTS}）"
}
block() {
  local h
  for h in $GH_HOSTS; do printf '0.0.0.0 %s %s\n::1 %s %s\n' "$h" "$MARK" "$h" "$MARK"; done >>"$HOSTS"
  command -v dscacheutil >/dev/null 2>&1 && [ "$HOSTS" = /etc/hosts ] && dscacheutil -flushcache
  return 0
}

# ---------------------------------------------------------------- run ------------
ASK_ALL=0
TO="" FAILSHA="" JOINF="" LOGINS="" HUB="${FLEET_HUB_URL:-}"
OUT="" STEPS="" FAILED=0

ask() { # ask <question> → 0 do it · 1 skip · exits 3 on q
  [ "$ASK_ALL" = 1 ] && return 0
  local a
  printf '\n▶ %s [y/n/q] ' "$1" >/dev/tty
  read -r a </dev/tty || a=q
  case "$a" in y|Y|yes) return 0 ;; q|Q) report; echo "$PROG: 停在这一步（q）" >&2; exit 3 ;; *) return 1 ;; esac
}
# row <step> <who> <secs> <PASS|FAIL|SKIP> <note>
row() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >>"$STEPS"
  printf '  %-8s %-4s %5ss  %-4s %s\n' "$1" "$2" "$3" "$4" "$5"
  [ "$4" = FAIL ] && FAILED=1
  return 0
}
t0() { T0=$(date +%s); }
dt() { echo $(( $(date +%s) - T0 )); }

# wait_update <want result> <want current sha> → 0 reached · 1 timeout / a wrong result
wait_update() {
  local end=$(( $(date +%s) + WAIT )) st res cur
  while :; do
    st="$(UPD status --json 2>/dev/null)"
    res="$(printf '%s' "$st" | "$PY" -c 'import json,sys
try: print(json.load(sys.stdin).get("result",""))
except ValueError: print("")')"
    cur="$(readlink "$ROOT/current" 2>/dev/null)"; cur="${cur##*/}"
    if [ "$res" = "$1" ] && [ "$cur" = "$2" ]; then return 0; fi
    case "$res:$1" in failed:*|rolled-back:committed) NOTE="$res — $(UPD status 2>/dev/null)"; return 1 ;; esac
    [ "$(date +%s)" -ge "$end" ] && { NOTE="${WAIT}s 内没到 $1（${res}，current ${cur:0:12}）"; return 1; }
    sleep "$POLL"
  done
}

report() {
  [ -n "$OUT" ] || return 0
  local before="$OUT/before.env" after="$OUT/after.env"
  {
    echo "# fleet-node-drill · $(hostname -s 2>/dev/null) · $(basename "$OUT")"
    echo
    echo "| 步 | 谁 | 用时 | 结果 | 说明 |"
    echo "|---|---|---|---|---|"
    LC_ALL=C awk -F'\t' '{printf "| %s | %s | %ss | %s | %s |\n", $1, $2, $3, $4, $5}' "$STEPS"
    echo
    echo "| 指标 | 演练前 | 演练后 | 目标 | 达标 |"
    echo "|---|---|---|---|---|"
    local human b a
    human=$(LC_ALL=C awk -F'\t' '$1 ~ /^(加入码|安装)$/ && $2 == "人" && $4 != "SKIP"' "$STEPS" | wc -l | tr -d ' ')
    # read only off an install that went through
    LC_ALL=C awk -F'\t' '$1 == "安装" && $4 == "PASS" {f = 1} END {exit !f}' "$STEPS" || human=""
    m() { # m <name> <key> <target> <op: le|eq>
      b="$( [ -f "$before" ] && val "$(cat "$before")" "$2")"; a="$( [ -f "$after" ] && val "$(cat "$after")" "$2")"
      local okw="—"
      if [ -n "$a" ]; then { [ "$a" -le "$3" ] && okw="✓"; } || okw="✗"; fi
      echo "| $1 | ${b:--} | ${a:--} | ≤ $3 | $okw |"
    }
    local okh="—"; [ -n "$human" ] && { { [ "$human" -le 2 ] && okh="✓"; } || okh="✗"; }
    echo "| 把一台 Mac 变成托管机器要人动手的步骤 | 8 | ${human:--} | ≤ 2 | $okh |"
    m "一台机器上 fleet 的后台服务" services 3
    m "不跟着发布版自动更新的部件" parts 0
    m "各账号后台服务不一致的种类" kinds 1
    m "机器更新时要连 GitHub 的地方" github 0
  } >"$OUT/report.md"
  echo
  cat "$OUT/report.md"
  echo
  echo "报告：$OUT/report.md"
}

run() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) TO="${2:-}"; shift ;;
      --fail) FAILSHA="${2:-}"; shift ;;
      --join-file) JOINF="${2:-}"; shift ;;
      --hub) HUB="${2:-}"; shift ;;
      --logins) LOGINS="${2:-}"; shift ;;
      --yes) ASK_ALL=1 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "$PROG: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
  done
  case "$TO:$FAILSHA" in *[!0-9a-f:]*|:*|*:) echo "$PROG: --to and --fail take the full commit sha of each" >&2; exit 2 ;; esac
  if [ "$(id -u)" != 0 ] && [ "${FLEET_NODE_TEST:-}" != 1 ]; then
    echo "$PROG: run as root (sudo) — it installs and swaps the machine's runtime" >&2; exit 2
  fi
  [ -n "$HUB" ] || HUB="$(sed -n 's/^CCQUOTA_HUB_URL=//p' "$STATE/machine.env" 2>/dev/null | head -n 1)"
  unblock >/dev/null   # a block a killed run left behind
  OUT="$STATE/drill/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$OUT" && chmod 700 "$OUT" || { echo "$PROG: cannot write $OUT" >&2; exit 1; }
  STEPS="$OUT/steps.tsv"; : >"$STEPS"
  trap 'unblock >/dev/null' EXIT

  t0; count >"$OUT/before.env"
  row 基线 自动 "$(dt)" PASS "$(tr '\n' ' ' <"$OUT/before.env")"

  # 加入码 + 安装 — one person, two steps
  local code="" rc
  if ask "在 $(hostname -s 2>/dev/null) 上安装托管机器（fleet-node-install.sh，覆盖现有安装）"; then
    t0
    if [ -n "$JOINF" ]; then code="$(tr -d ' \n' <"$JOINF")"
    elif [ "$ASK_ALL" != 1 ]; then printf '加入码（入口「机器」页「添加机器」，不回显）：' >/dev/tty; read -rs code </dev/tty; echo >/dev/tty
    fi
    row 加入码 人 "$(dt)" PASS "入口「机器」页点一次「添加机器」"
    t0
    "$(script fleet-node-install.sh "${FLEET_DRILL_INSTALL:-}")" ${HUB:+--hub "$HUB"} ${code:+--join "$code"} >"$OUT/install.log" 2>&1; rc=$?
    code=""
    [ "$rc" = 0 ] && [ -n "$JOINF" ] && rm -f "$JOINF"
    if [ "$rc" = 0 ]; then row 安装 人 "$(dt)" PASS "一条命令；$(grep -c '^✓' "$OUT/install.log") 步做了 · $(grep -c '^跳过' "$OUT/install.log") 步跳过"
    else row 安装 人 "$(dt)" FAIL "$(grep '^✗' "$OUT/install.log" | head -n 1)"; report; exit 1; fi
  else row 安装 人 0 SKIP "没装"; fi

  # 迁账号 — one at a time; the person's own login last (risk table)
  local l list="${LOGINS:-$(val "$(cat "$OUT/before.env")" accounts)}" me="${SUDO_USER:-}"
  list="$(printf '%s' "$list" | tr ',' '\n' | grep -v "^${me:-^}$"; [ -n "$me" ] && printf '%s\n' "$list" | tr ',' '\n' | grep -x "$me")"
  for l in $list; do
    if ask "把 $l 的服务交给守护（account adopt ${l}；退回：account release ${l}）"; then
      t0
      if SUP account adopt "$l" >"$OUT/adopt-$l.log" 2>&1; then row "迁:$l" 自动 "$(dt)" PASS "$(tail -n 1 "$OUT/adopt-$l.log")"
      else row "迁:$l" 自动 "$(dt)" FAIL "$(tail -n 1 "$OUT/adopt-$l.log") — 退回：sudo $(script fleet-node-supervisor.py "${FLEET_DRILL_SUPERVISOR:-}") account release $l"; report; exit 1; fi
    else row "迁:$l" 自动 0 SKIP "没迁"; fi
  done

  # 升级
  if ask "把 stable（或这台的期望发布版）移到 ${TO:0:12} — 移好了再答 y，然后等更新器"; then
    t0
    if wait_update committed "$TO"; then row 升级 自动 "$(dt)" PASS "current = ${TO:0:12}（更新器自己换的）"
    else row 升级 自动 "$(dt)" FAIL "$NOTE"; fi
  else row 升级 自动 0 SKIP "没移"; fi

  # 回退
  if ask "把 stable 移到故意失败的 ${FAILSHA:0:12}（带 conf/drill-fail）— 移好了再答 y；看完往前移到删掉标记的提交"; then
    t0
    if wait_update rolled-back "$TO"; then row 回退 自动 "$(dt)" PASS "体检多出 FAIL → 整体退回 ${TO:0:12}"
    else row 回退 自动 "$(dt)" FAIL "$NOTE"; fi
  else row 回退 自动 0 SKIP "没移"; fi

  # 复查
  t0
  UPD doctor >"$OUT/doctor.txt" 2>&1; rc=$?
  UPD versions >>"$OUT/doctor.txt" 2>&1
  count >"$OUT/after.env"
  if [ "$rc" = 0 ]; then row 复查 自动 "$(dt)" PASS "doctor --machine 0 FAIL · $(tr '\n' ' ' <"$OUT/after.env")"
  else row 复查 自动 "$(dt)" FAIL "doctor --machine $rc FAIL（$OUT/doctor.txt）"; fi

  # 断 GitHub
  if ask "挡住 GitHub（/etc/hosts，这一步内），再装一遍、从入口取一次当前发布版"; then
    t0; block
    local cur tmp ok=1 why=""
    cur="$(readlink "$ROOT/current" 2>/dev/null)"; cur="${cur##*/}"
    "$(script fleet-node-install.sh "${FLEET_DRILL_INSTALL:-}")" ${HUB:+--hub "$HUB"} >"$OUT/offline-install.log" 2>&1 \
      || { ok=0; why="重装：$(grep '^✗' "$OUT/offline-install.log" | head -n 1)"; }
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/fleet-node-drill.XXXXXX")"
    if [ "$ok" = 1 ]; then
      if [ -n "${FLEET_DRILL_FETCH:-}" ]; then $FLEET_DRILL_FETCH "$cur" "$tmp/r" >"$OUT/offline-fetch.log" 2>&1
      else "$ROOT/current/bin/ccquota" release fetch --hub "$(sed -n 's/^CCQUOTA_HUB_URL=//p' "$STATE/machine.env" | head -n 1)" \
             --pubkey "$STATE/release.pub" --artifacts "$cur" "$tmp/r" >"$OUT/offline-fetch.log" 2>&1
      fi || { ok=0; why="取发布版：$(tail -n 1 "$OUT/offline-fetch.log")"; }
    fi
    rm -rf "$tmp"; unblock >/dev/null
    if [ "$ok" = 1 ]; then row 断GitHub 自动 "$(dt)" PASS "重装 $(grep -c '^跳过' "$OUT/offline-install.log") 步跳过 · 只从入口取到 ${cur:0:12}"
    else row 断GitHub 自动 "$(dt)" FAIL "$why"; fi
  else row 断GitHub 自动 0 SKIP "没挡"; fi

  # 回话
  # --yes cannot look: a person answers this one, so it stays open (SKIP), never a PASS
  if [ "$ASK_ALL" = 1 ]; then row 回话 人 0 SKIP "--yes 代跑：待人确认会话能回话、入口能往这台派会话"
  elif ask "这台上的会话都能回话、入口能往这台派会话？（自己看一眼：答 y = 是）"; then row 回话 人 0 PASS "发起人看过"
  else row 回话 人 0 FAIL "会话不回话或派不过来"; fi

  report
  [ "$FAILED" = 0 ]
}

case "${1:-}" in
  run) shift; run "$@"; exit $? ;;
  count) count ;;
  unblock) unblock ;;
  -h|--help|help|'') usage ;;
  *) echo "$PROG: unknown command $1 (see --help)" >&2; exit 2 ;;
esac
