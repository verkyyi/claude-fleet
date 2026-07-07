#!/bin/bash
# tmux-dash-collect.sh — background collector for the dash. Owns ALL the slow /
# external status work and writes it to cache files; the dash producer only READS
# these, so the dashboard renders instantly. Run from launchd
# (com.claude-fleet.collect, StartInterval ~45s) or a systemd user timer.
# Writes under $C = $TMPDIR/.claude-dash:
#   prmap            — branch<TAB>#num<TAB>state<TAB>ci  (gh, ≥90s)
#   issues           — milestone<TAB>#num<TAB>assignee<TAB>title (gh, ≥90s)
#   git_<key>        — branch<TAB>dirty  per live worktree (every run)
#   ctx_<key>        — model<TAB>context-tokens per worktree (every run)
#   usage            — token-consumption proxy 5h/7d       (≥300s)
#   ratelimit        — last-seen official weekly-% line + epoch (scrape, every run)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
REPO="${FLEET_REPO:-}"
BASE="${FLEET_BASE_BRANCH:-main}"
now() { date +%s; }
tmux info >/dev/null 2>&1 || exit 0

# gh fetch TTL (issues + PR map). FLEET_GH_TTL in fleet.conf tunes staleness
# vs API chatter; GH_TTL=0 on a one-off run forces a fetch.
GH_TTL="${GH_TTL:-${FLEET_GH_TTL:-90}}"

# --- PR map ---
prts=$(cat "$C/prmap.ts" 2>/dev/null || echo 0)
if [ -n "$REPO" ] && [ $(( $(now) - prts )) -ge "$GH_TTL" ] && command -v gh >/dev/null 2>&1; then
  gh pr list --repo "$REPO" --state all --limit 100 \
    --json number,headRefName,state,statusCheckRollup \
    --jq 'group_by(.headRefName)[] | max_by(.number) |
          .headRefName + "\t#" + (.number|tostring) + "\t" + .state + "\t" + (
            (.statusCheckRollup // []) | if length==0 then "·"
            elif any(.conclusion=="FAILURE" or .conclusion=="CANCELLED") then "✗"
            elif any(.status!="COMPLETED") then "…" else "✓" end)' \
    > "$C/prmap.tmp" 2>/dev/null && mv "$C/prmap.tmp" "$C/prmap"
  now > "$C/prmap.ts"
fi

# --- GitHub open issues (backlog source of truth) → cache ---
its=$(cat "$C/issues.ts" 2>/dev/null || echo 0)
if [ -n "$REPO" ] && [ $(( $(now) - its )) -ge "$GH_TTL" ] && command -v gh >/dev/null 2>&1; then
  gh issue list --repo "$REPO" --state open --limit 300 \
    --json number,title,milestone,assignees \
    --jq '.[] | (.milestone.title // "· no milestone")+"\t#"+(.number|tostring)+"\t"+((((.assignees|map(.login)|join(","))[0:10]) | if .=="" then "·" else . end))+"\t"+(.title)' \
    > "$C/issues.tmp" 2>/dev/null && mv "$C/issues.tmp" "$C/issues"
  now > "$C/issues.ts"
fi

# --- git per live worktree (every run) ---
tmux list-windows -a -F '#{pane_current_path}' | sort -u | while read -r path; do
  [ -z "$path" ] && continue
  git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || continue
  key=$(printf '%s' "$path" | tr '/ ' '__')
  branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null); dirty=''
  [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ] && dirty='✱'
  ab=$(git -C "$path" rev-list --left-right --count "$BASE...HEAD" 2>/dev/null)
  behind=$(echo "$ab" | awk '{print $1+0}'); ahead=$(echo "$ab" | awk '{print $2+0}')
  [ "${ahead:-0}" != 0 ] && branch="$branch+$ahead"; [ "${behind:-0}" != 0 ] && branch="$branch-$behind"
  printf '%s\t%s' "$branch" "$dirty" > "$C/git_$key"
done

# --- per-window context tokens (every run): newest transcript's last-turn input+cache ---
# Claude Code writes transcripts to ~/.claude/projects/<cwd-slug>/*.jsonl; the last
# assistant turn's input+cache tokens = the conversation's current context weight.
# NB: paths passed as ARGV, not stdin — stdin is the heredoc script (can't be both).
CTX_PATHS=$(tmux list-windows -a -F '#{pane_current_path}' | sort -u)
python3 - "$C" $CTX_PATHS <<'PY' 2>/dev/null
import json, glob, os, sys, re
C=sys.argv[1]
for path in sys.argv[2:]:
    if not path: continue
    slug=re.sub(r'[/._]', '-', path)
    files=sorted(glob.glob(os.path.expanduser(f'~/.claude/projects/{slug}/*.jsonl')),
                 key=os.path.getmtime, reverse=True)
    if not files: continue
    ctx=0; model=''
    try: lines=open(files[0], errors='ignore').readlines()[-250:]
    except OSError: continue
    for line in lines:
        if '"usage"' not in line: continue
        try: d=json.loads(line)
        except: continue
        m=d.get('message') or {}; u=m.get('usage')
        if u and d.get('type')=='assistant':
            ctx=u.get('input_tokens',0)+u.get('cache_read_input_tokens',0)+u.get('cache_creation_input_tokens',0)
            model=m.get('model','') or model
    key=path.replace('/','_').replace(' ','_')
    open(f'{C}/ctx_{key}','w').write(f'{model}\t{ctx}')   # model<TAB>context-tokens
PY

# --- token-usage proxy (≥300s): sum across ALL session transcripts, 5h + 7d ---
# The official rate-limit % is not exposed by any API, so this is a local proxy
# over Claude's official limit windows (rolling 5h + 7d), weighted like limits
# meter: output heavy, cache-read light.
uts=$(cat "$C/usage.ts" 2>/dev/null || echo 0)
if [ $(( $(now) - uts )) -ge 300 ]; then
  python3 - "$C/usage" <<'PY' 2>/dev/null
import json, glob, os, sys, time
out=sys.argv[1]; t=time.time()
w={'5h':t-5*3600, '7d':t-7*86400}
agg={k:0 for k in w}
for f in glob.glob(os.path.expanduser('~/.claude/projects/*/*.jsonl')):
    mt=os.path.getmtime(f)
    if mt < w['7d']: continue
    for line in open(f, errors='ignore'):
        if '"usage"' not in line: continue
        try: d=json.loads(line)
        except: continue
        m=d.get('message') or {}; u=m.get('usage')
        if not u or d.get('type')!='assistant': continue
        tok=u.get('output_tokens',0)*1.0 + u.get('input_tokens',0)*0.25 \
            + u.get('cache_creation_input_tokens',0)*0.25 + u.get('cache_read_input_tokens',0)*0.02
        for k,cut in w.items():
            if mt>=cut: agg[k]+=tok
def fmt(n):
    n=int(n)
    return f"{n/1e6:.1f}M" if n>=1e6 else (f"{n/1e3:.0f}k" if n>=1e3 else str(n))
open(out,'w').write(f"5h {fmt(agg['5h'])} · 7d {fmt(agg['7d'])}")
PY
  now > "$C/usage.ts"
fi

# --- opportunistic scrape of the official weekly-% line (every run) ---
# If any session happens to print "N% of your weekly limit", capture it.
line=$(for w in $(tmux list-windows -a -F '#{session_name}:#{window_index}'); do
  tmux capture-pane -p -S -600 -t "$w" 2>/dev/null
done | grep -aoE "[0-9]+% of your (weekly|[0-9]+-hour) limit[^│]*" | tail -1)
if [ -n "$line" ]; then printf '%s\t%s' "$(now)" "$line" > "$C/ratelimit"; fi

# --- PR/CI attention signal (every run) ---
# Maps each window's branch → its open PR's CI state; writes @prci (glyph) +
# @pfg (color). window-status-format renders them after the window name and
# tmux-sort-windows.sh treats ✗ like 'needs'. Single writer of @prci/@pfg.
PRM=$(cat "$C/prmap" 2>/dev/null)
US=$'\x1f'
tmux list-windows -a -F "#{session_name}:#{window_index}${US}#{pane_current_path}${US}#{@prci}" 2>/dev/null | \
while IFS="$US" read -r win path cur; do
  [ -z "$path" ] && continue
  key=$(printf '%s' "$path" | tr '/ ' '__')
  branch=$(cut -f1 "$C/git_$key" 2>/dev/null)
  bare=$(printf '%s' "$branch" | sed -E 's/(\+[0-9]+)?(-[0-9]+)?$//')
  glyph=""; pfg=""
  if [ -n "$bare" ] && [ "$bare" != "-" ]; then
    hit=$(printf '%s\n' "$PRM" | awk -F'\t' -v x="$bare" '$1==x{print;exit}')
    if [ -n "$hit" ] && [ "$(echo "$hit"|cut -f3)" = "OPEN" ]; then
      case "$(echo "$hit"|cut -f4)" in
        ✗) glyph="✗"; pfg="#f7768e";;   # CI failed → attention
        ✓) glyph="✓"; pfg="#9ece6a";;   # CI green, awaiting merge
      esac
    fi
  fi
  if [ "$cur" != "$glyph" ]; then
    tmux set-window-option -t "$win" @prci "$glyph" 2>/dev/null
    tmux set-window-option -t "$win" @pfg "$pfg" 2>/dev/null
  fi
done

# --- detached-attention escalation (every run) ---
# A window stuck on 'needs' >FLEET_ESCALATE_AFTER sec while NO tmux client is
# attached → run FLEET_NOTIFY_CMD (fleet.conf) with the message as $1 — plug in
# any notifier (Slack webhook curl, WeCom bot, ntfy, …). One ping per episode.
ESC_AFTER="${FLEET_ESCALATE_AFTER:-300}"
if [ -n "${FLEET_NOTIFY_CMD:-}" ] && [ -z "$(tmux list-clients 2>/dev/null)" ]; then
  nowts=$(now)
  tmux list-windows -a -F "#{session_name}:#{window_index}${US}#{window_name}${US}#{@claude_state}${US}#{@claude_state_ts}${US}#{@escalated}${US}#{window_id}" 2>/dev/null | \
  while IFS="$US" read -r win name st ts esc wid; do
    [ "$st" = "needs" ] || continue
    case "$ts" in ''|*[!0-9]*) continue;; esac
    [ $(( nowts - ts )) -ge "$ESC_AFTER" ] || continue
    [ "$esc" = "$ts" ] && continue
    sum=$(head -1 "$C/summary_${wid//[^0-9]/}" 2>/dev/null | cut -c1-80)
    msg="[claude-fleet] session ${name} blocked on your input for $(( (nowts-ts)/60 ))m (no client attached)${sum:+ — ${sum}}"
    $FLEET_NOTIFY_CMD "$msg" >/dev/null 2>&1 \
      && tmux set-window-option -t "$win" @escalated "$ts" 2>/dev/null
  done
fi
exit 0
