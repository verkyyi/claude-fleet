#!/bin/bash
# fleet-codex-version-selftest.sh — the Codex version check (issue #1079).
#
# fleet reads a Codex worker's context% out of Codex's rollout file, a format
# verified only on the versions in fleet-codex-runtime.py
# (SUPPORTED_ROLLOUT_VERSIONS). Pinned here:
#   * version-check: 0.154.0 / 0.154.7 → exit 0; 0.160.0 / 0.1540.0 → exit 1
#     (a prefix matches whole components only); garbage → exit 2; missing → 2.
#   * doctor `codex` row: verified → PASS; unverified → WARN naming the pin
#     command AND the silencer (EPIC #1074 rule 9); not installed → INFO;
#     FLEET_CODEX_VERSION_CHECK=0 (env or fleet.settings) → no row; the row
#     prints nothing on stderr.
#   * launcher: an unverified version still LAUNCHES (warn, never block), warns
#     exactly once on stderr, and hands the line to the session hook through
#     FLEET_CODEX_VERSION_WARNING; a verified one is silent; =0 skips the check.
#
# Hermetic: fake `codex` / `uname` on PATH, scratch HOME/TMPDIR/conf, no tmux.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$BIN/.." && pwd)"
for f in fleet-doctor.sh fleet-codex.sh fleet-codex-runtime.py fleet-lib.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done
command -v python3 >/dev/null 2>&1 || { echo 'selftest: python3 missing — skip'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/codex-version-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/fake" "$WORK/conf" "$WORK/install/bin" "$WORK/install/conf" "$WORK/wt"

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; printf -- '--- detail ---\n%s\n' "${2:-(none)}" >&2; exit 1; }
has()  { CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) ;; *) fail "$3" "$2";; esac; }
lacks(){ CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) fail "$3" "$2";; esac; }
eq()   { CHECKS=$((CHECKS + 1)); [ "$1" = "$2" ] || fail "$3" "got '$1', want '$2'"; }

# fake codex: `--version` prints the fixture; anything else is "the launch" —
# records argv and the warning env the launcher exported.
cat > "$WORK/fake/codex" <<SH
#!/bin/sh
if [ "\$1" = --version ]; then cat "$WORK/codex.version"; exit "\$(cat "$WORK/codex.rc" 2>/dev/null || echo 0)"; fi
printf '%s\n' "\$*" > "$WORK/launched"
printf '%s' "\${FLEET_CODEX_VERSION_WARNING:-}" > "$WORK/launch.warn"
exit 0
SH
chmod +x "$WORK/fake/codex"
setv() { printf '%s\n' "$1" > "$WORK/codex.version"; echo "${2:-0}" > "$WORK/codex.rc"; }

# A PATH with no real codex on it — every dir that holds one is dropped.
CLEAN=""
IFS=: ; for d in $PATH; do [ -x "$d/codex" ] && continue; CLEAN="${CLEAN:+$CLEAN:}$d"; done; unset IFS

# ============================================================================
# 1. version-check itself
# ============================================================================
vc() { PATH="$WORK/fake:$CLEAN" python3 "$BIN/fleet-codex-runtime.py" version-check; }
setv 'codex-cli 0.154.0';  out=$(vc); eq "$?" 0 "1a: 0.154.0 must be verified"; has "0.154.0" "$out" "1a: line names the version"
setv 'codex-cli 0.154.7';  vc >/dev/null; eq "$?" 0 "1b: 0.154.7 matches the 0.154 prefix"
setv 'codex-cli 0.160.0';  out=$(vc); eq "$?" 1 "1c: 0.160.0 must be unverified"
has "npm i -g @openai/codex@0.154.0" "$out" "1c: the line names the pin command"
has "FLEET_CODEX_VERSION_CHECK=0" "$out" "1c: the line names the silencer"
setv 'codex-cli 0.1540.0'; vc >/dev/null; eq "$?" 1 "1d: 0.1540 is NOT 0.154 (whole components)"
setv 'codex-cli 0.15.2';   vc >/dev/null; eq "$?" 1 "1e: 0.15 is NOT 0.154"
setv 'no version here';    vc >/dev/null; eq "$?" 2 "1f: unreadable output → 2"
setv 'codex-cli 0.154.0' 3; vc >/dev/null; eq "$?" 2 "1g: a failing --version → 2"
out=$(PATH="$CLEAN" python3 "$BIN/fleet-codex-runtime.py" version-check); eq "$?" 2 "1h: not installed → 2"
has "not installed" "$out" "1h: says not installed"

# ============================================================================
# 2. the doctor row
# ============================================================================
printf 'Linux\n' > "$WORK/os"   # keep the macOS host section out of the way
cat > "$WORK/fake/uname" <<SH
#!/bin/sh
[ "\$1" = -s ] && { cat "$WORK/os"; exit 0; }
exec /usr/bin/uname "\$@"
SH
chmod +x "$WORK/fake/uname"
mkdir -p "$WORK/dbin"
for f in fleet-doctor.sh fleet-diskguard.sh fleet-lib.sh fleet-daemon-lib.sh fleet-daemon-loaded.sh fleet-codex-runtime.py; do
  [ -f "$BIN/$f" ] && cp "$BIN/$f" "$WORK/dbin/"
done
doctor() {   # $1 = PATH prefix ('' = no codex at all)
  PATH="${1:+$1:}$CLEAN" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
  FLEET_CONF_DIR="$WORK/conf" sh "$WORK/dbin/fleet-doctor.sh" 2>"$WORK/stderr"
}
row() { printf '%s\n' "$1" | grep -aE '^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+codex([[:space:]]|$)' | head -1; }
quiet() { CHECKS=$((CHECKS + 1)); [ -s "$WORK/stderr" ] && grep -a 'codex\|_gconf\|runtime' "$WORK/stderr" >/dev/null && fail "$1" "$(cat "$WORK/stderr")"; return 0; }

setv 'codex-cli 0.154.0'; l=$(row "$(doctor "$WORK/fake")")
has PASS "$l" "2a: a verified codex must PASS"; quiet "2a: no codex noise on stderr"
setv 'codex-cli 0.160.0'; l=$(row "$(doctor "$WORK/fake")")
has WARN "$l" "2b: an unverified codex must WARN"
has "npm i -g @openai/codex@0.154.0" "$l" "2b: the WARN names the pin command"
has "FLEET_CODEX_VERSION_CHECK=0" "$l" "2b: the WARN names the silencer (EPIC rule 9)"
quiet "2b: no codex noise on stderr"
l=$(row "$(doctor '')"); has INFO "$l" "2c: codex not installed must be INFO"; has "not installed" "$l" "2c: says so"
l=$(row "$(FLEET_CODEX_VERSION_CHECK=0 doctor "$WORK/fake")"); eq "$l" "" "2d: FLEET_CODEX_VERSION_CHECK=0 (env) drops the row"
echo 'FLEET_CODEX_VERSION_CHECK=0' > "$WORK/conf/fleet.settings"
l=$(row "$(doctor "$WORK/fake")"); eq "$l" "" "2e: FLEET_CODEX_VERSION_CHECK=0 in fleet.settings drops the row"
rm -f "$WORK/conf/fleet.settings"

# ============================================================================
# 3. the launcher: warn once, never block
# ============================================================================
for f in fleet-codex.sh fleet-lib.sh fleet-codex-runtime.py fleet-hooks-emit.sh set-claude-state.sh; do
  [ -f "$BIN/$f" ] && ln -s "$BIN/$f" "$WORK/install/bin/$f"
done
ln -s "$ROOT/commands" "$WORK/install/commands"; ln -s "$ROOT/hooks" "$WORK/install/hooks"
ln -s "$ROOT/conf/codex-preamble.md" "$WORK/install/conf/codex-preamble.md"
: > "$WORK/install/fleet.conf"
printf '#!/bin/sh\nexit 0\n' > "$WORK/install/bin/fleet-account.sh"; chmod +x "$WORK/install/bin/fleet-account.sh"
mkdir -p "$WORK/codexhome"
launch() {
  rm -f "$WORK/launched" "$WORK/launch.warn"
  ( cd "$WORK/wt" && env -u TMUX -u TMUX_PANE -u FLEET_CODEX_VERSION_WARNING \
      PATH="$WORK/fake:/usr/bin:/bin" HOME="$WORK" CODEX_HOME="$WORK/codexhome" \
      FLEET_CONF_DIR="$WORK/conf" FLEET_SKIP_GLOBAL_CONF=1 FLEET_FAILOVER=0 "$@" \
      bash "$WORK/install/bin/fleet-codex.sh" 'hello' ) >/dev/null 2>"$WORK/lerr"
}
setv 'codex-cli 0.160.0'; launch
[ -f "$WORK/launched" ] || fail "3a: an unverified codex must still launch" "$(cat "$WORK/lerr")"
CHECKS=$((CHECKS + 1))
eq "$(grep -c 'warning: codex 0.160.0' "$WORK/lerr")" 1 "3a: exactly one stderr warning"
has "npm i -g @openai/codex@0.154.0" "$(cat "$WORK/launch.warn")" "3a: the warning reaches the session (FLEET_CODEX_VERSION_WARNING)"
setv 'codex-cli 0.154.0'; launch
[ -f "$WORK/launched" ] || fail "3b: a verified codex must launch" "$(cat "$WORK/lerr")"
lacks "warning: codex" "$(cat "$WORK/lerr")" "3b: a verified codex prints no warning"
eq "$(cat "$WORK/launch.warn")" "" "3b: no warning env for a verified codex"
setv 'codex-cli 0.160.0'; launch FLEET_CODEX_VERSION_CHECK=0
[ -f "$WORK/launched" ] || fail "3c: launch with the check off" "$(cat "$WORK/lerr")"
lacks "warning: codex" "$(cat "$WORK/lerr")" "3c: FLEET_CODEX_VERSION_CHECK=0 skips the warning"
setv 'codex-cli 0.154.0'; launch FLEET_CODEX_VERSION_WARNING=stale
eq "$(cat "$WORK/launch.warn")" "" "3d: an inherited warning never leaks into a verified launch"

printf 'fleet-codex-version-selftest: PASS (%d checks)\n' "$CHECKS"
