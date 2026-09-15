#!/bin/sh
# selftest-shadow-root.sh — build a CONF-FREE mirror of an install root, print its path.
#
# The problem it solves (issue #660)
# -----------------------------------
# Every fleet script resolves the global config RELATIVE TO ITS OWN bin/:
#
#     [ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
#
# ~60 scripts do exactly that, plus fleet-lib.sh on load. From a clean checkout the
# repo root has no `fleet.conf` (only `fleet.conf.example` is tracked), so every
# script falls back to its defaults and the suite is all green. From the LIVE
# install — `~/.claude/fleet/bin/run-selftests.sh`, the most natural way for an
# operator to ask "is this machine healthy?" — that same path is the operator's
# REAL config, and FLEET_REPO / FLEET_MAIN / FLEET_CTX_WINDOW / CCQUOTA_HUB_URL …
# leak into tests that assert on defaults. Six tests went red on a commit that is
# all-green from a checkout. Fake red is worse than no test: it trains people to
# ignore the colour, and it makes "does the code on this machine actually run?"
# unanswerable right after `docs/INSTALL.md` told a new user to check.
#
# Why a shadow ROOT and not an env override
# ------------------------------------------
# The obvious fix — one env knob (`FLEET_CONF=/dev/null`) honoured by all ~60 load
# sites — is wrong here, and not only because it is 60 edits that a 61st script can
# silently skip. Several selftests (fleet-claude, fleet-codex, dash-agent-toggle,
# fleet-lib, …) deliberately build their OWN sandbox bin/ + fleet.conf and assert
# that the relative lookup finds it. A global env override neutralises those
# sandboxes too, so the knob would break the very tests that already got isolation
# right. Swapping the ROOT leaves relative resolution exactly as it is — it just
# points it somewhere with nothing of the operator's in it.
#
# How the mirror is built
# ------------------------
#   <shadow>/bin/        REAL directory, one symlink per file in the real bin/
#   <shadow>/logs/       REAL directory, EMPTY
#   <shadow>/conf-dir/   REAL directory, EMPTY — a FLEET_CONF_DIR for the caller to
#                        export, so fleet_load_conf finds no per-fleet overlay either
#   <shadow>/.claude-plugin/  COPIED, not symlinked — `claude plugin validate` refuses
#                        to follow a symlink and would validate nothing
#   <shadow>/<rest>      symlink to the real entry (docs, hooks, conf, skills,
#                        fleet.conf.example, .git, .github, …)
#   <shadow>/fleet.conf  ABSENT — the whole point
#
# `bin/` must be a real directory holding per-file symlinks, NOT a symlink to the
# real bin/. `$BIN` is computed with a LOGICAL `cd "$(dirname "$0")" && pwd`, so a
# script invoked as `<shadow>/bin/foo.sh` does see `$BIN=<shadow>/bin` either way —
# but `[ -f "$BIN/../fleet.conf" ]` is resolved by the KERNEL, which walks symlinks
# physically: with a symlinked bin/ it lands back on the real root and reads the
# real conf. A real dir of symlinks is what keeps `..` honest.
#
# `logs/` is emptied for the same reason one level down: it is not config, it is
# live STATE. `bin/tmux-spinner.sh` keeps its needs-reconcile strike table at
# `$BIN/../logs/.needs-strikes` and `bin/classify-sessions.sh` its change-gate
# hashes at `$BIN/../logs/.classify-cache`. Symlinked through, a suite run on a
# live install would read AND CLOBBER the running fleet's own state.
#
# SIX selftests reach those two files, not two — and not through their own code
# but through the scripts they drive: attn-signal, fleet-collect-stale and
# needs-reconcile all run tmux-spinner.sh, while helper-auth, auto-handoff and
# fleet-history all run classify-sessions.sh. They are safe only because the
# suite runs its tests ONE AT A TIME (each shard sequential, issue #681): two of
# a group in flight at once in the same root would trade state. Anything that
# would run them concurrently needs a root per concurrent slot, not a list of
# known state files — the #660 lesson is that such a list always misses the next
# script to keep something here.
#
# `fleet.conf.bak*` is skipped alongside `fleet.conf`: those are the config modal's
# backup slots (`fcfg_write`, bin/fleet-config-lib.sh) and older residue, and
# nothing should be able to resurrect a conf from them.
#
# Usage
# ------
#   selftest-shadow-root.sh [REAL_ROOT]
#
#   REAL_ROOT  install root to mirror (default: the parent of this script's dir).
#   stdout     the shadow root path. The CALLER owns it and must `rm -rf` it —
#              it holds only symlinks and empty dirs, so removing it never
#              touches the real tree.
#
# The temp dir is named `fleet-selftest-root.*` so that `fleet-selftest-reap.sh`
# (which sweeps aged `*selftest*` mktemp dirs) collects one orphaned by a SIGKILLed
# run.
#
# The links are made in ONE `ln -s src… dir/` per group rather than one fork per
# entry: bin/ holds 233 files, and a fork each cost ~1.6s of every gate run (and
# every nested one) for nothing. Batched it is ~50-250ms — which also keeps the
# prelude honest now that CI pays it once per shard job (issue #681).
set -u

unset CDPATH

# link_into <target-dir> <src>... — symlink each src into target-dir under its own
# basename. Batched into a single `ln -s` (see above); a name carrying whitespace
# or a glob character cannot ride in an unquoted list, so it gets its own call.
link_into() {
  _d=$1; shift
  _batch=''
  for _s in "$@"; do
    case "$_s" in
      *[!A-Za-z0-9_./+@:,=~-]*) ln -s "$_s" "$_d/${_s##*/}" || return 1 ;;
      *) _batch="$_batch $_s" ;;
    esac
  done
  [ -n "$_batch" ] || return 0
  # shellcheck disable=SC2086  # intentional: $_batch is the batched source list
  ln -s $_batch "$_d/"
}

self_dir=$(cd -- "$(dirname -- "$0")" && pwd) || exit 2
real=${1:-$(cd -- "$self_dir/.." && pwd)} || exit 2
[ -d "$real/bin" ] || { echo "selftest-shadow-root: $real has no bin/" >&2; exit 2; }

shadow=$(mktemp -d "${TMPDIR:-/tmp}/fleet-selftest-root.XXXXXX") || exit 2
mkdir -p "$shadow/bin" "$shadow/logs" "$shadow/conf-dir" || exit 2

# Top-level entries, dotfiles included. An unmatched glob stays literal under sh,
# which the -e/-L guard drops; `..?*` catches a `..foo` without ever matching `..`.
set --
for e in "$real"/* "$real"/.[!.]* "$real"/..?*; do
  [ -e "$e" ] || [ -L "$e" ] || continue
  b=${e##*/}
  case "$b" in
    bin|logs|conf-dir) continue ;;           # rebuilt above: real dirs, not symlinks
    fleet.conf|fleet.conf.bak*) continue ;;  # the leak itself
    # `claude plugin validate` never follows a symlink: with .claude-plugin symlinked
    # it reports `Local source "./" is or traverses a symlink` and reads no manifest
    # at all, so fleet-plugin-selftest.sh goes red having validated nothing — the same
    # fake failure by another route. The manifests are two small JSON files; copy them.
    .claude-plugin) cp -R "$e" "$shadow/$b" || exit 2; continue ;;
  esac
  set -- "$@" "$e"
done
[ "$#" -eq 0 ] || link_into "$shadow" "$@" || exit 2

# Same three globs for bin/: it holds DOTFILES too — `.fleet-restore-resolve.py` is
# a private helper bin/dash-raw-session.sh resolves as `$BIN/.fleet-restore-resolve.py`,
# and a `*`-only mirror silently drops it (the selftest that needs it then fails setup,
# which is the same fake red this whole file exists to prevent).
set --
for f in "$real"/bin/* "$real"/bin/.[!.]* "$real"/bin/..?*; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  set -- "$@" "$f"
done
[ "$#" -eq 0 ] || link_into "$shadow/bin" "$@" || exit 2

printf '%s\n' "$shadow"
