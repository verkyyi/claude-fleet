#!/bin/bash
# fleet-install-apply.sh — apply one fleet version to THIS login's live install,
# non-interactively (issue #1119, EPIC #1117 C2).
#
# The install has already been moved (fast-forwarded) to --to; this applies
# everything that move implies beyond the files themselves, driven by the diff
# --from..--to so nothing reloads or re-merges unless it actually moved:
#
#   layout    migrate durable state to the per-fleet layout (idempotent, #181)
#   daemons   by diff: a changed plist/unit template is re-rendered and reloaded
#             (macOS bootout+bootstrap; Linux daemon-reload+restart), an added one
#             installed + loaded, a retired one unloaded + removed; a changed
#             KeepAlive spinner script is kickstarted. A script-only change
#             reloads nothing (an interval daemon re-reads its script each tick).
#             A login whose daemons are system LaunchDaemons (`UserName`, label
#             com.claude-fleet.<login>.<x>) keeps that shape; it needs root, and
#             without passwordless sudo the exact commands are printed instead.
#             `--no-daemons` skips this step whole (issue #1214): nothing is
#             rendered, loaded or removed, and its one line says so — for a
#             caller that has already found this login's daemons have nowhere
#             to go yet (fleet-login-bootstrap.sh on launchd with neither a
#             gui/<uid> domain nor system LaunchDaemons) and reports them itself,
#             so the hooks, commands and skills still land instead of the whole
#             apply going PARTIAL on a `launchctl bootstrap` that cannot work.
#   plugin    a plugin install owns commands/skills/hooks: `claude plugin update
#             fleet` replaces the three passes below (unless a copy install sits
#             beside it, in which case both run)
#   hooks     settings-hooks.json changed -> fleet-hooks-merge.py merge
#   settings  every apply that moved -> fleet-hooks-merge.py defaults (issue
#             #1558, folding #1528's keys pass): conf/claude-settings.default.json
#             — the ONE default Claude configuration for every login on a
#             managed machine — filled into ~/.claude/settings.json (its
#             "settings": permissions.defaultMode=bypassPermissions, effort,
#             output style, theme, …; never model / enabledPlugins) and into
#             Claude Code's GLOBAL config ~/.claude.json, or
#             $CLAUDE_CONFIG_DIR/.claude.json (its "globalConfig": today
#             `leftArrowOpensAgents: false` — the only switch for ←'s agents
#             view; settings.json does not reach it). FILL ONLY: a key the login
#             lacks is set, a key it has is never overwritten, and the keys
#             listed in ~/.claude/settings.fleet-override.json are never written
#             at all. Not gated on the file changing: a login whose settings lost
#             a key, or whose .claude.json did not exist yet, gets it on its next
#             sync; a complete login writes nothing. Runs on a plugin install too
#             (a plugin cannot set a settings key). FLEET_KEEP_AGENTS_KEY=1 (env
#             or this login's fleet.settings) leaves leftArrowOpensAgents to the
#             login (= listing it in the override file).
#   commands  install added/changed fleet commands, remove retired ones. Gate
#             (#858): a line that IS the marker — exactly
#             `<!-- fleet skill · owner: <owner> -->` — outside a code fence. A
#             file that merely QUOTES the marker (commands/README.md, the
#             _template.md placeholder `worker|hub|either`) is not a command.
#   skills    mirror added/changed skills/<name>/ dirs, remove retired ones;
#             never clobber a personal (unmarked, divergent) skill
#   codex     mirror the same fleet commands as native Codex skills under each
#             known $CODEX_HOME/skills/<command>/SKILL.md, and mirror repo skills
#             there too. Old Codex homes that do not exist are ignored.
#   agents    every apply that moved -> fleet-agent-defaults.py apply (issue
#             #1559, EPIC #1524 C12): conf/agent-defaults/ is the ONE default
#             package for BOTH agents on a managed login — the user-scope MCP
#             servers context7 / playwright / github / fetch into ~/.claude.json
#             AND every known $CODEX_HOME/config.toml, Codex's approval_policy=
#             never / sandbox_mode=danger-full-access / model_reasoning_effort,
#             and one marker-delimited fleet block in ~/.claude/CLAUDE.md and
#             $CODEX_HOME/AGENTS.md. FILL ONLY (#1558's semantics): a server or
#             key the login has is never rewritten, `model` is never shipped,
#             ~/.config/claude-fleet/agent-overrides.json names what is never
#             written. The github token is read by bin/mcp-github.sh from
#             `gh auth token` at start — no merged file carries one. Skills are
#             the two passes above; this one only counts them.
#   credsep   FLEET_CRED_SEPARATE (issue #1971): converge this login on it —
#             bin/fleet-credsep.sh apply (install / uninstall / refresh the root-
#             owned copy; needs password-less sudo, else one line says what to
#             run). Off and never separated: no line at all.
#   ui        dash launcher / tmux conf changed -> fleet-ui-refresh.sh --all
#   repark    re-park stale sleeping-worker pages on every live fleet (#1064)
#   loopmark  give every Claude window on every live fleet the `@loop` mark its
#             transcript says it should carry (fleet_loop_mark.py sweep, #1370): a
#             session that scheduled a ScheduleWakeup / CronCreate before the
#             PostToolUse hook was synced otherwise reads `done` until its next
#             call. Only adds, never clears; a window that already has one is left.
#   reeval    re-ask every idle window on every live fleet the Stop hook's
#             "still waiting?" question (fleet-wait-reeval.sh, #1376): `done` ↔
#             `looping` + @claude_wait for children / a background job / a Loop.
#             Never touches working/needs.
#   logins    --sync-logins only (issue #1122): bring this machine's OTHER
#             logins to this commit — fleet-sync-logins.sh, the second command
#             /fleet-sync-install used to end with, folded into this one. A
#             login that set FLEET_INSTALL_SYNC=0 is left alone unless
#             --sync-logins=<a,b> names it. Runs only when every step above
#             passed (never push a version this login could not apply), also on
#             the from==to no-op (this login current, the others may not be).
#             Its lines land here under `logins:`; its exit maps to ok, WARN
#             (blocked / needs sudo — nothing changed there, the rows say what
#             to do) or FAIL (a sync failed → PARTIAL). The install-sync daemon
#             never passes it: each login follows `stable` on its own, and a
#             daemon pushing one login's HEAD onto the others would fight that.
#
#   --bundle  (issue #1725, EPIC #1718 C7) the Agent configuration package alone,
#             on an install that is NOT a git checkout — a client-only computer's
#             ~/.claude/fleet without bin/fleet-up.sh (#1804), which the installer (bin/fleet-install.sh)
#             fills from the hub's /install or GitHub's stable. No --from/--to:
#             every file conf/agent-bundle.manifest lists counts as changed (each
#             pass below compares before it writes, so a current login writes
#             nothing), and one the previous package had and this one does not is
#             gone (the list is kept in $FLEET_CONF_DIR/agent-bundle.state). Runs
#             hooks · settings · commands · codex-skills · skills · agents and a
#             `mod` line; layout, conf, daemons, plugin, ui, repark, loopmark,
#             reeval and logins are a node's and do not run. Hooks are wired
#             through the package's bin/fleet-hook-run.sh (fleet-hooks-merge.py
#             --via) and the github / fetch MCP servers point at its bin/
#             (fleet-agent-defaults.py --scripts-root): there is no ~/.claude/fleet
#             here. A login that HAS the full install (~/.claude/fleet,
#             FLEET_INSTALL_NODE_ROOT) is that install's to apply — one line, exit 0.
#
# /fleet-sync-install is: ff -> this (--sync-logins) -> report. The install-sync
# daemon (C3) calls it the same way, minus the flag — one implementation of
# "sync once".
#
# Usage:
#   fleet-install-apply.sh --from <sha> --to <sha> [--dry-run] [--root <dir>]
#                          [--sync-logins[=a,b]] [--no-daemons]
#   fleet-install-apply.sh --bundle [--root <dir>] [--dry-run]
#   fleet-install-apply.sh --is-command <file>    # exit 0 iff the #858 gate passes
#   fleet-install-apply.sh --render-system <unit> [--root <dir>]
#                            # the system-shape plist for <unit> on stdout (#1192):
#                            # Label com.claude-fleet.$FLEET_INSTALL_LOGIN.<unit>,
#                            # UserName that login, __HOME__ = $FLEET_INSTALL_HOME —
#                            # what fleet-login-new.sh --apply installs for a new
#                            # login before it ever signs in
#
#   --from     the rev the install was at before the move
#   --to       the rev it is at now — must resolve to the install's HEAD
#   --dry-run  print what each step WOULD do; change nothing (passed on to the
#              logins step: it plans and prints, syncs nothing)
#   --root     the install (default $FLEET_INSTALL_ROOT, else ~/.claude/fleet)
#   --sync-logins[=a,b]
#              also bring the machine's other logins to --to (all that have
#              auto-update on; `=a,b` exactly those, on or off)
#   --no-daemons
#              skip the daemons step (every other step runs as usual)
#
# Output: one line per step (and one per action inside a step), `<step>: …`, so a
# daemon can log it verbatim. The last line is `apply: ok …` or `apply: PARTIAL …`.
#
# Exit: 0 every step ok · 1 at least one step failed (the lines say which) ·
#       2 usage (bad flag, unknown rev, --to is not HEAD)
#
# Test seams (env): CLAUDE_CONFIG_DIR (~/.claude), FLEET_LAUNCHD_AGENTS_DIR
# (~/Library/LaunchAgents), FLEET_INSTALL_DAEMON_DIR (/Library/LaunchDaemons),
# FLEET_SYSTEMD_USER_DIR (~/.config/systemd/user), FLEET_INSTALL_PLATFORM
# (launchd|systemd|none; default from uname), FLEET_INSTALL_LAUNCHCTL,
# FLEET_INSTALL_SYSTEMCTL, FLEET_INSTALL_SUDO ("sudo -n"), FLEET_INSTALL_CLAUDE
# (claude), FLEET_INSTALL_BREW_PREFIX, FLEET_INSTALL_LOGIN ($USER),
# FLEET_INSTALL_HOME ($HOME — the __HOME__ a template renders to; another
# login's when rendering FOR it, #1192).
set -uo pipefail

SELF="${BASH_SOURCE[0]}"
usage() { sed -n '2,/^set -uo pipefail/p' "$SELF" | sed '$d' | sed 's/^# \{0,1\}//'; }

# --- the #858 marker gate ---------------------------------------------------
# A fleet command carries the marker as a line of its own, outside any fenced
# code block, with a concrete owner word. Substring matching installed
# commands/README.md (which documents the marker) as a `/README` skill.
is_command() {
  [ -f "$1" ] || return 1
  awk '
    { sub(/\r$/, "") }
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    !fence && /^<!-- fleet skill · owner: [a-z][a-z-]* -->$/ { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$1"
}

# --- rendering a daemon template (used by the daemons step and --render-system) --
brew_prefix() {
  if [ -n "${FLEET_INSTALL_BREW_PREFIX:-}" ]; then printf '%s' "$FLEET_INSTALL_BREW_PREFIX"
  else brew --prefix 2>/dev/null || printf '/opt/homebrew'; fi
}
render_tmpl() { # $1 template -> stdout, the gui-shape plist / user unit
  sed -e "s|__HOME__|$RHOME|g" -e "s|__BREW_PREFIX__|$BREW|g" "$1"
}
# system shape: the gui plist + Label com.claude-fleet.<login>.<x>, UserName /
# GroupName, and argv wrapped so the job gets the user's own TMPDIR (a
# LaunchDaemon does not inherit one) — the shape the installed ones carry.
render_system() { # $1 template $2 unit $3 out
  local tmp n i a cmdline=''
  tmp="$3"
  render_tmpl "$1" > "$tmp" || return 1
  n=$(plutil -extract ProgramArguments raw -o - "$tmp" 2>/dev/null) || return 1
  i=0
  while [ "$i" -lt "$n" ]; do
    a=$(plutil -extract "ProgramArguments.$i" raw -o - "$tmp") || return 1
    cmdline="$cmdline '$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'"
    i=$((i + 1))
  done
  plutil -replace Label -string "$(fleet_daemon_label "$2" system "$LOGIN")" "$tmp" \
    && plutil -replace UserName -string "$LOGIN" "$tmp" \
    && plutil -replace GroupName -string staff "$tmp" \
    && plutil -replace ProgramArguments -json '["/bin/sh","-c"]' "$tmp" \
    && plutil -insert ProgramArguments.2 -string "TMPDIR=\"\$(getconf DARWIN_USER_TEMP_DIR)\"; export TMPDIR; exec$cmdline" "$tmp"
}

FROM='' TO='' DRY=0 ROOT="${FLEET_INSTALL_ROOT:-$HOME/.claude/fleet}" SYNCL=0 SYNCL_ONLY='' RENDER='' NODAEMONS=0 BUNDLE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="${2:-}"; shift 2 || { usage >&2; exit 2; } ;;
    --to) TO="${2:-}"; shift 2 || { usage >&2; exit 2; } ;;
    --dry-run) DRY=1; shift ;;
    --sync-logins) SYNCL=1; shift ;;
    --sync-logins=*) SYNCL=1; SYNCL_ONLY="${1#--sync-logins=}"; shift ;;
    --no-daemons) NODAEMONS=1; shift ;;
    --bundle) BUNDLE=1; shift ;;
    --root) ROOT="${2:-}"; shift 2 || { usage >&2; exit 2; } ;;
    --is-command) is_command "${2:-}"; exit $? ;;
    --render-system) RENDER="${2:-}"; shift 2 || { usage >&2; exit 2; } ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'fleet-install-apply: unknown arg %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
LOGIN="${FLEET_INSTALL_LOGIN:-${USER:-$(id -un)}}"
RHOME="${FLEET_INSTALL_HOME:-$HOME}"
# The daemons' launchd SHAPE (gui LaunchAgents / system LaunchDaemons) and each
# unit's label + plist path in it are the lib's one rule (issue #1495), shared with
# fleet-daemon-loaded.sh — so the doctor looks where this script installs.
# A copy of this script without its lib must not render an empty Label quietly.
# shellcheck source=/dev/null
. "$(dirname "$SELF")/fleet-daemon-lib.sh" 2>/dev/null && command -v fleet_daemon_label >/dev/null 2>&1 \
  || { printf 'fleet-install-apply: fleet-daemon-lib.sh (fleet_daemon_label, #1495) is missing beside %s\n' "$SELF" >&2; exit 2; }

# --- --render-system <unit>: one system-shape plist on stdout, nothing else ------
# fleet-login-new.sh --apply (issue #1192) renders a NEW login's daemons from the
# clone it just made for that login, as the admin, and installs them under
# /Library/LaunchDaemons — so the login's own first-login apply finds every unit
# "already current" and never needs root. Needs no HEAD, no diff: just the template.
if [ -n "$RENDER" ]; then
  tmpl="$ROOT/launchd/com.claude-fleet.$RENDER.plist.tmpl"
  [ -f "$tmpl" ] || { printf 'fleet-install-apply: --render-system: no template %s\n' "$tmpl" >&2; exit 2; }
  command -v plutil >/dev/null 2>&1 || { echo 'fleet-install-apply: --render-system needs plutil' >&2; exit 2; }
  BREW=$(brew_prefix)
  tmp=$(mktemp "${TMPDIR:-/tmp}/fleet-render.XXXXXX") || exit 1
  if render_system "$tmpl" "$RENDER" "$tmp"; then cat "$tmp"; rc=0
  else printf 'fleet-install-apply: --render-system %s failed\n' "$RENDER" >&2; rc=1; fi
  rm -f "$tmp"; exit "$rc"
fi

if [ "$BUNDLE" = 0 ]; then
[ -n "$FROM" ] && [ -n "$TO" ] || { echo 'fleet-install-apply: --from and --to are required' >&2; exit 2; }
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
  || { printf 'fleet-install-apply: %s is not a git checkout\n' "$ROOT" >&2; exit 2; }
from=$(git -C "$ROOT" rev-parse --verify --quiet "$FROM^{commit}") \
  || { printf 'fleet-install-apply: --from %s is not a commit in %s\n' "$FROM" "$ROOT" >&2; exit 2; }
to=$(git -C "$ROOT" rev-parse --verify --quiet "$TO^{commit}") \
  || { printf 'fleet-install-apply: --to %s is not a commit in %s\n' "$TO" "$ROOT" >&2; exit 2; }
head=$(git -C "$ROOT" rev-parse HEAD)
[ "$to" = "$head" ] || { printf 'fleet-install-apply: --to %s is not the install HEAD %s — move the install first\n' "${to:0:7}" "${head:0:7}" >&2; exit 2; }
fi

CDIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
AGENTS=$(fleet_daemon_agents_dir)   # the lib's dirs (#1495); the system one is only ever reached through fleet_daemon_plist
SDIR="${FLEET_SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
LAUNCHCTL="${FLEET_INSTALL_LAUNCHCTL:-launchctl}"
SYSTEMCTL="${FLEET_INSTALL_SYSTEMCTL:-systemctl}"
SUDO="${FLEET_INSTALL_SUDO-sudo -n}"
CLAUDE="${FLEET_INSTALL_CLAUDE:-claude}"
PLATFORM="${FLEET_INSTALL_PLATFORM:-}"
if [ -z "$PLATFORM" ]; then
  case "$(uname -s)" in Darwin) PLATFORM=launchd ;; Linux) PLATFORM=systemd ;; *) PLATFORM=none ;; esac
fi

# shielded <path> — <path> (claude.skills, claude.commands, codex.skills …) or an
# ancestor of it (claude, codex) is listed in agent-overrides.json (#1559's
# file): this login's own, never written — the skills / commands / codex-skills
# passes honor it too (issue #1725). No file → never (no python spawned).
OVR="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/agent-overrides.json"
shielded() {
  [ -f "$OVR" ] || return 1
  python3 - "$OVR" "$1" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
keys = {k for k in d if isinstance(k, str)} if isinstance(d, (list, dict)) else set()
p = sys.argv[2].split(".")
sys.exit(0 if any(".".join(p[:i]) in keys for i in range(1, len(p) + 1)) else 1)
PY
}

FAILS=0
DRYFLAG=; [ "$DRY" = 1 ] && DRYFLAG=--dry-run
say() { printf '%s\n' "$*"; }
fail() { FAILS=$((FAILS + 1)); say "$1: FAIL $2"; }
# run <cmd...> — execute, or print under --dry-run
run() { if [ "$DRY" = 1 ]; then say "    would: $*"; return 0; fi; "$@" >/dev/null 2>&1; }

# --- a running EPIC batch? (issue #953) — a warning, never a gate ---------------
# The batch-end /fleet-sync-install is exactly this call, made after the run loop
# cleared its own heartbeat. The install-sync daemon never reaches here under a
# FRESH mark (it defers before the switch, issue #2062), so a fresh mark — any
# batch on this login, one mark each — is a hand sync under a batch that is
# still running: a worker /fleet-claim told not to, or a hub that skipped the
# clear. Say so; the operator decides. An older version's lib has no reader → quiet.
if [ -f "$ROOT/bin/fleet-lib.sh" ] \
   && er=$( . "$ROOT/bin/fleet-lib.sh" >/dev/null 2>&1 && fleet_epic_running 2>/dev/null ); then
  say "epic: WARN a batch is running on this login ($er) — syncing mid-batch swaps the floor under its workers (issue #953); the run loop syncs once, at its closing tick (fleet-epic-heartbeat.sh --clear <N> lifts that batch's mark)"
fi

# --- logins (issue #1122) — the last step, on both paths below ---------------
# Opt-in, and silent when not asked for: the daemon's log stays one line per
# thing that happened. The other logins get THIS install's HEAD (--to); a login
# with FLEET_INSTALL_SYNC=0 is skipped unless --sync-logins=<a,b> names it.
logins_step() {
  [ "$SYNCL" = 1 ] || return 0
  sl="$ROOT/bin/fleet-sync-logins.sh"
  [ -f "$sl" ] || { say 'logins: skip — no fleet-sync-logins.sh in this version'; return 0; }
  if [ "$FAILS" -gt 0 ]; then
    say "logins: skip — $FAILS step(s) failed above; fix them, then: bash $sl"; return 0
  fi
  slargs=(--source "$ROOT")
  [ -n "$SYNCL_ONLY" ] && slargs+=(--logins "$SYNCL_ONLY")
  [ "$DRY" = 1 ] && slargs+=(--dry-run)
  out=$(bash "$sl" ${slargs[@]+"${slargs[@]}"} 2>&1); rc=$?
  printf '%s\n' "$out" | sed '/^$/d; s/^/logins:   /'
  tail_=$(printf '%s\n' "$out" | grep -E '^(other logins on this machine: |no other login)' | tail -1)
  tail_=${tail_#other logins on this machine: }
  case "$rc" in
    0|1) say "logins: ok — ${tail_:-nothing to sync}" ;;   # 1 = --dry-run found drift
    4) say "logins: WARN — ${tail_:-a login is blocked}; a blocked login is untouched (local edits, or newer than this install — its row says which; sync from there, or --force by hand)" ;;
    5) say "logins: WARN — ${tail_:-a login needs sudo}; nothing changed for it — run the printed sudo command as an admin" ;;
    *) # the FAILED rows are the message — the tail line does not count failures
       failed=$(printf '%s\n' "$out" | grep -E '^[^ ]+: FAILED — ' | tr '\n' '|' | sed 's/|$//; s/|/ · /g')
       fail logins "${failed:-$(printf '%s\n' "$out" | tail -1)} (exit $rc — a FAILED row names the backup to restore from)" ;;
  esac
}
finish() {   # $1 — what "apply: ok —" says
  if [ "$FAILS" -gt 0 ]; then
    say "apply: PARTIAL — $FAILS step(s) failed at ${to:0:7} (the FAIL lines above name them)"
    exit 1
  fi
  say "apply: ok — $1"
  exit 0
}

# --- bundle (issue #1725): the package alone, on a client-only install ------------
CLIENT=0
if [ "$BUNDLE" = 1 ]; then
  [ -f "$ROOT/conf/agent-bundle.manifest" ] && [ -f "$ROOT/bin/fleet-agent-bundle.py" ] \
    || { printf 'fleet-install-apply: --bundle: no conf/agent-bundle.manifest + bin/fleet-agent-bundle.py in %s\n' "$ROOT" >&2; exit 2; }
  NODE="${FLEET_INSTALL_NODE_ROOT:-$HOME/.claude/fleet}"
  if [ "$(cd "$ROOT" && pwd -P)" != "$(cd "$NODE" 2>/dev/null && pwd -P)" ]; then
    if [ -f "$NODE/bin/fleet-lib.sh" ]; then
      say "bundle: skip — this login has the full install ($NODE); its sync applies the same package"
      say "apply: ok — nothing to apply from $ROOT"
      exit 0
    fi
    CLIENT=1
  elif [ ! -f "$ROOT/bin/fleet-up.sh" ]; then
    # the install line's base IS ~/.claude/fleet (issue #1804): the part
    # everyone has, no part that runs sessions — wired the client's way
    CLIENT=1
  fi
  BFILES=$(python3 "$ROOT/bin/fleet-agent-bundle.py" files --root "$ROOT") \
    || { echo 'fleet-install-apply: --bundle: fleet-agent-bundle.py files failed' >&2; exit 2; }
  to=$(python3 "$ROOT/bin/fleet-agent-bundle.py" version --root "$ROOT") || exit 2
  BSTATE="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/agent-bundle.state"
  from=$(sed -n '1s/^version //p' "$BSTATE" 2>/dev/null)
  ADDED="$BFILES"
  GONE=$(sed '1d' "$BSTATE" 2>/dev/null | grep -vxF -f <(printf '%s\n' "$BFILES") || true)
  CHANGED=$(printf '%s\n%s\n' "$ADDED" "$GONE" | sed '/^$/d' | sort -u)
  say "range: package ${from:-none}..$to · $(printf '%s\n' "$BFILES" | sed '/^$/d' | wc -l | tr -d ' ') file(s)$([ -n "$GONE" ] && printf ' · %s gone' "$(printf '%s\n' "$GONE" | wc -l | tr -d ' ')")$([ "$DRY" = 1 ] && printf ' (dry-run)')"
else
say "range: ${from:0:7}..${to:0:7}$([ "$DRY" = 1 ] && printf ' (dry-run)')"
if [ "$from" = "$to" ]; then
  # nothing moved for THIS login — the machine's other logins may still be behind it
  logins_step
  finish "install already at ${to:0:7}, nothing to apply"
fi

# name-status with renames: "<S>\t<path>" or "R<n>\t<old>\t<new>". Flattened to
# two lists — ADDED (A/M/C + a rename's new path) and GONE (D + a rename's old
# path) — which is all every step below needs.
NS=$(git -C "$ROOT" diff --name-status -M "$from" "$to")
ADDED=$(printf '%s\n' "$NS" | awk -F'\t' '$1 ~ /^[AMCT]/ {print $2} $1 ~ /^R/ {print $3}')
GONE=$(printf '%s\n' "$NS" | awk -F'\t' '$1 ~ /^D/ {print $2} $1 ~ /^R/ {print $2}')
CHANGED=$(printf '%s\n%s\n' "$ADDED" "$GONE" | sed '/^$/d' | sort -u)
say "range: $(printf '%s\n' "$CHANGED" | sed '/^$/d' | wc -l | tr -d ' ') path(s) changed"
fi
touched() { printf '%s\n' "$CHANGED" | grep -qx "$1"; }
# is_new <path> — present at --to, absent at --from: an upstream addition, which
# this login has never had the chance to install (so "not installed" ≠ opted out)
is_new() { [ -f "$ROOT/$1" ] && ! git -C "$ROOT" cat-file -e "${from}:$1" 2>/dev/null; }

# layout · conf · daemons are a node's: a --bundle apply skips all three.
if [ "$BUNDLE" = 0 ]; then
# --- layout -------------------------------------------------------------------
if [ -f "$ROOT/bin/fleet-migrate-layout.sh" ]; then
  if out=$(bash "$ROOT/bin/fleet-migrate-layout.sh" ${DRYFLAG:+"$DRYFLAG"} 2>&1); then
    say "layout: ok — $(printf '%s\n' "$out" | tail -1 | sed 's/^fleet-migrate-layout: //')"
  else
    fail layout "$(printf '%s\n' "$out" | tail -1)"
  fi
else
  say 'layout: skip — no migrator in this version'
fi

# --- conf (issue #1623): the machine's ONE config file ------------------------------
# Folds the install's fleet.conf, fleet.settings, the fleet conf, shell.conf and
# hub.json's url into $FLEET_CONF_DIR/fleet.conf, each old file kept as .bak.
# Idempotent: a machine already on one file says so and changes nothing.
# FIRST every fleet's identity is frozen (issue #1936): fleet_uuid writes
# fleets/<sess>/identity from today's repo + checkout, so whatever this pass — or
# a later one — does to FLEET_REPO / FLEET_MAIN, the fleet's UUID stays put.
if [ -z "$DRYFLAG" ] && [ -f "$ROOT/bin/fleet-lib.sh" ]; then
  frozen=$( . "$ROOT/bin/fleet-lib.sh" >/dev/null 2>&1 || exit 0
            n=0
            while IFS=$'\t' read -r s _c; do
              [ -n "$s" ] || continue
              [ -f "$(fleet_identity_file "$s")" ] && continue
              fleet_uuid "$s" >/dev/null 2>&1 && n=$((n + 1))
            done <<EOF
$(fleet_each_conf)
EOF
            printf '%s' "$n" )
  [ "${frozen:-0}" = 0 ] || say "conf: froze the identity of $frozen fleet(s)"
fi
if [ -f "$ROOT/bin/fleet-conf.sh" ]; then
  if out=$(bash "$ROOT/bin/fleet-conf.sh" migrate ${DRYFLAG:+"$DRYFLAG"} 2>&1); then
    say "conf: ok — $(printf '%s\n' "$out" | grep -v '^  |' | tail -1 | sed 's/^fleet-conf: //')"
  else
    fail conf "$(printf '%s\n' "$out" | tail -1)"
  fi
else
  say 'conf: skip — no fleet-conf.sh in this version'
fi

# --- daemons ------------------------------------------------------------------
same_plist() { # semantic equality — the installed file may be binary or reformatted
  [ -f "$2" ] || return 1
  if command -v plutil >/dev/null 2>&1; then
    cmp -s <(plutil -convert xml1 -o - "$1" 2>/dev/null) <(plutil -convert xml1 -o - "$2" 2>/dev/null)
  else cmp -s "$1" "$2"; fi
}

daemons_launchd() {
  local units shape tmpl u label dst dom pre tmp acted=0 sudo_ok=1 need_root=''
  units=$(printf '%s\n' "$CHANGED" | sed -n 's#^launchd/com\.claude-fleet\.\(.*\)\.plist\.tmpl$#\1#p' | sort -u)
  # shape: this login's installed daemons decide — gui LaunchAgents, or system
  # LaunchDaemons carrying UserName (a guest login), gui when neither exists
  # (fleet_daemon_shape, the rule fleet-daemon-loaded.sh reads by too, #1495).
  shape=$(fleet_daemon_shape "$LOGIN")
  if [ "$shape" = system ]; then
    { [ -z "$SUDO" ] || $SUDO true >/dev/null 2>&1; } || sudo_ok=0
  fi
  local spin=0
  touched bin/tmux-spinner.sh && spin=1
  if [ -z "$units" ] && [ "$spin" = 0 ]; then say 'daemons: ok — no daemon change, no reload needed'; return; fi
  if [ "$shape" = system ] && ! command -v plutil >/dev/null 2>&1; then
    fail daemons "system LaunchDaemons need plutil to render — not found"; return
  fi
  for u in $units; do
    tmpl="$ROOT/launchd/com.claude-fleet.$u.plist.tmpl"
    label=$(fleet_daemon_label "$u" "$shape" "$LOGIN"); dst=$(fleet_daemon_plist "$u" "$shape" "$LOGIN")
    dom=$(fleet_daemon_domain "$shape"); pre=''; [ "$shape" = system ] && pre="$SUDO"
    if [ ! -f "$tmpl" ]; then                                    # retired
      [ -f "$dst" ] || { say "daemons: skip $u — retired, never installed"; continue; }
      if [ "$shape" = system ] && [ "$sudo_ok" = 0 ]; then
        need_root="$need_root; sudo launchctl bootout system/$label; sudo rm -f $dst"; continue
      fi
      run $pre "$LAUNCHCTL" bootout "$dom/$label"
      if run $pre rm -f "$dst"; then say "daemons: $([ "$DRY" = 1 ] && echo 'would retire' || echo retired) $u (unload + remove)"; acted=1
      else fail daemons "retire $u — could not remove $dst"; fi
      continue
    fi
    if [ ! -f "$dst" ] && ! is_new "launchd/com.claude-fleet.$u.plist.tmpl"; then
      say "daemons: skip $u — changed, not installed on this login"; continue
    fi
    tmp=$(mktemp "${TMPDIR:-/tmp}/fleet-apply.XXXXXX")
    if [ "$shape" = gui ]; then render_tmpl "$tmpl" > "$tmp"; else render_system "$tmpl" "$u" "$tmp"; fi \
      || { rm -f "$tmp"; fail daemons "render $u failed"; continue; }
    if same_plist "$tmp" "$dst"; then rm -f "$tmp"; say "daemons: ok $u — installed plist already current"; continue; fi
    local verb=reloaded; [ -f "$dst" ] || verb=added
    if [ "$shape" = system ] && [ "$sudo_ok" = 0 ]; then
      # keep the rendered plist where the printed commands can find it
      pend="$ROOT/logs/install-apply-pending"
      if [ "$DRY" = 0 ] && mkdir -p "$pend" && cp "$tmp" "$pend/$label.plist"; then
        need_root="$need_root; sudo install -m 644 $pend/$label.plist $dst"
      else
        need_root="$need_root; sudo install -m 644 <$u rendered from $tmpl> $dst"
      fi
      [ "$verb" = reloaded ] && need_root="$need_root; sudo launchctl bootout system/$label"
      need_root="$need_root; sudo launchctl bootstrap system $dst"
      rm -f "$tmp"; continue
    fi
    if [ "$DRY" = 1 ]; then
      say "daemons: would ${verb%ed} $u ($dom/$label)"; rm -f "$tmp"; acted=1; continue
    fi
    if [ "$shape" = gui ]; then mkdir -p "$AGENTS" && cp "$tmp" "$dst"
    else $pre install -m 644 "$tmp" "$dst"; fi || { rm -f "$tmp"; fail daemons "write $dst"; continue; }
    rm -f "$tmp"
    [ "$verb" = reloaded ] && $pre "$LAUNCHCTL" bootout "$dom/$label" >/dev/null 2>&1
    if $pre "$LAUNCHCTL" bootstrap "$dom" "$dst" >/dev/null 2>&1; then say "daemons: $verb $u"; acted=1
    else fail daemons "bootstrap $dom $dst — $u is NOT loaded"; fi
    [ "$u" = spinner ] && spin=0
  done
  if [ "$spin" = 1 ]; then
    label=$(fleet_daemon_label spinner "$shape" "$LOGIN"); dst=$(fleet_daemon_plist spinner "$shape" "$LOGIN")
    dom=$(fleet_daemon_domain "$shape"); pre=''; [ "$shape" = system ] && pre="$SUDO"
    if [ ! -f "$dst" ]; then say 'daemons: skip spinner kick — not installed'
    elif [ "$shape" = system ] && [ "$sudo_ok" = 0 ] && is_new bin/tmux-spinner.sh; then
      # A first install (#1192): the script is NEW in this range, so no unit was
      # ever running an older one — the LaunchDaemon the admin installed for this
      # login (RunAtLoad) already runs it. A kick here would only need root the
      # login does not have, and turn a clean first apply into PARTIAL.
      say "daemons: ok spinner — script new since ${from:0:7}, the installed unit runs it (no kick)"
    elif [ "$shape" = system ] && [ "$sudo_ok" = 0 ]; then need_root="$need_root; sudo launchctl kickstart -k system/$label"
    elif [ "$DRY" = 1 ]; then say "daemons: would kickstart -k $dom/$label (spinner script changed)"; acted=1
    elif $pre "$LAUNCHCTL" kickstart -k "$dom/$label" >/dev/null 2>&1; then say 'daemons: kicked spinner (script changed)'; acted=1
    else fail daemons "kickstart -k $dom/$label"; fi
  fi
  if [ -n "$need_root" ]; then
    fail daemons "no passwordless sudo for this login's system LaunchDaemons — run as an admin:${need_root#;}"
  fi
  [ "$acted" = 1 ] || [ -n "$need_root" ] || say 'daemons: ok — nothing to reload on this login'
}

daemons_systemd() {
  local units u f any_file dirty=0 acted=0 unit kind
  units=$(printf '%s\n' "$CHANGED" | sed -En 's#^systemd/claude-fleet-(.*)\.(service|timer)$#\1#p' | sort -u)
  local spin=0; touched bin/tmux-spinner.sh && spin=1
  if [ -z "$units" ] && [ "$spin" = 0 ]; then say 'daemons: ok — no daemon change, no reload needed'; return; fi
  local RESTART='' ENABLE='' DISABLE=''
  for u in $units; do
    any_file=0
    for kind in service timer; do [ -f "$ROOT/systemd/claude-fleet-$u.$kind" ] && any_file=1; done
    if [ "$any_file" = 0 ]; then                                  # retired
      if [ -f "$SDIR/claude-fleet-$u.service" ] || [ -f "$SDIR/claude-fleet-$u.timer" ]; then
        DISABLE="$DISABLE $u"
      else say "daemons: skip $u — retired, never installed"; fi
      continue
    fi
    local installed=0 changed=0
    { [ -f "$SDIR/claude-fleet-$u.service" ] || [ -f "$SDIR/claude-fleet-$u.timer" ]; } && installed=1
    if [ "$installed" = 0 ] && ! is_new "systemd/claude-fleet-$u.service" && ! is_new "systemd/claude-fleet-$u.timer"; then
      say "daemons: skip $u — changed, not installed on this login"; continue
    fi
    for kind in service timer; do
      f="$ROOT/systemd/claude-fleet-$u.$kind"; [ -f "$f" ] || continue
      if ! cmp -s <(render_tmpl "$f") "$SDIR/claude-fleet-$u.$kind" 2>/dev/null; then
        changed=1
        if [ "$DRY" = 0 ]; then
          mkdir -p "$SDIR" && render_tmpl "$f" > "$SDIR/claude-fleet-$u.$kind" || fail daemons "write $SDIR/claude-fleet-$u.$kind"
        fi
      fi
    done
    [ "$changed" = 1 ] || { say "daemons: ok $u — installed unit already current"; continue; }
    dirty=1
    if [ "$installed" = 1 ]; then RESTART="$RESTART $u"; else ENABLE="$ENABLE $u"; fi
  done
  unit_of() { if [ -f "$ROOT/systemd/claude-fleet-$1.timer" ] || [ -f "$SDIR/claude-fleet-$1.timer" ]; then printf 'claude-fleet-%s.timer' "$1"; else printf 'claude-fleet-%s.service' "$1"; fi; }
  for u in $DISABLE; do
    unit=$(unit_of "$u")
    run "$SYSTEMCTL" --user disable --now "$unit"
    if [ "$DRY" = 1 ] || rm -f "$SDIR/claude-fleet-$u.service" "$SDIR/claude-fleet-$u.timer"; then
      say "daemons: $([ "$DRY" = 1 ] && echo 'would retire' || echo retired) $u"; dirty=1; acted=1
    else fail daemons "retire $u"; fi
  done
  if [ "$dirty" = 1 ]; then run "$SYSTEMCTL" --user daemon-reload || fail daemons 'systemctl --user daemon-reload'; fi
  for u in $RESTART; do
    unit=$(unit_of "$u")
    if run "$SYSTEMCTL" --user restart "$unit"; then say "daemons: $([ "$DRY" = 1 ] && echo 'would reload' || echo reloaded) $u"; acted=1
    else fail daemons "restart $unit"; fi
    [ "$u" = spinner ] && spin=0
  done
  for u in $ENABLE; do
    unit=$(unit_of "$u")
    if run "$SYSTEMCTL" --user enable --now "$unit"; then say "daemons: $([ "$DRY" = 1 ] && echo 'would add' || echo added) $u"; acted=1
    else fail daemons "enable --now $unit"; fi
  done
  if [ "$spin" = 1 ]; then
    if [ ! -f "$SDIR/claude-fleet-spinner.service" ]; then say 'daemons: skip spinner kick — not installed'
    elif run "$SYSTEMCTL" --user restart claude-fleet-spinner.service; then
      say "daemons: $([ "$DRY" = 1 ] && echo 'would kick' || echo kicked) spinner (script changed)"; acted=1
    else fail daemons 'restart claude-fleet-spinner.service'; fi
  fi
  [ "$acted" = 1 ] || say 'daemons: ok — nothing to reload on this login'
}

BREW=$(brew_prefix)
if [ "$NODAEMONS" = 1 ]; then
  # issue #1214: the caller has found these daemons have nowhere to go yet and
  # reports them itself — render, load and remove nothing here
  say 'daemons: skip — --no-daemons (nothing rendered, loaded or removed; the caller reports them)'
else
  case "$PLATFORM" in
    launchd) daemons_launchd ;;
    systemd) daemons_systemd ;;
    *) say "daemons: skip — no launchd/systemd on this platform" ;;
  esac
fi

fi   # BUNDLE = 0

# --- plugin -------------------------------------------------------------------
PLUGIN=0 COPY=1
if [ "$BUNDLE" = 0 ] && ls -d "$CDIR"/plugins/cache/*/fleet/*/commands/fleet-claim.md >/dev/null 2>&1; then PLUGIN=1; fi
if [ "$PLUGIN" = 1 ]; then
  is_command "$CDIR/commands/fleet-claim.md" || COPY=0
  if printf '%s\n' "$CHANGED" | grep -qE '^(commands/|skills/|hooks/settings-hooks\.json$|\.claude-plugin/)'; then
    if [ "$DRY" = 1 ]; then say "plugin: would run $CLAUDE plugin update fleet"
    elif "$CLAUDE" plugin update fleet >/dev/null 2>&1; then say 'plugin: updated (takes effect in the next session)'
    else fail plugin "\`$CLAUDE plugin update fleet\` failed — run /plugin update fleet by hand"; fi
  else
    say 'plugin: ok — nothing plugin-side changed'
  fi
  [ "$COPY" = 1 ] || say 'plugin: commands/skills/hooks are the plugin'\''s — copy passes skipped'
fi

# --- hooks --------------------------------------------------------------------
if [ "$COPY" = 1 ]; then
  if touched hooks/settings-hooks.json; then
    via=(); [ "$CLIENT" = 1 ] && via=(--via "$ROOT")   # no ~/.claude/fleet here (#1725)
    if out=$(python3 "$ROOT/bin/fleet-hooks-merge.py" merge --source "$ROOT/hooks/settings-hooks.json" \
               --settings "$CDIR/settings.json" ${via[@]+"${via[@]}"} ${DRYFLAG:+"$DRYFLAG"} 2>&1); then
      n=$(printf '%s\n' "$out" | grep -cE '(replaced|removed dup|removed stale|appended)')
      say "hooks: $([ "$DRY" = 1 ] && echo 'would re-merge' || echo 're-merged') — $n change(s)"
      printf '%s\n' "$out" | grep -E '(replaced|removed dup|removed stale|appended)' | sed 's/^/    /'
    else
      fail hooks "fleet-hooks-merge.py merge: $(printf '%s\n' "$out" | tail -1)"
    fi
  else
    say 'hooks: skip — settings-hooks.json unchanged'
  fi
fi

# --- settings (issue #1558; folds the #1528 keys pass) ---------------------------
# Not under $COPY: the plugin wires hooks, but no plugin can set a settings key.
GCONF="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
DEFAULTS="$ROOT/conf/claude-settings.default.json"
if [ -f "$DEFAULTS" ]; then
  keep="${FLEET_KEEP_AGENTS_KEY:-}"
  [ -n "$keep" ] || keep=$( . "$ROOT/bin/fleet-lib.sh" >/dev/null 2>&1; printf '%s' "${FLEET_KEEP_AGENTS_KEY:-}" )
  kskip=(); [ "$keep" = 1 ] && kskip=(--skip leftArrowOpensAgents)
  note=''; [ "$keep" = 1 ] && note=' (leftArrowOpensAgents left to this login: FLEET_KEEP_AGENTS_KEY=1)'
  if out=$(python3 "$ROOT/bin/fleet-hooks-merge.py" defaults --defaults "$DEFAULTS" --settings "$CDIR/settings.json" \
             --config "$GCONF" ${kskip[@]+"${kskip[@]}"} ${DRYFLAG:+"$DRYFLAG"} 2>&1); then
    n=$(printf '%s\n' "$out" | grep -c '^set ')
    kept=$(printf '%s\n' "$out" | sed -n 's/^kept    //p')
    if [ "$n" -gt 0 ]; then
      say "settings: $([ "$DRY" = 1 ] && echo 'would fill' || echo 'filled') — $n default key(s) this login lacked${kept:+; $kept}$note"
      printf '%s\n' "$out" | grep '^set ' | sed 's/^/    /'
    else
      say "settings: ok — every default key present, or this login's own${kept:+; $kept}$note"
    fi
    if printf '%s\n' "$out" | grep -q '^absent '; then
      say "settings: no $GCONF yet (Claude Code has not run on this login; the next sync fills its key)"
    fi
  else
    fail settings "fleet-hooks-merge.py defaults: $(printf '%s\n' "$out" | tail -1)"
  fi
else
  say 'settings: skip — no conf/claude-settings.default.json in this version'
fi

# --- commands -----------------------------------------------------------------
if [ "$COPY" = 1 ] && shielded claude.commands; then
  say "commands: skip — this login keeps its own (claude.commands in $OVR)"
elif [ "$COPY" = 1 ]; then
  inst=0 rem=0 same=0
  for p in $(printf '%s\n' "$ADDED" | grep -E '^commands/[^/]+\.md$'); do
    b=${p#commands/}; src="$ROOT/$p"; dst="$CDIR/commands/$b"
    is_command "$src" || continue                       # README.md, _template.md, …
    if cmp -s "$src" "$dst" 2>/dev/null; then same=$((same + 1)); continue; fi
    if [ "$DRY" = 1 ]; then say "commands: would install $b"; inst=$((inst + 1)); continue; fi
    if mkdir -p "$CDIR/commands" && cp -p "$src" "$dst"; then inst=$((inst + 1))
    else fail commands "install $b"; fi
  done
  for p in $(printf '%s\n' "$GONE" | grep -E '^commands/[^/]+\.md$'); do
    b=${p#commands/}; dst="$CDIR/commands/$b"
    [ -f "$ROOT/$p" ] && continue                       # renamed away and back
    [ -f "$dst" ] || continue
    if ! is_command "$dst"; then say "commands: WARN $b is retired upstream but the installed copy is not a fleet command — left alone"; continue; fi
    if [ "$DRY" = 1 ]; then say "commands: would remove $b"; rem=$((rem + 1)); continue; fi
    if rm -f "$dst"; then rem=$((rem + 1)); else fail commands "remove $b"; fi
  done
  # #858 residue: a README.md an older sync installed as a `/README` skill. Only
  # when it is byte-identical to a repo version — then it is ours, not personal.
  if [ "$BUNDLE" = 0 ] && [ -f "$CDIR/commands/README.md" ] && ! is_command "$CDIR/commands/README.md"; then
    for rev in "$to" "$from"; do
      if cmp -s <(git -C "$ROOT" show "${rev}:commands/README.md" 2>/dev/null) "$CDIR/commands/README.md"; then
        if [ "$DRY" = 1 ]; then say 'commands: would remove README.md (installed by the pre-#858 gate)'
        else rm -f "$CDIR/commands/README.md" && say 'commands: removed README.md (installed by the pre-#858 gate)'; fi
        break
      fi
    done
  fi
  if printf '%s\n' "$CHANGED" | grep -qE '^commands/'; then
    say "commands: $([ "$DRY" = 1 ] && echo 'would install' || echo installed) $inst · $([ "$DRY" = 1 ] && echo 'would remove' || echo removed) $rem · current $same"
  else
    say 'commands: skip — no commands/*.md changed'
  fi
fi

# --- codex skills --------------------------------------------------------------
codex_homes() {
  {
    printf '%s\n' "${CODEX_HOME:-$HOME/.codex}"
    [ -n "${FLEET_CODEX_HOME:-}" ] && printf '%s\n' "$FLEET_CODEX_HOME"
    python3 - "${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}" <<'PY' 2>/dev/null
import json, pathlib, sys
root = pathlib.Path(sys.argv[1]).expanduser() / "codex" / "accounts.json"
try:
    data = json.loads(root.read_text())
except Exception:
    data = {}
if isinstance(data, dict):
    for value in data.values():
        if isinstance(value, str):
            print(value)
PY
  } | sed '/^$/d' | awk '!seen[$0]++'
}
codex_skill_marked() { [ -f "$1/SKILL.md" ] && grep -qF '<!-- fleet codex command skill -->' "$1/SKILL.md"; }
codex_base_marked() { [ -f "$1/SKILL.md" ] && grep -qF '<!-- fleet skill -->' "$1/SKILL.md"; }
codex_command_skill() { # $1 source command.md $2 skill-name
  local src="$1" name="$2" title desc
  title=$(sed -n '1s/^# //p' "$src" | sed 's/[[:space:]]\{1,\}/ /g; s/:/ -/g')
  [ -n "$title" ] || title="/$name"
  desc="Run the claude-fleet /$name command as a native Codex skill. Use when the user invokes /$name, \$$name, or asks for this fleet command. Source: commands/$name.md ($title)."
  printf -- '---\nname: %s\ndescription: >-\n  %s\n---\n\n' "$name" "$desc"
  printf '# claude-fleet Codex adapter for /%s\n\n<!-- fleet codex command skill -->\n\n' "$name"
  if [ -r "$ROOT/conf/codex-preamble.md" ]; then
    sed 's/\$ARGUMENTS/the text after this skill name/g' "$ROOT/conf/codex-preamble.md"
    printf '\n---\n\n'
  fi
  sed 's/\$ARGUMENTS/the text after this skill name/g' "$src"
}
if touched conf/codex-preamble.md; then
  codex_command_paths=$(find "$ROOT/commands" -maxdepth 1 -type f -name '*.md' | sed "s#^$ROOT/##" | sort)
else
  codex_command_paths=$(printf '%s\n%s\n' "$ADDED" "$GONE" | grep -E '^commands/[^/]+\.md$' | sort -u)
fi
codex_skill_names=$(printf '%s\n' "$CHANGED" | sed -n 's#^skills/\([^/][^/]*\)/.*#\1#p' | sort -u)
if shielded codex.skills; then
  say "codex-skills: skip — this login keeps its own (codex.skills in $OVR)"
elif [ -z "$codex_command_paths$codex_skill_names" ] && ! touched conf/codex-preamble.md; then
  say 'codex-skills: skip — no commands/*.md, skills/ or codex preamble changed'
else
  homes=$(codex_homes)
  if [ -z "$homes" ]; then
    say 'codex-skills: skip — no Codex homes known'
  else
    inst=0 rem=0 warn=0 homes_n=0
    tmp_skill=$(mktemp "${TMPDIR:-/tmp}/fleet-codex-skill.XXXXXX") || { fail codex-skills "mktemp failed"; tmp_skill=''; }
    while IFS= read -r home; do
      [ -n "$home" ] || continue
      case "$home" in *$'\n'*|*$'\r'*|*$'\t'*) warn=$((warn + 1)); say "codex-skills: WARN skipping unsafe CODEX_HOME path"; continue ;; esac
      if [ ! -d "$home" ]; then
        [ "$home" = "$HOME/.codex" ] || { warn=$((warn + 1)); say "codex-skills: WARN $home is not a directory — skipped"; continue; }
        [ "$BUNDLE" = 0 ] || continue   # a client with no Codex set up: nothing created there (#1725)
      fi
      homes_n=$((homes_n + 1))
      for p in $codex_command_paths; do
        b=${p#commands/}; name=${b%.md}; src="$ROOT/$p"; dst="$home/skills/$name"
        if [ ! -f "$src" ] || ! is_command "$src"; then
          [ -d "$dst" ] || continue
          if ! codex_skill_marked "$dst"; then warn=$((warn + 1)); say "codex-skills: WARN $name is retired upstream but the Codex skill is personal — left alone"; continue; fi
          if [ "$DRY" = 1 ]; then rem=$((rem + 1)); say "codex-skills: would remove $home/skills/$name"; continue; fi
          rm -rf "$dst" && rem=$((rem + 1)) || fail codex-skills "remove $dst"
          continue
        fi
        codex_command_skill "$src" "$name" > "$tmp_skill" || { fail codex-skills "render $name"; continue; }
        if [ -f "$dst/SKILL.md" ] && ! codex_skill_marked "$dst" && ! cmp -s "$tmp_skill" "$dst/SKILL.md"; then
          warn=$((warn + 1)); say "codex-skills: WARN $name is a personal Codex skill — left alone"; continue
        fi
        if cmp -s "$tmp_skill" "$dst/SKILL.md" 2>/dev/null; then continue; fi
        if [ "$DRY" = 1 ]; then inst=$((inst + 1)); say "codex-skills: would install $home/skills/$name"; continue; fi
        mkdir -p "$dst" && cp -p "$tmp_skill" "$dst/SKILL.md" && inst=$((inst + 1)) || fail codex-skills "install $dst"
      done
      for n in $codex_skill_names; do
        src="$ROOT/skills/$n" dst="$home/skills/$n"
        if [ ! -f "$src/SKILL.md" ]; then
          [ -d "$dst" ] || continue
          if ! codex_base_marked "$dst"; then warn=$((warn + 1)); say "codex-skills: WARN $n is retired upstream but the Codex skill is personal — left alone"; continue; fi
          if [ "$DRY" = 1 ]; then rem=$((rem + 1)); say "codex-skills: would remove $home/skills/$n"; continue; fi
          rm -rf "$dst" && rem=$((rem + 1)) || fail codex-skills "remove $dst"
          continue
        fi
        codex_base_marked "$src" || continue
        if [ -f "$dst/SKILL.md" ] && ! codex_base_marked "$dst" && ! cmp -s "$src/SKILL.md" "$dst/SKILL.md"; then
          warn=$((warn + 1)); say "codex-skills: WARN $n is a personal Codex skill — left alone"; continue
        fi
        if [ -d "$dst" ] && diff -rq "$src" "$dst" >/dev/null 2>&1; then continue; fi
        if [ "$DRY" = 1 ]; then inst=$((inst + 1)); say "codex-skills: would install $home/skills/$n"; continue; fi
        mkdir -p "$dst" && cp -pR "$src"/. "$dst"/ && inst=$((inst + 1)) || fail codex-skills "install $dst"
      done
    done <<EOF
$homes
EOF
    [ -n "$tmp_skill" ] && rm -f "$tmp_skill"
    say "codex-skills: $([ "$DRY" = 1 ] && echo 'would install' || echo installed) $inst · $([ "$DRY" = 1 ] && echo 'would remove' || echo removed) $rem · homes $homes_n$([ "$warn" -gt 0 ] && printf ' · WARN %s' "$warn")"
  fi
fi

# --- skills -------------------------------------------------------------------
if [ "$COPY" = 1 ] && shielded claude.skills; then
  say "skills: skip — this login keeps its own (claude.skills in $OVR)"
elif [ "$COPY" = 1 ]; then
  names=$(printf '%s\n' "$CHANGED" | sed -n 's#^skills/\([^/][^/]*\)/.*#\1#p' | sort -u)
  if [ -z "$names" ]; then
    say 'skills: skip — no skills/ changed'
  else
    inst=0 rem=0
    for n in $names; do
      src="$ROOT/skills/$n" dst="$CDIR/skills/$n"
      marked() { [ -f "$1/SKILL.md" ] && grep -qF '<!-- fleet skill -->' "$1/SKILL.md"; }
      if [ ! -f "$src/SKILL.md" ]; then                  # retired
        [ -d "$dst" ] || continue
        if ! marked "$dst"; then say "skills: WARN $n is retired upstream but the installed copy is personal — left alone"; continue; fi
        if [ "$DRY" = 1 ]; then say "skills: would remove $n"; rem=$((rem + 1)); continue; fi
        rm -rf "$dst" && rem=$((rem + 1)) || fail skills "remove $n"
        continue
      fi
      marked "$src" || continue
      if [ -f "$dst/SKILL.md" ] && ! marked "$dst" && ! cmp -s "$src/SKILL.md" "$dst/SKILL.md"; then
        say "skills: WARN $n is a personal skill that diverges from the repo copy — left alone; reconcile by hand"
        continue
      fi
      if [ -d "$dst" ] && diff -rq "$src" "$dst" >/dev/null 2>&1; then continue; fi   # already current
      if [ "$DRY" = 1 ]; then say "skills: would install $n"; inst=$((inst + 1)); continue; fi
      if mkdir -p "$dst" && cp -pR "$src"/. "$dst"/; then inst=$((inst + 1)); else fail skills "install $n"; fi
    done
    say "skills: $([ "$DRY" = 1 ] && echo 'would install' || echo installed) $inst · $([ "$DRY" = 1 ] && echo 'would remove' || echo removed) $rem"
  fi
fi

# --- agents (issue #1559; EPIC #1524 C12) ------------------------------------------
# conf/agent-defaults/ is the ONE default package for BOTH agents on a managed
# login: the user-scope MCP servers (context7 · playwright · github · fetch) into
# ~/.claude.json and $CODEX_HOME/config.toml, Codex's approval_policy /
# sandbox_mode / model_reasoning_effort, and one marker-delimited fleet block in
# ~/.claude/CLAUDE.md / $CODEX_HOME/AGENTS.md. Fill only (the #1558 semantics): a
# server or key the login has is never rewritten; the override file names what is
# never written. Every moving apply; every Codex home the script knows
# (CODEX_HOME, FLEET_CODEX_HOME, codex/accounts.json). Not under $COPY — a plugin
# cannot write these files. After the skills passes, so the skills count (the one
# thing this pass only COUNTS) reads what they just installed.
if [ -d "$ROOT/conf/agent-defaults" ] && [ -f "$ROOT/bin/fleet-agent-defaults.py" ]; then
  sroot=(); [ "$CLIENT" = 1 ] && sroot=(--scripts-root "$ROOT")   # bin/mcp-*.sh live here (#1725)
  if out=$(python3 "$ROOT/bin/fleet-agent-defaults.py" apply --root "$ROOT" --claude-config "$GCONF" ${sroot[@]+"${sroot[@]}"} \
             --claude-md "$CDIR/CLAUDE.md" --claude-skills "$CDIR/skills" \
             --override "${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/agent-overrides.json" ${DRYFLAG:+"$DRYFLAG"} 2>&1); then
    n=$(printf '%s\n' "$out" | grep -c '^set ')
    kept=$(printf '%s\n' "$out" | sed -n 's/^kept    //p')
    if [ "$n" -gt 0 ]; then
      sum=$(printf '%s\n' "$out" | sed -n 's/^filled  \(claude [0-9]* · codex [0-9]*\).*/\1/p')
      say "agents: $([ "$DRY" = 1 ] && echo 'would fill' || echo 'filled') — ${sum:-$n} default item(s) this login lacked${kept:+; $kept}"
      printf '%s\n' "$out" | grep '^set ' | sed 's/^/    /'
    else
      say "agents: ok — every default in place, or this login's own${kept:+; $kept}"
    fi
    printf '%s\n' "$out" | sed -n 's/^absent  /agents: no /p'
    printf '%s\n' "$out" | sed -n 's/^skills  /agents: skills /p'
  else
    fail agents "fleet-agent-defaults.py apply: $(printf '%s\n' "$out" | tail -1)"
  fi
else
  say 'agents: skip — no conf/agent-defaults in this version'
fi

# --- team (issue #1726, EPIC #1718 C8) ----------------------------------------------
# The hub's team layer over what the agents pass just filled — fleet default <
# team < local: fleet-agent-team.py sync fetches /v1/fleet/team-bundle (the node
# token, else this person's connection certificate) and composes it, recording
# every item's source in $FLEET_CONF_DIR/agent-effective.json. Always run (the
# agents pass may have refilled a default the team replaces). No hub and no layer
# ever applied here (exit 3) → no line at all: a login with no hub is byte for
# byte what it was. A hub that does not answer keeps the cached version.
if [ -f "$ROOT/bin/fleet-agent-team.py" ] && [ "$DRY" = 0 ]; then
  out=$(python3 "$ROOT/bin/fleet-agent-team.py" sync --root "$ROOT" --claude-config "$GCONF" ${sroot[@]+"${sroot[@]}"}           --claude-settings "$CDIR/settings.json" --claude-skills "$CDIR/skills"           --override "${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/agent-overrides.json" 2>&1); rc=$?
  case "$rc" in
    0) say "team: ok — $(printf '%s\n' "$out" | grep '^team: ' | tail -1 | sed 's/^team: //')" ;;
    3) : ;;
    1) say "team: WARN — $(printf '%s\n' "$out" | grep '^team: ' | head -1 | sed 's/^team: //'); the cached version stays" ;;
    *) say "team: WARN — $(printf '%s\n' "$out" | tail -1 | sed 's/^team: //; s/^fleet-agent-team: //'); nothing applied" ;;
  esac
fi

# --- agentcfg (issue #1782, EPIC #1776 C6) ---------------------------------------
# What a fresh session would be launched with moved with this sync: refresh the
# fingerprint cache ($FLEET_CONF_DIR/global/agent-cfg.expected, one line per agent)
# that the stale-session readers (C7, #1783) compare each window's @agent_cfg to.
# The team pass above refreshes it too when a layer applied; this covers a sync
# that moved only the fleet defaults or the mod. FLEET_AGENT_LOCK / FLEET_MOD are
# read from the login's conf files by the composer itself (nothing is sourced here).
if [ -f "$ROOT/bin/fleet-agent-team.py" ] && [ "$DRY" = 0 ] && [ "$BUNDLE" != 1 ]; then
  if out=$(python3 "$ROOT/bin/fleet-agent-team.py" expected --write --root "$ROOT" --claude-config "$GCONF" \
             --claude-settings "$CDIR/settings.json" --override "${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}/agent-overrides.json" 2>&1); then
    say "agentcfg: ok — expected $(printf '%s\n' "$out" | awk '{printf "%s%s %s", (NR>1?" · ":""), $1, $2}')"
  else
    say "agentcfg: WARN — $(printf '%s\n' "$out" | tail -1)"
  fi
fi

# --- credsep (issue #1971, EPIC #1967 C4) ------------------------------------------
# Converge on FLEET_CRED_SEPARATE: 1 and not separated → install (root once, via
# password-less sudo; none → one line saying what to run); 0 and separated →
# uninstall; separated → refresh the root-owned code copy the role account runs.
# Off and never separated: nothing runs and no line is printed — byte for byte.
if [ -f "$ROOT/bin/fleet-credsep.sh" ] && [ "$BUNDLE" != 1 ]; then
  _cs_cf="${FLEET_CONF_DIR:-$HOME/.config/claude-fleet}"
  if [ -f "$_cs_cf/credsep.json" ] || grep -qs '^[[:space:]]*\(export[[:space:]]*\)\{0,1\}FLEET_CRED_SEPARATE=["'"'"']\{0,1\}1' \
       "$_cs_cf/fleet.conf" "$_cs_cf/fleet.settings" "$ROOT/fleet.conf" || [ "${FLEET_CRED_SEPARATE:-0}" = 1 ]; then
    say "$(bash "$ROOT/bin/fleet-credsep.sh" apply ${DRYFLAG:+"$DRYFLAG"} 2>&1 | tail -n 1)"
  fi
fi

# --- mod + the package's record (--bundle, issue #1725) ---------------------------
# The mod is files, not a merge: it sits in the package (mod/fleet/) and every
# fleet-launched Claude loads it from there (fleet_mod_dir). The state file is
# what the next --bundle apply diffs against to see what a newer package retired.
if [ "$BUNDLE" = 1 ]; then
  mv_=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version") or "?")' \
          "$ROOT/mod/fleet/.claude-plugin/plugin.json" 2>/dev/null)
  if [ -n "$mv_" ]; then say "mod: ok — fleet mod $mv_ in $ROOT/mod/fleet"
  else fail mod "no mod/fleet/.claude-plugin/plugin.json in $ROOT"; fi
  if [ "$DRY" = 0 ] && [ "$FAILS" = 0 ]; then
    mkdir -p "$(dirname "$BSTATE")" \
      && { printf 'version %s\n' "$to"; printf '%s\n' "$BFILES"; } > "$BSTATE.tmp" \
      && mv -f "$BSTATE.tmp" "$BSTATE" \
      || fail bundle "could not record $BSTATE"
  fi
  finish "package $to$([ "$DRY" = 1 ] && printf ' (dry-run, nothing changed)')"
fi

# --- ui -------------------------------------------------------------------------
uiargs=()
touched bin/tmux-dashboard.sh || touched bin/tmux-dashboard-rows.sh && uiargs+=(--dash)
beforeconf=''
# The bar's two files are sourced BY tmux-attention.conf (issue #1534), so a
# change to either reloads it the same way; so is the human key layer (#1840).
if touched conf/tmux-attention.conf || touched conf/tmux-bar.conf || touched conf/fleet-palette.conf || touched conf/tmux-fleet-server.conf || touched conf/tmux-node-human.conf; then
  # The pre-sync conf, straight from --from — never from a shell var a caller
  # might have lost (#295) or a zsh-mangled ref (#325).
  beforeconf=$(mktemp "${TMPDIR:-/tmp}/fleet-apply-conf.XXXXXX")
  git -C "$ROOT" show "${from}:conf/tmux-attention.conf" > "$beforeconf" 2>/dev/null || : > "$beforeconf"
  # Re-source what the fleet servers start from (issue #1845), not ~/.tmux.conf:
  # an error in the person's file must not keep the new layer off every fleet.
  uiargs+=(--conf "$beforeconf" "$ROOT/conf/tmux-attention.conf" "$ROOT/conf/tmux-fleet-server.conf")
fi
if [ "${#uiargs[@]}" -gt 0 ]; then
  if out=$(bash "$ROOT/bin/fleet-ui-refresh.sh" --all ${uiargs[@]+"${uiargs[@]}"} ${DRYFLAG:+"$DRYFLAG"} 2>&1); then
    say "ui: ok — $(printf '%s\n' "$out" | tail -1)"
  else
    fail ui "fleet-ui-refresh.sh: $(printf '%s\n' "$out" | tail -1)"
  fi
else
  say 'ui: skip — dash launcher and tmux conf unchanged'
fi
[ -n "$beforeconf" ] && rm -f "$beforeconf"

# --- repark ---------------------------------------------------------------------
if [ -f "$ROOT/bin/fleet-sleep.sh" ] && [ -f "$ROOT/bin/fleet-lib.sh" ]; then
  socks=$( # shellcheck source=/dev/null
    . "$ROOT/bin/fleet-lib.sh" >/dev/null 2>&1 && fleet_sockets 2>/dev/null)
  nf=0 rp=0 rf=0
  for s in $socks; do
    nf=$((nf + 1))
    [ "$DRY" = 1 ] && continue
    if out=$(bash "$ROOT/bin/fleet-sleep.sh" repark "$s" 2>&1); then
      rp=$((rp + $(printf '%s\n' "$out" | grep -c '"reparked"')))
    else rf=$((rf + 1)); fi
  done
  if [ "$DRY" = 1 ]; then say "repark: would re-park stale sleeping pages on $nf live fleet(s)"
  elif [ "$rf" -gt 0 ]; then fail repark "$rf of $nf fleet(s) failed; $rp page(s) re-parked"
  else say "repark: ok — $rp page(s) re-parked on $nf live fleet(s)"; fi
else
  say 'repark: skip — no sleep pages in this version'
fi

# --- loopmark (issue #1370) --------------------------------------------------------
if [ -f "$ROOT/bin/fleet_loop_mark.py" ] && [ -f "$ROOT/bin/fleet-lib.sh" ]; then
  socks=$( # shellcheck source=/dev/null
    . "$ROOT/bin/fleet-lib.sh" >/dev/null 2>&1 && fleet_sockets 2>/dev/null)
  nf=0 lm=0 lw=0 lf=0
  for s in $socks; do
    nf=$((nf + 1))
    [ "$DRY" = 1 ] && continue
    out=$(python3 "$ROOT/bin/fleet_loop_mark.py" sweep --socket-name "$s" 2>/dev/null) || lf=$((lf + 1))
    case "$out" in marked=*' 'windows=*)
      _lmn=${out#marked=}; _lmn=${_lmn%% *}; _lmw=${out#* windows=}; _lmw=${_lmw%% *}
      case "$_lmn$_lmw" in *[!0-9]*) ;; *) lm=$((lm + _lmn)); lw=$((lw + _lmw)) ;; esac ;;
    esac
  done
  # A fleet it could not read is a WARN, not a FAIL: the Stop hook backfills the same
  # window on its next turn, so nothing is lost — only the head start.
  if [ "$DRY" = 1 ]; then say "loopmark: would mark pending Loops on $nf live fleet(s)"
  elif [ "$lf" -gt 0 ]; then say "loopmark: WARN $lf of $nf fleet(s) unreadable; $lm of $lw window(s) marked"
  else say "loopmark: ok — $lm of $lw Claude window(s) marked on $nf live fleet(s)"; fi
else
  say 'loopmark: skip — no @loop mark in this version'
fi

# --- reeval (issue #1376) ----------------------------------------------------------
# After loopmark, so a freshly backfilled @loop is already a reason: every idle
# window's `done` ↔ `looping` + @claude_wait re-asked once (fleet-wait-reeval.sh) —
# a parent that stopped before this version still reads ✓ while its children run.
if [ -f "$ROOT/bin/fleet-wait-reeval.sh" ]; then
  socks=$( # shellcheck source=/dev/null
    . "$ROOT/bin/fleet-lib.sh" >/dev/null 2>&1 && fleet_sockets 2>/dev/null)
  nf=0 rc_=0 rw=0
  for s in $socks; do
    nf=$((nf + 1))
    [ "$DRY" = 1 ] && continue
    out=$(bash "$ROOT/bin/fleet-wait-reeval.sh" --quiet -- "$s" 2>/dev/null | tail -1)
    case "$out" in changed=*' 'windows=*)
      _rc=${out#changed=}; _rc=${_rc%% *}; _rw=${out#* windows=}; _rw=${_rw%% *}
      case "$_rc$_rw" in *[!0-9]*) ;; *) rc_=$((rc_ + _rc)); rw=$((rw + _rw)) ;; esac ;;
    esac
  done
  if [ "$DRY" = 1 ]; then say "reeval: would re-ask idle windows on $nf live fleet(s)"
  else say "reeval: ok — $rc_ of $rw idle window(s) changed on $nf live fleet(s)"; fi
else
  say 'reeval: skip — no fleet-wait-reeval.sh in this version'
fi

# --- oldcfg (issue #2076, EPIC #2074 C3) --------------------------------------------
# Which open sessions THIS version breaks — their start (@agent_cfg_manifest) names a
# hook script, a mod tool's handler or an MCP script the new tree no longer has, the
# C2 judgment (fleet-oldcfg-replay.py) asked per window by fleet-oldcfg-check.sh —
# and which stale ones are looping (a scheduler the idle tick never reopens). Named
# here, with window · repo · issue · state, and NEVER reopened: #2068 B is the
# operator's call (a looping scheduler is reopened by hand, when free). The sweep
# also writes global/agent-cfg.broken, so the sidebar's red is right on the first
# frame after the move rather than one collector tick later.
if [ -f "$ROOT/bin/fleet-oldcfg-check.sh" ] && [ "$BUNDLE" != 1 ]; then
  if [ "$DRY" = 1 ]; then say 'oldcfg: would name the open sessions this version breaks, and the looping ones on an old configuration'
  else
    out=$(bash "$ROOT/bin/fleet-oldcfg-check.sh" --sweep --list --new-dir "$ROOT" 2>&1); rc=$?
    nb=$(printf '%s\n' "$out" | grep -c '^broken	'); nl=$(printf '%s\n' "$out" | grep -c '^looping	')
    if [ "$rc" -gt 2 ]; then say "oldcfg: WARN — $(printf '%s\n' "$out" | tail -1)"
    elif [ "$nb" = 0 ] && [ "$nl" = 0 ]; then say 'oldcfg: ok — no open session breaks on this version; none looping on an old configuration'
    else
      say "oldcfg: 会坏·需重开 $nb · 循环中的配置旧 $nl — not reopened (#2068 B): reopen them when free (a looping one by hand, an idle broken one the cfg-restart tick takes)"
      printf '%s\n' "$out" | grep -E '^(broken|looping)	' \
        | awk -F'\t' '{ printf "    %s  %s:%s  %s  %s  %s%s\n", ($1 == "broken" ? "会坏" : "循环"), $2, $3, $4, $5, $6, ($7 != "" ? "  — " $7 : "") }'
    fi
  fi
else
  say 'oldcfg: skip — no fleet-oldcfg-check.sh in this version'
fi

logins_step
finish "${from:0:7}..${to:0:7}$([ "$DRY" = 1 ] && printf ' (dry-run, nothing changed)')"
