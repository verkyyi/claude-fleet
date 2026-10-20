# shellcheck shell=sh
# Shared selftest primitives, sourced after each test defines BIN.
# Sourcing changes no options, environment, traps or counters. Failures exit 1;
# ST_LEG optionally names the current leg (otherwise the test's filename).
st_fail() {
  printf 'FAIL: %s: %s' "${ST_LEG:-${0##*/}}" "${1:-assertion failed}" | tr '\n\r' '  ' >&2
  [ -z "${2:-}" ] || { printf ' — %s' "$2" | tr '\n\r' '  ' >&2; }
  printf '\n' >&2
  exit 1
}
st_ok() { printf 'ok   %s\n' "$1"; }
st_eq() { [ "$2" = "$3" ] || st_fail "$1" "expected [$2], got [$3]"; }
st_has() { case "$2" in *"$3"*) ;; *) st_fail "$1" "missing [$3] in [$2]" ;; esac; }
st_hasnt() { case "$2" in *"$3"*) st_fail "$1" "unexpected [$3] in [$2]" ;; esac; }
# Exact counter/output variants already used by tests. Their owners initialize
# CHECKS/pass; keep them separate from assertions that never count or print.
st_count() { CHECKS=$((CHECKS + 1)); }
st_pass() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
st_ok_all() { printf 'ok   %s\n' "$*"; }

# st_sandbox <mktemp-template> [physical]: owns WORK and its EXIT trap only.
# Tests with custom cleanup, signals, KEEP, or another temp variable keep theirs.
st_sandbox() {
  WORK=$(mktemp -d "$1") || exit 2
  if [ "${2:-}" = physical ]; then WORK="$(cd "$WORK" && pwd -P)"; fi
  trap 'rm -rf "$WORK"' EXIT
}

# Resolve BEFORE installing a shim on PATH. Callers choose a private socket and
# keep their own socket cleanup; this never runs a command on the live server.
st_real_tmux() {
  REAL_TMUX="$(command -v tmux 2>/dev/null)"
  [ -n "$REAL_TMUX" ] || { printf 'selftest: tmux not installed — SKIP\n' >&2; exit 0; }
}
# Quote generated script literals, including paths containing apostrophes.
_st_quote() { printf "'"; printf '%s' "$1" | sed "s/'/'\\\\''/g"; printf "'"; }
# st_tmux_socket <bin-dir> <socket>: verbatim forwarding, including -L/-S args.
# Tests that strip or remap those arguments retain their specialized shims.
st_tmux_socket() {
  mkdir -p "$1" || return 1
  { printf '#!/bin/sh\nexec '; _st_quote "$REAL_TMUX"
    printf ' -S '; _st_quote "$2"; printf ' "$@"\n'
  } > "$1/tmux" || return 1
  chmod +x "$1/tmux"
}
# A no-op tmux and an offline gh; neither can fall through to a real command.
# st_fake_tmux <bin-dir> [log]: optional log gets one "$*" line per invocation.
st_fake_tmux() {
  mkdir -p "$1" || return 1
  { printf '#!/bin/sh\n'
    if [ -n "${2:-}" ]; then
      printf 'printf '\''%%s\\n'\'' "$*" >> '; _st_quote "$2"; printf '\n'
    fi
    printf 'exit 0\n'
  } > "$1/tmux" || return 1
  chmod +x "$1/tmux"
}
st_fake_gh() {
  mkdir -p "$1" || return 1
  printf '#!/bin/sh\nexit 1\n' > "$1/gh" || return 1
  chmod +x "$1/gh"
}
