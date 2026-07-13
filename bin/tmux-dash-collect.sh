#!/bin/bash
# tmux-dash-collect.sh — background collector for the dash. Owns ALL the slow /
# external status work and writes it to cache files; the dash producer only READS
# these, so the dashboard renders instantly. Run from launchd
# (com.claude-fleet.collect, StartInterval 60s) or a systemd user timer.
# PR status (prmap_<slug>, the flat prmap mirror, and @prci/@pfg) is NOT written
# here — it lives in bin/tmux-pr-refresh.sh, which owns it on a faster ~15s tick
# (see #81). The collector still WRITES sessmap and git_<key>, which that
# refresher reads; the two never write the same cache file.
# Writes under $C = $TMPDIR/.claude-dash, one directory per fleet (issue #181):
#   global/sessmap        — session<TAB>slug<TAB>repo  (one row per live tmux session)
#   fleets/<slug>/issues  — milestone<TAB>#num<TAB>assignee<TAB>title per repo (gh, ≥90s)
#   fleets/<slug>/labels  — #num<TAB>comma-joined-labels per repo, split from the SAME
#                           issues fetch (no extra gh call). Read by the fleet watcher
#                           (bin/fleet-watch.sh, issue #147) for prod-alert + eligibility
#   global/git_<key>      — branch<TAB>dirty  per live worktree (every run). Keyed by a
#                           globally-unique worktree path, so it lives in global/ (not
#                           per-fleet) — the reader resolves it without a slug lookup
#   global/ctx_<key>      — model<TAB>context-tokens per worktree (every run)
#   global/usage          — token-consumption proxy 5h/7d       (≥300s)
#   global/usage.filecache— per-file raw token sums keyed by (mtime,size) — memoizes
#                           the usage scan so unchanged transcripts aren't re-read
#   global/ratelimit      — last-seen official weekly-% line + epoch (scrape, every run)
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"
C="${TMPDIR:-/tmp}/.claude-dash"; mkdir -p "$C"
# Per-fleet cache layout (issue #181): slug-keyed fetches live under fleets/<slug>/
# and machine-wide caches under global/. G is the global bucket.
G="$C/global"; mkdir -p "$G"
# Sweep this run's PID-unique temps on exit (across the global/ + fleets/<slug>/
# subdirs now): the per-repo gh fetches only `mv` their temp on success, so a failed
# fetch would otherwise orphan a 0-byte issues.<pid> (and sessmap.<pid>) forever.
trap 'find "$C" -maxdepth 3 -name "*.'"$$"'" -delete 2>/dev/null || true' EXIT
REPO="${FLEET_REPO:-}"
BASE="${FLEET_BASE_BRANCH:-main}"
now() { date +%s; }

# Targeted mode (issue #315): `--issues <owner/repo>` refreshes JUST that repo's
# issues/labels cache NOW and exits (the webhook handler's instant kick,
# bin/fleet-webhook.sh), skipping the git/ctx/usage/snapshot work of a full 60s
# tick. The collector stays the SINGLE writer of issues_<slug>. Normal (no-arg)
# invocation is byte-for-byte unchanged.
TARGET_ISSUES_REPO=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --issues) TARGET_ISSUES_REPO="${2:-}"; shift ;;
    -*)       printf 'tmux-dash-collect: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *)        printf 'tmux-dash-collect: unexpected argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

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

# fetch_issues_for REPO SLUG [FORCE] — the SINGLE issues/labels fetch, shared by the
# per-repo TTL-gated loop below AND the targeted `--issues <repo>` webhook kick
# (issue #315) so the two can never drift on the jq/column contract. FORCE=1
# bypasses the TTL (the kick wants it NOW); else it fetches only when the cache is
# older than GH_TTL. No-op (return) when gh is missing.
#
# ONE fetch, TWO caches. The gh --jq emits a 6-column raw line whose LEADING two
# columns are the backlog flag + comma-joined labels, FOLLOWED by the historical 4
# (milestone, #num, assignee, title). Putting the extra columns FIRST keeps the
# title LAST, so a tab inside an issue title is absorbed into the title field
# (harmless) instead of shifting the label/flag columns and dropping the issue. jq
# does the exact `steward-control` match into the flag, so a weird label name can't
# fool the comma-split. We then derive:
#   issues_<slug>  — the 4-column backlog (milestone, #num, assignee, title), keeping
#                    its contract EXACTLY (readers `cut`/`read` fields 1-4) and
#                    DROPPING steward-control issues (#176: a relay endpoint is not a
#                    task; spawn-eligibility excludes the same label). Filter = the jq
#                    flag column ⇒ still one gh call + fixture-testable.
#   labels_<slug>  — #num<TAB>labels for EVERY open issue (incl. steward-control /
#                    prod-alert) for the fleet watcher (#147). It must NOT inherit the
#                    backlog's steward-control drop — split from the unfiltered raw.
# Deriving both from one fetch keeps the labels cache zero-extra-token. The raw temp
# is <name>.$$, so the EXIT trap sweeps it if we die mid-split.
fetch_issues_for() {
  local rp="$1" sg="$2" force="${3:-0}" FD its raw ttl
  command -v gh >/dev/null 2>&1 || return 0
  ttl="${GH_TTL:-${FLEET_GH_TTL:-90}}"
  FD=$(fleet_cache_dir "$sg")          # fleets/<slug>/ (issue #181)
  its=$(cat "$FD/issues.ts" 2>/dev/null || echo 0)
  if [ "$force" = 1 ] || [ $(( $(now) - its )) -ge "$ttl" ]; then
    raw="$FD/issuesx.$$"
    if gh issue list --repo "$rp" --state open --limit 300 \
      --json number,title,milestone,assignees,labels \
      --jq '.[] | (.labels|map(.name)) as $l | (if ($l|any(.=="steward-control")) then "0" else "1" end)+"\t"+($l|join(","))+"\t"+(.milestone.title // "· no milestone")+"\t#"+(.number|tostring)+"\t"+((((.assignees|map(.login)|join(","))[0:10]) | if .=="" then "·" else . end))+"\t"+(.title)' \
      > "$raw" 2>/dev/null; then
      awk -F'\t' '$1=="1"' "$raw" | cut -f3-6 > "$FD/issues.$$" \
        && mv "$FD/issues.$$" "$FD/issues"
      awk -F'\t' '{n=$4; sub(/^#/,"",n); print n"\t"$2}' "$raw" > "$FD/labels.$$" \
        && mv "$FD/labels.$$" "$FD/labels"
    fi
    rm -f "$raw"
    now > "$FD/issues.ts"
  fi
}

# Targeted issues kick (issue #315): `--issues <owner/repo>` force-refreshes JUST
# that repo's issues/labels cache and exits — the webhook handler's instant kick,
# skipping all the git/ctx/usage/escalation/snapshot work a full tick does. Placed
# BEFORE the tmux/socket enumeration so it stays cheap.
if [ -n "$TARGET_ISSUES_REPO" ]; then
  _tr=$(fleet_norm_repo "$TARGET_ISSUES_REPO")
  [ -n "$_tr" ] && fetch_issues_for "$_tr" "$(fleet_slug "$_tr")" 1
  exit 0
fi

# Each fleet runs on its OWN tmux server/socket now (issue #159), so there is no
# single shared server to probe — enumerate the live fleet sockets ONCE and fan
# every tmux query out across them. NB: we do NOT early-exit when the set is empty
# (unlike the old `tmux info` gate): the per-repo issue fetch below still refreshes
# every CONFIGURED repo's cache even with no live fleet, so the backlog has data
# the moment a fleet opens. The tmux-dependent sections (sessmap, git/ctx, capture,
# escalation, snapshot) each iterate $SOCKETS / lw_all and simply no-op when empty.
SOCKETS=$(fleet_sockets)
# lw_all FMT — the per-fleet-socket replacement for the old `tmux list-windows -a
# -F FMT`: run it against every live fleet socket and concatenate. Reuses the
# cached $SOCKETS (no re-probe). Read-only callers use this; writers loop $SOCKETS
# themselves so they hold the -L label to target (see the escalation block).
lw_all() { local s; for s in $SOCKETS; do tmux -L "$s" list-windows -a -F "$1" 2>/dev/null; done; }

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
# Each tmux session ≡ one fleet ≡ one repo. Seed the fetch queue with the global
# FLEET_REPO (so its slug'd cache stays fresh even with no live session), then add
# every other repo a live session resolves to. No fleet is "primary": every fleet's
# cache is issues_<slug> only, and no flat mirror is written as any one fleet's copy
# (issue #180). Write sessmap for the read-side producers.
declare -a Q_REPO Q_SLUG          # unique (repo,slug) fetch queue (indexed arrays; bash 3.2 ok)
SEEN=' '
queue() {                          # $1=repo → add once
  local r="$1" s
  [ -z "$r" ] && return
  s=$(fleet_slug "$r")
  case "$SEEN" in *" $s "*) return;; esac
  SEEN="$SEEN$s "; Q_REPO+=("$r"); Q_SLUG+=("$s")
}
[ -n "$REPO" ] && queue "$(fleet_norm_repo "$REPO")"
SM="$G/sessmap.$$"; : > "$SM"          # PID-unique tmp: safe if two collectors overlap (global bucket, issue #181)
# Fan the session enumeration across every live fleet socket (issue #159): no
# single shared server sees them all now.
for sock in $SOCKETS; do
  for sess in $(tmux -L "$sock" list-sessions -F '#{session_name}' 2>/dev/null); do
    r=$(fleet_resolve_repo_for_session "$sess")
    [ -z "$r" ] && continue
    printf '%s\t%s\t%s\n' "$sess" "$(fleet_slug "$r")" "$r" >> "$SM"
    queue "$r"
  done
done
# Sessmap write-guard (issue #203, mirror of the #160 restore-map shrink-guard):
# NEVER let an EMPTY sessmap replace/shadow a non-empty one. If discovery hiccups
# — fleet_sockets momentarily returns nothing (the very #203 regression, or a
# transient tmux) — a 0-row sessmap makes fleet_slug_cached return empty, so
# fleet_cache falls back to a stale flat file and the backlog renders ANOTHER
# repo's issues. So only publish an empty map when there's nothing good to protect.
smrows() { if [ -f "$1" ]; then grep -c . "$1" 2>/dev/null || true; else echo 0; fi; }
new_rows=$(smrows "$SM")
if [ "${new_rows:-0}" -gt 0 ]; then
  mv "$SM" "$G/sessmap"                 # real rows → publish
else
  rm -f "$SM"
  g_rows=$(smrows "$G/sessmap")         # existing new-layout global map
  l_rows=$(smrows "$C/sessmap")         # legacy flat map (fleet_sessmap_file's fallback)
  if [ "${g_rows:-0}" -eq 0 ] && [ "${l_rows:-0}" -gt 0 ]; then
    # An empty global/sessmap would SHADOW the good legacy flat rows (fleet_sessmap_file
    # prefers global/ once it exists) — drop it so the fallback un-shadows and serves
    # the correct repo. A NON-empty global map is always kept as-is.
    rm -f "$G/sessmap"
  fi
  # else: nothing good anywhere (genuinely no live fleet) — leave the map absent so
  # readers show "loading"/empty rather than a wrong-repo flat leftover.
fi

# Prune dead pre-#180 flat mirrors (issue #203): current code writes issues/prmap/
# labels ONLY under fleets/<slug>/ (never the flat $C root), so a leftover
# unsuffixed issues/prmap/labels is a PRE-#180 artifact that fleet_cache's
# degenerate (unresolved-session) fallback would serve as ANOTHER repo's data —
# worse than empty. Remove them so that fallback reads absent → "loading". The flat
# `sessmap` is deliberately NOT pruned: fleet_sessmap_file dual-reads it as the
# cold-start fallback until global/sessmap is populated.
for _stale in issues prmap labels; do
  rm -f "$C/$_stale" "$C/$_stale.ts" 2>/dev/null || true
done

# pin repos with NO live session so their caches stay fresh (a steward watching a
# repo you haven't opened; a fleet-up'd-but-closed fleet): FLEET_REPOS list +
# every configured per-fleet conf.
for r in ${FLEET_REPOS:-}; do queue "$(fleet_norm_repo "$r")"; done
while IFS=$'\t' read -r _s cf; do
  [ -f "$cf" ] || continue
  r=$( . "$cf" >/dev/null 2>&1; printf '%s' "${FLEET_REPO:-}" )
  [ -n "$r" ] && queue "$(fleet_norm_repo "$r")"
done < <(fleet_each_conf)

# --- per-repo issues (TTL-gated per repo) ---
# NB: PR status (prmap_<slug> + the flat prmap mirror + @prci/@pfg) is NOT built
# here anymore — it moved to bin/tmux-pr-refresh.sh so it can refresh on a ~15s
# cadence instead of this 60s tick. That script is the SINGLE writer of all PR
# state; the collector only touches issues/git/usage. See issue #81.
i=0
while [ "$i" -lt "${#Q_REPO[@]}" ]; do
  rp="${Q_REPO[$i]}"; sg="${Q_SLUG[$i]}"; i=$((i+1))
  command -v gh >/dev/null 2>&1 || break
  fetch_issues_for "$rp" "$sg" 0     # TTL-gated (see fetch_issues_for above)
done

# No flat issues mirror is written (issue #180 — all fleets equal, no primary):
# every reader routes through fleet_cache, which returns issues_<slug> for a
# resolved fleet and only falls back to the un-slug'd name during cold start.

# --- git per live worktree (every run) ---
lw_all '#{pane_current_path}' | sort -u | while read -r path; do
  [ -z "$path" ] && continue
  git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || continue
  key=$(cache_key "$path")
  branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null); dirty=''
  [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ] && dirty='✱'
  ab=$(git -C "$path" rev-list --left-right --count "$BASE...HEAD" 2>/dev/null)
  behind=$(echo "$ab" | awk '{print $1+0}'); ahead=$(echo "$ab" | awk '{print $2+0}')
  [ "${ahead:-0}" != 0 ] && branch="$branch+$ahead"; [ "${behind:-0}" != 0 ] && branch="$branch-$behind"
  printf '%s\t%s' "$branch" "$dirty" | atomic_write "$G/git_$key"
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
  < <(lw_all '#{pane_current_path}' | sort -u)
if [ "${#CTX_PATHS[@]}" -gt 0 ] && have_py3; then
python3 - "$G" "$$" "${CTX_PATHS[@]}" <<'PY'
import json, glob, os, sys, re
C=sys.argv[1]; pid=sys.argv[2]   # C = the global/ cache bucket (ctx_<key> lives here)
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
uts=$(cat "$G/usage.ts" 2>/dev/null || echo 0)
if [ $(( $(now) - uts )) -ge 300 ] && have_py3; then
  python3 - "$G/usage" "$$" <<'PY'
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
  now > "$G/usage.ts"
fi

# --- opportunistic scrape of the official weekly-% line (every run) ---
# If any session happens to print "N% of your weekly limit", capture it.
# tolerant by design: grep exits 1 when no session shows the line (the common
# case) — that non-zero pipeline status is intentionally discarded; only the
# captured $line matters.
line=$(for sock in $SOCKETS; do
  for w in $(tmux -L "$sock" list-windows -a -F '#{session_name}:#{window_index}' 2>/dev/null); do
    tmux -L "$sock" capture-pane -p -S -600 -t "$w" 2>/dev/null
  done
done | grep -aoE "[0-9]+% of your (weekly|[0-9]+-hour) limit[^│]*" | tail -1)
if [ -n "$line" ]; then printf '%s\t%s' "$(now)" "$line" | atomic_write "$G/ratelimit"; fi

# --- multi-account auto-switch (every run) ---
# When a window running under a registered account shows the "You've hit your …
# limit · resets …" banner, mark THAT account limited and rotate the active
# pointer so NEW sessions spawn on a fresh subscription. The window carries its
# account label in @cc_account (stamped by bin/fleet-claude.sh at launch).
# No-op unless accounts are registered — so single-account installs skip it.
US=$'\x1f'
if [ -d "${FLEET_ACCOUNTS_DIR:-$FLEET_CONF_DIR/accounts}" ]; then
  for sock in $SOCKETS; do
  tmux -L "$sock" list-windows -a -F "#{session_name}:#{window_index}${US}#{@cc_account}" 2>/dev/null | \
  while IFS="$US" read -r win acct; do
    [ -n "$acct" ] || continue
    # match the core signal ("hit your <session|weekly|Opus> limit"); the trailing
    # "· resets …" (when present) is captured for the notification but not required.
    banner=$(tmux -L "$sock" capture-pane -p -S -200 -t "$win" 2>/dev/null \
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
  done
fi

# NB: the PR/CI attention signal (@prci/@pfg per window) moved to
# bin/tmux-pr-refresh.sh (single writer, ~15s cadence) — see #81. The collector
# no longer touches it.

# --- detached-attention escalation (every run) ---
# A window stuck on 'needs' >FLEET_ESCALATE_AFTER sec while NO tmux client is
# attached → run FLEET_NOTIFY_CMD (fleet.conf) with the message as $1 — plug in
# any notifier (Slack webhook curl, WeCom bot, ntfy, …). One ping per episode.
# Per-fleet-socket now (issue #159): the "no client attached" gate is evaluated
# PER FLEET (its own server), so an unwatched fleet still escalates even while
# you're attached to a DIFFERENT fleet — strictly better than the old shared
# server, where any attached client suppressed escalation for every fleet.
ESC_AFTER="${FLEET_ESCALATE_AFTER:-300}"
if [ -n "${FLEET_NOTIFY_CMD:-}" ]; then
  nowts=$(now)
  for sock in $SOCKETS; do
  [ -z "$(tmux -L "$sock" list-clients 2>/dev/null)" ] || continue   # someone's watching THIS fleet → skip it
  tmux -L "$sock" list-windows -a -F "#{session_name}:#{window_index}${US}#{window_name}${US}#{@claude_state}${US}#{@claude_state_ts}${US}#{@escalated}${US}#{window_id}" 2>/dev/null | \
  while IFS="$US" read -r win name st ts esc wid; do
    [ "$st" = "needs" ] || continue
    case "$ts" in ''|*[!0-9]*) continue;; esac
    [ $(( nowts - ts )) -ge "$ESC_AFTER" ] || continue
    [ "$esc" = "$ts" ] && continue
    sum=$(head -1 "$G/summary_$(fleet_summary_key "$sock" "$wid")" 2>/dev/null | cut -c1-80)
    msg="# session blocked
**${name}** has been waiting for your input for $(( (nowts-ts)/60 ))m (no client attached)${sum:+
> doing: ${sum}}"
    $FLEET_NOTIFY_CMD "$msg" >/dev/null 2>&1 \
      && tmux -L "$sock" set-window-option -t "$win" @escalated "$ts" 2>/dev/null
  done
  done
fi

# --- crash-recovery snapshot (every run) ---
# Durably record the live fleet layout (which fleets, work windows, worktrees,
# Claude session ids) so fleet-restore.sh can rebuild every fleet and
# `claude --resume` every session after a tmux-server-wide crash. Cheap; never
# fatal to the collector.
bash "$BIN/fleet-restore.sh" --snapshot >/dev/null 2>&1 || true
exit 0
