#!/bin/bash
# fleet-ui-refresh.sh — re-apply landed dash/conf UI changes to EVERY live fleet's
# tmux server, not just the current one (issue #248).
#
# Why this exists: the live install (~/.claude/fleet) is SHARED by every fleet,
# but each fleet now runs on its OWN tmux socket (issue #159). /fleet-sync-install
# fast-forwards that one shared checkout, yet its two UI-refresh steps only touched
# the CURRENT fleet's server:
#   • step 7 — respawn open @dash=1 panes so a landed bin/tmux-dashboard.sh launcher
#     is picked up (fzf reads its --bind/--header once, at launch).
#   • step 8 — the unbind-aware conf reload (tmux-conf-reload.sh) so a landed
#     conf/tmux-attention.conf change (esp. a REMOVED bind) reaches the server.
# So after a sync that touched the dash launcher or the conf, every OTHER fleet
# kept a stale dash pane + stale server binds until respawned by hand. This helper
# fans BOTH refreshes out over `fleet_sockets` (the live fleets), running each
# per-server against its own `-L <label>` — the same socket-fanout shape the
# collector/bridge/watch daemons already use.
#
# The one-fleet scoping rail stays for everything NON-UI in /fleet-sync-install
# (daemons, settings, commands, charter): those touch machine-global or
# current-fleet state, not per-server UI that each fleet's own server holds a stale
# copy of. Only the dash pane + server binds are per-server, so only they fan out.
#
# Usage:
#   fleet-ui-refresh.sh --all [--dash] [--conf <before> <after> [<tmux-conf>]] [--dry-run]
#
#   --all          operate on every live fleet socket (fleet_sockets). Required —
#                  it's the only scope this helper is for; the single-fleet path
#                  is the in-session step 7/8 the skill still runs directly.
#   --dash         respawn each server's @dash=1 panes with the current launcher
#                  (bin/tmux-dashboard.sh). Wire from step 7 (launcher changed).
#   --conf B A [T] run tmux-conf-reload.sh --socket <label> B A [T] against each
#                  server (unbind removed binds, then re-source). B/A are the
#                  before/after conf; T defaults to ~/.tmux.conf. Wire from step 8
#                  (conf changed). Passing the same before-conf to every server is
#                  the best available approximation — a fleet may have sourced a
#                  different vintage, but the live install is one checkout and the
#                  unbind is harmless when a key is already gone.
#   --dry-run      print what WOULD be respawned/reloaded per socket, touch nothing.
#
# At least one of --dash / --conf must be given (else there's nothing to refresh).
#
# Fleet-scoping (the rail): every tmux call carries `-L <label>` for the fleet it
# targets — a pane id / bind is only meaningful on its own server. It iterates only
# CONFIGURED, live fleets (fleet_sockets), never the user's ad-hoc default-socket
# tmux. A socket whose server is down is simply skipped.
#
# Exit 0 on success (including "no live fleets" / "no open dash"). Non-zero only on
# a usage error or if a per-server conf reload failed.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$BIN/fleet-lib.sh"

# The dash launcher a respawned @dash pane runs. Overridable via FLEET_DASH_LAUNCHER
# ONLY so the hermetic selftest can point it at a marker script (no fzf); production
# always uses the real launcher.
DASH_LAUNCHER="${FLEET_DASH_LAUNCHER:-$BIN/tmux-dashboard.sh}"
CONF_RELOAD="$BIN/tmux-conf-reload.sh"

# --- args ---------------------------------------------------------------------
all=0 do_dash=0 do_conf=0 dry=0
conf_before='' conf_after='' conf_tmux="$HOME/.tmux.conf"

usage() {
  echo "usage: fleet-ui-refresh.sh --all [--dash] [--conf <before> <after> [<tmux-conf>]] [--dry-run]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --all)     all=1; shift ;;
    --dash)    do_dash=1; shift ;;
    --dry-run) dry=1; shift ;;
    --conf)
      # <before> <after> are required; an optional 3rd non-flag arg is <tmux-conf>.
      [ $# -ge 3 ] || { echo "fleet-ui-refresh: --conf needs <before> <after>" >&2; usage; }
      do_conf=1; conf_before="$2"; conf_after="$3"; shift 3
      if [ $# -gt 0 ]; then case "$1" in --*) ;; *) conf_tmux="$1"; shift ;; esac; fi
      ;;
    -h|--help) usage ;;
    *) echo "fleet-ui-refresh: unknown arg '$1'" >&2; usage ;;
  esac
done

[ "$all" -eq 1 ] || { echo "fleet-ui-refresh: --all is required" >&2; usage; }
[ "$do_dash" -eq 1 ] || [ "$do_conf" -eq 1 ] || {
  echo "fleet-ui-refresh: nothing to do — pass --dash and/or --conf" >&2; usage; }

# --- fan out over every live fleet socket -------------------------------------
sockets="$(fleet_sockets)"
if [ -z "$sockets" ]; then
  echo "fleet-ui-refresh: no live fleets — nothing to refresh"
  exit 0
fi

rc=0 dash_total=0 conf_total=0 fleet_n=0
while IFS= read -r label; do
  [ -n "$label" ] || continue
  fleet_n=$((fleet_n + 1))

  # -- dash panes: respawn every @dash=1 pane in this server's session ----------
  if [ "$do_dash" -eq 1 ]; then
    n=0
    for p in $(tmux -L "$label" list-panes -s -t "$label" -F '#{pane_id} #{@dash}' 2>/dev/null \
                 | awk '$2==1{print $1}'); do
      if [ "$dry" -eq 1 ]; then
        echo "[$label] would respawn dash pane $p"
      else
        tmux -L "$label" respawn-pane -k -t "$p" "bash $DASH_LAUNCHER"
      fi
      n=$((n + 1))
    done
    dash_total=$((dash_total + n))
    [ "$n" -gt 0 ] && echo "[$label] dash: $n pane(s)" || echo "[$label] dash: none open"
  fi

  # -- conf reload: unbind removed binds + re-source, on THIS server ------------
  if [ "$do_conf" -eq 1 ]; then
    if [ "$dry" -eq 1 ]; then
      echo "[$label] would reload conf ($conf_before → $conf_after via $conf_tmux)"
    else
      if out="$(bash "$CONF_RELOAD" --socket "$label" "$conf_before" "$conf_after" "$conf_tmux" 2>&1)"; then
        echo "[$label] conf: $out"
        conf_total=$((conf_total + 1))
      else
        echo "[$label] conf: FAILED — $out" >&2
        rc=1
      fi
    fi
  fi
done <<EOF
$sockets
EOF

# --- summary ------------------------------------------------------------------
summary="refreshed $fleet_n fleet(s)"
[ "$do_dash" -eq 1 ] && summary="$summary; dash panes: $dash_total"
[ "$do_conf" -eq 1 ] && summary="$summary; conf reloaded: $conf_total"
[ "$dry" -eq 1 ] && summary="(dry-run) $summary"
echo "$summary"
exit "$rc"
