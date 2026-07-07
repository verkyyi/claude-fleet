#!/bin/bash
# tmux-dash-collect.sh — background collector for the dash. Owns ALL the slow /
# external status work and writes it to cache files; the dash producer only READS
# these, so the dashboard renders instantly. Run from launchd
# (com.claude-fleet.collect, StartInterval 60s) or a systemd user timer.
# Writes under $C = $TMPDIR/.claude-dash:
#   sessmap          — session<TAB>slug<TAB>repo  (one row per live tmux session)
#   prmap_<slug>     — branch<TAB>#num<TAB>state<TAB>ci   per repo (gh, ≥90s)
#   issues_<slug>    — milestone<TAB>#num<TAB>assignee<TAB>title per repo (gh, ≥90s)
#   prmap / issues   — flat mirror of the PRIMARY (FLEET_REPO) slug'd file, kept
#                      for single-fleet back-compat (un-migrated readers)
#   git_<key>        — branch<TAB>dirty  per live worktree (every run)
#   ctx_<key>        — model<TAB>context-tokens per worktree (every run)
#   usage            — token-consumption proxy 5h/7d       (≥300s)
#   ratelimit        — last-seen official weekly-% line + epoch (scrape, every run)
set -u
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
# Sweep this run's PID-unique temps on exit: the per-repo gh fetches only `mv`
# their temp on success, so a failed fetch would otherwise orphan a 0-byte
# prmap_<slug>.$$ / issues_<slug>.$$ (and sessmap.$$) forever.
trap 'rm -f "$C"/*.'"$$" EXIT
REPO="${FLEET_REPO:-}"
BASE="${FLEET_BASE_BRANCH:-main}"
now() { date +%s; }
tmux info >/dev/null 2>&1 || exit 0

# python3 powers the context% and usage caches (below). It's a hard dep for
# those, so guard it once with a diagnostic to stderr (StandardErrorPath →
# logs/collect.launchd.log) rather than letting a `command not found` get
# swallowed and leaving those caches silently empty forever.
py_warned=0
have_py3() {
  command -v python3 >/dev/null 2>&1 && return 0
  [ "$py_warned" = 0 ] && printf 'fleet-collect: python3 not found on PATH (%s) — context%% and usage caches will be empty\n' "$PATH" >&2
  py_warned=1
  return 1
}

# gh fetch TTL (issues + PR map). FLEET_GH_TTL in fleet.conf tunes staleness
# vs API chatter; GH_TTL=0 on a one-off run forces a fetch.
GH_TTL="${GH_TTL:-${FLEET_GH_TTL:-90}}"

# --- resolve the repo set from live tmux sessions (multi-fleet) ---
# Each tmux session ≡ one fleet ≡ one repo. Seed the fetch queue with the primary
# FLEET_REPO (so its flat mirror stays fresh even with no session), then add every
# other repo a live session resolves to. Write sessmap for the read-side producers.
declare -a Q_REPO Q_SLUG          # unique (repo,slug) fetch queue (indexed arrays; bash 3.2 ok)
SEEN=' '
queue() {                          # $1=repo → add once
  local r="$1" s
  [ -z "$r" ] && return
  s=$(fleet_slug "$r")
  case "$SEEN" in *" $s "*) return;; esac
  SEEN="$SEEN$s "; Q_REPO+=("$r"); Q_SLUG+=("$s")
}
PRIMARY_SLUG=''
if [ -n "$REPO" ]; then PRIMARY_SLUG=$(fleet_slug "$(fleet_norm_repo "$REPO")"); queue "$(fleet_norm_repo "$REPO")"; fi
SM="$C/sessmap.$$"; : > "$SM"          # PID-unique tmp: safe if two collectors overlap
for sess in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
  r=$(fleet_resolve_repo_for_session "$sess")
  [ -z "$r" ] && continue
  printf '%s\t%s\t%s\n' "$sess" "$(fleet_slug "$r")" "$r" >> "$SM"
  queue "$r"
done
mv "$SM" "$C/sessmap"

# pin repos with NO live session so their caches stay fresh (a steward watching a
# repo you haven't opened; a fleet-up'd-but-closed fleet): FLEET_REPOS list +
# every configured per-fleet conf.
for r in ${FLEET_REPOS:-}; do queue "$(fleet_norm_repo "$r")"; done
if [ -d "$FLEET_CONF_DIR" ]; then
  for cf in "$FLEET_CONF_DIR"/*.conf; do
    [ -f "$cf" ] || continue
    r=$( . "$cf" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
    [ -n "$r" ] && queue "$(fleet_norm_repo "$r")"
  done
fi

# --- per-repo PR map + issues (TTL-gated per repo) ---
i=0
while [ "$i" -lt "${#Q_REPO[@]}" ]; do
  rp="${Q_REPO[$i]}"; sg="${Q_SLUG[$i]}"; i=$((i+1))
  command -v gh >/dev/null 2>&1 || break
  pts=$(cat "$C/prmap_$sg.ts" 2>/dev/null || echo 0)
  if [ $(( $(now) - pts )) -ge "$GH_TTL" ]; then
    gh pr list --repo "$rp" --state all --limit 100 \
      --json number,headRefName,state,statusCheckRollup \
      --jq 'group_by(.headRefName)[] | max_by(.number) |
            .headRefName + "\t#" + (.number|tostring) + "\t" + .state + "\t" + (
              (.statusCheckRollup // []) | if length==0 then "·"
              elif any(.conclusion=="FAILURE" or .conclusion=="CANCELLED") then "✗"
              elif any(.status!="COMPLETED") then "…" else "✓" end)' \
      > "$C/prmap_$sg.$$" 2>/dev/null && mv "$C/prmap_$sg.$$" "$C/prmap_$sg"
    now > "$C/prmap_$sg.ts"
  fi
  its=$(cat "$C/issues_$sg.ts" 2>/dev/null || echo 0)
  if [ $(( $(now) - its )) -ge "$GH_TTL" ]; then
    gh issue list --repo "$rp" --state open --limit 300 \
      --json number,title,milestone,assignees \
      --jq '.[] | (.milestone.title // "· no milestone")+"\t#"+(.number|tostring)+"\t"+((((.assignees|map(.login)|join(","))[0:10]) | if .=="" then "·" else . end))+"\t"+(.title)' \
      > "$C/issues_$sg.$$" 2>/dev/null && mv "$C/issues_$sg.$$" "$C/issues_$sg"
    now > "$C/issues_$sg.ts"
  fi
done

# --- back-compat flat mirror: PRIMARY repo → the un-slug'd prmap/issues names ---
if [ -n "$PRIMARY_SLUG" ]; then
  [ -s "$C/prmap_$PRIMARY_SLUG" ]  && cp "$C/prmap_$PRIMARY_SLUG"  "$C/prmap"
  [ -s "$C/issues_$PRIMARY_SLUG" ] && cp "$C/issues_$PRIMARY_SLUG" "$C/issues"
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
# shellcheck disable=SC2086  # intentional word-split: each path becomes its own argv entry
if have_py3; then
python3 - "$C" $CTX_PATHS <<'PY'
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
fi

# --- token-usage proxy (≥300s): sum across ALL session transcripts, 5h + 7d ---
# The official rate-limit % is not exposed by any API, so this is a local proxy
# over Claude's official limit windows (rolling 5h + 7d), weighted like limits
# meter: output heavy, cache-read light.
uts=$(cat "$C/usage.ts" 2>/dev/null || echo 0)
if [ $(( $(now) - uts )) -ge 300 ] && have_py3; then
  python3 - "$C/usage" <<'PY'
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
US=$'\x1f'
tmux list-windows -a -F "#{session_name}${US}#{session_name}:#{window_index}${US}#{pane_current_path}${US}#{@prci}" 2>/dev/null | \
while IFS="$US" read -r sess win path cur; do
  [ -z "$path" ] && continue
  # each window matches against ITS fleet's prmap (slug from sessmap), flat fallback
  slug=$(fleet_slug_cached "$sess")
  prmf="$C/prmap"; [ -n "$slug" ] && [ -f "$C/prmap_$slug.ts" ] && prmf="$C/prmap_$slug"
  key=$(printf '%s' "$path" | tr '/ ' '__')
  branch=$(cut -f1 "$C/git_$key" 2>/dev/null)
  bare=$(printf '%s' "$branch" | sed -E 's/(\+[0-9]+)?(-[0-9]+)?$//')
  glyph=""; pfg=""
  if [ -n "$bare" ] && [ "$bare" != "-" ]; then
    hit=$(awk -F'\t' -v x="$bare" '$1==x{print;exit}' "$prmf" 2>/dev/null)
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
    msg="# session blocked
**${name}** has been waiting for your input for $(( (nowts-ts)/60 ))m (no client attached)${sum:+
> doing: ${sum}}"
    $FLEET_NOTIFY_CMD "$msg" >/dev/null 2>&1 \
      && tmux set-window-option -t "$win" @escalated "$ts" 2>/dev/null
  done
fi
exit 0
