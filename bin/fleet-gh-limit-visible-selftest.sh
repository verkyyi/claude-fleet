#!/bin/bash
# fleet-gh-limit-visible-selftest.sh — a GitHub rate limit is SEEN where the
# operator looks (issue #989, EPIC #1262 C2): fleet-doctor's `github` row WARNs,
# and only READS the shared gh-limit marker (bin/fleet-gh-lib.sh) — it never
# probes GitHub. (The old client's status bar said it too; it went with that
# client, issue #3008.)
# (The preflight half — a limit is a WARN, never BLOCKED — is case M of
# fleet-epic-preflight-selftest.sh.)
#
#   R. fleet_gh_limit_rows / _until: live marker, expired marker, injected limit
#   D. fleet-doctor.sh `github`: PASS clear, WARN limited, last-hour log tally
#
# No network and no live marker: gh is a shim that fails the test if called,
# FLEET_STATE_DIR / FLEET_GH_LOG / TMPDIR are a sandbox.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gh-limit-visible.XXXXXX") || exit 2
[ -n "${KEEP:-}" ] || trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- output ---\n%s\n' "$2" >&2; exit 1; }

export FLEET_STATE_DIR="$WORK/state" FLEET_GH_LOG="$WORK/gh-limit.log"
unset FLEET_GH_FAKE_LIMIT
mkdir -p "$FLEET_STATE_DIR" "$WORK/fakebin"
# Reading a limit must never cost a GitHub call.
printf '#!/bin/sh\necho "$*" >> "%s/gh.called"\nexit 1\n' "$WORK" > "$WORK/fakebin/gh"
chmod +x "$WORK/fakebin/gh"
export PATH="$WORK/fakebin:$PATH"

mark() { printf 'reset=%s\nsource=%s\nat=1\n' "$2" "${3:-pr-merge}" > "$FLEET_STATE_DIR/gh-limit.$1"; }
now=$(date +%s)

# ============================ R: the reader ==================================
# shellcheck source=/dev/null
. "$BIN/fleet-gh-lib.sh"
fleet_gh_limit_rows >/dev/null && fail "R1 no marker must read as not limited"
fleet_gh_limit_until >/dev/null && fail "R1 no marker has no until"
mark graphql $((now + 600)); mark core $((now + 1800)) fleet-comment; mark secondary 5
rows=$(fleet_gh_limit_rows) || fail "R2 a live marker must read as limited"
[ "$(printf '%s\n' "$rows" | grep -c .)" -eq 2 ] || fail "R2 two live buckets, the expired one dropped" "$rows"
printf '%s\n' "$rows" | grep -qx "core	$((now + 1800))	fleet-comment" || fail "R2 a row is bucket/reset/source" "$rows"
[ "$(fleet_gh_limit_until)" = $((now + 1800)) ] || fail "R3 until is the LAST bucket to lift" "$(fleet_gh_limit_until)"
rm -f "$FLEET_STATE_DIR"/gh-limit.*
[ "$(FLEET_GH_FAKE_LIMIT=graphql fleet_gh_limit_until)" = fake ] || fail "R4 an injected limit reads as fake"
[ -e "$FLEET_STATE_DIR/gh-limit.graphql" ] && fail "R4 an injected limit never writes the marker"
ok "R the reader: live rows, expired dropped, until = last reset, injection = fake"

# ============================ D: doctor `github` row ==========================
doc() { bash "$BIN/fleet-doctor.sh" 2>/dev/null | grep -E '^  (PASS|WARN|FAIL)  github '; }
old=$(date -u -r $((now - 7200)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((now - 7200))" +%Y-%m-%dT%H:%M:%SZ)
cur=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s limited bucket=graphql source=old\n%s limited bucket=graphql source=x\n%s skip bucket=graphql source=y\n%s fallback-ok op=merge used=4100\n' \
  "$old" "$cur" "$cur" "$cur" > "$FLEET_GH_LOG"
row=$(doc)
case "$row" in "  PASS  github   not rate-limited · last hour: 1 limited · 1 skipped · 1 fallback-ok · X-RateLimit-Used max 4100") ;;
  *) fail "D1 clear → PASS with the last-hour tally (the 2h-old line excluded)" "$row" ;; esac
ok "D1 clear → PASS github, last-hour tally only"

reset=$((now + 1200))
hhmm=$(fleet_gh_hhmm "$reset")
mark graphql "$reset" pr-merge
row=$(doc)
case "$row" in "  WARN  github   graphql limited until $hhmm (seen by pr-merge) — "*"not a permission problem"*) ;;
  *) fail "D2 a live marker → WARN github naming bucket, until and source" "$row" ;; esac
ok "D2 a live marker → WARN github: graphql limited until $hhmm (seen by pr-merge)"

rm -f "$FLEET_STATE_DIR"/gh-limit.*
row=$(FLEET_GH_FAKE_LIMIT=graphql doc)
case "$row" in "  WARN  github   graphql limited (injected: FLEET_GH_FAKE_LIMIT)"*) ;;
  *) fail "D3 an injected limit → WARN github" "$row" ;; esac
ok "D3 FLEET_GH_FAKE_LIMIT=graphql → WARN github"

printf '\nselftest OK: %s checks (gh limit visible: reader · doctor)\n' "$pass"
exit 0
