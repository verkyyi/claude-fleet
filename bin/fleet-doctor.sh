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
#   claude       the sessions you run + the optional classify hook
#   perl HiRes   soft — dash spinner sub-second frames (degrades to 1s ticks)
#   jq is NOT required standalone: the collector only uses `gh --jq` (built in).
#
# Network: doctor is a HUMAN-run preflight, so it may pay for network reads no
# daemon could afford — `gh` for the base-branch check, and one `git fetch` of a
# single branch for the live-install freshness check (issue #635).
set -u  # POSIX sh: pipefail is bash-only (dash has none)

# --- output helpers (color only on a tty) ---
if [ -t 1 ]; then
  R=$(printf '\033[31m'); G=$(printf '\033[32m'); Y=$(printf '\033[33m')
  B=$(printf '\033[1m'); Z=$(printf '\033[0m')
else
  R=''; G=''; Y=''; B=''; Z=''
fi
fails=0; warns=0

# Where the fleet's durable state lives. fleet-lib.sh defaults this for every bash
# caller, but this doctor is /bin/sh and cannot source it, so it defaults the
# value ITSELF — and every `$FLEET_CONF_DIR` below must read `$conf_dir`, never
# the raw variable. Under `set -u` a raw read is fatal when the variable is unset,
# and it is unset exactly where the doctor is run by hand: the launcher never
# exports it and neither does a login shell. The selftest gate DOES export it
# (bin/run-selftests.sh points it at an empty shadow dir), which is how a raw
# read once shipped green through CI and killed the doctor on both live machines
# at its first use (#759: `line 254: FLEET_CONF_DIR: unbound variable`, every
# later check silently gone). bin/fleet-doctor-conf-dir-selftest.sh pins this.
conf_dir="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"

# The interval-daemon liveness registry (issue #639). POSIX-clean on purpose so
# this /bin/sh doctor can source it, unlike the bash-only fleet-lib.sh.
_dlib="$(dirname "$0")/fleet-daemon-lib.sh"
# shellcheck source=/dev/null
[ -f "$_dlib" ] && . "$_dlib"
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
  else fail fzf "$v — need ≥ 0.45; dash binds use \`transform\` (prefix+g breaks below)"; fi
else
  fail fzf "not found — need ≥ 0.45 for the prefix+g dashboard"
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
  warn claude "not found — the CLI you run per window and the optional classify hook"
fi

# --- fleet quality-of-life commands (optional: repo-shipped /skills) ---
# TWO install paths reach a session with these (issue #611), and the fleet runs
# without either, so a missing set is a warn and never a fail:
#
#   plugin  `/plugin install fleet@claude-fleet` — commands, skills and the hook
#           table together, updated by `/plugin update`. Typed NAMESPACED:
#           `/fleet:fleet-claim`.
#   copy    commands/*.md → ~/.claude/commands/ (the historic path, still
#           supported). Typed bare: `/fleet-claim`.
#
# Each fleet skill carries a `fleet skill · owner:` marker just under its title
# (see commands/README.md); count how many landed in the copy dir. Match only the
# file head so README.md — which merely quotes the marker in prose — isn't
# miscounted as a skill.
cmd_dir="${CLAUDE_COMMANDS_DIR:-$HOME/.claude/commands}"
n=0
if [ -d "$cmd_dir" ]; then
  for f in "$cmd_dir"/*.md; do
    [ -f "$f" ] || continue   # literal *.md when the glob matches nothing
    head -n 3 "$f" 2>/dev/null | grep -qF 'fleet skill · owner:' && n=$((n+1))
  done
fi
# The plugin ships the same commands from its own cache. Doctor is /bin/sh and
# cannot source the bash-only fleet-lib.sh, so this inlines fleet_plugin_installed
# — KEEP IN SYNC with it. The cache path is
# <config>/plugins/cache/<marketplace>/<plugin>/<version>/, and the version dir
# moves on EVERY update, so glob it rather than remembering one.
plug=0
for _d in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/*/fleet/*/; do
  [ -f "$_d/commands/fleet-claim.md" ] && { plug=1; break; }
done
if [ "$n" -gt 0 ] && [ "$plug" = 1 ]; then
  pass commands "$n fleet command(s) in $cmd_dir + the fleet plugin (both resolve; the bare /fleet-claim wins)"
elif [ "$plug" = 1 ]; then
  pass commands "fleet plugin installed — commands are namespaced (/fleet:fleet-claim), updated by /plugin update"
elif [ "$n" -gt 0 ]; then
  pass commands "$n fleet command(s) in $cmd_dir (copy install; \`/plugin install fleet@claude-fleet\` replaces the copying)"
elif [ -d "$cmd_dir" ]; then
  warn commands "no fleet commands in $cmd_dir and no fleet plugin — optional /skills not installed (install the plugin, or copy commands/*.md)"
else
  warn commands "$cmd_dir absent and no fleet plugin — optional fleet /skills not installed"
fi

# --- fleet skills tree (optional: repo-shipped skills/ base skills) ---
# Some fleet commands delegate to a repo-versioned base SKILL under
# ~/.claude/skills/ (installed by /fleet-sync-install's skills pass — see
# docs/INSTALL.md). The load-bearing case is /fleet-handoff, which runs the base
# `handoff` skill VERBATIM: with the command present but the skill missing,
# /fleet-handoff points at a dependency a fresh install never shipped (issue #311).
# So specifically flag that combination — command installed, base skill absent.
# A plugin install ships commands AND skills from the same cache, so the pair can
# never be half-present there — this gap is specific to the copy path.
skills_dir="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
if [ "$plug" = 0 ] && [ -f "$cmd_dir/fleet-handoff.md" ] && [ ! -f "$skills_dir/handoff/SKILL.md" ]; then
  warn skills "/fleet-handoff installed but its base skill $skills_dir/handoff/SKILL.md is missing — handoff will have nothing to delegate to (run /fleet-sync-install to install skills/*)"
fi

# doc-preview is a soft/opt dep on tailscale: it hosts Markdown docs on the
# machine's tailnet, so with the skill installed but tailscale absent it's a
# no-op (share.sh exits "tailscale is not running / logged out"), not a broken
# install. Warn, never fail — the fleet runs fine without it (issue #354).
if [ -f "$skills_dir/doc-preview/SKILL.md" ] && ! command -v tailscale >/dev/null 2>&1; then
  warn skills "doc-preview skill installed but tailscale not on PATH — the skill is a no-op without it (it serves docs over the tailnet); install/enable Tailscale to use it"
fi

# --- live install freshness: is THIS machine's ~/.claude/fleet current? (#635) ---
# The commands/skills checks above answer "is it installed". This answers "is it
# CURRENT", which nothing used to. `/fleet-sync-install` is per-machine and
# manual, so machine #2 goes stale in silence: on 2026-09-14 macmini's live
# install sat 28 commits behind master — no #603 base-branch fix, no #617 quota
# ranking, no #608 matrix — and doctor was green on BOTH boxes. The plugin path
# (#611) fixed this for commands/skills/hooks only; `bin/`, `conf/` and the
# daemons still ride a hand-run `git pull`, and that half is what this measures.
#
# It costs ONE `git fetch` of one branch (~1s). That is fine here — doctor is
# run by a human — and is exactly why the fetching form must never be put on the
# collector's 60s tick (fleet-install-version.sh --no-fetch is the free read).
#
# A machine with no ~/.claude/fleet is not a fault: doctor's other job is
# preflight BEFORE an install exists. Nothing is printed in that case.
iv="$(dirname "$0")/fleet-install-version.sh"
live_dir="${FLEET_LIVE_DIR:-$HOME/.claude/fleet}"
if [ -f "$iv" ] && [ -d "$live_dir" ]; then
  ivout=$(sh "$iv" 2>/dev/null)
  # Parse the human form, not --json: these keys are line-anchored, so a path or
  # a message containing a quote can't shift the fields (doctor has no jq).
  _ivf() { printf '%s\n' "$ivout" | sed -n "s/^$1:  *//p"; }
  iv_verdict=$(_ivf verdict); iv_behind=$(_ivf behind); iv_ahead=$(_ivf ahead)
  iv_trunk=$(_ivf trunk); iv_head=$(_ivf head); iv_note=$(_ivf note); iv_dirty=$(_ivf dirty)
  iv_fix="git -C $live_dir pull --ff-only, then /fleet-sync-install (which also reloads the changed daemons — a bare pull does not)"
  case "$iv_verdict" in
    CURRENT)
      pass install "$live_dir at ${iv_head:-?} — up to date with ${iv_trunk%% *}"
      [ "$iv_dirty" = yes ] && printf '        note: the live install has uncommitted tracked changes — the next fast-forward will refuse.\n'
      ;;
    BEHIND)
      warn install "$live_dir is $iv_behind commit(s) behind ${iv_trunk%% *} — this machine runs old bin/ + daemons while master has moved (the drift nothing used to report, #635); fix: $iv_fix"
      ;;
    AHEAD)
      warn install "$live_dir has $iv_ahead local commit(s) not on ${iv_trunk%% *} — someone edited/tested in place; the next \`pull --ff-only\` will refuse until that is resolved"
      ;;
    DIVERGED)
      warn install "$live_dir has diverged from ${iv_trunk%% *} ($iv_ahead local commit(s), $iv_behind upstream) — \`pull --ff-only\` will refuse; resolve before the next sync"
      ;;
    *)
      warn install "could not tell whether $live_dir is current — reporting unknown, NOT up to date (${iv_note:-no reason given})"
      ;;
  esac
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

# --- panel keys vs the tmux prefix (issues #556/#558) ---
# tmux never delivers its prefix (or prefix2) to a pane, so a panel ⌃-key equal
# to it is dead on the keyboard (⌃a was: the operator's prefix is C-a).
# bin/dash-keymap.sh resolves each panel's bind table against the prefix (the live
# server, else the tmux conf) and remaps a colliding default to its ⌥ twin — the
# fleet-keys.sh shows the real key. Say so here anyway (docs name the defaults),
# and shout when even the fallback is a prefix: that key is unreachable.
km="$(dirname "$0")/dash-keymap.sh"
if [ -f "$km" ]; then
  pfx=$(bash "$km" prefixes 2>/dev/null); pfx="${pfx:-C-b -}"
  p1="${pfx%% *}"; p2="${pfx#* }"
  if [ "$p2" = "-" ]; then p2=""; else p2=" + prefix2 $p2"; fi
  for panel in dash backlog config; do
  coll=$(bash "$km" --panel "$panel" collisions 2>/dev/null)
  if [ -z "$coll" ]; then
    pass keys "no $panel key collides with the tmux prefix ($p1$p2)"
  else
    while read -r act def pname fb; do
      [ -n "$act" ] || continue
      if [ "$fb" = UNREACHABLE ]; then
        warn keys "$panel $def ($act) is your tmux prefix $pname and its ⌥ twin is one too — unreachable from $panel; change prefix2 or the key"
      else
        warn keys "$panel $def ($act) is your tmux prefix $pname — the $panel binds $fb instead (fleet-keys.sh shows it)"
      fi
    done <<EOF
$coll
EOF
  fi
  done
else
  warn keys "bin/dash-keymap.sh missing — panel keys are not checked against the tmux prefix"
fi

# --- multi-account token pool (optional: auto-failover across subscriptions) ---
if [ -d "$conf_dir/handoffs/quota-requests" ]; then
  _failover=$(python3 - "$conf_dir/handoffs/quota-requests" <<'PY'
import json,pathlib,sys
for p in pathlib.Path(sys.argv[1]).glob('*/request.json'):
    try: r=json.loads(p.read_text())
    except (OSError,ValueError): continue
    if r.get('state') not in ('bound','cancelled','recovered'):
        s=r.get('source',{})
        print('%s/%s: %s — %s' % (s.get('session','?'),s.get('window','?'),r.get('state','?'),r.get('detail','')))
PY
)
  if [ -n "$_failover" ]; then warn failover "$_failover (fleet-account.sh failover-status)";
  else pass failover 'no pending subscription cutovers'; fi
fi
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
  # ccquota-driven PRE-EMPTIVE rotation (issue #513): with a hub URL + ccquota on
  # PATH the collector rotates at FLEET_ACCOUNT_CEILING before any banner. Report
  # what the collector would see: rows per pool label (unmapped labels = ccquota
  # names that don't match the fleet's — fix with `ccquota name <uuid> <label>` or
  # CCQUOTA_ACCOUNT=<uuid> in <label>.conf), or why it is running banner-only.
  if [ -n "${CCQUOTA_HUB_URL:-}" ]; then
    # Watch LIVENESS first (issue #551), BEFORE the --refresh below restamps the
    # cache: account.quota.ts is restamped by every fleet-quotawatch tick (even an
    # unreachable hub restamps), so its age says whether the watch is ticking at
    # all. Stale = the 70%/85% pre-emptive rotation is BLIND — that silent
    # fail-open cost a whole 5-hour window on 2026-09-11, so it is a FAIL.
    qst=$(bash "$(dirname "$0")/fleet-quotawatch.sh" --status 2>/dev/null)
    # state <TAB> how long it has held (s) <TAB> consecutive-empty-fetch streak.
    qstate=${qst%%	*}; qrest=${qst#*	}; qage=${qrest%%	*}; qstreak=${qrest#*	}
    case "$qage"    in ''|*[!0-9]*) qage=0 ;; esac
    case "$qstreak" in ''|*[!0-9]*) qstreak=0 ;; esac
    qdur="$((qage/60))m"; [ "$qage" -lt 60 ] && qdur="${qage}s"
    case "$qstate" in
      stale) fail qwatch "quota cache last refreshed $((qage/60))m ago (> FLEET_ACCOUNT_QUOTA_STALE ${FLEET_ACCOUNT_QUOTA_STALE:-600}s) — pre-emptive rotation is BLIND; is com.claude-fleet.quotawatch loaded? (\`launchctl list | grep quotawatch\`; the collector falls back to running the watch first thing each tick once this unit stops ticking, issue #671 — check its heartbeat below)" ;;
      never) warn qwatch "quota cache never written — no fleet-quotawatch tick has run yet (install/kick com.claude-fleet.quotawatch, or run bin/fleet-quotawatch.sh once)" ;;
      blind) fail qwatch "quota cache is FRESH BUT EMPTY — the last $qstreak ccquota reads returned no rows ($qdur, ≥ FLEET_ACCOUNT_QUOTA_BLIND_STREAK ${FLEET_ACCOUNT_QUOTA_BLIND_STREAK:-3}). The watch IS ticking, so nothing here is stale; the 70%/85% pre-emptive rotation simply has nothing to act on, which is the same outage with every dial green (issue #684). Check the hub: \`ccquota budget --account all --json\`, then \`fleet-account.sh quota --refresh\`; the quota line below names any account ccquota cannot read" ;;
      fresh) pass qwatch "quota cache ${qage}s old and non-empty — the pre-emptive watch is ticking AND getting readings (\`fleet-quotawatch.sh --status\`)" ;;
    esac
    # …and whether the ticks that ARE happening finish their work (issue #698).
    # `--status` above answers "is it ticking", which a tick that winds down on
    # budget passes: it restamps the cache and exits 0. What it drops on the way —
    # a fleet not swept, an account not warned — lives in the heartbeat's over= and
    # skipped=, and would otherwise only ever be visible in the launchd log. Same
    # argument as the collector's line below, which #653 added for the same reason.
    qhb="${TMPDIR:-/tmp}/.claude-dash/global/quotawatch.heartbeat"
    if [ -f "$qhb" ]; then
      qhb_get() { sed -n "s/^$1=//p" "$qhb" | head -1; }
      qhb_dur=$(qhb_get dur); qhb_budget=$(qhb_get budget)
      qhb_over=$(qhb_get over); qhb_skipped=$(qhb_get skipped)
      if [ -n "$qhb_skipped" ] || [ -n "$qhb_over" ]; then
        qhb_detail=''
        [ -n "$qhb_over" ]    && qhb_detail="; over budget: $qhb_over"
        [ -n "$qhb_skipped" ] && qhb_detail="$qhb_detail; deferred to the next tick: $qhb_skipped"
        warn qwatch "last quotawatch tick took ${qhb_dur:-?}s against its ${qhb_budget:-?}s budget (FLEET_QUOTAWATCH_TICK_BUDGET)$qhb_detail — it wound down instead of overrunning, which is by design, but a tick that keeps deferring is one whose work no longer fits in 60s"
      fi
    fi
    # --- the per-fleet model-cap probe (issue #706) --------------------------
    # A cap probe that times out is not a slow tick, it is a BLIND fleet: the probe
    # is the only input to model-cap detection, which is the only trigger for
    # fleet-model-switch.sh --capped. And a walled worker fails in the ugliest way
    # there is — a capped turn never fires the Stop hook, so @claude_state stays
    # `working` forever and the sweep keeps deferring its own candidate as
    # "mid-turn". On 2026-09-15 one fleet had timed out on 788 of 1136 ticks, 18 of
    # the last 18, and nothing outside logs/quotawatch.launchd.log ever said so.
    # A single timeout is noise; the STREAK the watch keeps is the verdict.
    #
    # And the record must be CURRENT, not merely bad. A health file outlives the
    # fleet it describes — `fleet-down` removes the session, not this file — so
    # without an age gate a torn-down fleet would leave a doctor line that FAILs
    # forever about something that no longer exists, and the same goes for any
    # window in which the daemon itself is not ticking (which the staleness check
    # above already reports, once, in the right words). That is the #639/#658
    # lesson: a check that can cry wolf is worse than no check, because the next
    # real one gets scrolled past. FLEET_ACCOUNT_QUOTA_STALE is the horizon the
    # rest of this section already uses for "no tick has run".
    for qmf in "${TMPDIR:-/tmp}/.claude-dash/global/quotawatch.modelcap."*; do
      case "$qmf" in *'quotawatch.modelcap.*') continue ;; esac   # an unmatched glob
      [ -f "$qmf" ] || continue
      qmfleet=${qmf##*/quotawatch.modelcap.}
      qmstreak=$(sed -n 's/^streak=//p' "$qmf" | head -1)
      qmstep=$(sed -n 's/^step=//p' "$qmf" | head -1)
      qmlastok=$(sed -n 's/^lastok=//p' "$qmf" | head -1)
      qmat=$(sed -n 's/^at=//p' "$qmf" | head -1)
      case "$qmstreak" in ''|*[!0-9]*) qmstreak=0 ;; esac
      case "$qmlastok" in ''|*[!0-9]*) qmlastok=0 ;; esac
      case "$qmat" in ''|*[!0-9]*) qmat=0 ;; esac
      [ "$qmstreak" -ge "${FLEET_QUOTAWATCH_MODELCAP_STREAK:-3}" ] || continue
      [ $(( $(date +%s) - qmat )) -lt "${FLEET_ACCOUNT_QUOTA_STALE:-600}" ] || continue
      if [ "$qmlastok" -gt 0 ]; then qmago="last completed $(( ( $(date +%s) - qmlastok ) / 60 ))m ago"
      else qmago="it has never completed"; fi
      fail qwatch "$qmfleet: the model-cap probe has timed out $qmstreak ticks running (in step '${qmstep:-?}'; $qmago) — model-cap detection on that fleet is BLIND, so a worker walled on its model will sit at @claude_state=working forever and \`fleet-model-switch.sh --capped\` will never fire for it. The step name says where the budget went; raise FLEET_QUOTAWATCH_PROBE_BUDGET (${FLEET_QUOTAWATCH_PROBE_BUDGET:-20}s) only after reading it, and check \`bash bin/fleet-model-switch.sh --capped --dry-run --session $qmfleet\`"
    done
    if command -v "${FLEET_QUOTA_BIN:-ccquota}" >/dev/null 2>&1; then
      # NAME the binary on the other side of this contract (issue #668). ccquota
      # ships no tagged release (docs/INSTALL.md) — everyone installs it with
      # `go install …@latest`, so the builds DO drift between machines, and the
      # shape FAIL below is precisely the moment a human needs to know which one
      # answered: its advice can only say *"that build is probably newer than this
      # fleet"*, and until now there was no build named anywhere on the line.
      # `ccquota version` is a local print (cmd/ccquota/main.go); a build old
      # enough to predate the subcommand exits non-zero with usage on stderr, and
      # one that printed usage on STDOUT would hand us a sentence — so take one
      # whitespace-free token or nothing. Omitting the version is the graceful
      # path: it must never turn a quota verdict into an error of its own.
      # $qtag is the message subject everywhere below, so ALL FOUR verdicts
      # (PASS / both WARNs / FAIL) carry it, and degrade to today's bare
      # "ccquota" when the version can't be had.
      qver=$("${FLEET_QUOTA_BIN:-ccquota}" version 2>/dev/null | head -1 | tr -d '\r')
      qver=${qver#ccquota }                      # `ccquota <ver>` → <ver>
      case "$qver" in ''|*[[:space:]]*) qver='' ;; esac
      qtag="ccquota"; [ -n "$qver" ] && qtag="ccquota $qver"
      # Two calls on purpose (issue #628): the first FETCHES and is read for its
      # STDERR — quota_parse's only channel for "ccquota cannot read account X"
      # and "I do not understand this payload". Those accounts produce NO row, so
      # the rows alone cannot tell them apart from a label ccquota never knew, and
      # the advice differs. The second is cache-only (no second network hit).
      qdiag=$(bash "$(dirname "$0")/fleet-account.sh" quota --refresh 2>&1 >/dev/null)
      qrows=$(bash "$(dirname "$0")/fleet-account.sh" quota --cached 2>/dev/null); qn=$(printf '%s' "$qrows" | grep -c .)
      qshape=$(printf '%s\n' "$qdiag" | sed -n 's/^fleet-account: ccquota payload shape not recognized for \([^:]*\):.*/\1/p' | tr '\n' ' ')
      qnoread=$(printf '%s\n' "$qdiag" | sed -n 's/^fleet-account: ccquota has no reading for \([^ ]*\) .*/\1/p' | tr '\n' ' ')
      if [ -n "$qshape" ]; then
        # The contract itself broke: ccquota answered, the account is not flagged
        # unreadable, and yet neither window is there. Silence used to turn that
        # into `0% used` — a confident wrong number that never benches and
        # attracts every migrate. RED, not a warn: nobody is rotating on this.
        fail quota "$qtag payload shape not recognized for: ${qshape% } — neither five_hour nor seven_day in an account that is not flagged unavailable; those accounts get NO row (never benched, never a migrate target). That build is probably newer than this fleet — compare \`ccquota budget --account all --json\` with quota_parse in bin/fleet-account.sh"
      elif [ "$qn" -gt 0 ] && [ "$qn" -eq "$n" ]; then
        pass quota "$qtag → hub $CCQUOTA_HUB_URL: $qn/$n pool accounts mapped — pre-emptive rotation at ${FLEET_ACCOUNT_CEILING:-85}% (warn ${FLEET_ACCOUNT_WARN_PCT:-70}%)"
      elif [ -n "$qnoread" ]; then
        # ccquota is explicit about this one (available:false) — expected while a
        # token is fresh or the hub has not seen the account yet. Fail-open, but
        # NAMED: it is invisible to the rotation for as long as it lasts.
        warn quota "$qtag has NO reading for: ${qnoread% } ($qn/$n pool labels have one) — those get no row: never benched at ${FLEET_ACCOUNT_CEILING:-85}%, and never picked as a migrate landing spot. Check \`ccquota budget --account all --json\` (\`available:false\` + its reason)"
      elif [ "$qn" -gt 0 ]; then
        warn quota "$qtag maps only $qn/$n pool labels — unmapped ones rotate banner-only (\`ccquota name\` must equal the fleet label, or set CCQUOTA_ACCOUNT= in <label>.conf)"
      else
        warn quota "$qtag → hub $CCQUOTA_HUB_URL unreachable or unknown — rotation is banner-driven only (fail-open)"
      fi
    else
      warn quota "CCQUOTA_HUB_URL set but ccquota not on PATH — pre-emptive rotation off; install it with \`go install github.com/verkyyi/ccquota/cmd/ccquota@latest\` (needs Go 1.25+; the product is TokenLedger, https://github.com/verkyyi/tokenledger, the binary is still \`ccquota\`)"
    fi
  else
    printf '        note: set CCQUOTA_HUB_URL (fleet.conf) for pre-emptive rotation via ccquota — today it rotates only after a limit banner.\n'
  fi
  if [ "$(uname)" = "Darwin" ]; then
    printf '        note: on macOS token files are the ONLY way to switch accounts (Keychain ignores CLAUDE_CONFIG_DIR).\n'
  fi
fi

# Report an optional daemon whose fleets have it enabled in conf. Turns what used
# to be an unconditional PASS (conf flag only) into a verdict that can actually
# fail — see bin/fleet-daemon-loaded.sh for why (issue #492).
daemon_verdict() {   # $1=tag $2=label $3=pass-msg $4=what-is-lost-when-missing
  tag="$1"; label="$2"; msg="$3"; lost="$4"
  sh "$(dirname "$0")/fleet-daemon-loaded.sh" "$label"
  case $? in
    0) pass "$tag" "$msg" ;;
    1) warn "$tag" "$label is NOT installed — $lost (conf says on, but nothing is running)" ;;
    *) pass "$tag" "$msg (could not verify $label is loaded on this platform)" ;;
  esac
}

# --- per-fleet conf enumeration (shared by the optional-daemon checks below) ---
# $conf_dir is defaulted once at the top of the file (see the note there).

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

# --- autofill dispatcher (optional: auto-spawn `autofill`-labelled backlog, #70/#421) ---
# OFF unless a fleet's conf sets FLEET_AUTOFILL=1. When ON, the dispatch daemon
# auto-spawns eligible `autofill`-labelled backlog issues — which spends LLM tokens —
# so surface the armed fleets and the cost. A missing daemon/config is not a fault
# (opt-in), so this only speaks up when at least one fleet has enabled it.
if [ -d "$conf_dir" ]; then
  armed=0
  # here-doc (not a pipe) so the `while` runs in THIS shell and `armed` survives.
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    # FLEET_AUTOFILL=1, tolerating quotes/spaces (FLEET_AUTOFILL = "1").
    val=$(sed -n 's/^[[:space:]]*FLEET_AUTOFILL[[:space:]]*=[[:space:]]*//p' "$cf" | head -1 | tr -d "\"' 	")
    [ "$val" = 1 ] && armed=$((armed+1))
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
  if [ "$armed" -gt 0 ]; then
    if command -v gh >/dev/null 2>&1; then
      pass autofill "$armed fleet(s) with FLEET_AUTOFILL=1 — dispatcher auto-spawns \`autofill\`-labelled issues (spends LLM tokens)"
    else
      warn autofill "$armed fleet(s) set FLEET_AUTOFILL=1 but gh is missing — the dispatcher can't read the backlog"
    fi
    printf '        note: needs the com.claude-fleet.dispatch daemon installed + the `autofill` label on issues; each auto-spawn opens a real Claude session + PR.\n'
  fi
fi

# --- webhook daemon (optional: fresh ~1s PR/issue/CI status via gh webhook forward) ---
# OFF unless a fleet's conf sets FLEET_WEBHOOK=1 (issue #315). When ON it needs the
# cli/gh-webhook extension (registers the repo webhook against GitHub's hosted relay
# — no public endpoint) + gh + python3 (the localhost handler). Flag an armed fleet
# missing any of them; the extension is the one that's easy to forget.
if [ -d "$conf_dir" ]; then
  wharmed=0
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    val=$(sed -n 's/^[[:space:]]*FLEET_WEBHOOK[[:space:]]*=[[:space:]]*//p' "$cf" | head -1 | tr -d "\"' 	")
    [ "$val" = 1 ] && wharmed=$((wharmed+1))
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
  if [ "$wharmed" -gt 0 ]; then
    if ! command -v gh >/dev/null 2>&1; then
      warn webhook "$wharmed fleet(s) set FLEET_WEBHOOK=1 but gh is missing — nothing to forward"
    elif ! gh extension list 2>/dev/null | grep -q 'gh-webhook'; then
      warn webhook "$wharmed fleet(s) set FLEET_WEBHOOK=1 but the cli/gh-webhook extension is missing — \`gh extension install cli/gh-webhook\`"
    elif ! command -v python3 >/dev/null 2>&1; then
      warn webhook "$wharmed fleet(s) set FLEET_WEBHOOK=1 but python3 is missing — the localhost handler can't run"
    else
      pass webhook "$wharmed fleet(s) with FLEET_WEBHOOK=1 — fresh ~1s PR/issue/CI status (no public endpoint)"
    fi
    printf '        note: needs com.claude-fleet.webhook installed (KeepAlive) + `gh extension install cli/gh-webhook`; polling (collector + pr-refresh) stays the backstop.\n'
  fi
fi

# --- session lifecycle emitter (optional: joins spend to outcome downstream) ---
# OFF unless a fleet's conf sets FLEET_EMIT_URL (issue #625). It is fire-and-forget
# over a bounded spool, which is exactly why it wants a doctor line: a dead endpoint
# is SILENT by design, so the only visible symptom is a spool that stops draining.
# A non-empty queue after the detached drain has had its chance means the endpoint
# is refusing or unreachable — nothing is broken in the fleet, but nothing is
# arriving downstream either, and that would otherwise go unnoticed for weeks.
if [ -d "$conf_dir" ]; then
  earmed=0
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    val=$(sed -n 's/^[[:space:]]*FLEET_EMIT_URL[[:space:]]*=[[:space:]]*//p' "$cf" | head -1 | tr -d "\"' 	")
    [ -n "$val" ] && earmed=$((earmed+1))
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
  if [ "$earmed" -gt 0 ]; then
    qd=$(bash "$(dirname "$0")/fleet-emit.sh" --queue-depth 2>/dev/null | tr -cd '0-9')
    [ -n "$qd" ] || qd=0
    if ! command -v curl >/dev/null 2>&1; then
      warn emit "$earmed fleet(s) set FLEET_EMIT_URL but curl is missing — nothing can be delivered"
    elif [ "$qd" -ge 50 ]; then
      warn emit "$earmed fleet(s) emitting, but $qd events are stuck in the spool — the endpoint is refusing or unreachable"
    elif [ "$qd" -gt 0 ]; then
      pass emit "$earmed fleet(s) emitting session lifecycle facts ($qd in flight)"
    else
      pass emit "$earmed fleet(s) emitting session lifecycle facts (spool drained)"
    fi
    printf '        note: session.start/bind/pr/end only — no prompt content, paths, titles or hostname leave the machine. See docs/EMIT.md.\n'
  fi
fi

# --- cleanup daemon (reaps worktrees + records the resume ledger after merges) ---
# ON by default per fleet (opt out with FLEET_CLEANUP=0). THIS DAEMON NEVER MERGES:
# the worker's /fleet-claim ship+land step merges its own PR (#441); this daemon reaps
# the leftover worktree/window/branch once a PR is final. It merges nothing, so there's no approval-gate warning
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
      daemon_verdict cleanup com.claude-fleet.cleanup \
        "$cleaning fleet(s) with the cleanup daemon on$([ "$optout" -gt 0 ] && printf ' (%s opted out)' "$optout") — worktrees reaped after merges" \
        "merged worktrees are NOT being reaped and landed sessions are NOT being recorded"
    fi
    printf '        note: needs com.claude-fleet.cleanup installed; this daemon merges nothing — the worker lands its own PR (#441) and this cleans up after it.\n'
  fi
fi

# --- ledger-watch daemon (indexes every closed worker session for resume) ------
# ON by default per fleet (opt out with FLEET_LEDGER_WATCH=0). Records a
# `closed-unlanded` history-ledger row when a worker window vanishes without
# landing, so a hand-closed/crashed/abandoned session stays resumable via
# /fleet-history. Pure tmux snapshot + a local ledger append (no gh/LLM) — so no
# tool-dependency warning; it just needs com.claude-fleet.ledger-watch installed.
if [ -d "$conf_dir" ]; then
  watching=0 lw_optout=0
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    val=$(sed -n 's/^[[:space:]]*FLEET_LEDGER_WATCH[[:space:]]*=[[:space:]]*//p' "$cf" | head -1 | tr -d "\"' 	")
    if [ "$val" = 0 ]; then lw_optout=$((lw_optout+1)); else watching=$((watching+1)); fi
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
  if [ "$watching" -gt 0 ]; then
    daemon_verdict ledger com.claude-fleet.ledger-watch \
      "$watching fleet(s) with the ledger-watch daemon on$([ "$lw_optout" -gt 0 ] && printf ' (%s opted out)' "$lw_optout") — every closed session indexed for resume" \
      "closed-unlanded sessions are NOT being indexed (invisible to /fleet-history, unresumable)"
    printf '        note: needs com.claude-fleet.ledger-watch installed; records closed-unlanded sessions into the history ledger (no merge, no reap).\n'
  fi
fi

# --- base-sync daemon (keeps the local base fast-forwarded to the remote) ------
# ON by default per fleet (opt out with FLEET_BASE_SYNC=0). Runs the same ff-only
# base pull the cleaner does, but on the clock — so a merge with no local reap (a
# web/collaborator merge, a direct push, another machine) still advances the base
# and fresh worktrees don't branch off stale code. Pure git fetch + pull --ff-only
# under the shared land lease (no gh/LLM) — so no tool-dependency warning; it just
# needs com.claude-fleet.base-sync installed.
if [ -d "$conf_dir" ]; then
  syncing=0 bs_optout=0
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    val=$(sed -n 's/^[[:space:]]*FLEET_BASE_SYNC[[:space:]]*=[[:space:]]*//p' "$cf" | head -1 | tr -d "\"' 	")
    if [ "$val" = 0 ]; then bs_optout=$((bs_optout+1)); else syncing=$((syncing+1)); fi
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
  if [ "$syncing" -gt 0 ]; then
    daemon_verdict basesync com.claude-fleet.base-sync \
      "$syncing fleet(s) with the base-sync daemon on$([ "$bs_optout" -gt 0 ] && printf ' (%s opted out)' "$bs_optout") — local base fast-forwarded to the remote (merge-independent)" \
      "the local base is NOT being fast-forwarded (new worktrees fork off a stale base)"
    printf '        note: needs com.claude-fleet.base-sync installed; fetches + pulls --ff-only the base under the shared land lease (no merge, no gh).\n'
  fi
fi

# --- quota-watch daemon (issue #551) ---------------------------------------------
# The ccquota pre-emptive rotation has its OWN 60s unit since #551 — the collector
# still runs the watch first thing each tick, so a missing unit degrades the
# cadence to the collector's (and to nothing if the collector is wedged) rather
# than switching the watch off: WARN, not FAIL. Only meaningful with a pool + hub.
if [ -d "$acct_dir" ] && [ -n "${CCQUOTA_HUB_URL:-}" ]; then
  daemon_verdict qwatch com.claude-fleet.quotawatch \
    "com.claude-fleet.quotawatch loaded — 60s pre-emptive rotation tick, independent of the collector" \
    "the quota watch only runs at the top of each collector tick (and not at all while the collector is wedged)"
  printf '        note: bin/fleet-quotawatch.sh — its own 60s unit; heartbeat in global/quotawatch.heartbeat, staleness on the status bar (⚠ quota stale) + above.\n'
fi

# --- collector heartbeat (issue #551) -------------------------------------------
# global/collect.heartbeat: key=value written at every phase boundary of a tick —
# last complete tick's end/dur/phases, or the phase a dying tick was in. A stale
# heartbeat means the dash caches (git/ctx/usage, and pre-#551 the quota watch)
# are not moving: wedged tick (past FLEET_COLLECT_DEADLINE it is killed + superseded
# by the next one) or an unloaded com.claude-fleet.collect.
hb="${TMPDIR:-/tmp}/.claude-dash/global/collect.heartbeat"
if [ -f "$hb" ]; then
  hb_now=$(date +%s)
  hb_get() { sed -n "s/^$1=//p" "$hb" | head -1; }
  hb_end=$(hb_get end); hb_start=$(hb_get start); hb_phase=$(hb_get phase); hb_dur=$(hb_get dur); hb_phases=$(hb_get phases)
  # over= / skipped= (issue #653): which phases spent their own budget, and which
  # the whole-tick budget truncated away. The heartbeat has always carried the
  # per-phase seconds, so "which phase ate the tick" was free information nobody
  # was printing — the last two times the bottleneck moved (git, then usage) it
  # cost a hand investigation to find that out. Say it here instead.
  hb_over=$(hb_get over); hb_skipped=$(hb_get skipped)
  case "$hb_start" in ''|*[!0-9]*) hb_start=0;; esac
  case "$hb_end"   in ''|*[!0-9]*) hb_end=0;;   esac
  hb_slow=$(printf '%s\n' "$hb_phases" | tr ' ' '\n' | sort -t= -k2 -nr | head -1)
  [ -n "$hb_slow" ] && hb_slow="${hb_slow}s"     # "usage=226" reads better as "usage=226s"
  hb_budget=''
  [ -n "$hb_over" ]    && hb_budget="; over budget: $hb_over"
  [ -n "$hb_skipped" ] && hb_budget="$hb_budget; deferred to the next tick: $hb_skipped"
  if [ "$hb_end" -gt 0 ]; then
    hb_age=$((hb_now - hb_end))
    if [ "$hb_age" -gt "${FLEET_COLLECT_DEADLINE:-600}" ]; then
      warn collect "last complete tick ended $((hb_age/60))m ago (took ${hb_dur:-?}s; slowest phase ${hb_slow:-?}$hb_budget) — dash caches are stale; is com.claude-fleet.collect loaded / a tick wedged in \`$hb_phase\`? (the status bar shows \`⚠ dash stale\`; bin/fleet-daemon-watch.sh self-heals, see below)"
    elif [ -n "$hb_skipped" ]; then
      # A truncated tick is working as designed (better a phase waits a round than
      # the whole tick drifting off its interval) but it is the signal that the
      # bottleneck has moved again — so name it rather than passing silently.
      warn collect "last tick ${hb_age}s ago took ${hb_dur:-?}s and hit its ${FLEET_COLLECT_TICK_BUDGET:-120}s budget (FLEET_COLLECT_TICK_BUDGET) — slowest phase ${hb_slow:-?}$hb_budget. Those caches refresh on a later tick (global/collect.phase.cursor resumes there); raise that phase's budget, or find out why it got slow"
    else
      pass collect "last tick ${hb_age}s ago, took ${hb_dur:-?}s (slowest phase ${hb_slow:-?}$hb_budget; tick budget ${FLEET_COLLECT_TICK_BUDGET:-120}s, deadline ${FLEET_COLLECT_DEADLINE:-600}s)"
    fi
  else
    hb_age=$((hb_now - hb_start))
    if [ "$hb_age" -gt "${FLEET_COLLECT_DEADLINE:-600}" ]; then
      warn collect "a tick started $((hb_age/60))m ago is still in phase \`$hb_phase\` and never finished — wedged (the next tick kills + supersedes it past the deadline); see logs/collect.launchd.log"
    else
      pass collect "a tick is running (phase \`$hb_phase\`, ${hb_age}s in)"
    fi
  fi
else
  printf '        note: no collector heartbeat yet (global/collect.heartbeat) — the collector has not completed a tick since #551; run bin/tmux-dash-collect.sh once or check com.claude-fleet.collect.\n'
fi

# --- interval-daemon liveness + self-heal (issues #636, #639) -------------------
# launchd can PEND a StartInterval unit for hours (`state = not running`, `pended
# nondemand spawn = interval`, `last exit code = 0`) — and #639 measured it doing
# that to EVERY interval unit in this user domain at once, every log freezing
# inside the same two minutes while the two KeepAlive units never missed a frame.
# Nothing errors and nothing empties: the collector just serves a two-hour-old
# world, cleanup stops reaping workers, dispatch stops autofilling, base-sync
# stops fast-forwarding the base, issue-bridge stops relaying comments,
# ledger-watch stops indexing closed sessions.
#
# So every unit is checked here, each against its OWN StartInterval rather than
# one absolute number — the failure is usually DEGRADATION, not a stop: the
# measured collector was running once per 7–14 minutes against a 60s interval and
# the old absolute 600s threshold called that `fresh` for hours.
#
# A unit that has NEVER ticked on this host is counted, not warned: that is a
# fresh install, or a unit this machine never had (#492 — ledger-watch was missing
# for months while the doctor printed PASS), and fleet-daemon-loaded.sh above is
# the check that answers "is it installed?".
#
# AND WHY THE PER-UNIT LINES ARE NOT ALWAYS THE RIGHT ANSWER (issue #711). On
# 2026-09-15 this section printed NINE of them at once — every interval unit on
# the host, each line true, the nine together false. The fleet's daemons were
# fine: the whole `gui/501` launchd domain had stopped spawning jobs, which a
# throwaway agent sharing nothing with the fleet proved in 40 seconds by never
# running once (not even its RunAtLoad), and which the SAME install on the SAME
# commit did not do on the other machine. Nine unit-shaped warnings send the
# operator to read plists, ProcessType and load — none of which is the fault, and
# none of which they can fix, because the remedy is to log out or reboot.
#
# So when the stall has the DOMAIN signature — see the two of them below the loop —
# the per-unit lines are held back and bin/fleet-launchd-probe.sh is asked the
# question one level up. A verdict is cached for FLEET_LAUNCHD_PROBE_TTL, so
# repeated doctor runs during an incident pay for the measurement once. Probing
# NEVER happens on a healthy host: the signature gate is checked first, and it
# needs a real stall — or a self-heal already working overtime — to open.
if command -v fleet_daemon_unit_names >/dev/null 2>&1; then
  d_root="$(dirname "$0")/.."
  d_over=0; d_never=0; d_fresh=0; d_names=''; d_lines=''
  for d_u in $(fleet_daemon_unit_names); do
    if [ "$(fleet_daemon_tick_ts "$d_u" "$d_root")" -le 0 ]; then d_never=$((d_never+1)); continue; fi
    d_age=$(fleet_daemon_overdue "$d_u" "$d_root")
    if [ -z "$d_age" ]; then d_fresh=$((d_fresh+1)); continue; fi
    d_over=$((d_over+1))
    d_names="${d_names:+$d_names,}$d_u"
    d_int=$(fleet_daemon_interval "$d_u"); d_thr=$(fleet_daemon_stale_secs "$d_u")
    d_f=$(fleet_daemon_kick_fails "$d_u" "$d_root")
    # A kickstart buys ONE execution, not restored scheduling (#639 measured six
    # units at ZERO runs over 27.8 min right after a hand-kick), so the count of
    # kicks that did NOT bring it back is the number worth reading: past
    # FLEET_DAEMON_RELOAD_AFTER the watch escalates to a real unload + reload, and
    # a unit still stalled after THAT is one only a human can fix.
    d_note=''
    if [ "$d_f" -gt 0 ]; then
      d_note=", self-healed ${d_f}× with no effect"
      [ "$d_f" -ge "$(fleet_daemon_reload_after)" ] && d_note="$d_note — escalated to unload+reload"
    fi
    # HELD, not printed: the domain check below decides whether these nine lines
    # are the finding or the symptom. Newline-joined in one variable — this doctor
    # is /bin/sh, so no arrays, and every message here is single-line by
    # construction.
    d_lines="$d_lines$(printf 'com.claude-fleet.%s last ticked %sm ago — %s× its own %ss StartInterval (alarms past %ss)%s. Nothing is scheduling it; bin/fleet-daemon-watch.sh drives the self-heal from the KeepAlive spinner (history: logs/daemon-kick.log)' \
      "$d_u" "$((d_age/60))" "$((d_age/d_int))" "$d_int" "$d_thr" "$d_note")
"
  done

  # --- domain signature → ask the probe ----------------------------------------
  # TWO signatures, because the obvious one stops working exactly when the
  # self-heal starts:
  #
  #   stalled-together — several units overdue AT ONCE, and at least half of the
  #     ones that have ever ticked here. One stalled unit is that unit's problem;
  #     eight of nine is not a coincidence. This is the shape #711 was filed from.
  #
  #   healed-together — several units KICKED inside the last hour. Each kick buys
  #     one execution, so a kicked unit reads fresh again for a whole interval and
  #     the first signature collapses to one or two units. Measured on the wedged
  #     host while the kicks were running: 1 overdue, 9 kicked in the previous two
  #     minutes, all nine logging the same `kick → stale → kick` cycle. Without
  #     this second test the doctor would go quiet on a machine whose every daemon
  #     is running at its self-heal cooldown instead of its StartInterval — the
  #     WORSE state, because nothing on screen says so.
  d_seen=$((d_over + d_fresh))
  d_domain=''
  d_probe="$(dirname "$0")/fleet-launchd-probe.sh"
  d_min="${FLEET_DAEMON_DOMAIN_MIN:-3}"
  case "$d_min" in ''|*[!0-9]*) d_min=3 ;; esac
  d_kicked=$(fleet_daemon_kicked_recently "$d_root" "${FLEET_DAEMON_DOMAIN_KICK_WINDOW:-3600}")
  d_sig=''
  if [ "$d_over" -ge "$d_min" ] && [ "$((d_over * 2))" -ge "$d_seen" ]; then
    d_sig="$d_over interval units are stalled together"
  elif [ "$d_kicked" -ge "$d_min" ]; then
    d_sig="$d_kicked interval units are only ticking because the self-heal kicks them"
  fi
  if [ -n "$d_sig" ] && [ -f "$d_probe" ]; then
    d_domain=$(fleet_daemon_probe_verdict "$d_root")
    if [ -z "$d_domain" ] && [ "${FLEET_LAUNCHD_PROBE:-1}" != 0 ] && command -v launchctl >/dev/null 2>&1; then
      printf '        note: %s — measuring whether launchd still spawns anything (~%ss)…\n' \
        "$d_sig" "${FLEET_LAUNCHD_PROBE_WINDOW:-40}"
      bash "$d_probe" --quiet >/dev/null 2>&1
      d_domain=$(fleet_daemon_probe_verdict "$d_root")
    fi
  fi

  case "$d_domain" in
    no-spawn|no-interval)
      # ONE line instead of $d_over. The units are listed, not warned about: they
      # are the symptom, and naming them keeps the old information without
      # reinstating the wrong diagnosis.
      if [ "$d_domain" = no-spawn ]; then
        d_what="spawns NOTHING automatically — a throwaway agent bootstrapped beside the fleet's never ran once, not even its RunAtLoad"
      else
        d_what="ran a throwaway agent at load but NEVER on its StartInterval — interval scheduling is pended domain-wide"
      fi
      # Say which of the two signatures brought us here. With the self-heal
      # working, `$d_over` is routinely 0 or 1 and the fleet is STILL crippled —
      # so a message written only for the stalled-together case would read as
      # though nothing much were wrong.
      d_who=''
      [ "$d_over" -gt 0 ] && d_who="$d_over interval unit(s) ($d_names) are stalled for that reason, and their plists/scripts are not the fault"
      if [ "$d_kicked" -ge "$d_min" ]; then
        d_who="${d_who:+$d_who; }$d_kicked unit(s) were kicked in the last hour, i.e. anything that does NOT read stale is ticking at its self-heal cooldown rather than its own StartInterval"
      fi
      [ -n "$d_who" ] || d_who="no unit is stale yet, but nothing here is being scheduled either"
      warn launchd "the gui/$(id -u) launchd domain $d_what. This is MACHINE state, not fleet state: $d_who. Nothing in the fleet can fix it — log out and back in, or reboot. Until then the self-heal's kicks are the only thing running these daemons (\`launchctl kickstart\` is an explicit command, so it bypasses the stuck spawn path). Re-measure: bin/fleet-launchd-probe.sh"
      d_pa=$(fleet_daemon_probe_age "$d_root")
      printf '        note: verdict `%s` measured %ss ago by bin/fleet-launchd-probe.sh (cached for %ss; --cached reads it without re-probing).\n' \
        "$d_domain" "${d_pa:-?}" "${FLEET_LAUNCHD_PROBE_TTL:-900}"
      ;;
    *)
      # Either the stall is not domain-shaped, or the probe says the domain is
      # fine (so these units really are individually stuck), or nothing could be
      # measured. All three want the per-unit detail — an UNMEASURED domain must
      # never be reported as a healthy one.
      # A here-doc, NOT a pipe: a `while` on the right of `|` runs in a subshell,
      # where every warn() would print correctly and increment a copy of $warns
      # that dies with it — the run would end "all good" under nine warnings.
      while IFS= read -r d_l; do
        [ -n "$d_l" ] && warn daemons "$d_l"
      done <<EOF
$d_lines
EOF
      if [ -n "$d_sig" ]; then
        printf '        note: %s — that is the DOMAIN-stall signature (#711), not a per-unit one. Before reading any plist, run bin/fleet-launchd-probe.sh: it settles machine-vs-fleet in ~%ss.\n' \
          "$d_sig" "${FLEET_LAUNCHD_PROBE_WINDOW:-40}"
      fi
      ;;
  esac

  # A green PASS under a red domain would be the same lie in the other direction:
  # with the self-heal keeping every unit inside its staleness window, "10 units
  # ticking" is TRUE and completely misleading — they are ticking once per
  # cooldown, not once per StartInterval.
  if [ "$d_over" = 0 ] && [ "$d_domain" != no-spawn ] && [ "$d_domain" != no-interval ]; then
    d_note=''
    # "Never seen" is not a complaint — see the note above — but it IS the number
    # that tells you whether this host is running the daemons you think it is.
    [ "$d_never" -gt 0 ] && d_note=" ($d_never never seen on this host)"
    pass daemons "$d_fresh interval unit(s) ticking inside ${FLEET_DAEMON_STALE_MULT:-5}× their own StartInterval$d_note"
  fi
  # A kick is not a problem solved: it is evidence a daemon stalled, so say so for
  # as long as the stamp is worth reading and point at the whole history.
  d_kick=$(fleet_daemon_recent_kick "$d_root")
  if [ -n "$d_kick" ]; then
    printf '        note: daemon self-heal last kicked a unit %sm ago — it had stopped being scheduled; per-unit history in logs/daemon-kick.log.\n' \
      "$(( d_kick / 60 ))"
  fi
fi

# --- machine load + orphaned runaways (issue #697) ------------------------------
# The blind spot #697 was filed about. On 2026-09-15 this screen printed a steady
# "1 warn" while the machine sat at load 108 with eight leaked PPID=1 CPU burners
# on it — `ps` and `uptime` were themselves timing out, both daemons were wedged,
# and the doctor had no line that could say any of it. Every other check here asks
# "is the fleet installed correctly"; this one asks "is the machine it runs on
# still usable", which is a different question and was nobody's.
#
# Severity is WARN, never FAIL, on purpose: the exit status gates an install
# (`sh fleet-doctor.sh && …`) and a runaway is a transient condition, not a
# missing dependency — failing here would block an install over something that
# clears on its own. What it must not be is SILENT.
mcores=$( { sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null; } \
          | head -1 | awk '{ n=$1+0; print (n>0 ? n : 1) }' )
mload=$( { sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' || awk '{print $1}' /proc/loadavg 2>/dev/null; } \
         | head -1 | awk '{ if (NF) printf "%.2f", $1+0 }' )
mper=$(awk -v l="${mload:-0}" -v c="$mcores" 'BEGIN{ printf "%.2f", (c>0 ? l/c : l) }')
mwarn="${FLEET_LOAD_WARN_PER_CORE:-4}"
# The orphan scan lives in the daemon that acts on it, so the doctor and the
# watchdog can never disagree about what counts as a runaway.
_dg="$(dirname "$0")/fleet-diskguard.sh"
morph=''
[ -f "$_dg" ] && morph="$(bash "$_dg" --orphans 2>/dev/null)"
# awk, not `grep -c` (issue #709): `grep -c` on no match prints `0` AND exits 1,
# so the `|| echo 0` this was written with fired on top of grep's own output and
# glued the two into `0\n0` — which `[ "$morphn" -gt 0 ]` below then rejected with
# `integer expression expected` on stderr of every HEALTHY run. The verdict
# survived by luck (the error made the `elif` false, and false was the right
# answer when there are no orphans), so only stderr ever showed it. awk returns a
# single `0` on empty input and exits 0, with no fallback clause to get wrong.
morphn=$(printf '%s' "$morph" | awk 'NF{n++} END{print n+0}')

if [ -z "$mload" ]; then
  # Not a measurement bug to shrug at — "the load average would not come back" is
  # the machine answering the question by refusing to.
  warn machine "could not read the load average — on a healthy box this is instant, so a timeout here is itself the finding (\`uptime\`/\`ps\` were timing out at load 108 in issue #697)"
elif [ "$morphn" -gt 0 ]; then
  mtop=$(printf '%s\n' "$morph" | sort -t"$(printf '\t')" -k2,2nr | head -1)
  mpid=$(printf '%s' "$mtop" | cut -f1); mcpu=$(printf '%s' "$mtop" | cut -f2)
  met=$(printf '%s' "$mtop" | cut -f3)
  # awk's substr, not `cut -c`: an argv can hold multibyte bytes and cut would
  # slice one in half, and the "Illegal byte sequence" that follows would be the
  # only thing the operator ever saw of this line.
  mcmd=$(printf '%s' "$mtop" | cut -f4 | awk '{ print substr($0,1,70) }')
  warn machine "load $mload on $mcores cores (${mper}/core) — and $morphn ORPHANED runaway(s): PPID=1, fleet-fingerprinted, burning CPU with no worktree or pane to reap them. Worst: pid $mpid at ${mcpu}%, up $met — \`${mcmd}…\`. Full list: \`bin/fleet-diskguard.sh --orphans\`; a leaked load experiment stops with \`bin/fleet-loadgen.sh --stop\`; forensics land in \${FLEET_CONF_DIR:-~/.config/claude-fleet}/diskguard/incident-orphan-*.log"
elif awk -v p="$mper" -v w="$mwarn" 'BEGIN{ exit !(p>=w) }'; then
  warn machine "load $mload on $mcores cores = ${mper}/core, at or over the ${mwarn}/core line — every fleet on this box is sharing it. No fleet-fingerprinted orphan is responsible (\`bin/fleet-diskguard.sh --orphans\` is empty), so look at what else is running"
else
  pass machine "load $mload on $mcores cores (${mper}/core), no orphaned runaways"
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

# --- auto-handoff nudge: does the Stop hook SEE the threshold? (issue #561) ---
# FLEET_AUTO_HANDOFF_PCT=60 sat in the global fleet.conf for weeks while the Stop
# hook (bin/set-claude-state.sh) read the knob from its ENVIRONMENT — which nothing
# exports — so the nudge never fired once (#561; the #472 class: a conf key only a
# launcher could see). The hook now resolves it through bin/fleet-hook-conf.sh
# (global conf → per-fleet overlay). Evaluate it HERE the same way, per fleet, and
# compare with what the conf files literally say — so "configured 60, hook sees 0"
# is a WARN on this screen instead of a silent no-op. Probed through a LIVE worker
# pane when the fleet is up ($TMUX + $TMUX_PANE — exactly the hook's inputs, so the
# pane→session→conf hop is exercised too), else resolved by session name.
hc="$(dirname "$0")/fleet-hook-conf.sh"
gconf="$(dirname "$0")/../fleet.conf"
# _conf_val <file> <KEY> → the LAST uncommented assignment's value, quotes/blanks
# stripped ('' if none) — what sourcing the file would leave in KEY.
_conf_val() {
  [ -f "$1" ] || return 0
  sed -n 's/^[[:space:]]*'"$2"'[[:space:]]*=[[:space:]]*\([^#]*\).*/\1/p' "$1" | tail -1 | tr -d "\"' 	"
}
if [ ! -f "$hc" ]; then
  warn handoff "bin/fleet-hook-conf.sh missing — the Stop hook cannot read FLEET_AUTO_HANDOFF_PCT from the conf, so the auto-handoff nudge is inert (#561); run /fleet-sync-install"
elif [ -d "$conf_dir" ]; then
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    case "$cf" in */fleets/*/conf) sess=${cf%/conf}; sess=${sess##*/} ;; *) sess=$(basename "$cf" .conf) ;; esac
    # what the operator SET: the per-fleet line, else the global one, else off.
    want=$(_conf_val "$cf" FLEET_AUTO_HANDOFF_PCT)
    [ -n "$want" ] || want=$(_conf_val "$gconf" FLEET_AUTO_HANDOFF_PCT)
    case "$want" in ''|*[!0-9]*) want=0 ;; esac
    # what the HOOK SEES: the same resolver the hook runs.
    via="session name (fleet not running)"
    kv=$(bash "$hc" --session "$sess" FLEET_AUTO_HANDOFF_PCT FLEET_HANDOFF_DEFER_SECS 2>/dev/null)
    sock=$(tmux -L "$sess" display-message -p '#{socket_path}' 2>/dev/null)
    if [ -n "$sock" ]; then
      # any pane the nudge applies to: an issue-bound worker (@issue) or a scratch (@raw)
      pane=$(tmux -L "$sess" list-panes -s -t "$sess" -F '#{pane_id} i=#{@issue} r=#{@raw}' 2>/dev/null \
             | awk '$2!="i=" || $3=="r=1" {print $1; exit}')
      if [ -n "$pane" ]; then
        kv=$(TMUX="$sock,0,0" TMUX_PANE="$pane" bash "$hc" FLEET_AUTO_HANDOFF_PCT FLEET_HANDOFF_DEFER_SECS 2>/dev/null)
        via="live pane $pane"
      else
        via="session name (fleet up, no worker/scratch pane to probe)"
      fi
    fi
    sees=$(printf '%s\n' "$kv" | sed -n 1p)
    # the operator-typing hold (issue #571) rides the same resolver: unset ⇒ 30s, 0 ⇒ off
    dsees=$(printf '%s\n' "$kv" | sed -n 2p)
    case "$sees" in ''|*[!0-9]*) sees=0 ;; esac
    case "$dsees" in ''|*[!0-9]*) dsees=30 ;; esac
    if [ "$dsees" -gt 0 ]; then defer="defer ${dsees}s"; else defer="defer off"; fi
    if [ "$want" -gt 0 ] && [ "$sees" -eq "$want" ]; then
      pass handoff "$sess: auto-handoff at ${want}% (hook sees $sees via $via) · $defer while the operator types at the pane"
    elif [ "$want" -gt 0 ]; then
      warn handoff "$sess: conf says FLEET_AUTO_HANDOFF_PCT=$want but the Stop hook sees $sees via $via — nudge inert (#561); check bin/fleet-lib.sh + the fleet.conf beside bin/"
    else
      pass handoff "$sess: auto-handoff OFF (FLEET_AUTO_HANDOFF_PCT unset/0; hook sees $sees)"
    fi
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
fi

# --- the floor under auto-handoff: spinner alive + the timeout invariant (#677) ---
# /fleet-handoff's auto-cycle waits for @claude_state to leave `working` and ABORTS
# WITHOUT CLEARING if it never does. For the case that matters most — a turn that
# emitted no Stop hook at all (a model cap #580, a crash) — the ONLY thing that can
# ever open that gate is the spinner's stuck-working demotion (#101). So auto-handoff
# rests on two things nobody was checking: that the demoter is RUNNING, and that it
# lands before the cycle gives up (FLEET_STUCK_WORKING_SECS + 2 sweeps < the wait-idle
# ceiling). Shipped, the margin was 40s across two files that had never heard of each
# other. Both failures are SILENT — an overnight loop just fills its context and stops
# — which is exactly the shape that belongs on this screen.
hbf="$(dirname "$0")/../logs/spinner.heartbeat"
inv="$(dirname "$0")/fleet-handoff-invariant.sh"
hb_age=''
if [ -f "$hbf" ]; then
  hb=$(cat "$hbf" 2>/dev/null)
  case "$hb" in ''|*[!0-9]*) ;; *) hb_age=$(( $(date +%s 2>/dev/null || echo 0) - hb )) ;; esac
fi
# Cadence is ~20-30s: HB_CHECK_SECS is converted to a FRAME count, so like every
# other throttle in that loop it tracks what a frame actually costs (measured 27s on
# a live fleet), and a busy machine stretches it further (#653). The spinner keeps
# stamping while no fleet is up, so silence is never just "nothing to do". 180s is
# therefore ~6 missed writes at nominal cadence — a stopped or wedged loop, not a
# slow one — and deliberately loose: a false "your demoter is dead" on this screen
# would send the operator chasing the wrong thing.
if [ -z "$hb_age" ]; then
  if sh "$(dirname "$0")/fleet-daemon-loaded.sh" com.claude-fleet.spinner 2>/dev/null; then
    warn handoff "com.claude-fleet.spinner is loaded but stamps no heartbeat — an install predating #677; run /fleet-sync-install, then \`launchctl kickstart -k gui/\$UID/com.claude-fleet.spinner\`"
  else
    warn handoff "no spinner heartbeat and com.claude-fleet.spinner is not loaded — nothing demotes a window pinned at \`working\` by a turn that never emitted Stop (#580), so auto-handoff can only ever time out (#101/#677)"
  fi
elif [ "$hb_age" -gt 180 ]; then
  warn handoff "spinner heartbeat is ${hb_age}s old (stamps every ~20-30s) — the stuck-working demoter is stopped or wedged, so auto-handoff has no floor under it (#677); check logs/spinner.launchd.log"
else
  pass handoff "stuck-working demoter alive (heartbeat ${hb_age}s ago)"
fi
# The invariant itself, per fleet — FLEET_HANDOFF_IDLE_TIMEOUT takes a per-fleet
# overlay (FLEET_STUCK_WORKING_SECS is global-only: one spinner serves the machine).
if [ -x "$inv" ]; then
  _inv_line() {
    _s="$1"; _lbl="$2"
    _out=$(sh "$inv" ${_s:+--session "$_s"} --oneline 2>&1); _rc=$?
    case "$_rc" in
      0) pass handoff "$_lbl$_out" ;;
      1) warn handoff "$_lbl$_out" ;;
      *) warn handoff "$_lbl could not evaluate the handoff timeout invariant — $_out (#677)" ;;
    esac
  }
  _any=0
  if [ -d "$conf_dir" ]; then
    while IFS= read -r cf; do
      [ -n "$cf" ] || continue
      case "$cf" in */fleets/*/conf) sess=${cf%/conf}; sess=${sess##*/} ;; *) sess=$(basename "$cf" .conf) ;; esac
      _any=1; _inv_line "$sess" "$sess: "
    done <<EOF
$(_fleet_confs "$conf_dir")
EOF
  fi
  [ "$_any" = 0 ] && _inv_line '' ''
fi

# --- project trust: will a spawned worker stop at "trust this folder?" (issue #563) ---
# Claude Code keys its per-directory trust on the resolved project root — a linked
# worktree resolves to its MAIN checkout — with an exact lookup in ~/.claude.json
# (`projects[<root>].hasTrustDialogAccepted === true`). So the ONE entry a fleet
# needs is FLEET_MAIN's; with it missing/false every dispatched worker parks on the
# dialog with nobody to answer (macmini, 2026-09-12: 7+ minutes, slot "filled",
# nothing logged). The launcher pre-trusts at spawn since #563, but a live install
# that predates it, or an opted-out fleet (FLEET_PRETRUST=0), still stalls — say so
# here, with the one-line fix. Read the conf the way sourcing does (a subshell), so
# a `$HOME/…` FLEET_MAIN expands; the verdict comes from bin/fleet-trust.sh itself.
tr_sh="$(dirname "$0")/fleet-trust.sh"
if [ ! -f "$tr_sh" ]; then
  warn trust "bin/fleet-trust.sh missing — spawns cannot pre-trust the checkout; a worker may park on Claude Code's \"trust this folder?\" dialog (#563); run /fleet-sync-install"
elif [ -d "$conf_dir" ]; then
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    case "$cf" in */fleets/*/conf) sess=${cf%/conf}; sess=${sess##*/} ;; *) sess=$(basename "$cf" .conf) ;; esac
    main=$(sh -c '. "$1" 2>/dev/null; printf %s "${FLEET_MAIN:-}"' _ "$cf")
    [ -n "$main" ] || { warn trust "$sess: conf has no FLEET_MAIN — cannot check checkout trust"; continue; }
    pretrust=$(_conf_val "$cf" FLEET_PRETRUST); [ -n "$pretrust" ] || pretrust=$(_conf_val "$gconf" FLEET_PRETRUST)
    verdict=$(sh "$tr_sh" check "$main" 2>/dev/null)
    case "$verdict" in
      trusted)
        pass trust "$sess: $main is trusted in $(sh "$tr_sh" file) — workers skip the trust dialog" ;;
      untrusted)
        if [ "$pretrust" = 0 ]; then
          warn trust "$sess: $main is NOT trusted and FLEET_PRETRUST=0 — every spawned worker will hang at Claude Code's \"trust this folder?\" dialog; fix: sh $(dirname "$0")/fleet-trust.sh grant --main '$main'"
        else
          warn trust "$sess: $main is NOT trusted in $(sh "$tr_sh" file) — a worker spawned by a pre-#563 launcher hangs at the \"trust this folder?\" dialog; the current launcher pre-trusts at spawn; fix now: sh $(dirname "$0")/fleet-trust.sh grant --main '$main'"
        fi ;;
      *)
        if [ ! -d "$main" ]; then
          warn trust "$sess: FLEET_MAIN $main does not exist — nothing to trust (and nothing to spawn into)"
        elif ! command -v python3 >/dev/null 2>&1; then
          warn trust "$sess: cannot read $(sh "$tr_sh" file) without python3 — trust unknown; pre-trust at spawn is also inert"
        else
          printf '        note: %s: no %s yet (claude has never run here?) — the first spawn creates it with %s trusted.\n' "$sess" "$(sh "$tr_sh" file)" "$main"
        fi ;;
    esac
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
fi

# --- base branch: does each fleet's conf point at the repo's REAL trunk? (#603) ---
# FLEET_BASE_BRANCH is what every worker branches from and opens its PR against.
# When it is wrong, nothing looks broken — workers claim, branch, push, CI passes,
# PRs merge — onto a branch nobody ships from, and the trunk silently never moves.
# It is the single hardest fleet fault to notice from the dash, which is exactly why
# it needs a line here (2026-09-12: fleet-ccquota sat on 'dashboard-redesign' for a
# whole round of work while the repo's default was 'main'). fleet-up.sh now refuses
# to choose this quietly; this check catches the confs written before it did, and any
# base that drifted after the repo renamed or re-pointed its default branch.
if command -v gh >/dev/null 2>&1 && [ -d "$conf_dir" ]; then
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    case "$cf" in */fleets/*/conf) sess=${cf%/conf}; sess=${sess##*/} ;; *) sess=$(basename "$cf" .conf) ;; esac
    brepo=$(_conf_val "$cf" FLEET_REPO)
    bbase=$(_conf_val "$cf" FLEET_BASE_BRANCH)
    [ -n "$brepo" ] || { warn base "$sess: conf has no FLEET_REPO — cannot check the base branch"; continue; }
    if [ -z "$bbase" ]; then
      warn base "$sess: conf has no FLEET_BASE_BRANCH — the tooling has to guess this fleet's trunk; set it in $cf"
      continue
    fi
    bdef=$(gh repo view "$brepo" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)
    if [ -z "$bdef" ]; then
      printf '        note: %s: could not read %s default branch (unauthed/offline) — base "%s" left unverified.\n' "$sess" "$brepo" "$bbase"
    elif [ "$bbase" = "$bdef" ]; then
      pass base "$sess: $brepo base \"$bbase\" is the repo default"
    else
      warn base "$sess: base \"$bbase\" is NOT $brepo's default branch (\"$bdef\") — every worker here branches from and merges into \"$bbase\", so the trunk never moves; fix: set FLEET_BASE_BRANCH=\"$bdef\" in $cf (prefix+c), or keep it deliberately if \"$bbase\" really is this fleet's trunk"
    fi
  done <<EOF
$(_fleet_confs "$conf_dir")
EOF
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
