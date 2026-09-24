#!/bin/bash
# install-version-selftest.sh — bin/fleet-install-version.sh + the doctor's
# `install` line, fully hermetic (issue #635).
#
# Everything runs against throwaway git repos under a temp dir and a FILE remote
# (`file://`-less local path), so there is no network, no ~/.claude/fleet, and no
# tmux. "Offline" is simulated by moving the remote out from under the clone —
# which is exactly what a fetch failure looks like from the clone's side.
#
# What it pins, in order:
#   A. verdicts           CURRENT / BEHIND / AHEAD / DIVERGED and their exit codes
#   B. the honesty rule   a failed fetch is UNKNOWN with behind=null — NEVER 0
#                         (the whole point of the issue: silence read as green)
#   C. shapes             not-a-checkout, missing dir, detached HEAD
#   D. --no-fetch         free form, reports `fetched:false` so a stale count
#                         cannot pass for a fresh one
#   E. dirty              TRACKED modifications only (untracked litter ≠ dirty)
#   F. doctor             the `install` line: PASS when current, WARN carrying the
#                         count + fix command when behind, and never a silent pass
#                         when the fetch failed
#   G. other logins       the `logins:` line (issue #1069): absent with one login,
#                         the drift of other logins' installs when they exist,
#                         in --json too — and never a change to verdict or exit
#
# Exit 0 = pass.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
IV="$BIN/fleet-install-version.sh"
DOC="$BIN/fleet-doctor.sh"
[ -f "$IV" ]  || { printf 'selftest: %s not found\n' "$IV" >&2; exit 2; }
[ -f "$DOC" ] || { printf 'selftest: %s not found\n' "$DOC" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "install-version-selftest SKIP (no git)"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/install-version-selftest.XXXXXX")" || exit 2
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP

CHECKS=0
fail() { printf 'selftest FAIL: %s\n' "$1" >&2; exit 1; }
eq() { CHECKS=$((CHECKS + 1)); [ "$2" = "$3" ] || fail "$1 — expected [$2], got [$3]"; }
contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) ;; *) fail "$1 — output does not contain [$3]:\n$2";; esac; }
not_contains() { CHECKS=$((CHECKS + 1)); case "$2" in *"$3"*) fail "$1 — output unexpectedly contains [$3]:\n$2";; esac; }

# Hermetic git: no user config, no signing, no hooks, deterministic identity.
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
: > "$WORK/gitconfig"
export FLEET_SKIP_GLOBAL_CONF=1
# The `logins:` line scans a homes root (/Users, /home) — never the real one here.
export FLEET_SYNC_LOGINS_HOMES="$WORK/homes" FLEET_SYNC_LOGINS_TMP="$WORK"
mkdir -p "$WORK/homes"

g() { git -C "$1" "${@:2}"; }

# --- the trunk everything clones from ---------------------------------------
UP="$WORK/upstream"
mkdir -p "$UP"
git init -q -b master "$UP"
echo one > "$UP/f"; g "$UP" add f; g "$UP" commit -qm one
# A bare-less local remote refuses a push to the checked-out branch; nothing here
# pushes — the trunk advances by committing in $UP directly, and clones fetch it.

clone() {  # clone() <dest> → a fresh "live install" tracking master
  git clone -q "$UP" "$1" 2>/dev/null
}

run() {    # run() <args...> → stdout+stderr in $OUT, exit code in $RC
  OUT=$(sh "$IV" "$@" 2>&1); RC=$?
}

# ============================================================================
# A. verdicts
# ============================================================================
L="$WORK/live"; clone "$L"

run --dir "$L"
eq "current: exit 0" 0 "$RC"
contains "current: verdict" "$OUT" "verdict:  CURRENT"
contains "current: behind 0" "$OUT" "behind:   0"
not_contains "current: no fix line" "$OUT" "fix:"

# trunk moves ahead by 3
for i in 2 3 4; do echo "$i" >> "$UP/f"; g "$UP" add f; g "$UP" commit -qm "c$i"; done

run --dir "$L"
eq "behind: exit 1" 1 "$RC"
contains "behind: verdict" "$OUT" "verdict:  BEHIND"
contains "behind: count" "$OUT" "behind:   3"
contains "behind: names the fix" "$OUT" "pull --ff-only"
contains "behind: names /fleet-sync-install" "$OUT" "/fleet-sync-install"

# catch up, then commit locally → AHEAD
g "$L" pull -q --ff-only
echo local >> "$L/f"; g "$L" add f; g "$L" commit -qm local
run --dir "$L"
eq "ahead: exit 1" 1 "$RC"
contains "ahead: verdict" "$OUT" "verdict:  AHEAD"
contains "ahead: count" "$OUT" "ahead:    1"

# trunk moves again while the clone still carries its own commit → DIVERGED
echo five >> "$UP/f"; g "$UP" add f; g "$UP" commit -qm c5
run --dir "$L"
eq "diverged: exit 1" 1 "$RC"
contains "diverged: verdict" "$OUT" "verdict:  DIVERGED"

# ============================================================================
# B. the honesty rule — a failed fetch is UNKNOWN, never a silent 0
# ============================================================================
# The clone above is BEHIND by a known amount; take the remote away and the
# answer must become "unknown", not "up to date".
B="$WORK/behind-then-offline"; clone "$B"
echo six >> "$UP/f"; g "$UP" add f; g "$UP" commit -qm c6
mv "$UP" "$WORK/upstream.gone"

run --dir "$B"
eq "offline: exit 2" 2 "$RC"
contains "offline: verdict UNKNOWN" "$OUT" "verdict:  UNKNOWN"
contains "offline: behind unknown" "$OUT" "behind:   unknown"
not_contains "offline: never claims up to date" "$OUT" "verdict:  CURRENT"
contains "offline: says why" "$OUT" "NOT assumed 0"

run --json --dir "$B"
eq "offline json: exit 2" 2 "$RC"
contains "offline json: behind is null" "$OUT" '"behind":null'
contains "offline json: verdict" "$OUT" '"verdict":"UNKNOWN"'
not_contains "offline json: never behind 0" "$OUT" '"behind":0'
mv "$WORK/upstream.gone" "$UP"

# json shape on the happy path (the cross-machine producer, issue #635 part 2)
J="$WORK/json"; clone "$J"
run --json --dir "$J"
eq "json: exit 0" 0 "$RC"
contains "json: behind" "$OUT" '"behind":0'
contains "json: verdict" "$OUT" '"verdict":"CURRENT"'
contains "json: fetched" "$OUT" '"fetched":true'
contains "json: carries a host" "$OUT" '"host":"'
contains "json: carries a head sha" "$OUT" '"head":"'
# one line, so a reporter can append it to a stream without reassembling
eq "json: single line" 1 "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"

# ============================================================================
# H. the consumer contract (issue #644) — the key SET and the value SHAPES a
#    cross-machine reader hard-codes (TokenLedger's agent parses this object;
#    its hub renders it) are pinned here, so a renamed key or a re-quoted number
#    goes red in this gate before it goes blank on a roster nobody is watching.
#    Keys are taken from the object itself: jstr escapes every quote inside a
#    value, so a `"word":` inside prose cannot pose as a key.
# ============================================================================
run --json --no-fetch --no-logins --dir "$J"
eq "contract: exit 0" 0 "$RC"
KEYS=$(printf '%s' "$OUT" | grep -o '"[a-z_]*":' | tr -d '":' | tr '\n' ' ')
eq "contract: key set + order" "dir host head branch upstream behind ahead dirty fetched verdict error logins follow follow_verdict " "$KEYS"
contains "contract: behind is a bare integer" "$OUT" '"behind":0,'
contains "contract: ahead is a bare integer" "$OUT" '"ahead":0,'
contains "contract: dirty is a bare boolean" "$OUT" '"dirty":false,'
contains "contract: fetched is a bare boolean, false under --no-fetch" "$OUT" '"fetched":false,'
contains "contract: verdict is a quoted token" "$OUT" '"verdict":"CURRENT"'
contains "contract: error is a string" "$OUT" '"error":"'
contains "contract: logins is null under --no-logins" "$OUT" '"logins":null'
# follow_verdict: a quoted token from the fixed set, or null on an install that
# predates install-sync — never an empty string, never an unlisted word.
CHECKS=$((CHECKS + 1))
case "$OUT" in
  *'"follow_verdict":"OK"}'*|*'"follow_verdict":"STUCK"}'*|*'"follow_verdict":"OFF"}'*|*'"follow_verdict":"UNSEEN"}'*|*'"follow_verdict":"UNKNOWN"}'*|*'"follow_verdict":null}'*) ;;
  *) fail "contract: follow_verdict is a token from the fixed set or null — got:\n$OUT" ;;
esac

# ============================================================================
# C. shapes that cannot be measured
# ============================================================================
mkdir -p "$WORK/plain"; echo x > "$WORK/plain/file"
run --dir "$WORK/plain"
eq "not-a-checkout: exit 2" 2 "$RC"
contains "not-a-checkout: verdict" "$OUT" "verdict:  UNKNOWN"
contains "not-a-checkout: says so" "$OUT" "not a git checkout"

run --dir "$WORK/nope"
eq "missing dir: exit 2" 2 "$RC"
contains "missing dir: says so" "$OUT" "no live install at"

D="$WORK/detached"; clone "$D"
g "$D" checkout -q --detach HEAD
run --dir "$D"
eq "detached: exit 2" 2 "$RC"
contains "detached: verdict" "$OUT" "verdict:  UNKNOWN"
contains "detached: says so" "$OUT" "detached HEAD"

# ============================================================================
# D. --no-fetch is the free form and admits its staleness
# ============================================================================
N="$WORK/nofetch"; clone "$N"
echo seven >> "$UP/f"; g "$UP" add f; g "$UP" commit -qm c7

run --no-fetch --dir "$N"
eq "no-fetch: exit 0 (tracking ref still says current)" 0 "$RC"
contains "no-fetch: admits it did not fetch" "$OUT" "(fetched: no)"
run --json --no-fetch --dir "$N"
contains "no-fetch json: fetched false" "$OUT" '"fetched":false'
# and with a fetch, the same clone is behind — proving --no-fetch read a stale ref
run --dir "$N"
contains "no-fetch: fetching form sees the new commit" "$OUT" "verdict:  BEHIND"

# ============================================================================
# E. dirty = TRACKED modifications only
# ============================================================================
T="$WORK/dirty"; clone "$T"
echo litter > "$T/fleet.conf.bak"          # untracked — a live install always has some
run --dir "$T"
contains "dirty: untracked litter is not dirty" "$OUT" "dirty:    no"
echo edit >> "$T/f"                        # tracked, modified
run --dir "$T"
contains "dirty: a tracked edit is dirty" "$OUT" "dirty:    yes"

# ============================================================================
# F. the doctor line
# ============================================================================
# fleet-doctor.sh runs many checks; only the `install` ones are asserted here.
# Only the LABELLED install lines: `[[:space:]]` not `\s` (BSD grep has no \s),
# and no `note:` clause — several unrelated notes carry the word "install".
doc_install() {  # doc_install() <live-dir> → the install verdict line(s)
  FLEET_LIVE_DIR="$1" sh "$DOC" 2>&1 | grep -E '^[[:space:]]+(PASS|WARN|FAIL)[[:space:]]+install[[:space:]]' || true
}

C1="$WORK/doctor-current"; clone "$C1"
out=$(doc_install "$C1")
contains "doctor: current is a PASS" "$out" "PASS"
contains "doctor: current line labelled install" "$out" "install"

C2="$WORK/doctor-behind"; clone "$C2"
echo eight >> "$UP/f"; g "$UP" add f; g "$UP" commit -qm c8
out=$(doc_install "$C2")
contains "doctor: behind is a WARN" "$out" "WARN"
contains "doctor: behind names the count" "$out" "1 commit"
contains "doctor: behind names the fix" "$out" "pull --ff-only"
contains "doctor: behind names the sync command" "$out" "/fleet-sync-install"

C3="$WORK/doctor-offline"; clone "$C3"
mv "$UP" "$WORK/upstream.gone2"
out=$(doc_install "$C3")
contains "doctor: unreadable trunk is reported, not passed" "$out" "unknown"
not_contains "doctor: offline is never a PASS" "$out" "PASS"
mv "$WORK/upstream.gone2" "$UP"

# ============================================================================
# G. other logins (issue #1069)
# ============================================================================
G="$WORK/logins-live"; clone "$G"
run --dir "$G" --no-fetch
not_contains "logins: one login prints no line" "$OUT" "logins:"
mkdir -p "$WORK/homes/other/.claude"; git clone -q "$UP" "$WORK/homes/other/.claude/fleet"
g "$WORK/homes/other/.claude/fleet" reset -q --hard HEAD~1
run --dir "$G" --no-fetch
eq "logins: verdict/exit unchanged" 0 "$RC"
contains "logins: drift reported" "$OUT" "logins:   1 other · 0 current · 1 drifted"
contains "logins: names the fix" "$OUT" "fleet-sync-logins.sh"
run --dir "$G" --no-fetch --json
contains "logins: in json" "$OUT" '"logins":"1 other · 0 current · 1 drifted'
run --dir "$G" --no-fetch --no-logins
not_contains "logins: --no-logins skips it" "$OUT" "logins:"
bash "$BIN/fleet-sync-logins.sh" --source "$G" >/dev/null 2>&1
run --dir "$G" --no-fetch
contains "logins: current after a sync" "$OUT" "logins:   1 other · 1 current · 0 drifted"
not_contains "logins: no fix once current" "$OUT" "sync them"
run --dir "$G" --no-fetch --json
contains "logins: json null-free when present" "$OUT" '"logins":"1 other'
rm -rf "$WORK/homes/other"
run --dir "$G" --no-fetch --json
contains "logins: json null with one login" "$OUT" '"logins":null'

printf 'install-version-selftest OK (%d checks)\n' "$CHECKS"
