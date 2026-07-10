#!/bin/bash
# tmux-issue-preview.sh <issue-number> — render a GitHub issue's detail (state,
# title, labels, milestone, assignees, body, recent comments) for the backlog
# panel's fzf --preview, so you can READ an issue without leaving tmux or
# spawning a session. Fetched via `gh issue view` and cached per-issue with a
# short TTL, so moving the selection doesn't hammer the API. READ-ONLY.
#
# The prose (body + comments) is WORD-WRAPPED to the live preview width
# ($FZF_PREVIEW_COLUMNS, which fzf exports per render) so no line overflows the
# pane — fzf then never has to hard-wrap mid-word and never draws its wrap
# marker. We cache the raw gh JSON (not the coloured text) so the wrap re-flows
# to the current pane width every render (e.g. after a resize / toggle).
num="${1//[^0-9]/}"
export LANG="${LANG:-en_US.UTF-8}" LC_ALL="${LC_ALL:-en_US.UTF-8}"
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
GY='86;95;137'
c(){ printf '\033[38;2;%sm' "$1"; }; R=$'\033[0m'

# header rows (milestone group lines) and the loading/empty placeholders carry
# no issue number — nothing to preview.
[ -z "$num" ] && { printf '%s  ↑↓ move to an issue to preview it%s\n' "$(c "$GY")" "$R"; exit 0; }

# same session→repo resolution as the rows producer (FLEET_SESSION is exported
# by tmux-issues.sh so this inherits it under the fzf preview subprocess).
REPO="${FLEET_REPO:-}"
_r=$(fleet_repo_cached "${FLEET_SESSION:-}"); [ -n "$_r" ] && REPO="$_r"
[ -z "$REPO" ] && { printf '%s  (no repo resolved for this fleet)%s\n' "$(c "$GY")" "$R"; exit 0; }
command -v gh >/dev/null 2>&1 || { printf '%s  gh not found — cannot preview%s\n' "$(c "$GY")" "$R"; exit 0; }

slug=$(fleet_slug "$REPO"); cache="$C/issue_${slug}_${num}.json"; ts="$cache.ts"
TTL="${FLEET_ISSUE_TTL:-180}"
now=$(date +%s); last=$(cat "$ts" 2>/dev/null || echo 0)
if [ ! -s "$cache" ] || [ $(( now - last )) -ge "$TTL" ]; then
  # Cache the RAW JSON (gh's built-in engine — no standalone jq dependency); the
  # colouring + width-aware wrap happen at render time below so they track the
  # live pane width instead of a baked-in guess.
  raw=$(gh issue view "$num" --repo "$REPO" \
    --json number,title,state,body,labels,milestone,assignees,comments,url 2>/dev/null)
  if [ -n "$raw" ]; then
    printf '%s' "$raw" > "$cache.$$" && mv "$cache.$$" "$cache" && echo "$now" > "$ts"
    rm -f "$cache.$$"
  fi
fi
[ -s "$cache" ] || { printf '%s  (loading #%s…)%s\n' "$(c "$GY")" "$num" "$R"; exit 0; }

# Render + width-aware word-wrap in python3 (a hard fleet dep — fleet-doctor
# checks it). If it's somehow missing, fall back to gh's own plain-text view so
# the preview degrades to readable-but-unstyled rather than blank.
if command -v python3 >/dev/null 2>&1; then
  FZF_PREVIEW_COLUMNS="${FZF_PREVIEW_COLUMNS:-60}" python3 "$BIN/.tmux-issue-preview-render.py" < "$cache"
else
  gh issue view "$num" --repo "$REPO" 2>/dev/null | head -60
fi
