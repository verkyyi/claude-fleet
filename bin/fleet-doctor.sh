#!/bin/sh
# fleet-doctor.sh — preflight for a claude-fleet install. Checks the tools the
# fleet actually depends on and prints a pass/warn/fail line for each, so a
# manual or Linux user can see what's missing before wiring up tmux + daemons.
#
#   pass  — present and new enough
#   warn  — degraded but usable (a feature silently loses quality)
#   fail  — a core piece will not work
#
# Exit status is the number of FAILs (0 = everything at least usable), so it can
# gate an install script: `sh fleet-doctor.sh && ...`.
#
# Dependency truth (keep in sync with README.md#dependencies and docs/INSTALL.md):
#   tmux ≥ 3.2   core — the whole thing is a tmux session
#   fzf  ≥ 0.45  dash — the dashboard binds use `transform` (fzf 0.45+)
#   gh (authed)  backlog + PR/CI map (unauthed → panels silently empty)
#   python3      collector context% + usage caches
#   claude       the sessions you run + the optional classify/summarize hooks
#   perl HiRes   soft — dash spinner sub-second frames (degrades to 1s ticks)
#   jq is NOT required standalone: the collector only uses `gh --jq` (built in).
set -u  # POSIX sh: pipefail is bash-only (dash has none)

# --- output helpers (color only on a tty) ---
if [ -t 1 ]; then
  R=$(printf '\033[31m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m')
  B=$(printf '\033[1m'); Z=$(printf '\033[0m')
else
  R=''; G=''; Y=''; B=''; Z=''
fi
fails=0; warns=0
pass() { printf '  %sPASS%s  %-8s %s\n'  "$G" "$Z" "$1" "$2"; }
warn() { printf '  %sWARN%s  %-8s %s\n'  "$Y" "$Z" "$1" "$2"; warns=$((warns+1)); }
fail() { printf '  %sFAIL%s  %-8s %s\n'  "$R" "$Z" "$1" "$2"; fails=$((fails+1)); }

# vge A B → 0 (true) if dotted-numeric version A >= B (compares up to 3 parts).
vge() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    n=split(a,x,"."); m=split(b,y,".");
    for(i=1;i<=3;i++){ xi=(i<=n?x[i]+0:0); yi=(i<=m?y[i]+0:0);
      if(xi>yi) exit 0; if(xi<yi) exit 1 }
    exit 0 }'
}

printf '%sclaude-fleet doctor%s\n' "$B" "$Z"

# --- tmux ≥ 3.2 (core) ---
if command -v tmux >/dev/null 2>&1; then
  v=$(tmux -V 2>/dev/null | sed -E 's/[^0-9.]//g')
  if [ -n "$v" ] && vge "$v" 3.2; then pass tmux "$v (≥ 3.2)"
  else fail tmux "$v — need ≥ 3.2 (attention layer + status bar)"; fi
else
  fail tmux "not found — the fleet is a tmux session (need ≥ 3.2)"
fi

# --- fzf ≥ 0.45 (dashboard) ---
if command -v fzf >/dev/null 2>&1; then
  v=$(fzf --version 2>/dev/null | awk '{print $1}')
  if [ -n "$v" ] && vge "$v" 0.45; then pass fzf "$v (≥ 0.45)"
  else fail fzf "$v — need ≥ 0.45; dash binds use \`transform\` (prefix+G breaks below)"; fi
else
  fail fzf "not found — need ≥ 0.45 for the prefix+G dashboard"
fi

# --- gh + auth (backlog + PR/CI map) ---
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then pass gh "authed"
  else warn gh "installed but not authed — backlog + PR/CI panels stay empty (\`gh auth login\`)"; fi
  # PR status has its own fast daemon (decoupled from the 60s collector) so
  # CI-green / merged shows within ~15s. Recommended alongside the collector.
  printf '        note: install com.claude-fleet.pr-refresh (~15s, FLEET_PR_REFRESH_INTERVAL) for fast PR/CI status — single writer of prmap + @prci.\n'
else
  fail gh "not found — no backlog, no PR/CI map (\`brew install gh\`)"
fi

# --- python3 (collector context% + usage caches) ---
if command -v python3 >/dev/null 2>&1; then
  pass python3 "$(python3 --version 2>&1 | awk '{print $2}')"
else
  fail python3 "not found — collector context% and usage caches will be empty"
fi

# --- claude CLI (sessions + optional LLM daemons) ---
if command -v claude >/dev/null 2>&1; then
  pass claude "on PATH"
else
  warn claude "not found — the CLI you run per window and the optional classify/summarize hooks"
fi

# --- fleet quality-of-life commands (optional: repo-shipped /skills) ---
# Installed by copying the repo's commands/*.md into the Claude Code user
# commands dir (see docs/INSTALL.md). Optional — the fleet runs without them — so a
# missing set is a warn, never a fail. Each fleet skill carries a `fleet skill ·
# owner:` marker just under its title (see commands/README.md); count how many
# landed. Match only the file head so README.md — which merely quotes the marker
# in prose — isn't miscounted as a skill.
cmd_dir="${CLAUDE_COMMANDS_DIR:-$HOME/.claude/commands}"
if [ -d "$cmd_dir" ]; then
  n=0
  for f in "$cmd_dir"/*.md; do
    [ -f "$f" ] || continue   # literal *.md when the glob matches nothing
    head -n 3 "$f" 2>/dev/null | grep -qF 'fleet skill · owner:' && n=$((n+1))
  done
  if [ "$n" -gt 0 ]; then pass commands "$n fleet command(s) in $cmd_dir"
  else warn commands "no fleet commands in $cmd_dir — optional /skills not installed (copy commands/*.md)"; fi
else
  warn commands "$cmd_dir absent — optional fleet /skills not installed"
fi

# --- config modal (prefix+c: view/edit per-fleet + global fleet config) ---
# The popup (bin/tmux-config.sh) sources its key list + per-key help from
# fleet.conf.example; without that file it can't render. It lives in the repo /
# install root (one dir up from bin/).
ex_root=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
if [ -f "$ex_root/fleet.conf.example" ]; then
  pass config "fleet.conf.example present — prefix+c config modal can render (view/edit keys)"
else
  warn config "fleet.conf.example missing — prefix+c config modal has no key list/help source"
fi

# --- multi-account token pool (optional: auto-failover across subscriptions) ---
# OFF unless token files exist. When ON, each file's contents must be a non-empty
# `claude setup-token` OAuth token, and 0600 so the token isn't world-readable.
acct_dir="${FLEET_ACCOUNTS_DIR:-$HOME/.config/claude-fleet/accounts}"
if [ -d "$acct_dir" ] && [ -n "$(find "$acct_dir" -maxdepth 1 -type f ! -name '.*' ! -name '*~' ! -name '*.conf' 2>/dev/null)" ]; then
  n=0; bad=0
  for f in "$acct_dir"/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in .*|*~|*.conf) continue;; esac   # .conf = per-account settings
    n=$((n+1))
    [ -s "$f" ] || { warn account "empty token file: ${f##*/} (run \`claude setup-token\`)"; bad=$((bad+1)); continue; }
    # ls -ld perms: chars are type + owner(3) + group(3) + other(3);
    # char 5 = group-read, char 8 = other-read. Either 'r' → token is exposed.
    # shellcheck disable=SC2012  # labels are our own [.~-safe] filenames, not arbitrary
    mode=$(ls -ld "$f" 2>/dev/null | cut -c1-10)
    gr=$(printf '%s' "$mode" | cut -c5); ot=$(printf '%s' "$mode" | cut -c8)
    if [ "$gr" = "r" ] || [ "$ot" = "r" ]; then
      warn account "${f##*/} is group/other-readable — \`chmod 600 $f\`"; bad=$((bad+1))
    fi
  done
  # optional per-account settings: <label>.conf with LIMIT_TTL=<N>[smhd]
  for cf in "$acct_dir"/*.conf; do
    [ -f "$cf" ] || continue
    base=${cf##*/}; base=${base%.conf}
    [ -f "$acct_dir/$base" ] || warn account "${cf##*/}: no matching token file '$base'"
    ttl=$(sed -n 's/^[[:space:]]*LIMIT_TTL[[:space:]]*=[[:space:]]*//p' "$cf" | head -1 | tr -d '[:space:]')
    case "$ttl" in
      '') warn account "${cf##*/}: no LIMIT_TTL= line — per-account bench window ignored";;
      *[0-9]s|*[0-9]m|*[0-9]h|*[0-9]d) : ;;
      *[!0-9]*) warn account "${cf##*/}: LIMIT_TTL='$ttl' is not <N>[smhd] or bare seconds"; bad=$((bad+1));;
      *) : ;;
    esac
  done
  [ "$bad" -eq 0 ] && pass account "$n subscription token(s) in ${acct_dir} — auto-failover armed (per-account windows honored)"
  if [ "$(uname)" = "Darwin" ]; then
    printf '        note: on macOS token files are the ONLY way to switch accounts (Keychain ignores CLAUDE_CONFIG_DIR).\n'
  fi
fi

# --- per-fleet conf enumeration (shared by the optional-daemon checks below) ---
conf_dir="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"

# Enumerate configured fleet conf paths, dual-layout (issue #203): the new
# per-fleet layout (fleets/<sess>/conf, #181) preferred, with the legacy flat
# <sess>.conf read only when that session has no new-layout dir. POSIX inline copy
# (doctor is /bin/sh; it can't source the bash-only fleet-lib.sh) — KEEP IN SYNC
# with fleet_each_conf() in bin/fleet-lib.sh. A flat `for cf in "$conf_dir"/*.conf`
# glob matches nothing after the #181 migration, so this under-counts armed fleets.
_fleet_confs() {
  _cd="$1"
  if [ -d "$_cd/fleets" ]; then
    for _d in "$_cd"/fleets/*/; do
      [ -d "$_d" ] || continue
      [ -f "${_d}conf" ] || continue
      printf '%s\n' "${_d}conf"
    done
  fi
  for _c in "$_cd"/*.conf; do
    [ -f "$_c" ] || continue
    _s=$(basename "$_c" .conf)
    [ -f "$_cd/fleets/$_s/conf" ] && continue
    printf '%s\n' "$_c"
  done
}

# --- fleet watcher (optional: zero-token edge-driven steward wake, issue #147) ---
# OFF unless a fleet's conf sets FLEET_WATCH=1. When ON, the watch daemon reads only
# existing caches (no tokens) but each wake makes the steward take a turn, and it can
# only deliver through FLEET_STEWARD_ISSUE — so flag an armed-but-channel-less fleet.
if [ -d "$conf_dir" ]; then
  warmed=0 nochan=0
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    val=$(sed -n 's/^[[:space:]]*FLEET_WATCH[[:space:]]*=[[:space:]]*//p' "$cf" | head -1 | tr -d "\"' 	")
    [ "$val" = 1 ] || continue
    warmed=$((warmed+1))
    sti=$(sed -n 's/^[[:space:]]*FLEET_STEWARD_ISSUE[[:space:]]*=[[:space:]]*//p' "$cf" | head -1 | tr -d "\"' 	")
    [ -n "$sti" ] || nochan=$((nochan+1))
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
  if [ "$warmed" -gt 0 ]; then
    if [ "$nochan" -gt 0 ]; then
      warn watch "$warmed fleet(s) set FLEET_WATCH=1 but $nochan lack FLEET_STEWARD_ISSUE — those wakes have no channel"
    elif command -v gh >/dev/null 2>&1; then
      pass watch "$warmed fleet(s) with FLEET_WATCH=1 — steward woken on edges (zero-token; wakes spend steward tokens)"
    else
      warn watch "$warmed fleet(s) set FLEET_WATCH=1 but gh is missing — the watcher can't post the wake comment"
    fi
    printf '        note: needs com.claude-fleet.watch installed + the issue-bridge (FLEET_ISSUE_BRIDGE=1) to relay wakes into @steward.\n'
  fi
fi

# --- cleanup daemon (reaps worktrees + records the resume ledger after merges) ---
# ON by default per fleet (opt out with FLEET_CLEANUP=0). THE FLEET NEVER MERGES:
# the worker's /fleet-claim ship step arms GitHub auto-merge; this daemon reaps the leftover worktree/window/
# branch once a PR is final. It merges nothing, so there's no approval-gate warning
# — but it needs gh to read PR state, and it needs com.claude-fleet.cleanup installed.
if [ -d "$conf_dir" ]; then
  cleaning=0 optout=0
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    val=$(sed -n 's/^[[:space:]]*FLEET_CLEANUP[[:space:]]*=[[:space:]]*//p' "$cf" | head -1 | tr -d "\"' 	")
    if [ "$val" = 0 ]; then optout=$((optout+1)); else cleaning=$((cleaning+1)); fi
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
  if [ "$cleaning" -gt 0 ]; then
    if ! command -v gh >/dev/null 2>&1; then
      warn cleanup "$cleaning fleet(s) rely on the cleanup daemon but gh is missing — it can't read PR state to reap"
    else
      pass cleanup "$cleaning fleet(s) with the cleanup daemon on$([ "$optout" -gt 0 ] && printf ' (%s opted out)' "$optout") — worktrees reaped after merges"
    fi
    printf '        note: needs com.claude-fleet.cleanup installed; the fleet never merges — the worker ship step arms GitHub auto-merge and this daemon cleans up.\n'
  fi
fi

# --- status line (optional: conf/statusline.sh is jq-gated) ---
# The optional Claude Code status line (conf/statusline.sh, wired install-time
# into settings.json's statusLine — see docs/INSTALL.md step 8b) renders a
# context-% mini-bar + cwd + git branch + model. It exits silently without jq, so
# a wired-but-jq-less status line shows a blank line. Soft-warn (never fail) so the
# operator knows why. Only fires when a statusLine is actually wired to our script
# (match the .sh path so an unrelated custom status line isn't flagged); the
# component is off until then, so silence otherwise.
settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
if [ -f "$settings" ] && grep -q 'statusline\.sh' "$settings" 2>/dev/null; then
  if command -v jq >/dev/null 2>&1; then
    pass statusln "wired + jq present (context-% mini-bar + cwd + branch + model)"
  else
    warn statusln "settings.json wires statusline.sh but jq is missing — it exits silently, so the status line stays blank (\`brew install jq\`)"
  fi
fi

# --- perl Time::HiRes (soft: dash spinner sub-second frames) ---
if command -v perl >/dev/null 2>&1 && perl -MTime::HiRes -e1 >/dev/null 2>&1; then
  pass perl "Time::HiRes present (sub-second spinner)"
else
  warn perl "Time::HiRes missing — dash spinner falls back to whole-second frames"
fi

printf '\n'
if [ "$fails" -gt 0 ]; then
  printf '%s%d fail%s, %d warn — fix the fails before installing.\n' "$R" "$fails" "$Z" "$warns"
elif [ "$warns" -gt 0 ]; then
  printf '%s%d warn%s — usable; the noted features degrade.\n' "$Y" "$warns" "$Z"
else
  printf '%sall good.%s\n' "$G" "$Z"
fi
exit "$fails"
