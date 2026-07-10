#!/bin/bash
# tmux-conf-reload.sh — reload conf/tmux-attention.conf into a LIVE tmux server,
# unbinding any key binding that was *removed* from the conf first (issue #139).
#
# Why this exists: `tmux source-file` only ADDS/OVERWRITES bindings — it cannot
# remove a `bind` that was *deleted* from the conf. So when a landed change drops
# a `bind` line and /fleet-sync-install re-sources the conf, the OLD binding stays
# live in every existing session until an explicit `unbind` or a full tmux
# restart (live landing #135 removed `bind j`, but `prefix+j` stayed bound and
# resurrected the standalone dash it had just removed). This closes that gap:
# diff the before/after conf, `unbind-key` every bind that disappeared, THEN
# source the new conf so adds/changes still apply.
#
# Usage:
#   tmux-conf-reload.sh <before-conf> <after-conf> [tmux-conf]
#   tmux-conf-reload.sh --print <before-conf> <after-conf>
#
#   <before-conf>  conf/tmux-attention.conf as it was BEFORE the sync (e.g.
#                  `git show <before>:conf/tmux-attention.conf`). May be missing
#                  or empty — then nothing is treated as removed.
#   <after-conf>   the conf as it is NOW (the freshly-pulled working copy).
#   [tmux-conf]    file to `source-file` after unbinding (default ~/.tmux.conf,
#                  which is what sources tmux-attention.conf via reapply-*).
#
#   --print        parse-only: print the removed `<table>\t<key>` pairs to stdout
#                  and exit WITHOUT touching tmux. Used by the hermetic selftest
#                  and handy for a dry run.
#
# Bind-form coverage (the (table, key) extraction):
#   bind KEY …            / bind-key KEY …      → prefix table
#   bind -n KEY …         / bind-key -n KEY …   → root table
#   bind -T <tbl> KEY …                          → <tbl>
#   plus the -r (repeat) / -N <note> flags, which are skipped to find KEY.
#
# Scope: tmux bindings are server-global, so this runs against the ambient tmux
# server (the one the invoking fleet session lives on). It never targets another
# server/socket. No-op-safe: nothing removed → it just re-sources.
#
# Exit 0 on success (including "nothing removed"). Non-zero only on a usage error.
set -uo pipefail

# --- args ---------------------------------------------------------------------
print_only=0
if [ "${1:-}" = "--print" ]; then
  print_only=1
  shift
fi

before="${1:-}"
after="${2:-}"
tmux_conf="${3:-$HOME/.tmux.conf}"

if [ -z "$before" ] || [ -z "$after" ]; then
  echo "usage: tmux-conf-reload.sh [--print] <before-conf> <after-conf> [tmux-conf]" >&2
  exit 2
fi

# --- parse bind lines → "<table>\t<key>", one per bind ------------------------
# Reads a conf file; a missing/empty file yields no lines (so a brand-new conf
# has an empty "before" set and nothing counts as removed). `set -f` is REQUIRED:
# without it, word-splitting an unquoted line would glob-expand a bare `?` key
# (`bind ?`) or a `*` in the action against the cwd.
parse_binds() {
  local file="$1" line
  [ -f "$file" ] || return 0
  set -f
  while IFS= read -r line || [ -n "$line" ]; do
    # first token must be bind / bind-key (allow leading whitespace)
    case "$line" in
      *[!$' \t']*) ;;   # non-blank
      *) continue ;;
    esac
    # shellcheck disable=SC2086
    set -- $line
    case "${1:-}" in
      bind|bind-key) ;;
      *) continue ;;
    esac
    shift
    local table=prefix key=''
    while [ $# -gt 0 ]; do
      case "$1" in
        -n)     table=root; shift ;;
        -T)     table="${2:-}"; shift 2 ;;
        -N)     shift 2 ;;            # note text — skip it (and its arg)
        -r)     shift ;;             # repeatable flag — no arg
        -rn|-nr) table=root; shift ;; # combined repeat+root
        --)     shift; key="${1:-}"; break ;;
        -*)     shift ;;             # any other flag — skip
        *)      key="$1"; break ;;
      esac
    done
    [ -n "$key" ] && printf '%s\t%s\n' "$table" "$key"
  done < "$file"
  set +f
}

# removed = binds present in <before> but absent in <after>, compared by
# (table, key) — a bind that merely changed its *action* keeps its identity and
# is NOT removed (source-file overwrites it).
removed=$(comm -23 \
  <(parse_binds "$before" | sort -u) \
  <(parse_binds "$after"  | sort -u))

if [ "$print_only" -eq 1 ]; then
  [ -n "$removed" ] && printf '%s\n' "$removed"
  exit 0
fi

# --- unbind each removed bind, then re-source ---------------------------------
n=0
if [ -n "$removed" ]; then
  while IFS=$'\t' read -r table key; do
    [ -n "$key" ] || continue
    tmux unbind-key -T "$table" "$key"
    n=$((n + 1))
  done <<EOF
$removed
EOF
fi

tmux source-file "$tmux_conf"

echo "reloaded conf (unbound $n removed bind$([ "$n" -eq 1 ] || echo s))"
