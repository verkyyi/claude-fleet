#!/bin/sh
# fleet-install-version.sh [--json] [--no-fetch] [--no-logins] [--dir <path>] [--timeout <s>] [-q]
#   — how far is THIS machine's live install behind the trunk? (issue #635)
#
# `/fleet-sync-install` is per-machine AND manual, so the second machine goes
# stale silently. Measured 2026-09-14: macmini's live install sat 28 commits
# behind master — missing #603's base-branch fix, #617's quota ranking, #608's
# capability matrix — while `fleet-doctor.sh` was green on BOTH machines. Nothing
# anywhere said one of them was old. One person with two machines already hit it;
# at N people × M machines "merged but that box never pulled" becomes the default
# state, not the exception.
#
# PR #634 (issue #611) closed HALF of this: commands / skills / the hook table
# ship as a Claude Code plugin, so `/plugin update` carries them. The other half —
# `bin/`, `conf/` and the daemons — must live at the stable `~/.claude/fleet` (a
# plugin's install path carries a version and changes on every update; launchd
# units and tmux binds cannot point into it), so it stays a hand-run `git pull`.
# This script is the missing signal for that half.
#
# It only ever REPORTS. Auto-pulling `bin/` under a machine running 19 workers is
# far more risk than the staleness it would fix, so the fix command is printed,
# never run (and see docs/INSTALL.md — a real sync also reloads the changed
# launchd units, which no `git pull` does).
#
# Verdicts (the `verdict:` line, one token — exit code in brackets):
#   CURRENT   [0]  live install == trunk
#   BEHIND    [1]  trunk has commits this machine does not — run the fix
#   AHEAD     [1]  local commits not on trunk (someone edited/tested in place)
#   DIVERGED  [1]  both — `pull --ff-only` will refuse
#   UNKNOWN   [2]  could not tell (offline, detached HEAD, no upstream, not a
#                  checkout). NEVER reported as 0/CURRENT — a fetch that failed
#                  is not evidence of being up to date; same fail-open honesty
#                  the claim lease takes (#631). `behind` is JSON null, not 0.
#
# Network: one `git fetch` of ONE branch (~0.8s warm), bounded by --timeout via
# git's own http low-speed abort so a black-holed network cannot hang a caller.
# That cost is why this is for MANUAL / occasional callers — `fleet-doctor.sh`,
# an operator, a cross-machine reporter. Do NOT put the fetching form on the 60s
# collector tick; `--no-fetch` is the free form (it reads the remote-tracking ref
# as it stands, and says `fetched: no` so a stale answer can't pass as fresh).
#
# `dirty` counts TRACKED modifications only: a live install normally carries
# untracked litter (`fleet.conf.bak*`), which neither blocks a fast-forward nor
# means anything drifted.
#
# --json is the cross-machine half's producer (issue #635 part 2; TokenLedger's
# agent is the consumer, issue #644): it emits hostname + head sha + behind count
# as one object, so whatever ships the fact to the hub (or anything else) reads
# ONE source of truth rather than re-deriving it. Nothing is uploaded from here —
# this script makes no network call beyond its own `git fetch`.
#   The CONTRACT a consumer may hard-code — pinned by install-version-selftest.sh
#   leg H, so a renamed key or a re-quoted number goes red HERE, not blank on a
#   roster nobody is looking at:
#     host head branch upstream   strings ("" when unknown)
#     behind ahead                integers, or null when unknown — NEVER 0
#     dirty fetched               booleans
#     verdict                     CURRENT | BEHIND | AHEAD | DIVERGED | UNKNOWN
#     follow_verdict              OK | STUCK | OFF | UNSEEN | UNKNOWN, or null
#     error                       why behind is null — prose, for a tooltip
#   `logins` and `follow` are sentences for a human: parse neither. A collector
#   calls `--json --no-fetch --no-logins` (~0.2s, no network, no sudo); the
#   fetching form (~1s, one branch, --timeout) belongs on a minute-scale tick
#   at most. Render null as "unknown" — treating it as 0 re-creates #635.
#
# Other logins (issue #1069): on a shared machine the unit that goes stale is
# not the machine but the LOGIN — each has its own ~/.claude/fleet and daemons,
# and on 2026-09-23 four of the Mac mini's five sat 5–13 days behind the fifth
# with every daemon green. So when other logins' installs exist, a `logins:` line
# reports their drift against THIS install, read from
# `fleet-sync-logins.sh --summary` (one source of truth; it is also the fix).
# It never changes the verdict or the exit code — those stay about this install.
# `--no-logins` skips it; a machine with one login prints nothing.
#
# Following stable (issue #1123, EPIC #1117 C7): since #1120 each login's
# install-sync daemon moves it to `refs/tags/stable` by itself, so being behind
# TRUNK is expected (the mark trails master by design) and the question that
# matters is whether the daemon is still moving it. `follow:` is this login's
# answer (bin/fleet-install-follow.sh --self: on/off, the last tick's result and
# age, OK / STUCK / OFF / UNSEEN / UNKNOWN), and the `logins:` line carries one
# `login on/result age` token per other login (`⚠` = stuck), read as its owner.
# `--no-logins` skips the others; `--json` carries both (`follow`, `follow_verdict`).
#
# Read-only: it fetches (a remote-tracking ref update) and reads. It never
# checks out, merges, or writes the working tree.
set -u

LIVE_DEFAULT="${FLEET_LIVE_DIR:-$HOME/.claude/fleet}"
dir="$LIVE_DEFAULT"
as_json=0 quiet=0 do_fetch=1 timeout=15 do_logins=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json)      as_json=1 ;;
    --no-fetch)  do_fetch=0 ;;
    --no-logins) do_logins=0 ;;
    --dir)       shift; dir="${1:-}" ;;
    --timeout)   shift; timeout="${1:-15}" ;;
    -q|--quiet)  quiet=1 ;;
    -h|--help)   sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)         printf 'fleet-install-version: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)           printf 'fleet-install-version: unexpected argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
case "$timeout" in ''|*[!0-9]*) timeout=15 ;; esac
[ "$timeout" -gt 0 ] || timeout=15

host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo host)
branch='' upstream='' head='' behind='' ahead='' dirty='' err='' fetched=no cmp=''
verdict=UNKNOWN rc=2

# --- resolve the checkout ----------------------------------------------------
# A pre-#520 install was a file COPY, not a checkout; so is a hand-made one. That
# is not a failure to shout about — it is a different install shape that this
# check simply cannot measure, so it says so and exits UNKNOWN.
if [ ! -d "$dir" ]; then
  err="no live install at $dir"
elif ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  err="$dir is not a git checkout — this check needs one to compare (a file-copy install cannot be measured; re-home it per docs/INSTALL.md)"
else
  head=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
  branch=$(git -C "$dir" symbolic-ref --quiet --short HEAD 2>/dev/null)
  [ -n "$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)" ] && dirty=yes || dirty=no

  if [ -z "$branch" ]; then
    err="detached HEAD at ${head:-?} — nothing to compare against; check out the trunk branch"
  else
    # Which ref IS the trunk here, best first:
    #   1. the branch's own upstream — what `git pull` would use, so the counts
    #      match what the fix command will actually do
    #   2. origin/HEAD — a checkout whose branch was never tracked
    #   3. origin/<branch> — no origin/HEAD either (never `remote set-head`)
    upstream=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)
    [ -n "$upstream" ] || upstream=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
    [ -n "$upstream" ] || upstream="origin/$branch"
    remote=${upstream%%/*}
    rbranch=${upstream#*/}

    if [ "$do_fetch" -eq 1 ]; then
      # Fetch ONE branch, not the whole remote: this repo carries dozens of stale
      # PR branches and we need exactly one ref. lowSpeed{Limit,Time} is git's own
      # stall abort — POSIX has no portable `timeout(1)` (macOS ships none), and a
      # black-holed network otherwise hangs the doctor run that called us.
      if git -C "$dir" -c "http.lowSpeedLimit=1000" -c "http.lowSpeedTime=$timeout" \
             fetch --quiet "$remote" "$rbranch" >/dev/null 2>&1; then
        fetched=yes
        cmp=FETCH_HEAD   # always written by fetch, whatever the refspec config
      else
        err="fetch of $upstream failed (offline / no credentials / no such branch) — behind count unknown, NOT assumed 0"
      fi
    else
      # No-fetch: the remote-tracking ref as it stands. Free, and possibly stale —
      # `fetched: no` is what keeps that from reading as a fresh verdict.
      cmp="$upstream"
      git -C "$dir" rev-parse --verify --quiet "$cmp" >/dev/null 2>&1 \
        || err="no local ref for $upstream — nothing fetched yet on this machine; drop --no-fetch"
    fi

    if [ -z "$err" ]; then
      counts=$(git -C "$dir" rev-list --left-right --count "HEAD...$cmp" 2>/dev/null)
      ahead=$(printf '%s' "$counts" | awk '{print $1+0}')
      behind=$(printf '%s' "$counts" | awk '{print $2+0}')
      if [ -z "$counts" ]; then
        ahead='' behind=''
        err="could not compare HEAD with $upstream (unrelated histories?)"
      elif [ "$behind" -gt 0 ] && [ "$ahead" -gt 0 ]; then
        verdict=DIVERGED; rc=1
      elif [ "$behind" -gt 0 ]; then
        verdict=BEHIND; rc=1
      elif [ "$ahead" -gt 0 ]; then
        verdict=AHEAD; rc=1
      else
        verdict=CURRENT; rc=0
      fi
    fi
  fi
fi

# --- the other logins on this machine (issue #1069) --------------------------
logins=''
sl="$(dirname "$0")/fleet-sync-logins.sh"
if [ "$do_logins" -eq 1 ] && [ -n "$head" ] && [ -f "$sl" ]; then
  logins=$(bash "$sl" --summary --source "$dir" 2>/dev/null)
  case "$logins" in
    ''|'0 other'*) logins='' ;;
    *' 0 drifted') ;;
    *) logins="$logins — sync them: bash $sl" ;;
  esac
fi

# --- following stable: this login, then the others (issue #1123) -------------
# One reader for the daemon's state file (bin/fleet-install-follow.sh); the
# verdict/exit code above stay about trunk drift — this is a second, separate
# fact, and `head` empty (not a checkout) means there is nothing to follow with.
follow='' follow_verdict=''
fl="$(dirname "$0")/fleet-install-follow.sh"
if [ -n "$head" ] && [ -f "$fl" ]; then
  flout=$(sh "$fl" --self --dir "$dir" 2>/dev/null)
  _flf() { printf '%s\n' "$flout" | sed -n "s/^$1:  *//p"; }
  follow_verdict=$(_flf verdict)
  case "$follow_verdict" in
    '') ;;
    OFF) follow="off — $(_flf why)" ;;
    *)   follow="$(_flf follow) · $(_flf result) · $(_flf why) · last tick $(_flf checked) [$follow_verdict]" ;;
  esac
  if [ "$do_logins" -eq 1 ]; then
    flo=$(sh "$fl" --others --summary --dir "$dir" 2>/dev/null)
    [ -n "$flo" ] && logins="${logins:+$logins · }follow: $flo"
  fi
fi

# --- the one-line fix, printed for every non-CURRENT verdict -----------------
# `pull --ff-only` is deliberate: a live install must never grow a merge commit,
# and on AHEAD/DIVERGED the refusal IS the signal. It is also only HALF a sync —
# changed daemons still need their launchd units reloaded — so the hint names
# /fleet-sync-install, which does both, rather than pretending git is enough.
fix="git -C $dir pull --ff-only   (then /fleet-sync-install — it also reloads the changed daemons)"

if [ "$as_json" -eq 1 ]; then
  jnum() { [ -n "$1" ] && printf '%s' "$1" || printf 'null'; }
  jstr() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  printf '{"dir":"%s","host":"%s","head":"%s","branch":"%s","upstream":"%s","behind":%s,"ahead":%s,"dirty":%s,"fetched":%s,"verdict":"%s","error":"%s","logins":%s,"follow":%s,"follow_verdict":%s}\n' \
    "$(jstr "$dir")" "$(jstr "$host")" "$(jstr "$head")" "$(jstr "$branch")" "$(jstr "$upstream")" \
    "$(jnum "$behind")" "$(jnum "$ahead")" \
    "$( [ "$dirty" = yes ] && echo true || echo false )" \
    "$( [ "$fetched" = yes ] && echo true || echo false )" \
    "$verdict" "$(jstr "$err")" \
    "$( [ -n "$logins" ] && printf '"%s"' "$(jstr "$logins")" || printf 'null')" \
    "$( [ -n "$follow" ] && printf '"%s"' "$(jstr "$follow")" || printf 'null')" \
    "$( [ -n "$follow_verdict" ] && printf '"%s"' "$follow_verdict" || printf 'null')"
elif [ "$quiet" -eq 0 ]; then
  printf 'install:  %s\n' "$dir"
  printf 'host:     %s\n' "$host"
  printf 'head:     %s%s\n' "${head:-?}" "$( [ -n "$branch" ] && printf ' (%s)' "$branch" )"
  [ -n "$upstream" ] && printf 'trunk:    %s (fetched: %s)\n' "$upstream" "$fetched"
  printf 'behind:   %s\n' "${behind:-unknown}"
  printf 'ahead:    %s\n' "${ahead:-unknown}"
  [ -n "$dirty" ] && printf 'dirty:    %s\n' "$dirty"
  [ -n "$err" ] && printf 'note:     %s\n' "$err"
  [ -n "$follow" ] && printf 'follow:   %s\n' "$follow"
  [ -n "$logins" ] && printf 'logins:   %s\n' "$logins"
  printf 'verdict:  %s\n' "$verdict"
  case "$verdict" in BEHIND|AHEAD|DIVERGED) printf 'fix:      %s\n' "$fix" ;; esac
fi

exit "$rc"
