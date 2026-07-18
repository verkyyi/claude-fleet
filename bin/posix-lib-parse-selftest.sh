#!/bin/sh
# posix-lib-parse-selftest.sh — the regression net for issue #414.
#
# #414: fleet-lib.sh grew five `done < <(cmd)` process substitutions. `<(…)` is a
# bash-ism and a SYNTAX ERROR under POSIX sh (macOS /bin/sh = bash in POSIX mode,
# CI's /bin/sh = dash). But the conf wires the ⌂ hub tap / F9 to
# `run-shell "sh …/steward-zoom.sh --home"`, which sources fleet-lib.sh under
# `sh` — so sourcing aborted at the first `<(…)` and every later function
# (fleet_steward_pane, …) was left UNDEFINED. The ⌂ went dead when zoomed.
#
# Two nets, both here so a re-introduced bashism fails loudly the moment it lands:
#
#   PART 1 — PARSE guard. Every lib that the shared layer expects to stay
#     sourceable under sh must parse under a strict POSIX sh. This catches the
#     WHOLE class (process substitution, arrays, `[[ … ]]`), not just the one
#     symptom. Checked under `/bin/sh` (dash on CI, bash-POSIX on macOS) AND
#     `bash --posix` (reproduces the operator's production /bin/sh — bash in
#     POSIX mode, where <(…) is disabled — on ANY host, incl. the dash-based CI).
#     This is a PARSE net (`-n`); it does not assert runtime sh-safety (e.g.
#     fleet-config-lib.sh's `declare -F` is bash-only yet parse-clean) — that is a
#     separate concern. Parse-safety is exactly the property #414 broke.
#
#   PART 2 — functional EQUIVALENCE. The fix replaced each `< <(cmd)` with a
#     here-doc (`done <<EOF … $(cmd) … EOF`) so the loop stays in the current
#     shell. A here-doc differs from process substitution on EMPTY input: it runs
#     the body ONCE with an empty line, not zero times. Every converted loop is
#     guarded against that spurious pass (the `[ -n "$label" ] || continue` added
#     to fleet_list_windows_all closes the one site that lacked a guard). Part 2
#     drives the converted functions under sh, bash AND real dash against hermetic
#     fixtures and asserts identical, correct output. The dash arm also catches
#     RUNTIME bashisms `sh -n` can't see: ANSI-C quoting like `IFS=$'\t'` parses
#     fine but, under dash, IFS never becomes a tab — so `read` fails to split the
#     TSV and fleet_sess_for_repo/fleet_sockets return garbage (the CI failure on
#     PR #418). So the sh path #414 exposed can never silently regress (item 4).
#
# Fully hermetic: a fake `tmux` on PATH, temp conf trees, a throwaway git repo.
# No network, no live tmux. Exit 0 = pass, non-zero = fail (prints what diverged).
# git/bash/dash absent → the parts that need them SKIP cleanly (still exit 0).
set -u

BIN=$(cd -- "$(dirname -- "$0")" && pwd)
CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
ok()   { CHECKS=$((CHECKS + 1)); }

# The libs whose PARSE must stay POSIX-sh clean. fleet-lib.sh is MANDATORY — it is
# the one sourced under `sh` by the conf's steward-zoom path (the #414 failure).
# The siblings are guarded defensively to keep the shared lib layer free of the
# same syntax-error class. Extend this list when a new sourceable lib lands.
LIBS='fleet-lib.sh fleet-config-lib.sh fleet-land-lease.sh usage-lib.sh'

have_bash=0; command -v bash >/dev/null 2>&1 && have_bash=1
have_dash=0; command -v dash >/dev/null 2>&1 && have_dash=1

# ============================================================================
# PART 1 — PARSE guard: each lib parses under strict POSIX sh (and bash --posix)
# ============================================================================
for lib in $LIBS; do
  f="$BIN/$lib"
  [ -f "$f" ] || fail "guarded lib missing: $f"

  sh -n "$f" 2>/dev/null || {
    sh -n "$f" 2>&1 | sed 's/^/  /' >&2
    fail "sh -n rejected $lib — it is not POSIX-sh parseable (a bashism sneaked in)"
  }
  ok

  # bash --posix reproduces the production /bin/sh even on a dash CI host, where
  # a bare `sh -n` (dash) would MISS bash-POSIX-only syntax quirks and vice versa.
  if [ "$have_bash" = 1 ]; then
    bash --posix -n "$f" 2>/dev/null || {
      bash --posix -n "$f" 2>&1 | sed 's/^/  /' >&2
      fail "bash --posix -n rejected $lib (production /bin/sh would fail to source it)"
    }
    ok
  fi
done

# Targeted #414 guard: name the exact anti-pattern so a reviewer sees WHY it is
# banned (and it trips even on a lax sh that somehow parsed `<(…)`). `sh -n` above
# is the real net; this is the readable one.
for lib in $LIBS; do
  if grep -nE 'done[[:space:]]*<[[:space:]]*<\(' "$BIN/$lib" >/dev/null 2>&1; then
    grep -nE 'done[[:space:]]*<[[:space:]]*<\(' "$BIN/$lib" | sed 's/^/  /' >&2
    fail "$lib still has a process substitution (done < <(cmd)) — convert it to a here-doc"
  fi
  ok
done

# ============================================================================
# PART 2 — functional equivalence of the converted call sites under sh/bash/dash
# ============================================================================
LIB="$BIN/fleet-lib.sh"
export FLEET_SKIP_GLOBAL_CONF=1   # keep the load hermetic (issue #399 auto-source off)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/posix-lib-parse.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP

# --- fake tmux: answers has-session (down iff label in FAKE_DOWN) + list-windows.
#     An EMPTY label to list-windows is the bug the fleet_list_windows_all guard
#     prevents — emit a sentinel so an unguarded call is caught red-handed.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/tmux" <<'TMUXFAKE'
#!/bin/sh
label=""
case "${1:-}" in -L|-S) label="$2"; shift 2 ;; esac
case "${1:-}" in
  has-session)
    for d in ${FAKE_DOWN:-}; do [ "$d" = "$label" ] && exit 1; done
    exit 0 ;;
  list-windows)
    [ -z "$label" ] && { printf 'EMPTYLABEL\n'; exit 0; }
    printf 'win@%s\n' "$label"; exit 0 ;;
esac
exit 0
TMUXFAKE
chmod +x "$WORK/bin/tmux"
export PATH="$WORK/bin:$PATH"

# Run a snippet (with fleet-lib sourced) under sh, bash, AND real dash; every one
# must equal the expected value (sh vs bash must also agree). The explicit `dash`
# arm is the point: on a macOS dev box `sh` is bash-in-POSIX-mode, which HONORS
# ANSI-C quoting ($'\t'), so a runtime bashism like `IFS=$'\t'` passes there and
# would only fail on CI (where /bin/sh is dash). Driving `dash` directly catches
# that class locally too — it is what surfaced the tab-IFS bug fixed alongside the
# process substitutions. Exported env (PATH, FAKE_DOWN) reaches the children;
# per-case FLEET_CONF_DIR is set INSIDE the snippet, after sourcing, so the lib's
# own default can't clobber it.
both() {  # <desc> <expected> <snippet>
  _d=$1; _e=$2; _s=$3
  _osh=$(sh   -c ". \"$LIB\"; $_s" 2>/dev/null)
  [ "$_osh" = "$_e" ] || fail "$_d [sh]: expected [$_e] got [$_osh]"
  if [ "$have_bash" = 1 ]; then
    _oba=$(bash -c ". \"$LIB\"; $_s" 2>/dev/null)
    [ "$_oba" = "$_e" ] || fail "$_d [bash]: expected [$_e] got [$_oba]"
    [ "$_osh" = "$_oba" ] || fail "$_d: sh and bash diverged ([$_osh] vs [$_oba])"
    ok
  fi
  if [ "$have_dash" = 1 ]; then
    _oda=$(dash -c ". \"$LIB\"; $_s" 2>/dev/null)
    [ "$_oda" = "$_e" ] || fail "$_d [dash]: expected [$_e] got [$_oda] (runtime bashism — e.g. IFS=\$'\\t')"
    ok
  fi
  ok
}

# --- fixtures: three conf trees (repo-bearing / flat-sockets / empty) ---------
CONF_REPO="$WORK/conf-repo"; mkdir -p "$CONF_REPO/fleets/fleet-a"
printf 'FLEET_REPO="acme/new"\n' > "$CONF_REPO/fleets/fleet-a/conf"
CONF_SOCK="$WORK/conf-sock"; mkdir -p "$CONF_SOCK"
: > "$CONF_SOCK/s1.conf"; : > "$CONF_SOCK/s2.conf"; : > "$CONF_SOCK/s3.conf"
CONF_EMPTY="$WORK/conf-empty"; mkdir -p "$CONF_EMPTY"

# Site 138 — fleet_each_conf loop, via fleet_sess_for_repo. Match, miss, and the
# EMPTY-conf case (proves the `[ -n "$sess" ] || continue` guard: no crash, '').
both "sess_for_repo: match (site 138)" "fleet-a" \
  "FLEET_CONF_DIR='$CONF_REPO'; fleet_sess_for_repo acme/new"
both "sess_for_repo: miss → ''" "" \
  "FLEET_CONF_DIR='$CONF_REPO'; fleet_sess_for_repo acme/nope"
both "sess_for_repo: empty conf dir → '' (no spurious pass)" "" \
  "FLEET_CONF_DIR='$CONF_EMPTY'; fleet_sess_for_repo acme/new"

# Site 454 — fleet_sockets loop. Live confs (s3 down) list; empty dir lists none.
both "sockets: live confs, s3 down (site 454)" "s1,s2," \
  "FLEET_CONF_DIR='$CONF_SOCK'; export FAKE_DOWN=s3; fleet_sockets | sort | tr '\n' ','"
both "sockets: empty conf dir → '' (default tmux untouched)" "" \
  "FLEET_CONF_DIR='$CONF_EMPTY'; fleet_sockets | tr '\n' ','"

# Site 467 — fleet_list_windows_all loop (iterates fleet_sockets). Positive fan-out,
# then the KEY case: an empty conf dir must yield NO output — never the sentinel a
# `tmux -L "" list-windows` would emit. Without the added guard, the here-doc's
# lone empty line would drive exactly that spurious call.
both "list_windows_all: fan-out over live sockets (site 467)" "win@s1,win@s2,win@s3," \
  "FLEET_CONF_DIR='$CONF_SOCK'; fleet_list_windows_all '#{x}' | sort | tr '\n' ','"
both "list_windows_all: empty conf dir → no output, no EMPTYLABEL (guard)" "" \
  "FLEET_CONF_DIR='$CONF_EMPTY'; fleet_list_windows_all '#{x}' | tr '\n' ','"

# Site 579 — fleet_worktree_head loop, against a real throwaway repo (no tmux).
# A linked worktree makes the here-doc carry MULTIPLE records, so the assertions
# prove the loop selects the RIGHT one — not just that it parses.
if command -v git >/dev/null 2>&1; then
  REPO="$WORK/repo"; git init -q "$REPO"
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  BR=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)     # master or main (git default)
  MAIN_SHA=$(git -C "$REPO" rev-parse HEAD)
  git -C "$REPO" -c user.email=t@t -c user.name=t worktree add -q -b feat "$WORK/wt-feat" >/dev/null 2>&1
  FEAT_SHA=$(git -C "$REPO" rev-parse feat)

  both "worktree_head: main branch → its HEAD sha (site 579)" "$MAIN_SHA" \
    "fleet_worktree_head '$REPO' '$BR' | cut -f2"
  both "worktree_head: linked worktree → its own HEAD (right record among many)" "$FEAT_SHA" \
    "fleet_worktree_head '$REPO' feat | cut -f2"
  both "worktree_head: unknown branch → '' (full-consume, zero return)" "" \
    "fleet_worktree_head '$REPO' no-such-branch"
else
  printf 'selftest: git not installed — SKIP fleet_worktree_head equivalence\n' >&2
fi

# Site 892 (fleet_resolve_repo_for_session) shares the identical here-doc pattern
# and is covered by the PART 1 parse guard; a hermetic drive would need a fake
# tmux emitting pane paths plus a git remote — out of proportion here.

printf 'selftest OK: posix-lib-parse (%s checks — sh -n + bash --posix parse guard over %s libs; converted call sites equivalent under sh/bash/dash; #414)\n' \
  "$CHECKS" "$(printf '%s' "$LIBS" | wc -w | tr -d ' ')"
