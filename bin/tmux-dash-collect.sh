#!/bin/bash
# tmux-dash-collect.sh — background collector for the dash. Owns ALL the slow /
# external status work and writes it to cache files; the dash producer only READS
# these, so the dashboard renders instantly. Run from launchd
# (com.claude-fleet.collect, StartInterval 60s) or a systemd user timer.
# PR status (prmap_<slug>, the flat prmap mirror, and @prci/@pfg) is NOT written
# here — it lives in bin/tmux-pr-refresh.sh, which owns it on a faster ~15s tick
# (see #81). The collector still WRITES sessmap and git_<key>, which that
# refresher reads; the two never write the same cache file.
# Writes under $C = $TMPDIR/.claude-dash:
#   sessmap          — session<TAB>slug<TAB>repo  (one row per live tmux session)
#   issues_<slug>    — milestone<TAB>#num<TAB>assignee<TAB>title per repo (gh, ≥90s)
#   issues           — flat mirror of the PRIMARY (FLEET_REPO) slug'd file, kept
#                      for single-fleet back-compat (un-migrated readers)
#   labels_<slug>    — #num<TAB>comma-joined-labels per repo, split from the SAME
#                      issues fetch (no extra gh call). Read by the fleet watcher
#                      (bin/fleet-watch.sh, issue #147) for prod-alert + eligibility
#   git_<key>        — branch<TAB>dirty  per live worktree (every run)
#   ctx_<key>        — model<TAB>context-tokens per worktree (every run)
#   usage            — token-consumption proxy 5h/7d       (≥300s)
#   usage.filecache  — per-file raw token sums keyed by (mtime,size) — memoizes
#                      the usage scan so unchanged transcripts aren't re-read
#   ratelimit        — last-seen official weekly-% line + epoch (scrape, every run)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
# Sweep this run's PID-unique temps on exit: the per-repo gh fetches only `mv`
# their temp on success, so a failed fetch would otherwise orphan a 0-byte
# issues_<slug>.$$ (and sessmap.$$) forever.
trap 'rm -f "$C"/*.'"$$" EXIT
REPO="${FLEET_REPO:-}"
BASE="${FLEET_BASE_BRANCH:-main}"
now() { date +%s; }

# atomic_write DEST — stream stdin to a PID-unique temp, then rename into place.
# rename(2) is atomic on one filesystem, so a concurrent reader (the dash) always
# sees either the old file or the complete new one, never a half-written cache.
# The EXIT trap above sweeps any <name>.$$ temp orphaned by a crash mid-write.
atomic_write() {
  local dest="$1" tmp="$1.$$"
  cat > "$tmp" && mv "$tmp" "$dest"
}

# cache_key PATH — filesystem-safe, collision-FREE cache key for a worktree path.
# Reversibly escapes the escape char first, then '/' and ' ' to DISTINCT tokens,
# so no two distinct paths ever map to the same git_/ctx_ cache (the old
# tr '/ ' '__' collided '/a b' with '/a/b'). MUST stay byte-identical to the
# reader in bin/tmux-dashboard-rows.sh and the Python encoder further below.
cache_key() {
  local k=${1//_/_u}; k=${k//\//_s}; k=${k// /_w}; printf '%s' "$k"
}

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

# --- per-repo issues (TTL-gated per repo) ---
# NB: PR status (prmap_<slug> + the flat prmap mirror + @prci/@pfg) is NOT built
# here anymore — it moved to bin/tmux-pr-refresh.sh so it can refresh on a ~15s
# cadence instead of this 60s tick. That script is the SINGLE writer of all PR
# state; the collector only touches issues/git/usage. See issue #81.
i=0
while [ "$i" -lt "${#Q_REPO[@]}" ]; do
  rp="${Q_REPO[$i]}"; sg="${Q_SLUG[$i]}"; i=$((i+1))
  command -v gh >/dev/null 2>&1 || break
  its=$(cat "$C/issues_$sg.ts" 2>/dev/null || echo 0)
  if [ $(( $(now) - its )) -ge "$GH_TTL" ]; then
    # ONE fetch, TWO caches. The gh --jq emits a 6-column raw line — the historical
    # 4 (milestone, #num, assignee, title) + a comma-joined labels column + a
    # backlog flag (jq does the exact `steward-control` match, so a weird label name
    # can't fool the comma-split). We then derive:
    #   issues_<slug>  — the 4-column backlog, keeping its contract EXACTLY (readers
    #                    `cut`/`read` fields 1-4) and DROPPING steward-control issues
    #                    (#176: a relay endpoint like the #169 hub is not a task; the
    #                    autofill dispatcher excludes the same label). Filter = the jq
    #                    flag column, so it's still one gh call + fixture-testable.
    #   labels_<slug>  — #num<TAB>labels for EVERY open issue (incl. steward-control /
    #                    prod-alert) for the fleet watcher (#147). It must NOT inherit
    #                    the backlog's steward-control drop — the watcher needs to see
    #                    those labels — so it is split from the unfiltered raw.
    # Deriving both from one fetch keeps the labels cache zero-extra-token. The raw
    # temp is <name>.$$, so the EXIT trap sweeps it if we die mid-split.
    raw="$C/issuesx_$sg.$$"
    if gh issue list --repo "$rp" --state open --limit 300 \
      --json number,title,milestone,assignees,labels \
      --jq '.[] | (.labels|map(.name)) as $l | (.milestone.title // "· no milestone")+"\t#"+(.number|tostring)+"\t"+((((.assignees|map(.login)|join(","))[0:10]) | if .=="" then "·" else . end))+"\t"+(.title)+"\t"+($l|join(","))+"\t"+(if ($l|any(.=="steward-control")) then "0" else "1" end)' \
      > "$raw" 2>/dev/null; then
      awk -F'\t' '$6=="1"' "$raw" | cut -f1-4 > "$C/issues_$sg.$$" \
        && mv "$C/issues_$sg.$$" "$C/issues_$sg"
      awk -F'\t' '{n=$2; sub(/^#/,"",n); print n"\t"$5}' "$raw" > "$C/labels_$sg.$$" \
        && mv "$C/labels_$sg.$$" "$C/labels_$sg"
    fi
    rm -f "$raw"
    now > "$C/issues_$sg.ts"
  fi
done

# --- back-compat flat mirror: PRIMARY repo → the un-slug'd issues name ---
# (the prmap flat mirror is written by bin/tmux-pr-refresh.sh, not here — see #81)
if [ -n "$PRIMARY_SLUG" ] && [ -s "$C/issues_$PRIMARY_SLUG" ]; then
  atomic_write "$C/issues" < "$C/issues_$PRIMARY_SLUG"
fi

# --- git per live worktree (every run) ---
tmux list-windows -a -F '#{pane_current_path}' | sort -u | while read -r path; do
  [ -z "$path" ] && continue
  git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || continue
  key=$(cache_key "$path")
  branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null); dirty=''
  [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ] && dirty='✱'
  ab=$(git -C "$path" rev-list --left-right --count "$BASE...HEAD" 2>/dev/null)
  behind=$(echo "$ab" | awk '{print $1+0}'); ahead=$(echo "$ab" | awk '{print $2+0}')
  [ "${ahead:-0}" != 0 ] && branch="$branch+$ahead"; [ "${behind:-0}" != 0 ] && branch="$branch-$behind"
  printf '%s\t%s' "$branch" "$dirty" | atomic_write "$C/git_$key"
done

# --- per-window context tokens (every run): newest transcript's last-turn input+cache ---
# Claude Code writes transcripts to ~/.claude/projects/<cwd-slug>/*.jsonl; the last
# assistant turn's input+cache tokens = the conversation's current context weight.
# NB: paths passed as ARGV, not stdin — stdin is the heredoc script (can't be both).
# Gather paths into an ARRAY (not a word-split string) so a path containing a
# space stays a single argv entry end-to-end. Guard the length for bash 3.2,
# where "${arr[@]}" on an empty array trips `set -u`. $$ lets Python suffix its
# temp files so the EXIT trap can sweep any it orphans.
CTX_PATHS=()
while IFS= read -r p; do [ -n "$p" ] && CTX_PATHS+=("$p"); done \
  < <(tmux list-windows -a -F '#{pane_current_path}' | sort -u)
if [ "${#CTX_PATHS[@]}" -gt 0 ] && have_py3; then
python3 - "$C" "$$" "${CTX_PATHS[@]}" <<'PY'
import json, glob, os, sys, re
C=sys.argv[1]; pid=sys.argv[2]
for path in sys.argv[3:]:
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
    # cache key: keep byte-identical to cache_key() in the shell above
    key=path.replace('_','_u').replace('/','_s').replace(' ','_w')
    tmp=f'{C}/ctx_{key}.{pid}'
    with open(tmp,'w') as fh: fh.write(f'{model}\t{ctx}')  # model<TAB>context-tokens
    os.replace(tmp, f'{C}/ctx_{key}')                     # atomic: readers never see a partial cache
PY
fi

# --- token-usage proxy (≥300s): sum across ALL session transcripts, 5h + 7d ---
# The official rate-limit % is not exposed by any API, so this is a local proxy
# over Claude's official limit windows (rolling 5h + 7d), weighted like limits
# meter: output heavy, cache-read light.
#
# Memoized per file: ~/.claude/projects/ grows unbounded (thousands of *.jsonl,
# 1GB+), and re-parsing every in-window transcript each tick costs seconds — yet
# steady-state almost none of them changed. So cache each file's RAW per-file
# token sums keyed by (mtime,size) in $C/usage.filecache; on the next tick reuse
# the cached sums for any file whose (mtime,size) is unchanged and only re-read
# the handful actively being appended. Bucketing into 5h/7d is still done by file
# mtime (a cached-mtime-vs-cutoff compare, no re-read) exactly as before, so the
# rolling cutoffs still move correctly. Weighting is linear, so summing raw tokens
# per file then weighting is identical to weighting per line: warm == cold output.
uts=$(cat "$C/usage.ts" 2>/dev/null || echo 0)
if [ $(( $(now) - uts )) -ge 300 ] && have_py3; then
  python3 - "$C/usage" "$$" <<'PY'
import json, glob, os, sys, time
out=sys.argv[1]; pid=sys.argv[2]; t=time.time()
cachef=out+'.filecache'                                # $C/usage.filecache
w={'5h':t-5*3600, '7d':t-7*86400}
agg={k:0.0 for k in w}
# load prior per-file cache (path -> {mtime,size,tok:[out,in,cc,cr]}); tolerate any corruption
try:
    old=json.load(open(cachef))
    if not isinstance(old, dict): old={}
except Exception:
    old={}
new={}                                                 # rebuilt fresh → prunes vanished / >7d files
for f in glob.glob(os.path.expanduser('~/.claude/projects/*/*.jsonl')):
    try: st=os.stat(f)
    except OSError: continue
    mt=st.st_mtime
    if mt < w['7d']: continue
    ent=old.get(f)
    if ent and ent.get('mtime')==mt and ent.get('size')==st.st_size:
        tot=ent['tok']                                 # unchanged → reuse cached raw sums, no open()
    else:
        tot=[0,0,0,0]                                  # output / input / cache_creation / cache_read
        try: fh=open(f, errors='ignore')
        except OSError: continue
        with fh:
            for line in fh:
                if '"usage"' not in line: continue     # fast-path prefilter (kept)
                try: d=json.loads(line)
                except: continue
                m=d.get('message') or {}; u=m.get('usage')
                if not u or d.get('type')!='assistant': continue
                tot[0]+=u.get('output_tokens',0)
                tot[1]+=u.get('input_tokens',0)
                tot[2]+=u.get('cache_creation_input_tokens',0)
                tot[3]+=u.get('cache_read_input_tokens',0)
    new[f]={'mtime':mt,'size':st.st_size,'tok':tot}
    tok=tot[0]*1.0 + tot[1]*0.25 + tot[2]*0.25 + tot[3]*0.02
    for k,cut in w.items():
        if mt>=cut: agg[k]+=tok
def fmt(n):
    n=int(n)
    return f"{n/1e6:.1f}M" if n>=1e6 else (f"{n/1e3:.0f}k" if n>=1e3 else str(n))
tmp=f'{out}.{pid}'
with open(tmp,'w') as fh: fh.write(f"5h {fmt(agg['5h'])} · 7d {fmt(agg['7d'])}")
os.replace(tmp, out)                                   # atomic: readers never see a partial cache
ctmp=f'{cachef}.{pid}'
with open(ctmp,'w') as fh: json.dump(new, fh)
os.replace(ctmp, cachef)                               # atomic: overlapping collectors can't corrupt it
PY
  now > "$C/usage.ts"
fi

# --- opportunistic scrape of the official weekly-% line (every run) ---
# If any session happens to print "N% of your weekly limit", capture it.
# tolerant by design: grep exits 1 when no session shows the line (the common
# case) — that non-zero pipeline status is intentionally discarded; only the
# captured $line matters.
line=$(for w in $(tmux list-windows -a -F '#{session_name}:#{window_index}'); do
  tmux capture-pane -p -S -600 -t "$w" 2>/dev/null
done | grep -aoE "[0-9]+% of your (weekly|[0-9]+-hour) limit[^│]*" | tail -1)
if [ -n "$line" ]; then printf '%s\t%s' "$(now)" "$line" | atomic_write "$C/ratelimit"; fi

# --- multi-account auto-switch (every run) ---
# When a window running under a registered account shows the "You've hit your …
# limit · resets …" banner, mark THAT account limited and rotate the active
# pointer so NEW sessions spawn on a fresh subscription. The window carries its
# account label in @cc_account (stamped by bin/fleet-claude.sh at launch).
# No-op unless accounts are registered — so single-account installs skip it.
US=$'\x1f'
if [ -d "${FLEET_ACCOUNTS_DIR:-$FLEET_CONF_DIR/accounts}" ]; then
  tmux list-windows -a -F "#{session_name}:#{window_index}${US}#{@cc_account}" 2>/dev/null | \
  while IFS="$US" read -r win acct; do
    [ -n "$acct" ] || continue
    # match the core signal ("hit your <session|weekly|Opus> limit"); the trailing
    # "· resets …" (when present) is captured for the notification but not required.
    banner=$(tmux capture-pane -p -S -200 -t "$win" 2>/dev/null \
      | grep -aoE "hit your [A-Za-z0-9 -]*limit[^│]*" | tail -1)
    [ -n "$banner" ] || continue
    newact=$("$BIN/fleet-account.sh" mark-limited "$acct" "$banner" 2>/dev/null); rc=$?
    # exit 10 = this call rotated the active account away → notify once
    if [ "$rc" -eq 10 ] && [ -n "${FLEET_NOTIFY_CMD:-}" ]; then
      $FLEET_NOTIFY_CMD "# subscription limit reached
account **$acct** hit its usage limit — new sessions now use **${newact:-?}**
> ${banner}" >/dev/null 2>&1
    fi
  done
fi

# NB: the PR/CI attention signal (@prci/@pfg per window) moved to
# bin/tmux-pr-refresh.sh (single writer, ~15s cadence) — see #81. The collector
# no longer touches it.

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

# --- crash-recovery snapshot (every run) ---
# Durably record the live fleet layout (which fleets, work windows, worktrees,
# Claude session ids) so fleet-restore.sh can rebuild every fleet and
# `claude --resume` every session after a tmux-server-wide crash. Cheap; never
# fatal to the collector.
bash "$BIN/fleet-restore.sh" --snapshot >/dev/null 2>&1 || true
exit 0
