#!/bin/bash
# fleet-statusline.sh — the operator's switch for Claude Code's statusLine (issue #1459).
#
# Since #1452 conf/statusline.sh PRINTS nothing — the numbers live on the pane's
# top border — yet Claude Code keeps one blank row at the bottom of every pane for
# as long as settings.json has a `statusLine` at all (there is no hidden option).
# The row goes away only by removing the key. That used to blind the fleet: the
# status line's stdin JSON was the one place a session's context %, model,
# effort and rate limits were learned (@ctx_pct @ctx_limit @ctx_band @model
# @effort @rl*). Since #1459 the fleet mod (mod/fleet/hooks/usage.ts, v0.2.0+)
# feeds the same script from INSIDE the session — `statusline.sh --from mod`, the
# same fields, the same rounding, the same @ctx_band lines — so a login whose
# every Claude window carries that mod can drop the key and lose nothing.
#
# This script is the switch, and its only job is to never leave a blind spot:
#
#   status [--porcelain]   what settings.json wires (fleet | other | none), and a
#                          census of every Claude window on this login's live
#                          fleets: fed (a fresh @mod_alive and @mod_ver ≥ 0.2.0)
#                          or not, and why (no mod · stale beat · old mod).
#   off [--force] [--dry-run]
#                          remove `statusLine` — ONLY when it points at the fleet's
#                          conf/statusline.sh (a personal status line is never
#                          touched), and ONLY when every live Claude window is fed
#                          by the mod (exit 1 and the list otherwise; a window
#                          launched before the mod goes blind the moment the key
#                          goes, since nothing restarts it — cycle it first:
#                          /fleet-handoff, or close + fleet-restore). --force
#                          takes the blind spot knowingly. FLEET_MOD=0 refuses
#                          outright: that login has no second reporter.
#   on [--dry-run]         put the key back, pointing at THIS install's
#                          conf/statusline.sh; a personal one is never clobbered.
#
# settings.json is edited the way fleet-hooks-merge.py edits it: a backup to
# <settings>.bak.<epoch> first, the file rewritten (indent 2) only when it
# changes, nothing else in it touched. /fleet-sync-install never runs this —
# turning the row off is the operator's call, taken once the census is clean.
#
# Exit: 0 done / already so · 1 refused (gate, personal status line, FLEET_MOD=0)
#       · 2 usage / unreadable settings.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
OURS="$ROOT/conf/statusline.sh"
# shellcheck source=/dev/null
[ -f "$ROOT/fleet.conf" ] && . "$ROOT/fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
MIN_MOD_VER=0.2.0      # the first mod that feeds @ctx_band / @model / @effort

usage() {
  printf 'usage: fleet-statusline.sh status [--porcelain] | off [--force] [--dry-run] | on [--dry-run]\n' >&2
  exit 2
}

MODE="${1:-}"; [ -n "$MODE" ] && shift
PORCELAIN=0 FORCE=0 DRY=0
for a in "$@"; do
  case "$a" in
    --porcelain) PORCELAIN=1 ;;
    --force)     FORCE=1 ;;
    --dry-run)   DRY=1 ;;
    *) usage ;;
  esac
done
case "$MODE" in status|off|on) ;; *) usage ;; esac

# --- what settings.json wires -------------------------------------------------
# kind<TAB>command: fleet (the command ends in conf/statusline.sh — the live
# install's, a checkout's), other (a personal status line), none (no key). An
# unreadable file is exit 2 — never guess, never write.
wired() {
  [ -f "$SETTINGS" ] || { printf 'none\t\n'; return 0; }
  python3 - "$SETTINGS" <<'PY' || return 2
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        s = json.load(f)
except Exception as e:
    print("unreadable: %s" % e, file=sys.stderr); sys.exit(2)
sl = s.get("statusLine") if isinstance(s, dict) else None
if not sl:
    print("none\t"); sys.exit(0)
cmd = sl.get("command", "") if isinstance(sl, dict) else ""
kind = "fleet" if str(cmd).rstrip().endswith("conf/statusline.sh") else "other"
print("%s\t%s" % (kind, cmd))
PY
}

# --- the census: every Claude window on this login's live fleets --------------
# One list-windows per fleet socket. A Claude window is what fleet-doctor's `mod`
# row counts: not a panel, not codex, stamped by the launcher (@cc_model) or the
# state hooks (@claude_state). Fed = a beat within FLEET_MOD_ALIVE_SECS (45; the
# fleet_mod_alive rule) AND a mod that knows the fields (@mod_ver ≥ 0.2.0).
ver_ge() {   # ver_ge <a> <b> → 0 iff a ≥ b (dotted integers)
  local a="${1:-0}" b="${2:-0}" a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<EOF
$a
EOF
  IFS=. read -r b1 b2 b3 <<EOF
$b
EOF
  for v in a1 a2 a3 b1 b2 b3; do
    eval "case \"\${$v:-}\" in ''|*[!0-9]*) $v=0 ;; esac"
  done
  [ "$a1" -gt "$b1" ] && return 0; [ "$a1" -lt "$b1" ] && return 1
  [ "$a2" -gt "$b2" ] && return 0; [ "$a2" -lt "$b2" ] && return 1
  [ "$a3" -ge "$b3" ]
}

TAB=$(printf '\t')
US=$(printf '\037')   # the row separator: NOT whitespace, so `read` keeps EMPTY fields (a tab collapses them)
N_WIN=0 N_FED=0 N_BLIND=0 N_STAMPED=0
BLIND=()      # "<sess>\t<name>\t<why>"
census() {
  local now max sess wid name agent mark alive ver _pct src why
  now=$(date +%s); max="${FLEET_MOD_ALIVE_SECS:-45}"
  case "$max" in ''|*[!0-9]*) max=45 ;; esac
  while IFS= read -r sess; do
    [ -n "$sess" ] || continue
    # shellcheck disable=SC2034  # _pct: the column is read for alignment, not used (yet)
    while IFS="$US" read -r wid name agent mark alive ver _pct src; do
      [ -n "$wid" ] || continue
      case "$name" in dash|plan|backlog|home) continue ;; esac
      [ "$agent" = codex ] && continue
      [ -n "$mark" ] || continue
      N_WIN=$((N_WIN+1))
      [ "$src" = mod ] && N_STAMPED=$((N_STAMPED+1))
      why=''
      case "$alive" in
        '') why='no mod (launched before it, or FLEET_MOD=0)' ;;
        *[!0-9]*) why='no mod (garbled beat)' ;;
        *) [ $((now - alive)) -le "$max" ] || why="stale beat ($((now - alive))s)" ;;
      esac
      if [ -z "$why" ] && ! ver_ge "$ver" "$MIN_MOD_VER"; then why="old mod v${ver:-?} (< v$MIN_MOD_VER: no @model/@ctx_band feed)"; fi
      if [ -z "$why" ]; then N_FED=$((N_FED+1))
      else N_BLIND=$((N_BLIND+1)); BLIND+=("$sess$TAB$name$TAB$why"); fi
    done <<EOF
$(fleet_lw "#{window_id}${US}#{window_name}${US}#{@cc_agent}${US}#{@cc_model}#{@claude_state}${US}#{@mod_alive}${US}#{@mod_ver}${US}#{@ctx_pct}${US}#{@ctx_src}" tmux -L "$sess")
EOF
  done <<EOF
$(fleet_sockets)
EOF
}

W=$(wired) || { printf 'fleet-statusline: cannot read %s\n' "$SETTINGS" >&2; exit 2; }
KIND=${W%%"$TAB"*}; CMD=${W#*"$TAB"}
census

mod_on=1; fleet_mod_on || mod_on=0

# --- status -------------------------------------------------------------------
if [ "$MODE" = status ]; then
  if [ "$PORCELAIN" = 1 ]; then
    printf 'wired=%s\twindows=%s\tfed=%s\tblind=%s\tstamped=%s\tmod=%s\n' "$KIND" "$N_WIN" "$N_FED" "$N_BLIND" "$N_STAMPED" "$([ "$mod_on" = 1 ] && echo on || echo off)"
    for b in ${BLIND[@]+"${BLIND[@]}"}; do printf 'blind\t%s\n' "$b"; done
    exit 0
  fi
  case "$KIND" in
    fleet) printf 'statusLine: fleet — %s (keeps one blank row at the bottom of every pane)\n' "$CMD" ;;
    other) printf 'statusLine: personal — %s (never touched by this script)\n' "$CMD" ;;
    none)  printf 'statusLine: none — the bottom row is free; the mod is the measurement bus\n' ;;
  esac
  printf 'windows: %s claude · %s fed by the mod (v%s+, beat fresh) · %s stamped @ctx_src=mod · %s not fed\n' "$N_WIN" "$N_FED" "$MIN_MOD_VER" "$N_STAMPED" "$N_BLIND"
  for b in ${BLIND[@]+"${BLIND[@]}"}; do
    IFS="$TAB" read -r s n w <<EOF
$b
EOF
    printf '  ! %s:%s — %s\n' "$s" "$n" "$w"
  done
  if [ "$mod_on" = 0 ]; then
    printf 'verdict: FLEET_MOD=0 — no second reporter on this login; keep the statusLine\n'
  elif [ "$KIND" = fleet ] && [ "$N_BLIND" = 0 ]; then
    printf 'verdict: ready — `fleet-statusline.sh off` removes the key; new sessions get the row back, nothing goes blind\n'
  elif [ "$KIND" = fleet ]; then
    printf 'verdict: not yet — %s window(s) would lose their context/model readings; cycle them (/fleet-handoff, or close + fleet-restore) and re-run, or `off --force`\n' "$N_BLIND"
  elif [ "$KIND" = none ] && [ "$N_BLIND" -gt 0 ]; then
    printf 'verdict: %s window(s) have no reporter at all (statusLine off, no mod) — cycle them, or `fleet-statusline.sh on`\n' "$N_BLIND"
  fi
  exit 0
fi

# --- off / on: edit settings.json ---------------------------------------------
edit() {   # edit <remove|add> → prints what python did
  python3 - "$SETTINGS" "$1" "$OURS" "$DRY" <<'PY'
import json, os, shutil, sys, time
path, op, ours, dry = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
s = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        s = json.load(f)
new = json.loads(json.dumps(s))
if op == "remove":
    new.pop("statusLine", None)
else:
    new["statusLine"] = {"type": "command", "command": ours}
if new == s:
    print("unchanged"); sys.exit(0)
if dry:
    print("would %s statusLine in %s" % ("remove" if op == "remove" else "add", path)); sys.exit(0)
if os.path.exists(path):
    stamp, n = int(time.time()), 0
    bak = "%s.bak.%d" % (path, stamp)
    while os.path.exists(bak):           # a second write in the same second keeps the first backup
        n += 1
        bak = "%s.bak.%d.%d" % (path, stamp, n)
    shutil.copy2(path, bak)
    print("backup  %s" % bak)
tmp = path + ".tmp.%d" % os.getpid()
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(new, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, path)
print("%s statusLine in %s" % ("removed" if op == "remove" else "added", path))
PY
}

if [ "$MODE" = off ]; then
  case "$KIND" in
    none)  printf 'fleet-statusline: already off — settings.json has no statusLine\n'; exit 0 ;;
    other) printf 'fleet-statusline: REFUSED — settings.json wires a personal status line (%s); remove it yourself if you mean to\n' "$CMD" >&2; exit 1 ;;
  esac
  if [ "$mod_on" = 0 ] && [ "$FORCE" = 0 ]; then
    printf 'fleet-statusline: REFUSED — FLEET_MOD=0 on this login: the status line is the only measurement bus (--force to drop it anyway)\n' >&2; exit 1
  fi
  if [ "$N_BLIND" -gt 0 ] && [ "$FORCE" = 0 ]; then
    printf 'fleet-statusline: REFUSED — %s of %s Claude window(s) are not fed by the mod and would go blind (no context %%, no model, no auto-handoff):\n' "$N_BLIND" "$N_WIN" >&2
    for b in ${BLIND[@]+"${BLIND[@]}"}; do
      IFS="$TAB" read -r s n w <<EOF
$b
EOF
      printf '  ! %s:%s — %s\n' "$s" "$n" "$w" >&2
    done
    printf 'cycle them first (/fleet-handoff in the pane, or close + fleet-restore) and re-run; `off --force` takes the blind spot knowingly\n' >&2
    exit 1
  fi
  out=$(edit remove) || { printf 'fleet-statusline: edit failed\n' >&2; exit 2; }
  printf '%s\n' "$out"
  [ "$DRY" = 1 ] || printf 'statusLine off: %s/%s windows fed by the mod%s. New sessions have their bottom row back; running ones keep theirs until restarted.\n' \
    "$N_FED" "$N_WIN" "$([ "$N_BLIND" -gt 0 ] && printf ' (%s blind, --force)' "$N_BLIND")"
  exit 0
fi

# on
case "$KIND" in
  fleet) printf 'fleet-statusline: already on — %s\n' "$CMD"; exit 0 ;;
  other) printf 'fleet-statusline: REFUSED — settings.json wires a personal status line (%s); not clobbering it\n' "$CMD" >&2; exit 1 ;;
esac
[ -f "$OURS" ] || { printf 'fleet-statusline: %s is missing — nothing to wire\n' "$OURS" >&2; exit 2; }
out=$(edit add) || { printf 'fleet-statusline: edit failed\n' >&2; exit 2; }
printf '%s\n' "$out"
[ "$DRY" = 1 ] || printf 'statusLine on: %s — takes effect in new sessions (one blank row at the bottom of each pane comes back)\n' "$OURS"
exit 0
