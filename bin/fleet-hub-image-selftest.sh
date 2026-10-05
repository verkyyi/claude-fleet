#!/bin/bash
# fleet-hub-image-selftest.sh — bin/fleet-hub-image.sh + fleet-doctor's
# `hub-image` row (issue #1696), fully hermetic.
#
# A local BARE repo stands in for github (its refs/tags/stable is the mark); the
# hub is a file:// directory whose `version` / `healthz` files are what the
# hub's GET /version and /healthz would answer — curl reads file:// the same way.
#
# What it pins:
#   A. no hub URL        verdict NOHUB, exit 1; the doctor prints no row
#   B. hub down          UNREACHABLE — unknown, never current
#   C. no /version       (an image older than #1696) UNSTAMPED
#   D. stamp w/o sha     (`docker`) UNSTAMPED
#   E. same commit       CURRENT, behind 0
#   F. image older       BEHIND 2 — and the doctor WARNs with the count
#   G. image newer       AHEAD 1
#   H. no stable tag     UNKNOWN, never 0
#   I. hub from conf     FLEET_HUB_URL read from $FLEET_CONF_DIR/fleet.conf
#
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
HI="$BIN/fleet-hub-image.sh"
[ -f "$HI" ] || { printf 'selftest: %s not found\n' "$HI" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "fleet-hub-image-selftest SKIP (no git)"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "fleet-hub-image-selftest SKIP (no curl)"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fleet-hub-image-selftest.XXXXXX")" || exit 2
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — output does not contain [$3]:
$2";; esac; }
lacks() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — output contains [$3]:
$2";; esac; }

export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
: > "$WORK/gitconfig"
export HOME="$WORK/home" FLEET_CONF_DIR="$WORK/conf"
mkdir -p "$HOME" "$FLEET_CONF_DIR"
unset CCQUOTA_HUB_URL FLEET_HUB_URL XDG_CONFIG_HOME

BARE="$WORK/origin.git" SEED="$WORK/seed" CO="$WORK/co" HUB="$WORK/hub"
git init -q --bare -b master "$BARE"
git clone -q "$BARE" "$SEED" 2>/dev/null
commit() { echo "$1" >> "$SEED/f"; git -C "$SEED" add f; git -C "$SEED" commit -qm "$1"; git -C "$SEED" rev-parse --short HEAD; }
C1=$(commit one); C2=$(commit two); C3=$(commit three); C4=$(commit four)
git -C "$SEED" push -q origin HEAD:master
git -C "$SEED" push -q origin "$C3:refs/tags/stable"
git clone -q "$BARE" "$CO" 2>/dev/null
mkdir -p "$HUB"; echo '{"status":"ok"}' > "$HUB/healthz"
stamp() { printf '{"commit":"%s","version":"%s"}\n' "$2" "$1" > "$HUB/version"; }

run() { OUT=$(sh "$HI" --dir "$CO" "$@" 2>&1); RC=$?; }
field() { printf '%s\n' "$OUT" | sed -n "s/^$1:  *//p"; }

# --- A. no hub ---------------------------------------------------------------
run
eq "A: no hub exits 1" 1 "$RC"; eq "A: verdict NOHUB" NOHUB "$(field verdict)"
if [ -f "$BIN/fleet-doctor.sh" ]; then
  DOUT=$(FLEET_LIVE_DIR="$CO" sh "$BIN/fleet-doctor.sh" 2>&1)
  lacks "A: doctor prints no hub-image row without a hub" "$DOUT" "  hub-image "
fi

# --- B. hub down -------------------------------------------------------------
run --hub "file://$WORK/nohub"
eq "B: exit 0" 0 "$RC"; eq "B: UNREACHABLE" UNREACHABLE "$(field verdict)"

# --- C. hub without /version -------------------------------------------------
run --hub "file://$HUB"
eq "C: UNSTAMPED" UNSTAMPED "$(field verdict)"; contains "C: names #1696" "$OUT" "predates #1696"

# --- D. stamp without a sha ----------------------------------------------------
stamp docker ""
run --hub "file://$HUB"
eq "D: UNSTAMPED" UNSTAMPED "$(field verdict)"; eq "D: image" docker "$(field image)"

# --- E. same commit -------------------------------------------------------------
stamp "prod-$C3" "$C3"
run --hub "file://$HUB/"
eq "E: CURRENT" CURRENT "$(field verdict)"; eq "E: behind 0" 0 "$(field behind)"; eq "E: commit" "$C3" "$(field commit)"

# --- F. image older than stable -----------------------------------------------------
stamp "prod-$C1" "$C1"
run --hub "file://$HUB"
eq "F: BEHIND" BEHIND "$(field verdict)"; eq "F: behind 2" 2 "$(field behind)"
if [ -f "$BIN/fleet-doctor.sh" ]; then
  DOUT=$(FLEET_LIVE_DIR="$CO" FLEET_HUB_URL="file://$HUB" sh "$BIN/fleet-doctor.sh" 2>&1)
  contains "F: doctor WARNs hub-image" "$DOUT" "WARN  hub-image "
  contains "F: doctor names the commit" "$DOUT" "入口镜像 commit $C1 落后 stable"
  contains "F: doctor names the count" "$DOUT" "2 个 commit"
fi

# --- G. image newer than stable -------------------------------------------------------
stamp "prod-$C4" "$C4"
run --hub "file://$HUB"
eq "G: AHEAD" AHEAD "$(field verdict)"; eq "G: ahead 1" 1 "$(field ahead)"

# --- H. no stable tag ---------------------------------------------------------------------
git -C "$SEED" push -q origin :refs/tags/stable
run --hub "file://$HUB"
eq "H: UNKNOWN" UNKNOWN "$(field verdict)"; eq "H: stable none" none "$(field stable)"
git -C "$SEED" push -q origin "$C3:refs/tags/stable"

# --- I. hub URL from the machine's one config file --------------------------------------------
printf '# [common]\nexport FLEET_HUB_URL="file://%s"\nexport CCQUOTA_HUB_URL="$FLEET_HUB_URL"\n' "$HUB" > "$FLEET_CONF_DIR/fleet.conf"
stamp "prod-$C3" "$C3"
run
eq "I: hub read from fleet.conf" "file://$HUB" "$(field hub)"; eq "I: CURRENT" CURRENT "$(field verdict)"

printf 'fleet-hub-image-selftest OK (%d checks)\n' "$CHECKS"
