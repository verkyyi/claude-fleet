#!/bin/bash
# precompact-hook.sh — save a recovery map right BEFORE Claude Code's own
# compaction (issue #1321, EPIC #1315 R1). Wired to the Claude Code `PreCompact`
# hook with matcher `auto`.
#
# THE GAP. The fleet's ladder (#1269/#1318) compacts a session in place on its own
# terms: a Stop hook asks the session to write a recovery map first, then types
# `/compact`. With the lines set right, Claude Code's built-in auto-compaction
# should never get there first — but a window that never walked the fleet's path
# (a Stop that never came clean, a knob turned off, a turn that ran away) meets
# it anyway, unprepared: the summary is all that survives, and nothing records
# where the work stood.
#
# WHAT IT DOES. PreCompact fires on the same pane just before the summary is
# made. This hook writes the map ITSELF — facts only, no model turn: the window's
# @issue/@raw/@repo, cwd + branch + base + HEAD, `git status --short`, `git log -3`,
# the PR the dash's prmap knows for that branch, the issue's latest comment link,
# and the operator's last prompts from the transcript — to the same file the
# fleet's own prep step uses (fleet_recovery_map_path: the worktree's git dir,
# else the fleet's conf dir). It stamps @compact_native=<epoch> so the
# SessionStart(compact) refocus (bin/refocus-hook.sh) reads the map back, and
# writes ONE `native-precompact` row to logs/context-ladder.log, reason
# `<trigger> saved` — the ledger's 「已提前存档」.
#
# WHAT IT LEAVES ALONE.
#   - The fleet's own compaction: a `manual` trigger while @compact_stage is
#     `compacting` is the /compact bin/fleet-compact-send.sh just typed — its map
#     was written by the session at the prep step, and its ledger rows are
#     `prep`/`compacting`/`restored` already. Zero output, zero rows.
#   - A richer map: when the fleet's prep step already asked the session for a map
#     (@compact_stage `prep`/`compacting`) and that file is newer than the prep
#     stamp, a native compaction landing in between keeps it — reason `kept`.
#   - Hub, panels, a headless `claude -p` child, a pane outside tmux, a codex pane:
#     no recovery map path consumer, so no map. The hub still gets its ledger row
#     (reason `<trigger> no-map`) — a native compaction anywhere is worth knowing.
#
# The latest-comment link is the hook's ONE network read: bin/fleet-gh.sh (cache
# first, REST under a GraphQL limit) bounded by a kernel alarm,
# FLEET_PRECOMPACT_GH_SECS (default 8; 0 = offline, the issue URL only).
#
# Kill switch: FLEET_PRECOMPACT=0 in fleet.conf / the fleet overlay. Test seam:
# FLEET_PRECOMPACT_TRIGGER overrides the stdin trigger. Always exits 0 and prints
# nothing (PreCompact must never cost the session its compaction).
set -u
[ -n "${TMUX:-}" ] || exit 0
[ -n "${TMUX_PANE:-}" ] || exit 0
case "${CLAUDE_CODE_ENTRYPOINT:-cli}" in cli) : ;; *) exit 0 ;; esac

payload=''
[ -t 0 ] || payload=$(cat 2>/dev/null)
field() { printf '%s' "$payload" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1; }
trigger="${FLEET_PRECOMPACT_TRIGGER:-$(field trigger)}"
transcript=$(field transcript_path)
case "$trigger" in auto|manual) : ;; *) exit 0 ;; esac

BIN="$(cd "$(dirname "$0")" && pwd)"
LADDER="$BIN/fleet-ladder-log.sh"
ladder() { [ -f "$LADDER" ] && sh "$LADDER" native-precompact --reason "$trigger $1" </dev/null >/dev/null 2>&1; }

# One tmux read. window_name LAST: the one field that may itself hold a `|`.
st=$(tmux display-message -p -t "$TMUX_PANE" \
  '#{@compact_stage}|#{@compact_prep_ts}|#{@issue}|#{@raw}|#{@cc_agent}|#{window_name}' 2>/dev/null)
stage=${st%%|*}; st=${st#*|}
prep_ts=${st%%|*}; st=${st#*|}
issue=${st%%|*}; st=${st#*|}
raw=${st%%|*}; st=${st#*|}
agent=${st%%|*}; wname=${st#*|}
issue=$(printf '%s' "$issue" | tr -cd '0-9')
case "$prep_ts" in ''|*[!0-9]*) prep_ts=0 ;; esac

# The fleet's own /compact (fleet-compact-send.sh stamped `compacting` first).
[ "$trigger" = manual ] && [ "$stage" = compacting ] && exit 0
[ "$agent" = codex ] && exit 0
case "$wname" in dash|plan|backlog) exit 0 ;; esac

# shellcheck source=/dev/null
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh" 2>/dev/null || exit 0
sess=$(fleet_current_session)
[ -n "$sess" ] && fleet_load_conf "$sess" 2>/dev/null
[ "${FLEET_PRECOMPACT:-1}" = 0 ] && exit 0

# Only a worker (@issue) or a scratch (@raw=1) has a map the refocus reads back.
if [ -z "$issue" ] && [ "$raw" != 1 ]; then
  ladder no-map
  exit 0
fi

cwd=$(pwd -P 2>/dev/null)
map=$(fleet_recovery_map_path "$TMUX_PANE" "$cwd")
if [ -z "$map" ]; then
  ladder no-map
  exit 0
fi

now=$(date +%s 2>/dev/null || echo 0)
if [ -f "$map" ] && [ "$prep_ts" -gt 0 ]; then
  case "$stage" in prep|compacting)
    mt=$(stat -f %m "$map" 2>/dev/null || stat -c %Y "$map" 2>/dev/null || echo 0)
    if [ "${mt:-0}" -ge "$prep_ts" ]; then
      tmux set-window-option -t "$TMUX_PANE" @compact_native "$now" 2>/dev/null
      ladder kept
      exit 0
    fi ;;
  esac
fi

repo=''
[ -n "$sess" ] && repo=$(fleet_window_repo "$sess" "$TMUX_PANE" 2>/dev/null)
base="${FLEET_BASE_BRANCH:-master}"
if [ -n "$repo" ]; then
  fleet_load_repo_conf "$sess" "$repo" 2>/dev/null
  base="${FLEET_BASE_BRANCH:-$base}"
fi
branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
head=$(git -C "$cwd" log -1 --format='%h %s' 2>/dev/null)
gstatus=$(git -C "$cwd" status --short 2>/dev/null | head -n 20)
glog=$(git -C "$cwd" log -3 --format='%h %s' 2>/dev/null)

pr=''
comment=''
if [ -n "$repo" ]; then
  slug=$(fleet_slug "$repo")
  prmap="$FLEET_C/fleets/$slug/prmap"
  if [ -n "$branch" ] && [ -f "$prmap" ]; then
    pr=$(LC_ALL=C awk -F'\t' -v b="$branch" '$1 == b { s = $2 " " $3; if ($4 != "" && $4 != "·") s = s " ci" $4; print s; exit }' "$prmap" 2>/dev/null)
  fi
  gsecs="${FLEET_PRECOMPACT_GH_SECS:-8}"
  case "$gsecs" in ''|*[!0-9]*) gsecs=8 ;; esac
  if [ -n "$issue" ] && [ "$gsecs" -gt 0 ] && [ -f "$BIN/fleet-gh.sh" ]; then
    comment=$(perl -e 'alarm shift; exec @ARGV or exit 127' "$gsecs" \
        bash "$BIN/fleet-gh.sh" issue view "$issue" --repo "$repo" --json comments --max-age 600 \
        </dev/null 2>/dev/null \
      | python3 -c 'import json,sys
try: c = json.load(sys.stdin).get("comments") or []
except Exception: c = []
print(c[-1].get("url", "") if c else "")' 2>/dev/null)
  fi
fi

mkdir -p "$(dirname "$map")" 2>/dev/null
PC_MAP="$map" PC_TRIGGER="$trigger" PC_NOW="$now" PC_WIN="$wname" PC_ISSUE="$issue" \
PC_RAW="$raw" PC_REPO="$repo" PC_CWD="$cwd" PC_BRANCH="$branch" PC_BASE="$base" \
PC_HEAD="$head" PC_STATUS="$gstatus" PC_LOG="$glog" PC_PR="$pr" PC_COMMENT="$comment" \
PC_TRANSCRIPT="$transcript" python3 - <<'PY' 2>/dev/null || { ladder failed; exit 0; }
import json, os, time
e = lambda k: os.environ.get(k, "")

def last_prompts(path, keep=3, width=300):
    """The operator's last few typed prompts — the task, in their words."""
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if r.get("type") != "user" or r.get("isMeta") or r.get("isSidechain"):
                    continue
                c = (r.get("message") or {}).get("content")
                if isinstance(c, list):
                    c = " ".join(p.get("text", "") for p in c
                                 if isinstance(p, dict) and p.get("type") == "text")
                if not isinstance(c, str):
                    continue
                c = " ".join(c.split())
                # Skip tool plumbing and the harness's own wrapped messages.
                if not c or c.startswith("<") or c.startswith("[Request interrupted"):
                    continue
                out.append(c if len(c) <= width else c[:width - 1] + "…")
    except OSError:
        return []
    return out[-keep:]

n, repo = e("PC_ISSUE"), e("PC_REPO")
when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(int(e("PC_NOW") or 0)))
what = ("issue #%s · %s" % (n, repo or "repo unknown")) if n else "scratch session (no issue)"
lines = [
    "# fleet recovery map — auto-saved before Claude Code's own compaction (%s, %s)" % (e("PC_TRIGGER"), when),
    "Written by bin/precompact-hook.sh, not by the session: facts only. Check it against git and the PR.",
    "",
    "- %s · window %s · @raw=%s" % (what, e("PC_WIN") or "-", e("PC_RAW") or "-"),
]
if n and repo:
    lines.append("- issue: https://github.com/%s/issues/%s" % (repo, n))
    lines.append("- latest issue comment: %s" % (e("PC_COMMENT") or
                 "unknown — ~/.claude/fleet/bin/fleet-gh.sh issue view %s --json comments" % n))
lines += [
    "- cwd: %s" % (e("PC_CWD") or "-"),
    "- branch: %s → base %s · HEAD %s" % (e("PC_BRANCH") or "-", e("PC_BASE") or "-", e("PC_HEAD") or "-"),
    "- PR: %s" % (e("PC_PR") or "none known (dash prmap)"),
]
st = e("PC_STATUS").strip("\n")
lines += ["", "## git status --short", st if st else "(clean)"]
lg = e("PC_LOG").strip("\n")
if lg:
    lines += ["", "## git log -3", lg]
p = last_prompts(e("PC_TRANSCRIPT")) if e("PC_TRANSCRIPT") else []
if p:
    lines += ["", "## the operator's last prompts (oldest first)"] + ["- " + x for x in p]
tmp = e("PC_MAP") + ".tmp.%d" % os.getpid()
with open(tmp, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
os.replace(tmp, e("PC_MAP"))
PY
tmux set-window-option -t "$TMUX_PANE" @compact_native "$now" 2>/dev/null
ladder saved
exit 0
