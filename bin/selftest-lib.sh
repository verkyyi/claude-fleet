# shellcheck shell=sh
# Shared selftest primitives, sourced after each test defines BIN.
# Sourcing changes no options, environment, traps or counters. Failures exit 1;
# ST_LEG optionally names the current leg (otherwise the test's filename).
_st_say() {
  printf 'FAIL: %s: %s' "${ST_LEG:-${0##*/}}" "${1:-assertion failed}" | tr '\n\r' '  ' >&2
  [ -z "${2:-}" ] || { printf ' — %s' "$2" | tr '\n\r' '  ' >&2; }
  printf '\n' >&2
}
st_fail() { _st_say "$@"; exit 1; }
# st_miss: the same line without exiting, counted in FAIL (its owner sets FAIL=0
# and exits on it at the end) — the tests that report every miss in one run.
st_miss() { FAIL=$((FAIL + 1)); _st_say "$@"; }
st_ok() { printf 'ok   %s\n' "$1"; }
# st_eq/st_has/st_hasnt: <leg> <want|haystack> <got|needle> [detail]. A test
# that counts its checks sets ST_COUNT=1 (each assertion adds one to CHECKS);
# one that reports every miss before exiting sets ST_MISS=1 (st_miss, not st_fail).
_st_bad() { if [ -n "${ST_MISS:-}" ]; then st_miss "$@"; else st_fail "$@"; fi; }
_st_tick() { [ -z "${ST_COUNT:-}" ] || CHECKS=$((CHECKS + 1)); }
st_eq() { _st_tick; [ "$2" = "$3" ] || _st_bad "$1" "expected [$2], got [$3]${4:+ — $4}"; }
st_has() { _st_tick; case "$2" in *"$3"*) ;; *) _st_bad "$1" "missing [$3] in [$2]" ;; esac; }
st_hasnt() { _st_tick; case "$2" in *"$3"*) _st_bad "$1" "unexpected [$3] in [$2]" ;; esac; }
# st_tally [count] [miss]: start a run that tallies — FAIL=0 and CHECKS=0;
# count sets ST_COUNT, miss sets ST_MISS (above).
st_tally() {
  FAIL=0; CHECKS=0
  for _st_w in "$@"; do
    case "$_st_w" in count) ST_COUNT=1 ;; miss) ST_MISS=1 ;; esac
  done
}
# st_done: the last line of a test that counts its misses in FAIL — one line,
# exit 1 on any miss, else 0 (CHECKS, when it counted any, is named too).
st_done() {
  _st_n=''; [ "${CHECKS:-0}" -gt 0 ] 2>/dev/null && _st_n=$CHECKS
  [ "${FAIL:-0}" = 0 ] || st_fail "${FAIL} failed${_st_n:+ of ${_st_n} checks}"
  printf 'PASS %s: none failed%s\n' "${0##*/}" "${_st_n:+ (${_st_n} checks)}"
  exit 0
}
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
# st_need <tool>...: a test that cannot run without a tool says so and passes.
st_need() {
  for _st_t in "$@"; do
    command -v "$_st_t" >/dev/null 2>&1 || { printf 'selftest: %s absent — SKIP\n' "$_st_t" >&2; exit 0; }
  done
}
# Quote generated script literals, including paths containing apostrophes.
_st_quote() { printf "'"; printf '%s' "$1" | sed "s/'/'\\\\''/g"; printf "'"; }
# st_tmux_socket <bin-dir> <socket> [strip]: verbatim forwarding, including -L/-S
# args; strip first drops one leading -L/-S pair (a caller that names its own
# socket still lands on the test's). Tests that remap more keep their own shims.
st_tmux_socket() {
  mkdir -p "$1" || return 1
  { printf '#!/bin/sh\n'
    [ "${3:-}" != strip ] || printf 'case "${1:-}" in -L|-S) shift 2 ;; esac\n'
    printf 'exec '; _st_quote "$REAL_TMUX"
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
# st_fake_tmux_wlist <bin-dir>: the row producers' tmux — a list-windows asked
# with a \037-separated format prints $WLIST_FILE (the rows the test wrote);
# every other call exits 0.
st_fake_tmux_wlist() {
  mkdir -p "$1" || return 1
  cat > "$1/tmux" <<'ST_WLIST' || return 1
#!/bin/sh
US=$(printf '\037'); lw=0; fmt=0
for a in "$@"; do [ "$a" = list-windows ] && lw=1; case "$a" in *"$US"*) fmt=1 ;; esac; done
[ "$lw" = 1 ] && [ "$fmt" = 1 ] && cat "$WLIST_FILE"
exit 0
ST_WLIST
  chmod +x "$1/tmux"
}
# st_fake_tmux_opts <bin-dir> [list-panes] [set-option] [session-S] [no-send]:
# a tmux whose window options live in the file $FAKE_OPTS (key<TAB>value lines):
# display-message prints its format filled from them (#{name}, #{?c,a,b});
# set-window-option [-u] sets / unsets one. send-keys appends to $FAKE_SENDLOG
# when set, list-clients prints $FAKE_CLIENTS; anything else exits 1. The words:
# list-panes answers like display-message, set-option like set-window-option
# (-w dropped), session-S reads #S as #{session_name}, no-send refuses send-keys
# and list-clients too.
st_fake_tmux_opts() {
  _st_dir=$1; shift
  mkdir -p "$_st_dir" || return 1
  _st_flags=''; [ $# -eq 0 ] || _st_flags=$(printf '"%s",' "$@")
  { printf '#!/usr/bin/env python3\nFLAGS = set([%s])\n' "$_st_flags"
    cat <<'ST_OPTS'
import os, re, sys
a = sys.argv[1:]
if a[:1] in (["-L"], ["-S"]): a = a[2:]
path = os.environ["FAKE_OPTS"]
def load():
    d = {}
    try:
        for line in open(path):
            k, _, v = line.rstrip("\n").partition("\t"); d[k] = v
    except FileNotFoundError: pass
    return d
def save(d):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        for k, v in d.items(): f.write("%s\t%s\n" % (k, v))
    os.replace(tmp, path)
def _fx(d, f):   # innermost #{name} first; #{?cond,a,b} picks a or b
    r = re.compile(r"#\{([^#{}]*)\}")
    while True:
        m = r.search(f)
        if not m:
            return f
        k = m.group(1)
        if k.startswith("?"):
            p = k[1:].split(",", 2) + ["", ""]
            v = p[1] if p[0] else p[2]
        else:
            v = d.get(k, "")
        f = f[:m.start()] + v + f[m.end():]
verb = a[0] if a else ""
if verb == "display-message" or (verb == "list-panes" and "list-panes" in FLAGS):
    d = load(); fmt = a[-1]
    if verb == "display-message" and "session-S" in FLAGS:
        fmt = fmt.replace("#S", "#{session_name}")
    print(_fx(d, fmt))
elif verb == "set-window-option" or (verb == "set-option" and "set-option" in FLAGS):
    d = load(); unset = "-u" in a
    rest = [x for x in a[1:] if x not in (("-u", "-w") if "set-option" in FLAGS else ("-u",))]
    i = rest.index("-t"); rest = rest[:i] + rest[i+2:]
    if unset: d.pop(rest[0], None)
    else: d[rest[0]] = rest[1] if len(rest) > 1 else ""
    save(d)
elif verb == "send-keys" and "no-send" not in FLAGS:
    if os.environ.get("FAKE_SENDLOG"):
        with open(os.environ["FAKE_SENDLOG"], "a") as f: f.write(" ".join(a) + "\n")
elif verb == "list-clients" and "no-send" not in FLAGS:
    sys.stdout.write(os.environ.get("FAKE_CLIENTS", "").replace("\\n", "\n"))
else:
    sys.exit(1)
ST_OPTS
  } > "$_st_dir/tmux" || return 1
  chmod +x "$_st_dir/tmux"
}
st_fake_gh() {
  mkdir -p "$1" || return 1
  printf '#!/bin/sh\nexit 1\n' > "$1/gh" || return 1
  chmod +x "$1/gh"
}
