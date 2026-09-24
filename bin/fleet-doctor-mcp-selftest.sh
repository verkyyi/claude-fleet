#!/bin/bash
# fleet-doctor-mcp-selftest.sh — the `mcp` rows of bin/fleet-doctor.sh (issue #891):
# per fleet, its MCP allowlist (FLEET_MCP_CONFIG) and what its live claude
# sessions carry in MCP processes + RSS.
#
# Pinned:
#   - no allowlist → WARN naming the fix and the silencer (EPIC #1074 rule 9);
#   - an allowlist (file / inline JSON / none) → PASS with its server count;
#   - a repo overlay that sets the key empty re-opens the WARN for that fleet,
#     and one that sets a list is counted beside the fleet's own;
#   - the live census: only the claude's non-shell children count, each with its
#     whole subtree (npm exec → node), summed per fleet and in one total row;
#   - a fleet whose tmux server is down gets no live figure, never a guess;
#   - FLEET_DOCTOR_MCP=0 silences every row; the run prints nothing on stderr
#     and reaches the doctor's last check.
#
# Hermetic: fake tmux/ps on PATH, scratch HOME/TMPDIR/conf. Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
[ -f "$BIN/fleet-doctor.sh" ] || { printf 'selftest: fleet-doctor.sh not found\n' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "selftest: python3 missing — skip"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/doctor-mcp-selftest.XXXXXX")" || exit 2
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fakepath" "$WORK/conf/fleets"
for f in fleet-doctor.sh fleet-diskguard.sh fleet-lib.sh fleet-daemon-lib.sh fleet-daemon-loaded.sh; do
  [ -f "$BIN/$f" ] && cp "$BIN/$f" "$WORK/bin/"
done
chmod +x "$WORK/bin/"*.sh

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; printf -- '--- line ---\n%s\n' "${2:-(none)}" >&2; exit 1; }
has()  { CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) ;; *) fail "$3" "$2";; esac; }
hasnt() { CHECKS=$((CHECKS + 1)); case "$2" in *"$1"*) fail "$3" "$2";; esac; }

# Fleet names unique to this run: the fake tmux answers for them, and anything
# else aimed at a -L socket is refused rather than reaching a real server.
S="mcpst$$"
LIVE="${S}live"; LISTED="${S}listed"; NONE="${S}none"; INLINE="${S}inline"

# --- fake tmux: $LIVE's server is up with two panes; every other -L is down.
cat > "$WORK/fakepath/tmux" <<SH
#!/bin/sh
if [ "\$1" = -L ]; then
  [ "\$2" = "$LIVE" ] || exit 1
  case "\$3" in
    has-session) exit 0 ;;
    list-panes)  printf '100\n200\n'; exit 0 ;;
  esac
  exit 1
fi
command -p tmux "\$@"
SH
# --- fake ps: the doctor's snapshot argv gets the fixture; anything else the real ps.
cat > "$WORK/fakepath/ps" <<SH
#!/bin/sh
[ "\$*" = "-Ao pid=,ppid=,rss=,comm=" ] && { cat "$WORK/ps.out"; exit 0; }
exec /bin/ps "\$@"
SH
chmod +x "$WORK/fakepath/tmux" "$WORK/fakepath/ps"

# Pane 100: a claude with a tool shell, caffeinate, two MCP servers (one an
# npm-exec wrapper around node). Pane 200: the bridge (python) → claude → one
# server. A claude NOT under a pane (pid 900) must not be counted for the fleet.
cat > "$WORK/ps.out" <<'PS'
  100     1   2000 zsh
  101   100 400000 claude
  102   101   3000 /bin/zsh
  103   101  10240 npm exec mcp-image
  104   103  20480 node
  105   101   1024 caffeinate
  106   101  30720 /usr/bin/python3
  107   102   2048 ps
  200     1   2000 -zsh
  201   200  15000 python3
  202   201 300000 /Users/x/.local/share/claude/versions/2.1.281
  203   202  10240 node
  900     1 300000 claude
  901   900  99999 node
PS

# ~/.claude.json: three user-scope servers every unlisted session inherits.
printf '{"mcpServers":{"a":{},"b":{},"c":{}}}\n' > "$WORK/.claude.json"
printf '{"mcpServers":{"playwright":{"command":"npx"},"image":{"command":"npx"}}}\n' > "$WORK/two.json"

mk() { mkdir -p "$WORK/conf/fleets/$1"; printf 'FLEET_REPO="o/%s"\n%s' "$1" "$2" > "$WORK/conf/fleets/$1/conf"; }
mk "$LIVE"   ''
mk "$LISTED" "FLEET_MCP_CONFIG=\"$WORK/two.json\"
"
mk "$NONE"   'FLEET_MCP_CONFIG="none"
'
mk "$INLINE" "FLEET_MCP_CONFIG='{\"mcpServers\":{\"playwright\":{\"command\":\"npx\"}}}'
"

run_doctor() {
  : > "$WORK/stderr"
  PATH="$WORK/fakepath:$PATH" TMPDIR="$WORK" HOME="$WORK" FLEET_SKIP_GLOBAL_CONF=1 \
  FLEET_CONF_DIR="$WORK/conf" "$@" \
    sh "$WORK/bin/fleet-doctor.sh" 2>"$WORK/stderr"
}
row() { printf '%s\n' "$2" | grep -aE "^[[:space:]]+(PASS|WARN|FAIL|INFO)[[:space:]]+mcp[[:space:]]+$1" | head -1; }
survived() { printf '%s\n' "$1" | grep -qaE '^[[:space:]]+(PASS|WARN)[[:space:]]+perl'; }
quiet() { CHECKS=$((CHECKS + 1)); [ -s "$WORK/stderr" ] && fail "$1" "$(cat "$WORK/stderr")"; return 0; }

# 1. The baseline run.
out="$(run_doctor env)"
survived "$out" || fail "1: the doctor did not reach its last check" "$out"
quiet "1: the mcp rows must print nothing on stderr"

# 1a. No allowlist → WARN, with the fix, the silencer and the inherited count.
l="$(row "$LIVE:" "$out")"
has "WARN" "$l" "1a: a fleet with no FLEET_MCP_CONFIG must WARN"
has "no MCP allowlist (fleet)" "$l" "1a: the WARN must say the allowlist is missing"
has "/.claude.json (3," "$l" "1a: the WARN must count the servers the session inherits"
has "bin/fleet-claude.sh" "$l" "1a: the WARN must point at where the allowlist is applied"
has "FLEET_MCP_CONFIG=~/.claude/fleet/conf/mcp-worker.json" "$l" "1a: the WARN must name the fix"
has "FLEET_DOCTOR_MCP=0" "$l" "1a: the WARN must say how to silence it (EPIC rule 9)"
# 1b. The live census: pane 100 → 2 servers / 3 procs / 60 MB; pane 200 → 1 / 1 / 10 MB.
has "live: 2 claude session(s) carry 4 MCP process(es) (3 server(s)), 70 MB RSS" "$l" \
  "1b: the census must count only the claude's non-shell children, whole subtree, both panes"

# 1c. An allowlist file → PASS with its server count, and no live figure (server down).
l="$(row "$LISTED:" "$out")"
has "PASS" "$l" "1c: a fleet with an allowlist must PASS"
has "2 server(s) via FLEET_MCP_CONFIG=$WORK/two.json" "$l" "1c: the PASS must list the allowlist's server count"
hasnt "live:" "$l" "1c: a fleet whose server is down must get no live figure"
# 1d. none → 0 servers.
l="$(row "$NONE:" "$out")"
has "PASS" "$l" "1d: FLEET_MCP_CONFIG=none must PASS"
has "0 server(s)" "$l" "1d: none must read as zero servers"
# 1e. inline JSON (single-quoted in the conf) → its count survives the quoting.
l="$(row "$INLINE:" "$out")"
has "PASS" "$l" "1e: an inline-JSON allowlist must PASS"
has "1 server(s) via" "$l" "1e: an inline-JSON allowlist must be counted, not mangled"
# 1f. The total row sums the live fleets.
l="$(row "all fleets:" "$out")"
has "INFO" "$l" "1f: the total row is advice (INFO)"
has "2 claude session(s) carry 4 MCP process(es), 70 MB RSS" "$l" "1f: the total row must sum the census"

# 2. A repo overlay: set empty → the fleet WARNs naming the repo; set a list → counted.
mkdir -p "$WORK/conf/fleets/$LISTED/repos"
printf 'FLEET_REPO="o/b"\nFLEET_MCP_CONFIG=""\n' > "$WORK/conf/fleets/$LISTED/repos/o-b.conf"
printf 'FLEET_REPO="o/c"\nFLEET_MCP_CONFIG="none"\n' > "$WORK/conf/fleets/$LISTED/repos/o-c.conf"
printf 'FLEET_REPO="o/d"\n' > "$WORK/conf/fleets/$LISTED/repos/o-d.conf"
out="$(run_doctor env)"; l="$(row "$LISTED:" "$out")"
has "WARN" "$l" "2: an overlay that empties the allowlist must WARN"
has "no MCP allowlist (repo o-b)" "$l" "2: the WARN must name the overlay that dropped it"
has "repo o-c: 0 server(s)" "$l" "2: an overlay's own allowlist must be counted"
hasnt "o-d" "$l" "2: an overlay that leaves the key alone inherits the fleet's (not listed)"
quiet "2: the overlay run must print nothing on stderr"
rm -rf "$WORK/conf/fleets/$LISTED/repos"

# 3. FLEET_DOCTOR_MCP=0 silences every mcp row.
out="$(run_doctor env FLEET_DOCTOR_MCP=0)"
hasnt " mcp " "$out" "3: FLEET_DOCTOR_MCP=0 must silence the mcp rows"
survived "$out" || fail "3: the doctor did not reach its last check" "$out"

# 4. No fleet configured → no mcp row at all.
rm -rf "$WORK/conf/fleets"; mkdir -p "$WORK/conf"
out="$(run_doctor env)"
hasnt " mcp " "$out" "4: with no fleet configured there is nothing to report"
quiet "4: the no-fleet run must print nothing on stderr"

echo "fleet-doctor-mcp-selftest: all $CHECKS checks passed"
