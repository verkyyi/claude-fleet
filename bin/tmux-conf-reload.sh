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
#   tmux-conf-reload.sh [--socket <label>] <before-conf> <after-conf> [tmux-conf]
#   tmux-conf-reload.sh --print <before-conf> <after-conf>
#
#   <before-conf>  conf/tmux-attention.conf as it was BEFORE the sync (e.g.
#                  `git show <before>:conf/tmux-attention.conf`). May be missing
#                  or empty — then nothing is treated as removed, and the report
#                  SAYS so ("no readable before-conf …") instead of a bare
#                  "unbound 0", so a lost snapshot can't masquerade as a clean
#                  reload (issue #295).
#   <after-conf>   the conf as it is NOW (the freshly-pulled working copy).
#   [tmux-conf]    file to `source-file` after unbinding (default ~/.tmux.conf,
#                  which is what sources tmux-attention.conf via reapply-*).
#
#   --print        parse-only: print the removed `<table>\t<key>` pairs to stdout
#                  and exit WITHOUT touching tmux. Used by the hermetic selftest
#                  and handy for a dry run.
#   --socket <l>   run the unbind + source-file against the tmux server on socket
#                  LABEL `<l>` (`tmux -L <l> …`) instead of the ambient server.
#                  This is what lets fleet-ui-refresh.sh reload a conf into EVERY
#                  live fleet's own server (issue #248) — each fleet now has its
#                  own socket (#159), so a bare `tmux` would only hit one. Default
#                  (no --socket) = the ambient server, as the in-session caller
#                  (`/fleet-sync-install` step 8) inherits it via $TMUX.
#
# Bind-form coverage (the (table, key) extraction):
#   bind KEY …            / bind-key KEY …      → prefix table
#   bind -n KEY …         / bind-key -n KEY …   → root table
#   bind -T <tbl> KEY …                          → <tbl>
#   plus the -r (repeat) / -N <note> flags, which are skipped to find KEY.
#
# Scope: tmux bindings are server-global, so this runs against ONE tmux server —
# the ambient one (the invoking fleet session's) by default, or the `--socket
# <label>` server when given. It targets exactly that one server; to reload every
# live fleet, fleet-ui-refresh.sh --all calls this once per socket (issue #248).
# No-op-safe: nothing removed → it just re-sources.
#
# Exit 0 on success (including "nothing removed"). Non-zero only on a usage error.
set -uo pipefail

# --- args ---------------------------------------------------------------------
# Optional flags (--print / --socket <label>) may appear in any order before the
# positional confs. `tmux_cmd` is the tmux invocation used for the LIVE calls
# (unbind-key / source-file); --socket prepends `-L <label>` so it targets that
# fleet's own server (issue #248) instead of the ambient one.
print_only=0
tmux_cmd=(tmux)
while [ $# -gt 0 ]; do
  case "$1" in
    --print)  print_only=1; shift ;;
    --socket) [ $# -ge 2 ] || { echo "usage: --socket needs a label" >&2; exit 2; }
              tmux_cmd=(tmux -L "$2"); shift 2 ;;
    *)        break ;;
  esac
done

before="${1:-}"
after="${2:-}"
tmux_conf="${3:-$HOME/.tmux.conf}"

# `after` is required (it's the reload target). `before` is OPTIONAL and fails
# OPEN: a missing/empty before-conf just means "no snapshot to diff removals
# against" — handled below (before_usable=0) by re-sourcing anyway so ADDS still
# apply, warning that removals couldn't be detected. Bailing here on an empty
# before would leave every server on its old binds silently, which is exactly the
# failure this tool exists to prevent (issues #295, #325).
if [ -z "$after" ]; then
  echo "usage: tmux-conf-reload.sh [--print] <before-conf> <after-conf> [tmux-conf]" >&2
  exit 2
fi

# --- parse bind lines → "<table>\t<key>", one per bind ------------------------
# Reads a conf file; a missing/empty file yields no lines (so a brand-new conf
# has an empty "before" set and nothing counts as removed). `set -f` is REQUIRED:
# without it, word-splitting an unquoted line would glob-expand a bare `?` key
# (`bind ?`) or a `*` in the action against the cwd.
# `-N <note>` is the one bind flag whose argument can contain spaces (`bind -N
# "reload the conf" R …`). Word-splitting a quoted note would desync the token
# stream and hand a note word to KEY, so strip the note (double-quoted or a bare
# word) off the line BEFORE splitting. Kept in a var to dodge regex quoting hell.
NOTE_RE='^(.*[[:space:]])-N[[:space:]]+("[^"]*"|[^[:space:]]+)(.*)$'

parse_binds() {
  local file="$1" line
  [ -f "$file" ] || return 0
  set -f
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ $NOTE_RE ]] && line="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
    # shellcheck disable=SC2086
    set -- $line          # blank line → no args → the case below `continue`s
    case "${1:-}" in
      bind|bind-key) ;;
      *) continue ;;
    esac
    shift
    local table=prefix key=''
    while [ $# -gt 0 ]; do
      case "$1" in
        -n)      table=root; shift ;;
        -rn|-nr) table=root; shift ;; # combined repeat+root
        -r)      shift ;;             # repeatable flag — no arg
        -T)      [ $# -ge 2 ] || break  # malformed trailing -T: bail, don't spin
                 table="$2"; shift 2 ;;
        --)      shift; key="${1:-}"; break ;;
        -)       key='-'; break ;;    # a literal `-` is a key, not a flag
        -?*)     shift ;;             # any other flag — skip
        *)       key="$1"; break ;;
      esac
    done
    [ -n "$key" ] && printf '%s\t%s\n' "$table" "$key"
  done < "$file"
  set +f
}

# A before-conf that is absent or EMPTY yields no removed set — but that "0
# removed" is ambiguous: it also fires when a caller hands in a broken/empty
# before-conf. That is exactly how issue #295 slipped by — a lost pre-sync conf
# snapshot let removed binds (A/R/u) stay live on both servers while this pass
# cheerfully reported "unbound 0 removed binds". Flag when there was NO usable
# before-conf to diff so the report below can't mask a stale-bind miss. A genuinely
# brand-new conf legitimately hits this too; the honest wording covers both.
before_usable=1
[ -s "$before" ] || before_usable=0

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
    "${tmux_cmd[@]}" unbind-key -T "$table" "$key"
    n=$((n + 1))
  done <<EOF
$removed
EOF
fi

if "${tmux_cmd[@]}" source-file "$tmux_conf"; then
  if [ "$before_usable" -eq 0 ]; then
    # No before-conf to diff → removals could NOT be detected. Do not report a
    # bare "unbound 0" that reads like a clean reload (issue #295): say so plainly
    # so a lost snapshot is visible in the fan-out output, not silently swallowed.
    echo "reloaded conf (no readable before-conf — removed binds NOT diffed; a dropped bind stays live)"
  else
    echo "reloaded conf (unbound $n removed bind$([ "$n" -eq 1 ] || echo s))"
  fi
else
  # unbinds already applied; only the re-source failed — say so, don't claim a
  # clean reload the caller would surface as success.
  echo "unbound $n removed bind$([ "$n" -eq 1 ] || echo s), but 'source-file $tmux_conf' FAILED — adds/changes not applied" >&2
  exit 1
fi
