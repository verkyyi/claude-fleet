#!/bin/bash
# fleet-gh-limit-visible-selftest.sh — a GitHub rate limit is SEEN where the
# operator looks (issue #989, EPIC #1262 C2): the status bar says
# `⚠ GitHub 受限至 HH:MM`, fleet-doctor's `github` row WARNs, and both only READ
# the shared gh-limit marker (bin/fleet-gh-lib.sh) — they never probe GitHub.
# (The preflight half — a limit is a WARN, never BLOCKED — is case M of
# fleet-epic-preflight-selftest.sh.)
#
#   R. fleet_gh_limit_rows / _until: live marker, expired marker, injected limit
#   S. tmux-status.sh: no segment when clear — the render is otherwise identical;
#      the segment with HH:MM for a real marker, bare for FLEET_GH_FAKE_LIMIT
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

# ============================ S: status bar ==================================
# The alerts file is planted empty (fresh for FLEET_ALERTS_TTL=3600): the bar
# draws only what wants a hand (issue #1616), so with no alert the clear render
# is EMPTY and the limited one is the segment alone.
TMPD="$WORK/tmp"; mkdir -p "$TMPD/.claude-dash/global"
: > "$TMPD/.claude-dash/global/alerts.ndjson"; printf '%s\n' "$now" > "$TMPD/.claude-dash/global/alerts.ndjson.ts"
render() {
  TMPDIR="$TMPD/" FLEET_LIVE_ROOT="$BIN/.." FLEET_ACCOUNTS_DIR="$WORK/acc" CCQUOTA_HUB_URL=http://127.0.0.1:9 \
    FLEET_STATUS_CACHE_SECS=3600 FLEET_ALERTS_TTL=3600 bash "$BIN/tmux-status.sh" "$@" 2>&1
}
clear_out=$(render) || fail "S tmux-status.sh exited non-zero" "$clear_out"
[ -z "$clear_out" ] || fail "S1 nothing limited (and no alert) → an empty bar" "$clear_out"
ok "S1 nothing limited → no GitHub segment"

reset=$((now + 1200)); mark graphql "$reset"; hhmm=$(fleet_gh_hhmm "$reset")
lim_out=$(render)
seg="#[fg=#e0af68]⚠ GitHub 受限至 $hhmm"
case "$lim_out" in *"$seg"*) ;; *) fail "S2 a live marker shows ⚠ GitHub 受限至 $hhmm" "$lim_out" ;; esac
# Everything else on the bar is untouched: the segment is the whole bar.
[ "$lim_out" = " $seg " ] || fail "S3 the segment is the ONLY difference from the clear render" "clear: $clear_out
limited: $lim_out"
narrow=$(render cw=54)
[ "$narrow" = " #[fg=#e0af68]⚠ GitHub 受限 " ] || fail "S3 a narrow client (cw=54) gets the bare ⚠ GitHub 受限 (issue #1616)" "$narrow"
ok "S2/S3 a live marker adds exactly \`⚠ GitHub 受限至 $hhmm\` and nothing else"

rm -f "$FLEET_STATE_DIR"/gh-limit.*
fake_out=$(FLEET_GH_FAKE_LIMIT=graphql render)
case "$fake_out" in *"⚠ GitHub 受限 "*) ;; *) fail "S4 an injected limit shows ⚠ GitHub 受限 (no reset to print)" "$fake_out" ;; esac
[ -e "$WORK/gh.called" ] && fail "S the status bar must never call gh" "$(cat "$WORK/gh.called")"
ok "S4 FLEET_GH_FAKE_LIMIT=graphql shows the bare ⚠ GitHub 受限; gh never called"

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

printf '\nselftest OK: %s checks (gh limit visible: reader · status bar · doctor)\n' "$pass"
exit 0
