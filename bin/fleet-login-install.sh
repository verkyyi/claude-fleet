#!/bin/bash
# fleet-login-install.sh — a new login's ~/.claude/fleet, from this machine or the
# hub, never GitHub when either has it (issue #2775, EPIC #2770 C5). The ONE
# install road of a login's first minute: fleet-login-bootstrap.sh's `install`
# step runs it, and so does fleet-login-new.sh's step 7 (as the login, before its
# services and its first session). Three sources, the first that holds:
#
#   runtime  a managed machine (<root>/current → <root>/<sha>, the machine
#            updater's): ~/.claude/fleet becomes a tree of links into it —
#            `fleet-node-update.py link-tree <sha> --no-apply`, the runtime's own
#            copy (issue #2774) — no fetch at all, milliseconds. The login must be
#            adopted (`account adopt`) for the machine to move it later; a login
#            that is not is named on stderr.
#   hub      a hub that keeps releases (FLEET_HUB_URL / CCQUOTA_HUB_URL, or the
#            login's fleet.conf): its signed stable — the key pinned now
#            ($FLEET_CONF_DIR/release.pub), the tree verified by ccquota, imported
#            as ONE local commit on master (fleet-release-lib.sh, issue #2773); no
#            remote. FLEET_DIST_SOURCE=github skips it.
#   git      neither — a developer's machine with no hub (EPIC #2770 共同约定 7):
#            `git clone -b stable` of FLEET_BOOTSTRAP_GIT_BASE, on master tracking
#            origin/master so install-sync fast-forwards it. Today's road.
#
# The machine's old bootstrap mirror (fleet-bootstrap-cache.sh's claude-fleet.git)
# is not read: a runtime or the hub is the version, a mirror filled at the last
# opening was usually an old one.
#
# An install already there is reported, never touched: a checkout or a tree linked
# to a runtime is `present`; anything else is an error (move it aside).
#
# Prints ONE line on stdout: `<source> <sha> <what>` (source: runtime | hub | git
# | present). A made install also leaves $FLEET_CONF_DIR/global/bootstrap.install —
# `<source> <sha> <seconds> <UTC>` — so the bootstrap's timing names where the
# install came from and how long it took even when fleet-login-new.sh made it.
#
# Usage: fleet-login-install.sh [<dir>]       (default: FLEET_INSTALL_ROOT, ~/.claude/fleet)
# Env:   FLEET_NODE_ROOT (/Library/Application Support/claude-fleet) ·
#        FLEET_HUB_URL · FLEET_DIST_SOURCE · FLEET_CONF_DIR (~/.config/claude-fleet) ·
#        FLEET_BOOTSTRAP_GIT_BASE (https://github.com — the developer road; a seam)
# Exit:  0 the install is there · 1 not made (stderr says why; nothing left half) · 2 usage
set -uo pipefail

PROG=fleet-login-install
here=$(cd "$(dirname "$0")" && pwd)
ROOT="${1:-${FLEET_INSTALL_ROOT:-$HOME/.claude/fleet}}"; ROOT=${ROOT%/}
[ $# -le 1 ] || { printf 'usage: %s [<dir>]\n' "$PROG" >&2; exit 2; }
case "$ROOT" in -*) printf 'usage: %s [<dir>]\n' "$PROG" >&2; exit 2 ;; esac
CONF="${FLEET_CONF_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-fleet}"
NROOT="${FLEET_NODE_ROOT:-/Library/Application Support/claude-fleet}"; NROOT=${NROOT%/}
GITBASE="${FLEET_BOOTSTRAP_GIT_BASE:-https://github.com}"  # dist-ok: the developer road — no runtime, no hub that keeps releases (EPIC #2770 共同约定 7)
SELF=verkyyi/claude-fleet

err() { printf '%s: %s\n' "$PROG" "$*" >&2; }
now() { date +%s; }
T0=$(now)
# made <source> <sha> <what> — the one stdout line + the record the bootstrap times
made() {
  mkdir -p "$CONF/global" 2>/dev/null \
    && printf '%s %s %s %s\n' "$1" "$2" "$(( $(now) - T0 ))" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CONF/global/bootstrap.install" 2>/dev/null
  printf '%s %s %s\n' "$1" "$2" "$3"
}
# linked_sha <dir> — the release a tree linked by the updater names (its .fleet-linked)
linked_sha() { sed -n 's/.*"sha": *"\([0-9a-f]\{40\}\)".*/\1/p' "$(cd "$1" 2>/dev/null && pwd -P)/.fleet-linked" 2>/dev/null; }

# --- already there -------------------------------------------------------------
if [ -e "$ROOT" ] || [ -L "$ROOT" ]; then
  if [ -d "$ROOT/.git" ]; then
    printf 'present %s a checkout\n' "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo -)"; exit 0
  fi
  s=$(linked_sha "$ROOT")
  [ -n "$s" ] && { printf 'present %s linked to the runtime\n' "$s"; exit 0; }
  err "$ROOT exists but is neither a git checkout nor linked to the runtime — move it aside and run again"
  exit 1
fi
mkdir -p "$(dirname "$ROOT")" || { err "cannot make $(dirname "$ROOT")"; exit 1; }

# --- runtime: the managed machine's own copy ------------------------------------
rsha=$(readlink "$NROOT/current" 2>/dev/null); rsha=${rsha%/}; rsha=${rsha##*/}
case "$rsha" in *[!0-9a-f]*) rsha='' ;; esac
[ "${#rsha}" = 40 ] && [ -d "$NROOT/$rsha/bin" ] || rsha=''
if [ -n "$rsha" ]; then
  if [ "$ROOT" != "$HOME/.claude/fleet" ]; then
    err "a runtime is here ($NROOT/current), but link-tree makes ~/.claude/fleet only, not $ROOT — trying the hub"
  else
    upd="$NROOT/current/bin/fleet-node-update.py"
    [ -f "$upd" ] || upd="$here/fleet-node-update.py"
    out=$(FLEET_NODE_ROOT="$NROOT" python3 -I "$upd" link-tree "$rsha" --no-apply 2>&1 </dev/null); rc=$?
    if [ "$rc" = 0 ] && [ "$(linked_sha "$ROOT")" = "$rsha" ]; then
      mkdir -p "$ROOT/logs" 2>/dev/null
      made runtime "$rsha" "linked to this machine's runtime $NROOT/$rsha (no fetch)"
      if [ -f "$here/fleet-daemon-lib.sh" ]; then
        # shellcheck source=fleet-daemon-lib.sh
        . "$here/fleet-daemon-lib.sh"
        fleet_node_manages "${USER:-$(id -un)}" \
          || err "note: $(id -un) is not adopted yet — until an admin runs \`sudo python3 '$NROOT/current/bin/fleet-node-supervisor.py' account adopt $(id -un)\` the machine does not move this install with it (fleet-login-new.sh does that at its step 8)"
      fi
      exit 0
    fi
    err "link-tree $rsha did not link ~/.claude/fleet (rc $rc: $(printf '%s' "$out" | tail -n 1)) — trying the hub"
    [ -L "$ROOT" ] && [ -z "$(linked_sha "$ROOT")" ] && rm -f "$ROOT"
  fi
fi

# --- hub: its signed stable -----------------------------------------------------
if [ "${FLEET_DIST_SOURCE:-}" != github ] && [ -f "$here/fleet-release-lib.sh" ]; then
  # shellcheck source=fleet-release-lib.sh
  . "$here/fleet-release-lib.sh"
  new="$ROOT.new.$$"; rm -rf "$new"
  fleet_rel_first_checkout "$new" "$CONF" 30; hrc=$?
  case "$hrc" in
    0) git -C "$new" checkout -q -B master 2>/dev/null
       if mv "$new" "$ROOT"; then
         made hub "$REL_SHA" "the hub's stable, verified ($REL_FPR), from $REL_HUB — not GitHub"; exit 0
       fi
       rm -rf "$new"; err "the hub's stable verified, but cannot move it to $ROOT"; exit 1 ;;
    3) ;;  # no hub, or one that keeps no releases: the developer road
    *) rm -rf "$new"
       err "the hub ($REL_HUB) did not give its stable — $REL_STAGE: ${REL_ERR:-?}. Nothing was made; run again (FLEET_DIST_SOURCE=github takes GitHub instead)"
       exit 1 ;;
  esac
fi

# --- git: a developer's machine -------------------------------------------------
if ! git -c advice.detachedHead=false clone -q -b stable "$GITBASE/$SELF.git" "$ROOT" 2>/dev/null </dev/null; then
  rm -rf "$ROOT"
  err "git clone $GITBASE/$SELF.git failed (offline?) — no runtime here, no hub that keeps releases"
  exit 1
fi
# `clone -b stable` leaves HEAD detached at the tag: name it master (tracking
# origin/master) so install-sync's `merge --ff-only stable` moves a branch.
git -C "$ROOT" checkout -q -B master 2>/dev/null \
  && git -C "$ROOT" branch -q --set-upstream-to=origin/master master 2>/dev/null
made git "$(git -C "$ROOT" rev-parse HEAD)" "cloned $SELF at stable from $GITBASE (no runtime, no hub that keeps releases)"
