#!/bin/bash
# fleet-release.sh [--to <sha>] [--dry-run] [--machines a,b] [--no-kick]
#                  [--allow-no-checks] [--dir <checkout>] [--repo <owner/name>]
#                  [--ci-timeout <s>] [--hub-timeout <s>] [--machines-timeout <s>]
#                  [--local-timeout <s>]
# fleet-release.sh --rollback [--to <sha>] [--dry-run]
#   — `fleet release`: ONE command from «master is green» to «every machine runs
#   it», each step checked, stopping at the first that does not pass
#   (issue #2483, EPIC #2482 C3).
#
# Moving stable used to be a hand-run `fleet-stable.sh move` and nothing after
# it: nobody looked whether the hub handed the new client out, whether m4 / m5
# followed, whether this machine's own install switched. On 2026-10-08 stable sat
# 14 commits / 7 hours behind master and the client and node fixes reached no
# machine. The six steps, one line each:
#
#   ① CI      the target's check runs on GitHub, ALL of them — the `macOS shard *`
#             runs and the newest selftests-macos.yml run about the target too. A
#             red one REFUSES (exit 3) and is named; one still running is waited
#             for (--ci-timeout, default 1800 s); no macOS run yet is left to ②,
#             which dispatches the full suite on the target and waits.
#   ② stable  bin/fleet-stable.sh move <target> — every gate it has (on trunk,
#             forward only, CI green, the old-session replay, macOS, release.json),
#             unchanged. Its refusal is ours (exit 3), its lost lease too (exit 4).
#   ③ 入口    the hub's GET /version names the target as `stable` (the client
#             every computer installs follows it, issue #1805). Polled until it
#             does, up to --hub-timeout (default 600 s: the hub trusts a lookup
#             5 minutes). No hub address here = not applicable, said so.
#   ④ 机器    every OTHER machine reports the target as its fleet version: the
#             hub's /v1/nodes (the viewer token: CCQUOTA_VIEWER_TOKEN, else
#             ~/.ccquota/viewer-token) lists them. A machine's version is read
#             over ssh on a five-minute hub certificate (fleet-peer-cert.sh
#             <machine> upgrade): a managed machine's updater `current` link
#             (issue #2334 — its logins' ~/.claude/fleet is not what it runs, and
#             that is what their heartbeat reports), else `git rev-parse HEAD` of
#             its ~/.claude/fleet; when ssh cannot, the hub's reading — the most
#             recently heard login's fleet_version, as the bar's 旧. Which machines: --machines / FLEET_RELEASE_MACHINES,
#             else every online machine on /v1/nodes that is not personal, SPOT or
#             维护中 (a lost one is named and not waited for), else the machines
#             `fleet login` wrote to $FLEET_CONF_DIR/peer/machines (by alias, the
#             name ssh reaches). This machine is ⑤'s, never ④'s. Right after ② each
#             one is KICKED — its install-sync started now over the same ssh,
#             instead of on its next 30-minute tick (--no-kick: wait for the
#             tick); a managed machine's install-sync is off and the kick is a
#             no-op there — its updater ticks every 5 minutes and follows the
#             hub's stable (③), so it lands within about ten. Up to --machines-timeout (default 900 s); the ones that did
#             not follow are named.
#   ⑤ 本机    this machine's install-sync run now (the live install's own
#             bin/fleet-install-sync.sh — its EPIC gate, checks and rollback
#             unchanged; a tick the daemon holds is retried up to --local-timeout,
#             default 600 s), then its state must say head = the target and the
#             live doctor's `install` row must PASS (a WARN that only says master
#             has moved on past the target counts as a pass, and is said).
#   ⑥ 回退    `--rollback` moves stable BACK to the version before the last
#             release (logs/release.log), or to --to, with a lease on what it
#             read. Done on its own when ⑤'s install-sync rejected the version
#             (its doctor found a new FAIL: `rolled-back` / `skipped`) — the
#             version's own fault; a machine that is merely slow is not, and the
#             stop then prints the rollback command instead. Moving stable back
#             stops the version from spreading; an install that already switched
#             stays until stable moves forward past it (install-sync never moves
#             backward).
#
# --dry-run runs ① for real (read-only), asks ② with fleet-stable.sh --dry-run,
# and lists what ③–⑤ would wait for: nothing is pushed, kicked or synced.
# Nothing triggers a release on its own — the operator runs it.
#
# logs/release.log (FLEET_RELEASE_LOG): one line per run, tab-separated —
#   <UTC>  from=<sha7>  to=<sha7>  result=<word>  secs=<n>  waited=<n>
#   hub=<n>s|-  machines=<m>@<n>s,<m>:timeout…|-  local=<n>s|-  by=<user>
# result: released · verified (stable was already there) · refused:ci ·
# refused:stable · push-failed · failed:hub · failed:machines · failed:local ·
# rolled-back (failed, and stable was moved back) · rollback (--rollback).
# `waited` is how long the oldest commit this release carries had waited on
# master — the EPIC's «稳定版落后主干的时长», read from here.
#
# Exit: 0 released / verified / dry-run listed · 2 usage or a read error ·
#       3 refused (① red, or ② refused) · 4 push failed (lease lost) ·
#       5 a follow step (③ ④ ⑤) did not pass — stopped, rollback said or done
#
# Seams (bin/fleet-release-selftest.sh): FLEET_RELEASE_STABLE (fleet-stable.sh) ·
# FLEET_RELEASE_VERSION_CMD (prints /version) · FLEET_RELEASE_NODES_CMD (prints
# /v1/nodes) · FLEET_RELEASE_VERSION_OF_CMD (`<cmd> <machine>` prints its head) ·
# FLEET_RELEASE_KICK_CMD (`<cmd> <machine>`) · FLEET_RELEASE_SYNC_CMD ·
# FLEET_RELEASE_SYNC_STATE · FLEET_RELEASE_DOCTOR_CMD · FLEET_RELEASE_HOST ·
# FLEET_RELEASE_POLL (15) · FLEET_LIVE_DIR. gh is found on PATH.
set -uo pipefail

BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROG=fleet-release
dir="$(cd "$BIN/.." && pwd)"
remote=origin branch=master repo='' target='' dry=0 rollback=0 kick=1 allow_nochecks=0
machines_arg="${FLEET_RELEASE_MACHINES:-}"
ci_timeout=1800 hub_timeout=600 mach_timeout=900 local_timeout=600

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --to)               shift; target="${1:-}"; [ -n "$target" ] || die "--to needs a commit" ;;
    --dry-run|-n)       dry=1 ;;
    --rollback)         rollback=1 ;;
    --machines)         shift; machines_arg="${1:-}" ;;
    --no-kick)          kick=0 ;;
    --allow-no-checks)  allow_nochecks=1 ;;
    --dir)              shift; dir="${1:-}" ;;
    --repo)             shift; repo="${1:-}" ;;
    --ci-timeout)       shift; ci_timeout="${1:-}" ;;
    --hub-timeout)      shift; hub_timeout="${1:-}" ;;
    --machines-timeout) shift; mach_timeout="${1:-}" ;;
    --local-timeout)    shift; local_timeout="${1:-}" ;;
    -h|--help)          usage; exit 0 ;;
    *)                  usage >&2; die "unknown argument $1" ;;
  esac
  shift
done
for v in ci_timeout hub_timeout mach_timeout local_timeout; do
  eval "x=\${$v}"
  case "$x" in ''|*[!0-9]*) die "a --*-timeout takes seconds" ;; esac
done
git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || die "$dir is not a git checkout (--dir)"

STABLE_SH="${FLEET_RELEASE_STABLE:-$BIN/fleet-stable.sh}"
CONF_DIR="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
LIVE="${FLEET_LIVE_DIR:-$HOME/.claude/fleet}"
LOG="${FLEET_RELEASE_LOG:-$BIN/../logs/release.log}"
POLL="${FLEET_RELEASE_POLL:-15}"; case "$POLL" in ''|*[!0-9]*|0) POLL=15 ;; esac
HOST_SELF="${FLEET_RELEASE_HOST:-$(hostname -s 2>/dev/null || hostname)}"
HOST_SELF=$(printf '%s' "$HOST_SELF" | tr 'A-Z' 'a-z'); HOST_SELF=${HOST_SELF%%.*}
T0=$(date +%s)

g() { git -C "$dir" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 "$@"; }
short() { printf '%.7s' "${1:-}"; }
utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
el() { printf '%s' $(( $(date +%s) - $1 )); }
step() { printf '%s %s\n' "$1" "$2"; }           # one line per step, on stdout
note() { printf '    %s\n' "$*"; }

# The remote stable's commit ('' = no tag); rc 2 = the remote could not be read.
remote_stable() {
  local ls peeled
  ls=$(g ls-remote "$remote" "refs/tags/stable" "refs/tags/stable^{}" 2>/dev/null) || return 2
  peeled=$(printf '%s\n' "$ls" | awk '$2 ~ /\^\{\}$/ {print $1; exit}')
  [ -n "$peeled" ] && { printf '%s\n' "$peeled"; return 0; }
  printf '%s\n' "$ls" | awk 'NF {print $1; exit}'
}
repo_slug() {
  [ -n "$repo" ] && { printf '%s\n' "$repo"; return; }
  git -C "$dir" remote get-url "$remote" 2>/dev/null |
    sed -n 's#^.*github\.com[:/]\([^/]*/[^/]*\)$#\1#p' | sed 's#\.git$##'
}

# One line in logs/release.log. Globals: FROM TO WAITED R_HUB R_MACH R_LOCAL.
FROM='' TO='' WAITED='-' R_HUB='-' R_MACH='-' R_LOCAL='-'
log_line() {   # log_line <result>
  [ "$dry" -eq 1 ] && return 0
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  printf '%s\tfrom=%s\tto=%s\tresult=%s\tsecs=%s\twaited=%s\thub=%s\tmachines=%s\tlocal=%s\tby=%s\n' \
    "$(utc)" "$(short "${FROM:-none}")" "$(short "$TO")" "$1" "$(el "$T0")" "$WAITED" \
    "$R_HUB" "$R_MACH" "$R_LOCAL" "${USER:-?}" >> "$LOG" 2>/dev/null
}

# move_back <from> <to> — stable from <from> back to <to>, leased on <from>.
move_back() {
  if [ "$dry" -eq 1 ]; then
    note "dry-run: would run: git push --force-with-lease=refs/tags/stable:$1 $remote $2:refs/tags/stable"
    return 0
  fi
  g push -q "--force-with-lease=refs/tags/stable:$1" "$remote" "$2:refs/tags/stable"
}

# The version before <sha> per the release log: the `from` of the newest line
# that released <sha>. '' when the log does not know it.
prev_of() {
  [ -f "$LOG" ] || return 0
  awk -F'\t' -v to="to=$(short "$1")" '
    $3 == to && ($4 == "result=released" || $4 == "result=verified") { f = $2 }
    END { sub(/^from=/, "", f); if (f != "none") print f }' "$LOG"
}

# ── ⑥ --rollback ─────────────────────────────────────────────────────────────
if [ "$rollback" -eq 1 ]; then
  cur=$(remote_stable) || die "could not read refs/tags/stable from $remote"
  [ -n "$cur" ] || die "there is no stable tag to move back"
  back="$target"
  [ -n "$back" ] || back=$(prev_of "$cur")
  [ -n "$back" ] || die "the release log ($LOG) does not say what came before $(short "$cur") — name it: --rollback --to <sha>"
  g fetch --no-tags -q "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch" 2>/dev/null
  git -C "$dir" cat-file -e "$back^{commit}" 2>/dev/null || g fetch --no-tags -q "$remote" "$back" 2>/dev/null
  back=$(git -C "$dir" rev-parse -q --verify "$back^{commit}") || die "unknown commit $back"
  [ "$back" != "$cur" ] || { step '⑥ 回退' "stable 已在 $(short "$back")，不用回退"; exit 0; }
  git -C "$dir" merge-base --is-ancestor "$back" "$remote/$branch" 2>/dev/null ||
    die "$(short "$back") is not on $remote/$branch — stable only ever names a trunk commit"
  FROM=$cur TO=$back
  if move_back "$cur" "$back"; then
    step '⑥ 回退' "stable $(short "$cur") → $(short "$back")$([ "$dry" -eq 1 ] && printf '（dry-run，没推）')"
    note "已经切到 $(short "$cur") 的机器留在那里，直到 stable 再往前越过它（install-sync 不往回走）"
    log_line rollback; exit 0
  fi
  printf '%s: push FAILED — stable moved under us (lease lost) or no push rights\n' "$PROG" >&2
  exit 4
fi

# ── the target ───────────────────────────────────────────────────────────────
old=$(remote_stable) || die "could not read refs/tags/stable from $remote — not releasing blind"
g fetch --no-tags -q "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch" 2>/dev/null ||
  die "could not fetch $remote/$branch"
if [ -z "$target" ]; then
  new=$(git -C "$dir" rev-parse --verify "refs/remotes/$remote/$branch^{commit}") || die "no $remote/$branch"
else
  git -C "$dir" cat-file -e "$target^{commit}" 2>/dev/null || g fetch --no-tags -q "$remote" "$target" 2>/dev/null
  new=$(git -C "$dir" rev-parse -q --verify "$target^{commit}") || die "unknown commit $target"
fi
FROM=$old TO=$new
if [ -n "$old" ] && ! git -C "$dir" cat-file -e "$old^{commit}" 2>/dev/null; then
  g fetch --no-tags -q "$remote" "$old" 2>/dev/null || die "could not fetch the current stable commit $(short "$old")"
fi
# How long the oldest commit this release carries has waited on master.
if [ -n "$old" ] && [ "$old" != "$new" ]; then
  first=$(git -C "$dir" rev-list --reverse "$old..$new" 2>/dev/null | head -n 1)
  [ -n "$first" ] && WAITED=$(( $(date +%s) - $(git -C "$dir" log -1 --format=%ct "$first") ))
fi
slug=$(repo_slug); [ -n "$slug" ] || die "cannot tell the GitHub repo from $remote — pass --repo owner/name"
printf 'release: stable %s → %s  (%s)%s\n' "$(short "${old:-none}")" "$(short "$new")" \
  "$(git -C "$dir" log -1 --format=%s "$new" 2>/dev/null)" "$([ "$dry" -eq 1 ] && printf '  [dry-run]')"

# ── ① CI ─────────────────────────────────────────────────────────────────────
MACOS_WF="${FLEET_STABLE_MACOS_WORKFLOW:-selftests-macos.yml}"
ci_read() {   # CI_BAD (red, named) · CI_PEND (running) · CI_N (green) · CI_MAC (a word)
  local runs row mst mcl mid
  # The macOS shards are judged by the newest macOS run ABOUT the target below,
  # as fleet-stable.sh's gate 5 does: a push run a later push cancelled, or one a
  # green dispatch on the same commit superseded, is no verdict.
  runs=$(gh api --paginate "repos/$slug/commits/$new/check-runs?per_page=100" \
    --jq '.check_runs[] | "\(.status)\t\(.conclusion)\t\(.name)"' 2>/dev/null) || return 2
  runs=$(printf '%s\n' "$runs" | awk -F'\t' 'NF && $3 !~ /^macOS shard/')
  CI_BAD=$(printf '%s\n' "$runs" | awk -F'\t' 'NF && $1 == "completed" && $2 != "success" && $2 != "neutral" && $2 != "skipped" {print $3 " (" $2 ")"}')
  CI_PEND=$(printf '%s\n' "$runs" | awk -F'\t' 'NF && $1 != "completed" {print $3}')
  CI_N=$(printf '%s\n' "$runs" | awk -F'\t' 'NF && $1 == "completed" && ($2 == "success" || $2 == "neutral" || $2 == "skipped")' | wc -l | tr -d ' ')
  CI_MAC=absent
  git -C "$dir" cat-file -e "$new:.github/workflows/$MACOS_WF" 2>/dev/null || return 0
  row=$(gh api "repos/$slug/actions/workflows/$MACOS_WF/runs?per_page=100" \
    --jq '.workflow_runs[] | [.head_sha, .status, (.conclusion // ""), .event, (.id|tostring), (.display_title // "")] | @tsv' 2>/dev/null |
    awk -F'\t' -v sha="$new" 'NF < 5 || $4 ~ /^pull_request/ || $3 == "cancelled" { next }
      $1 == sha || $6 ~ ("@ " sha "$") { print $2 " " ($3 == "" ? "-" : $3) " " $5; exit }') || return 2
  mst=$(printf '%s' "$row" | awk '{print $1}') mcl=$(printf '%s' "$row" | awk '{print $2}') mid=$(printf '%s' "$row" | awk '{print $3}')
  if [ -z "$row" ]; then CI_MAC=none
  elif [ "$mst" != completed ]; then CI_MAC="running $mid"
  elif [ "$mcl" = success ]; then CI_MAC="green $mid"
  else
    CI_MAC=red
    CI_BAD="${CI_BAD:+$CI_BAD
}$MACOS_WF run $mid ($mcl): https://github.com/$slug/actions/runs/$mid"
  fi
}
t=$(date +%s)
while :; do
  ci_read || die "could not read the check runs of $(short "$new") on $slug (gh auth?)"
  [ -z "$CI_BAD" ] || break
  [ -n "$CI_PEND" ] || break
  if [ "$dry" -eq 1 ] || [ "$(el "$t")" -ge "$ci_timeout" ]; then break; fi
  sleep "$POLL"
done
if [ -n "$CI_BAD" ]; then
  step '① CI' "红 — $(short "$new") 有检查没过，不发布："
  printf '%s\n' "$CI_BAD" | sed 's/^/    ✗ /'
  log_line refused:ci; exit 3
fi
if [ -n "$CI_PEND" ]; then
  if [ "$dry" -eq 1 ]; then
    step '① CI' "还在跑 $(printf '%s\n' "$CI_PEND" | wc -l | tr -d ' ') 个（$(printf '%s' "$CI_PEND" | head -n 3 | tr '\n' ',' | sed 's/,$//')）— 真跑会等它们跑完（≤${ci_timeout}s）"
  else
    step '① CI' "$(short "$new") 的检查 ${ci_timeout}s 内没跑完：$(printf '%s' "$CI_PEND" | tr '\n' ',' | sed 's/,$//') — 晚点再发"
    log_line refused:ci; exit 3
  fi
else
  case "$CI_MAC" in
    none)    macw="macOS 还没在它上面跑过 — ② 会派发一次全量并等" ;;
    absent)  macw="这个版本没有 macOS 工作流" ;;
    running*) macw="macOS run ${CI_MAC#running } 还在跑 — ② 会等它" ;;
    *)       macw="macOS run ${CI_MAC#green } 绿" ;;
  esac
  step '① CI' "$CI_N 个检查全绿 · $macw"
fi

# ── ② stable ─────────────────────────────────────────────────────────────────
sargs=(move "$new" --dir "$dir" --remote "$remote" --branch "$branch" --repo "$slug")
[ "$allow_nochecks" -eq 1 ] && sargs+=(--allow-no-checks)
[ "$dry" -eq 1 ] && sargs+=(--dry-run)
already=0
if [ -n "$old" ] && [ "$old" = "$new" ]; then
  already=1
  step '② stable' "已在 $(short "$new")，不用挪 — 只核对 ③④⑤"
else
  sout=$(sh "$STABLE_SH" "${sargs[@]}" 2>&1); mrc=$?
  if [ "$mrc" -ne 0 ] && [ "$dry" -eq 1 ] && [ "$mrc" -eq 3 ] &&
     printf '%s' "$sout" | grep -q 'macos: .*--dry-run does'; then
    step '② stable' "其余各门都过；macOS 那门真跑时会派发 / 等待 — dry-run 不派发"
    printf '%s\n' "$sout" | grep -v 'REFUSED — macos:' | sed 's/^/    /'
  elif [ "$mrc" -ne 0 ]; then
    step '② stable' "fleet-stable.sh move 没挪（exit ${mrc}）："
    printf '%s\n' "$sout" | sed 's/^/    /'
    case "$mrc" in
      3) log_line refused:stable; exit 3 ;;
      4) log_line push-failed; exit 4 ;;
      *) log_line refused:stable; exit 2 ;;
    esac
  else
    if [ "$dry" -eq 1 ]; then step '② stable' "各门都过 — 会挪到 $(short "$new")（dry-run，没推）"
    else step '② stable' "已挪 $(short "${old:-none}") → $(short "$new")"; fi
    printf '%s\n' "$sout" | sed 's/^/    /'
  fi
fi

# stop <result> <why…> — a follow step did not pass: say it, and how to undo.
stop() {
  local res=$1; shift
  printf '%s: 停在这里 — %s\n' "$PROG" "$*" >&2
  if [ "$already" -eq 0 ] && [ -n "$old" ]; then
    printf '%s: 要退回上一版：fleet release --rollback   （stable → %s）\n' "$PROG" "$(short "$old")" >&2
  fi
  log_line "$res"; exit 5
}

# ── ③ 入口 ───────────────────────────────────────────────────────────────────
hub_url() {
  local u="${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-}}"
  [ -n "$u" ] || u=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?FLEET_HUB_URL=//p' "$CONF_DIR/fleet.conf" 2>/dev/null | tail -n 1 | tr -d "\"' ")
  [ -n "$u" ] || u=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("url") or "")
except Exception: pass' "${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet/hub.json" 2>/dev/null)
  printf '%s' "${u%/}"
}
HUB=$(hub_url)
hub_version() {
  if [ -n "${FLEET_RELEASE_VERSION_CMD:-}" ]; then sh -c "$FLEET_RELEASE_VERSION_CMD"; return; fi
  curl -fsS -m 10 "$HUB/version" 2>/dev/null
}
json_get() { python3 -c 'import json,sys
try: v = json.load(sys.stdin).get(sys.argv[1])
except Exception: sys.exit(1)
print("" if v is None else v)' "$1"; }
if [ -z "$HUB" ] && [ -z "${FLEET_RELEASE_VERSION_CMD:-}" ]; then
  step '③ 入口' "不适用 — 这台没有入口地址（FLEET_HUB_URL）"
elif [ "$dry" -eq 1 ]; then
  st=$(hub_version | json_get stable 2>/dev/null)
  step '③ 入口' "会等 ${HUB:-入口} /version 的 stable = $(short "$new")（现在 $(short "${st:-?}")，≤${hub_timeout}s）"
else
  t=$(date +%s) st=''
  while :; do
    vj=$(hub_version) && st=$(printf '%s' "$vj" | json_get stable 2>/dev/null) || st='?'
    [ "$st" = "$new" ] && break
    [ "$(el "$t")" -lt "$hub_timeout" ] || break
    sleep "$POLL"
  done
  if [ "$st" = "$new" ]; then
    R_HUB="$(el "$t")s"; step '③ 入口' "/version 的 stable = $(short "$new")（${R_HUB}）"
  elif [ -z "$st" ]; then
    R_HUB=n/a; step '③ 入口' "入口的 /version 没有 stable 字段 — 它不跟 stable 发客户端（CCQUOTA_FLEET_STABLE_REPO），不等"
  else
    R_HUB=timeout; step '③ 入口' "${hub_timeout}s 后 /version 的 stable 还是 $(short "$st")，不是 $(short "$new")"
    stop failed:hub "入口没跟上 stable（${HUB:-入口}/version）"
  fi
fi

# ── ④ 机器 ───────────────────────────────────────────────────────────────────
VTOK="${CCQUOTA_VIEWER_TOKEN:-}"
[ -n "$VTOK" ] || { [ -r "$HOME/.ccquota/viewer-token" ] && read -r VTOK < "$HOME/.ccquota/viewer-token"; } || VTOK=''
nodes_json() {
  if [ -n "${FLEET_RELEASE_NODES_CMD:-}" ]; then sh -c "$FLEET_RELEASE_NODES_CMD"; return; fi
  [ -n "$HUB" ] && [ -n "$VTOK" ] || return 1
  printf 'Authorization: Bearer %s\n' "$VTOK" | curl -fsS -m 10 -H @- "$HUB/v1/nodes" 2>/dev/null
}
# machine rows from /v1/nodes: `<name>\t<status>\t<version>` — name = alias or
# the hostname's first label; version = the newest-heard login's fleet_version.
machine_rows() {
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
names, out = {}, {}
for m in d.get("machines") or []:
    h = (m.get("hostname") or "").lower()
    if not h:
        continue
    st = m.get("status") or "?"
    if m.get("personal") or m.get("kind") == "ephemeral":
        continue
    if m.get("maintenance"):
        st = "maintenance"
    names[h] = (m.get("alias") or h.split(".")[0]).lower()
    out[h] = [st, "", ""]
for n in d.get("nodes") or []:
    h = (n.get("hostname") or "").lower()
    if h not in out or not n.get("fleet_version"):
        continue
    t = n.get("last_heartbeat") or ""
    if t >= out[h][2]:
        out[h][1], out[h][2] = n["fleet_version"], t
for h, (st, v, _) in sorted(out.items()):
    print("%s\t%s\t%s\t%s" % (names[h], st, v, h.split(".")[0]))
'
}
# peer_ssh_opts <machine> — PEER=(ssh options) on a hub certificate; rc 1 = refused.
peer_opts() {
  local out rc o
  PEER=()
  out=$(bash "$BIN/fleet-peer-cert.sh" "$1" upgrade 2>/dev/null); rc=$?
  case "$rc" in
    0) while IFS= read -r o; do [ -n "$o" ] && PEER+=("$o"); done <<EOF_PEER
$out
EOF_PEER
       ;;
    3) ;;
    *) return 1 ;;
  esac
}
version_of() {   # the fleet version a machine runs, over ssh
  if [ -n "${FLEET_RELEASE_VERSION_OF_CMD:-}" ]; then sh -c "$FLEET_RELEASE_VERSION_OF_CMD \"\$1\"" _ "$1"; return; fi
  peer_opts "$1" || return 1
  # a managed machine runs what its updater's `current` names (issue #2334) —
  # its logins' ~/.claude/fleet is not moved there; else the install's HEAD
  ssh -o BatchMode=yes -o ConnectTimeout=10 ${PEER[@]+"${PEER[@]}"} "$1" \
    'c="/Library/Application Support/claude-fleet/current"; if [ -L "$c" ]; then basename "$(readlink "$c")"; else git -C "$HOME/.claude/fleet" rev-parse HEAD; fi' 2>/dev/null
}
kick() {   # start a machine's install-sync now; its own gates decide the rest
  if [ -n "${FLEET_RELEASE_KICK_CMD:-}" ]; then sh -c "$FLEET_RELEASE_KICK_CMD \"\$1\"" _ "$1"; return; fi
  peer_opts "$1" || return 1
  ssh -o BatchMode=yes -o ConnectTimeout=10 ${PEER[@]+"${PEER[@]}"} "$1" \
    'nohup "$HOME/.claude/fleet/bin/fleet-install-sync.sh" >/dev/null 2>&1 </dev/null &' >/dev/null 2>&1
}
same() { case "$1" in "$2"*) return 0 ;; esac; case "$2" in "$1"*) [ -n "$1" ] && [ "${#1}" -ge 7 ] && return 0 ;; esac; return 1; }

src='' MLIST='' LOST='' rows=''
if nj=$(nodes_json) && rows=$(printf '%s' "$nj" | machine_rows) ; then src=hub
elif [ -r "$CONF_DIR/peer/machines" ]; then
  # no viewer token: the machines `fleet login` wrote down (fleet-peer-cert.sh's
  # own list, `<hostname> <alias>`), each read over ssh
  rows=$(awk 'NF >= 2 { print tolower($2) "\tonline\t\t" tolower($1) }' "$CONF_DIR/peer/machines")
  [ -n "$rows" ] && src=peer
fi
if [ -n "$machines_arg" ]; then
  MLIST=$(printf '%s' "$machines_arg" | tr ',' '\n' | tr 'A-Z' 'a-z' | awk 'NF')
elif [ -n "$src" ]; then
  MLIST=$(printf '%s\n' "$rows" | awk -F'\t' 'NF && $2 == "online" {print $1}')
  LOST=$(printf '%s\n' "$rows" | awk -F'\t' 'NF && $2 != "online" {print $1 "（" $2 "）"}' | tr '\n' ' ')
fi
# this machine is ⑤'s — by its hostname or its alias
self_row=$(printf '%s\n' "${rows:-}" | awk -F'\t' -v h="$HOST_SELF" 'NF && ($1 == h || $4 == h) {print $1; exit}')
MLIST=$(printf '%s\n' "$MLIST" | awk -v h="$HOST_SELF" -v a="$self_row" 'NF && $1 != h && $1 != a')
self_row=$(printf '%s\n' "${rows:-}" | awk -F'\t' -v h="$HOST_SELF" 'NF && ($1 == h || $4 == h) {print $4; exit}')
[ -z "$self_row" ] || MLIST=$(printf '%s\n' "$MLIST" | awk -v h="$self_row" 'NF && $1 != h')
mver() {   # mver <machine> — its version now ('' unknown): asked over ssh,
          # else the hub's heartbeat reading
  local v
  v=$(version_of "$1") && [ -n "$v" ] && { printf '%s\n' "$v"; return; }
  printf '%s\n' "$rows" | awk -F'\t' -v m="$1" '$1 == m || $4 == m {print $3; exit}'
}
if [ -z "$MLIST" ]; then
  if [ -z "$src" ] && [ -z "$machines_arg" ]; then
    if [ -z "$HUB" ]; then step '④ 机器' "不适用 — 没有入口，也没有 --machines：只有本机"
    else
      step '④ 机器' "读不到机器清单：没有 viewer token（CCQUOTA_VIEWER_TOKEN / ~/.ccquota/viewer-token）— 用 --machines m4,m5 走 ssh 读"
      [ "$dry" -eq 1 ] || stop failed:machines "不知道要等哪些机器"
    fi
  else
    step '④ 机器' "没有别的机器要等${LOST:+（不等：${LOST}）}"
  fi
elif [ "$dry" -eq 1 ]; then
  line=''
  for m in $MLIST; do v=$(mver "$m"); line="$line $m=$(short "${v:-?}")"; done
  step '④ 机器' "会$([ "$kick" -eq 1 ] && printf '叫醒各台的 install-sync，再')等它们都到 $(short "$new")（≤${mach_timeout}s）：${line# }${LOST:+ · 不等：$LOST}"
else
  if [ "$kick" -eq 1 ]; then
    for m in $MLIST; do kick "$m" || note "${m}：叫不醒它的 install-sync（hub 证书 / ssh）— 等它自己 30 分钟的一拍"; done
  fi
  t=$(date +%s) pending="$MLIST" R_MACH=''
  while :; do
    if [ "$src" = hub ]; then nj=$(nodes_json) && rows=$(printf '%s' "$nj" | machine_rows) || :; fi
    left=''
    for m in $pending; do
      v=$(mver "$m")
      if same "$v" "$new"; then R_MACH="${R_MACH:+$R_MACH,}$m@$(el "$t")s"; note "$m 到位（$(el "$t")s）"
      else left="$left $m"; fi
    done
    pending=$(printf '%s' "$left" | tr ' ' '\n' | awk 'NF')
    [ -n "$pending" ] || break
    [ "$(el "$t")" -lt "$mach_timeout" ] || break
    sleep "$POLL"
  done
  if [ -n "$pending" ]; then
    lag=''
    for m in $pending; do v=$(mver "$m"); R_MACH="${R_MACH:+$R_MACH,}$m:timeout"; lag="$lag ${m}（在 $(short "${v:-?}")）"; done
    step '④ 机器' "${mach_timeout}s 后还没跟上：${lag# }"
    stop failed:machines "有机器没跟上 stable $(short "$new")"
  fi
  step '④ 机器' "$(printf '%s' "$MLIST" | wc -l | tr -d ' ') 台都到 $(short "$new")：$R_MACH${LOST:+ · 不等：$LOST}"
fi

# ── ⑤ 本机 ───────────────────────────────────────────────────────────────────
SYNC="${FLEET_RELEASE_SYNC_CMD:-$LIVE/bin/fleet-install-sync.sh}"
SSTATE="${FLEET_RELEASE_SYNC_STATE:-$CONF_DIR/global/install-sync.state}"
DOCTOR="${FLEET_RELEASE_DOCTOR_CMD:-$LIVE/bin/fleet-doctor.sh}"
sget() { sed -n "s/^$1: //p" "$SSTATE" 2>/dev/null | head -n 1; }
# run_cmd <seam> <script> — a seam is a command line, the default a script path.
run_cmd() { if [ -n "$1" ]; then sh -c "$1"; else bash "$2"; fi; }
if [ -z "${FLEET_RELEASE_SYNC_CMD:-}" ] && [ ! -d "$LIVE" ]; then
  step '⑤ 本机' "不适用 — 这台没有 $LIVE"
elif [ "$dry" -eq 1 ]; then
  step '⑤ 本机' "会跑本机 install-sync（现在 $(short "$(sget head)")），再看 doctor 的 install 行"
else
  t=$(date +%s)
  # A tick the daemon is running right now holds the lock — try again until the
  # state says where this machine stands, up to --local-timeout.
  while :; do
    run_cmd "${FLEET_RELEASE_SYNC_CMD:-}" "$SYNC" >/dev/null 2>&1
    res=$(sget result) head=$(sget head) why=$(sget reason)
    same "$head" "$new" && break
    case "$res" in refused|rolled-back|skipped|deferred) break ;; esac
    [ "$(el "$t")" -lt "$local_timeout" ] || break
    sleep "$POLL"
  done
  if ! same "$head" "$new"; then
    R_LOCAL="$res"
    step '⑤ 本机' "install-sync 没切到 $(short "$new")：${res:-?} — ${why:-没有说明}"
    case "$res" in
      rolled-back|skipped)
        if [ "$already" -eq 0 ] && [ -n "$old" ]; then
          if move_back "$new" "$old"; then
            step '⑥ 回退' "本机体检拒了这个版本 — stable 已自动退回 $(short "$old")"
            log_line rolled-back; exit 5
          fi
          note "自动回退没推上（lease / 权限）— 手动：fleet release --rollback"
        fi ;;
    esac
    stop failed:local "本机 install-sync：${res:-?}"
  fi
  drow=$(run_cmd "${FLEET_RELEASE_DOCTOR_CMD:-}" "$DOCTOR" 2>/dev/null | awk '$2 == "install" && $1 != "INFO" {print; exit}')
  lvl=$(printf '%s' "$drow" | awk '{print $1}')
  R_LOCAL="$(el "$t")s"
  case "$lvl" in
    PASS) step '⑤ 本机' "install-sync ${res}，在 $(short "$new")；doctor install PASS（${R_LOCAL}）" ;;
    WARN) case "$drow" in
            *'behind'*) step '⑤ 本机' "install-sync ${res}，在 $(short "$new")；doctor install 只说 master 又往前走了 — 算过（${R_LOCAL}）" ;;
            *) step '⑤ 本机' "doctor 的 install 行没过：$(printf '%s' "$drow" | sed 's/^ *//')"
               R_LOCAL=doctor; stop failed:local "本机 doctor 的 install 行不是 PASS" ;;
          esac ;;
    '') step '⑤ 本机' "install-sync ${res}，在 $(short "$new")；doctor 没给 install 行（不是 checkout？）（${R_LOCAL}）" ;;
    *)  step '⑤ 本机' "doctor 的 install 行没过：$(printf '%s' "$drow" | sed 's/^ *//')"
        R_LOCAL=doctor; stop failed:local "本机 doctor 的 install 行不是 PASS" ;;
  esac
fi

if [ "$dry" -eq 1 ]; then
  step '⑥ 回退' "出错时：fleet release --rollback（stable → $(short "${old:-none}")）；本机体检拒了就自动回退"
  exit 0
fi
step '⑥ 回退' "不需要 — 发布完成（$(el "$T0")s）；要退：fleet release --rollback"
if [ "$already" -eq 1 ]; then log_line verified; else log_line released; fi
exit 0
