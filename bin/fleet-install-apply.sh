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
#   plugin    a plugin install owns commands/skills/hooks: `claude plugin update
#             fleet` replaces the three passes below (unless a copy install sits
#             beside it, in which case both run)
#   hooks     settings-hooks.json changed -> fleet-hooks-merge.py merge
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
#   ui        dash launcher / tmux conf changed -> fleet-ui-refresh.sh --all
#   repark    re-park stale sleeping-worker pages on every live fleet (#1064)
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
# /fleet-sync-install is: ff -> this (--sync-logins) -> report. The install-sync
# daemon (C3) calls it the same way, minus the flag — one implementation of
# "sync once".
#
# Usage:
#   fleet-install-apply.sh --from <sha> --to <sha> [--dry-run] [--root <dir>]
#                          [--sync-logins[=a,b]]
#   fleet-install-apply.sh --is-command <file>    # exit 0 iff the #858 gate passes
#
#   --from     the rev the install was at before the move
#   --to       the rev it is at now — must resolve to the install's HEAD
#   --dry-run  print what each step WOULD do; change nothing (passed on to the
#              logins step: it plans and prints, syncs nothing)
#   --root     the install (default $FLEET_INSTALL_ROOT, else ~/.claude/fleet)
#   --sync-logins[=a,b]
#              also bring the machine's other logins to --to (all that have
#              auto-update on; `=a,b` exactly those, on or off)
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
# (claude), FLEET_INSTALL_BREW_PREFIX, FLEET_INSTALL_LOGIN ($USER).
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

FROM='' TO='' DRY=0 ROOT="${FLEET_INSTALL_ROOT:-$HOME/.claude/fleet}" SYNCL=0 SYNCL_ONLY=''
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="${2:-}"; shift 2 || { usage >&2; exit 2; } ;;
    --to) TO="${2:-}"; shift 2 || { usage >&2; exit 2; } ;;
    --dry-run) DRY=1; shift ;;
    --sync-logins) SYNCL=1; shift ;;
    --sync-logins=*) SYNCL=1; SYNCL_ONLY="${1#--sync-logins=}"; shift ;;
    --root) ROOT="${2:-}"; shift 2 || { usage >&2; exit 2; } ;;
    --is-command) is_command "${2:-}"; exit $? ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'fleet-install-apply: unknown arg %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$FROM" ] && [ -n "$TO" ] || { echo 'fleet-install-apply: --from and --to are required' >&2; exit 2; }
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
  || { printf 'fleet-install-apply: %s is not a git checkout\n' "$ROOT" >&2; exit 2; }
from=$(git -C "$ROOT" rev-parse --verify --quiet "$FROM^{commit}") \
  || { printf 'fleet-install-apply: --from %s is not a commit in %s\n' "$FROM" "$ROOT" >&2; exit 2; }
to=$(git -C "$ROOT" rev-parse --verify --quiet "$TO^{commit}") \
  || { printf 'fleet-install-apply: --to %s is not a commit in %s\n' "$TO" "$ROOT" >&2; exit 2; }
head=$(git -C "$ROOT" rev-parse HEAD)
[ "$to" = "$head" ] || { printf 'fleet-install-apply: --to %s is not the install HEAD %s — move the install first\n' "${to:0:7}" "${head:0:7}" >&2; exit 2; }

CDIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
AGENTS="${FLEET_LAUNCHD_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
DDIR="${FLEET_INSTALL_DAEMON_DIR:-/Library/LaunchDaemons}"
SDIR="${FLEET_SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
LAUNCHCTL="${FLEET_INSTALL_LAUNCHCTL:-launchctl}"
SYSTEMCTL="${FLEET_INSTALL_SYSTEMCTL:-systemctl}"
SUDO="${FLEET_INSTALL_SUDO-sudo -n}"
CLAUDE="${FLEET_INSTALL_CLAUDE:-claude}"
LOGIN="${FLEET_INSTALL_LOGIN:-${USER:-$(id -un)}}"
UID_=$(id -u)
PLATFORM="${FLEET_INSTALL_PLATFORM:-}"
if [ -z "$PLATFORM" ]; then
  case "$(uname -s)" in Darwin) PLATFORM=launchd ;; Linux) PLATFORM=systemd ;; *) PLATFORM=none ;; esac
fi

FAILS=0
DRYFLAG=; [ "$DRY" = 1 ] && DRYFLAG=--dry-run
say() { printf '%s\n' "$*"; }
fail() { FAILS=$((FAILS + 1)); say "$1: FAIL $2"; }
# run <cmd...> — execute, or print under --dry-run
run() { if [ "$DRY" = 1 ]; then say "    would: $*"; return 0; fi; "$@" >/dev/null 2>&1; }

# --- a running EPIC batch? (issue #953) — a warning, never a gate ---------------
# The batch-end /fleet-sync-install is exactly this call, made after the run loop
# cleared its heartbeat; the install-sync daemon defers on a fresh one before it
# ever gets here. So a FRESH mark at this point is a hand sync under a batch that
# is still running — a worker /fleet-claim told not to, or a hub that skipped the
# clear. Say so; the operator decides. An older version's lib has no reader → quiet.
if [ -f "$ROOT/bin/fleet-lib.sh" ] \
   && er=$( . "$ROOT/bin/fleet-lib.sh" >/dev/null 2>&1 && fleet_epic_running 2>/dev/null ); then
  say "epic: WARN a batch is running on this login ($er) — syncing mid-batch swaps the floor under its workers (issue #953); the run loop syncs once, at its closing tick (fleet-epic-heartbeat.sh --clear lifts the mark)"
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
touched() { printf '%s\n' "$CHANGED" | grep -qx "$1"; }
# is_new <path> — present at --to, absent at --from: an upstream addition, which
# this login has never had the chance to install (so "not installed" ≠ opted out)
is_new() { [ -f "$ROOT/$1" ] && ! git -C "$ROOT" cat-file -e "${from}:$1" 2>/dev/null; }

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

# --- daemons ------------------------------------------------------------------
brew_prefix() {
  if [ -n "${FLEET_INSTALL_BREW_PREFIX:-}" ]; then printf '%s' "$FLEET_INSTALL_BREW_PREFIX"
  else brew --prefix 2>/dev/null || printf '/opt/homebrew'; fi
}
render_tmpl() { # $1 template -> stdout, the gui-shape plist / user unit
  sed -e "s|__HOME__|$HOME|g" -e "s|__BREW_PREFIX__|$BREW|g" "$1"
}
# system shape: the gui plist + Label com.claude-fleet.<login>.<x>, UserName /
# GroupName, and argv wrapped so the job gets the user's own TMPDIR (a
# LaunchDaemon does not inherit one) — the shape the installed ones carry.
render_system() { # $1 template $2 unit $3 out
  local tmp n i a argv=''
  tmp="$3"
  render_tmpl "$1" > "$tmp" || return 1
  n=$(plutil -extract ProgramArguments raw -o - "$tmp" 2>/dev/null) || return 1
  i=0
  while [ "$i" -lt "$n" ]; do
    a=$(plutil -extract "ProgramArguments.$i" raw -o - "$tmp") || return 1
    argv="$argv '$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'"
    i=$((i + 1))
  done
  plutil -replace Label -string "com.claude-fleet.$LOGIN.$2" "$tmp" \
    && plutil -replace UserName -string "$LOGIN" "$tmp" \
    && plutil -replace GroupName -string staff "$tmp" \
    && plutil -replace ProgramArguments -json '["/bin/sh","-c"]' "$tmp" \
    && plutil -insert ProgramArguments.2 -string "TMPDIR=\"\$(getconf DARWIN_USER_TEMP_DIR)\"; export TMPDIR; exec$argv" "$tmp"
}
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
  # LaunchDaemons carrying UserName (a guest login), gui when neither exists.
  shape=gui
  if ! ls "$AGENTS"/com.claude-fleet.*.plist >/dev/null 2>&1 \
     && ls "$DDIR/com.claude-fleet.$LOGIN".*.plist >/dev/null 2>&1; then
    shape=system
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
    if [ "$shape" = gui ]; then
      label="com.claude-fleet.$u"; dst="$AGENTS/$label.plist"; dom="gui/$UID_"; pre=''
    else
      label="com.claude-fleet.$LOGIN.$u"; dst="$DDIR/$label.plist"; dom=system; pre="$SUDO"
    fi
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
    if [ "$shape" = gui ]; then label=com.claude-fleet.spinner; dst="$AGENTS/$label.plist"; dom="gui/$UID_"; pre=''
    else label="com.claude-fleet.$LOGIN.spinner"; dst="$DDIR/$label.plist"; dom=system; pre="$SUDO"; fi
    if [ ! -f "$dst" ]; then say 'daemons: skip spinner kick — not installed'
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
case "$PLATFORM" in
  launchd) daemons_launchd ;;
  systemd) daemons_systemd ;;
  *) say "daemons: skip — no launchd/systemd on this platform" ;;
esac

# --- plugin -------------------------------------------------------------------
PLUGIN=0 COPY=1
ls -d "$CDIR"/plugins/cache/*/fleet/*/commands/fleet-claim.md >/dev/null 2>&1 && PLUGIN=1
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
    if out=$(python3 "$ROOT/bin/fleet-hooks-merge.py" merge --source "$ROOT/hooks/settings-hooks.json" \
               --settings "$CDIR/settings.json" ${DRYFLAG:+"$DRYFLAG"} 2>&1); then
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

# --- commands -----------------------------------------------------------------
if [ "$COPY" = 1 ]; then
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
  if [ -f "$CDIR/commands/README.md" ] && ! is_command "$CDIR/commands/README.md"; then
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
if [ -z "$codex_command_paths$codex_skill_names" ] && ! touched conf/codex-preamble.md; then
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
      [ -d "$home" ] || { [ "$home" = "$HOME/.codex" ] || { warn=$((warn + 1)); say "codex-skills: WARN $home is not a directory — skipped"; continue; }; }
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
if [ "$COPY" = 1 ]; then
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

# --- ui -------------------------------------------------------------------------
uiargs=()
touched bin/tmux-dashboard.sh || touched bin/tmux-dashboard-rows.sh && uiargs+=(--dash)
beforeconf=''
if touched conf/tmux-attention.conf; then
  # The pre-sync conf, straight from --from — never from a shell var a caller
  # might have lost (#295) or a zsh-mangled ref (#325).
  beforeconf=$(mktemp "${TMPDIR:-/tmp}/fleet-apply-conf.XXXXXX")
  git -C "$ROOT" show "${from}:conf/tmux-attention.conf" > "$beforeconf" 2>/dev/null || : > "$beforeconf"
  uiargs+=(--conf "$beforeconf" "$ROOT/conf/tmux-attention.conf" "$HOME/.tmux.conf")
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

logins_step
finish "${from:0:7}..${to:0:7}$([ "$DRY" = 1 ] && printf ' (dry-run, nothing changed)')"
