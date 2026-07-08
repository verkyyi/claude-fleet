#!/bin/bash
# tmux-issue-preview.sh <issue-number> — render a GitHub issue's detail (state,
# title, labels, milestone, assignees, body, recent comments) for the backlog
# panel's fzf --preview, so you can READ an issue without leaving tmux or
# spawning a session. Fetched via `gh issue view` and cached per-issue with a
# short TTL, so moving the selection doesn't hammer the API. READ-ONLY.
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

slug=$(fleet_slug "$REPO"); cache="$C/issue_${slug}_${num}"; ts="$cache.ts"
TTL="${FLEET_ISSUE_TTL:-180}"
now=$(date +%s); last=$(cat "$ts" 2>/dev/null || echo 0)
if [ ! -s "$cache" ] || [ $(( now - last )) -ge "$TTL" ]; then
  # Render with gh's BUILT-IN jq engine (`--jq`) so we don't depend on a
  # standalone jq — the collector avoids it too (see fleet-doctor.sh). Colors
  # are jq constants (gh's --jq takes no `--arg`); the jq program embeds real ESC bytes.
  # shellcheck disable=SC2016  # $IN/$st/… are jq variables, not shell expansions
  out=$(gh issue view "$num" --repo "$REPO" \
    --json number,title,state,body,labels,milestone,assignees,comments,url \
    --jq '
      def c($x): "[38;2;\($x)m";
      def R: "[0m";
      def B: "[1m";
      "187;154;247" as $IN | "86;95;137" as $GY | "169;177;214" as $TX
      | "158;206;106" as $GN | "247;118;142" as $RD | "125;207;255" as $CY
      | "224;175;104" as $YE
      | (if .state=="OPEN" then c($GN)+"● OPEN" else c($RD)+"✖ CLOSED" end) as $st
      | ([.labels[].name] | if length>0 then c($CY)+join(", ")+R else c($GY)+"·"+R end) as $lb
      | ((.milestone.title) // "·") as $ms
      | ([.assignees[].login] | if length>0 then join(", ") else "·" end) as $asg
      | [ c($YE)+"#\(.number)"+R+"  "+$st+R,
          B+c($TX)+.title+R,
          "",
          c($GY)+"labels    "+R+$lb,
          c($GY)+"milestone "+R+c($TX)+$ms+R+"    "+c($GY)+"assignee "+R+c($TX)+$asg+R,
          c($GY)+("─"*58)+R,
          ((.body // "") | if .=="" then c($GY)+"(no description)"+R else . end),
          "",
          c($IN)+"── comments (\(.comments|length)) ──"+R ]
        + ( (.comments|.[-5:]) | map(
              "\n"+c($CY)+"@\(.author.login)"+R+" "+c($GY)+(.createdAt|.[0:10])+R
              +"\n"+(.body) ) )
        | join("\n")' 2>/dev/null)
  if [ -n "$out" ]; then
    printf '%s\n' "$out" > "$cache.$$" && mv "$cache.$$" "$cache" && echo "$now" > "$ts"
    rm -f "$cache.$$"
  fi
fi
if [ -s "$cache" ]; then cat "$cache"; else printf '%s  (loading #%s…)%s\n' "$(c "$GY")" "$num" "$R"; fi
