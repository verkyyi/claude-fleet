#!/bin/bash
# fleet-pick-header-selftest.sh — the fleet-switch picker (bin/fleet-pick.sh) pins
# fleet-list.sh's column-title row at the TOP of the modal, aligned to the fleet
# rows (issue #378 — mirrors the backlog header, #374).
#
# Three guarantees, all hermetic (no live tmux server, no network):
#   (1) SAME printf — fleet-list.sh draws its header line and every row through the
#       SAME printf format ('%-2s %-22s %-40s %s'), so the labels sit over their
#       columns by construction (the marker glyph pads to the header's blank marker
#       field). This is the whole premise of #378; assert the two format literals are
#       byte-identical so a future edit to one can't silently misalign it. (A runtime
#       column-offset check would instead measure the runner's bash multibyte %-Ns
#       behavior, which is not an invariant of this code — so we pin the format.)
#   (2) HEADER LEADS — render the real listing from a sandboxed fake fleet and assert
#       fleet-list.sh's line 1 IS the column header (FLEET/REPO/CHECKOUT labels, an
#       empty ●/○ marker field so it leads with spaces) and that a real fleet row
#       follows it. --header-lines=1 pins line 1, so a data row leading would pin the
#       wrong line (the #374 failure mode).
#   (3) WIRING — fleet-pick.sh CAPTURES fleet-list.sh's header (doesn't drop it),
#       DIMS it (the backlog's muted color), feeds it as the FIRST fzf input line,
#       passes --header-lines=1 (pin at top + non-selectable), and still extracts the
#       pick from field 2 (the header row can never become a pick).
#
# tmux is isolated onto a private `-S` socket via a PATH shim (never the live server,
# per the repo rail); the liveness probe just fails closed to ○, which is fine — the
# marker field is a fixed-width column either way. Exit 0 = pass, non-zero = fail.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
LIST="$BIN/fleet-list.sh"
PICK="$BIN/fleet-pick.sh"
LIB="$BIN/fleet-lib.sh"
for f in "$LIST" "$PICK" "$LIB"; do
  [ -f "$f" ] || { printf 'selftest: %s not found\n' "$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fpickhdr-selftest.XXXXXX")" || exit 2
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# Isolate every tmux call onto a private socket so the liveness probe never touches
# the live server; it fails closed to ○, which the header/row checks don't care about.
REAL_TMUX="$(command -v tmux 2>/dev/null)"
if [ -n "$REAL_TMUX" ]; then
  SOCK="$WORK/tmux.sock"; mkdir -p "$WORK/bin"
  cat > "$WORK/bin/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -S "$SOCK" "\$@"
EOF
  chmod +x "$WORK/bin/tmux"
  PATH="$WORK/bin:$PATH"; export PATH
  cleanup() { tmux kill-server 2>/dev/null; rm -rf "$WORK"; }
else
  cleanup() { rm -rf "$WORK"; }
fi
trap cleanup EXIT

# --- (1) SAME printf: fleet-list.sh header line == row emit() format ---------
# Both aligned lines start `printf '%-2s …'`; the tab-format printf (the repo/main
# collector) doesn't, so this matches exactly the header + row pair.
fmts="$(grep -oE "printf '%-2s[^']*'" "$LIST")"
n_fmt="$(printf '%s\n' "$fmts" | grep -c .)"
f1="$(printf '%s\n' "$fmts" | sed -n '1p')"
f2="$(printf '%s\n' "$fmts" | sed -n '2p')"
[ "$n_fmt" -eq 2 ] || fail "fleet-list.sh: expected exactly 2 '%-2s …' printf lines (header + row), found $n_fmt" "$fmts"
[ "$f1" = "$f2" ] || fail "fleet-list.sh header printf ($f1) != row printf ($f2) — the pinned column header would misalign from the rows"
case "$f1" in *'%-2s %-22s %-40s %s'*) : ;; *) fail "fleet-list.sh: unexpected aligned printf format ($f1)" ;; esac

# --- (2) HEADER LEADS the listing -------------------------------------------
# One sandboxed configured fleet with distinctive ASCII markers; no sessmap under
# $TMPDIR/.claude-dash, so fleet-list.sh's live-session loop finds nothing extra.
export TMPDIR="$WORK"                       # points fleet-lib's FLEET_C (sessmap) here
export FLEET_CONF_DIR="$WORK/conf"; mkdir -p "$FLEET_CONF_DIR"
cat > "$FLEET_CONF_DIR/ZZFLEET.conf" <<'CONF'
FLEET_REPO=zz/repo
FLEET_MAIN=/zzcheck
CONF
out="$(bash "$LIST" 2>/dev/null)"
[ -n "$out" ] || fail "fleet-list.sh produced no output"
hdr_line="$(printf '%s\n' "$out" | sed -n '1p')"
row_line="$(printf '%s\n' "$out" | grep -F 'ZZFLEET' | head -n1)"
[ -n "$row_line" ] || fail "fleet-list.sh did not emit the sandboxed fleet row" "$out"
case "$hdr_line" in
  *FLEET*REPO*CHECKOUT*) : ;;
  *) fail "fleet-list.sh line 1 is not the FLEET/REPO/CHECKOUT column header" "$out" ;;
esac
# line 1 leads with the empty marker field (spaces), never a ●/○ data-row marker —
# so --header-lines=1 pins a header, not a fleet (the #374 failure mode).
case "$hdr_line" in
  ' '*) : ;;
  *) fail "fleet-list.sh line 1 does not lead with the empty marker column — it looks like a data row" "$hdr_line" ;;
esac
[ "$hdr_line" = "$row_line" ] && fail "the ZZFLEET row is on line 1 — the column header must lead the listing" "$out"

# --- (3) WIRING in fleet-pick.sh --------------------------------------------
grep -qF -- '--header-lines=1' "$PICK" || fail 'fleet-pick.sh: missing --header-lines=1 (the top-pin for the column header)'
grep -qE 'header=\$\(printf' "$PICK" || fail 'fleet-pick.sh: does not CAPTURE + style fleet-list.sh header (no header=$(printf …))'
grep -qF -- '38;2;86;95;137' "$PICK" || fail "fleet-pick.sh: header not dimmed with the backlog's muted color (38;2;86;95;137)"
grep -qE '\$header" +"\$listing"' "$PICK" || fail 'fleet-pick.sh: does not feed $header ahead of $listing into fzf'
grep -qF -- '{print $2}' "$PICK" || fail 'fleet-pick.sh: pick no longer extracted from field 2 (the pinned header must stay non-selectable)'

printf 'selftest PASS: fleet-pick pins fleet-list.sh column header — header+rows share %s, header leads, dimmed, --header-lines=1, pick from field 2\n' "$f1"
exit 0
