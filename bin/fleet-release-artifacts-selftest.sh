#!/usr/bin/env bash
# fleet-release-artifacts-selftest.sh — a self-hosting team fills its hub's
# CCQUOTA_FLEET_RELEASE_ARTIFACTS from a hub that already carries the release
# (issue #4009): bin/fleet-release-fetch.py --artifacts, against a sandbox hub
# on 127.0.0.1 that really signs (bin/fleet-release-hub-fixture.py).
#
#   A. take     every pinned artifact but ccquota-*, each by the size + sha256
#               the signed manifest names, 0755; `got <name>` per file
#   B. again    one already there with the right digest is kept, a wrong one
#               replaced
#   C. filter   --platforms keeps only those platforms'
#   D. refuse   an artifact served altered → refused, nothing written; another
#               key's manifest → refused
# Exit 0 = pass.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
command -v python3 >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1 || { echo 'fleet-release-artifacts-selftest SKIP (python3 / ssh-keygen)'; exit 0; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-release-arts.XXXXXX") || exit 2
WORK=$(cd "$WORK" && pwd -P)
SRV=''
trap '[ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM HUP
N=0
eq() { N=$((N + 1)); [ "$2" = "$3" ] || st_fail "$1 — expected [$2], got [$3]"; }
has() { N=$((N + 1)); case "$2" in *"$3"*) ;; *) st_fail "$1 — [$2] lacks [$3]" ;; esac; }
export HOME="$WORK/home" TMPDIR="$WORK"
mkdir -p "$HOME"
FETCH="$BIN/fleet-release-fetch.py"

S=1111111111111111111111111111111111111111
H="$WORK/hub"; mkdir -p "$H/rel/$S/.release" "$H/arts/$S"
printf 'tree\n' > "$H/rel/$S/f"
printf '{"schema":1,"sha":"%s","seq":2,"prev":""}\n' "$S" > "$H/rel/$S/.release/manifest.json"
printf '%s\n' "$S" > "$H/rel/stable"
for n in codex-0.1.0-darwin-arm64 codex-0.1.0-linux-amd64 tmux-3.7c-darwin-arm64 ccquota-darwin-arm64; do
  printf 'bytes of %s\n' "$n" > "$H/arts/$S/$n"
done
python3 "$BIN/fleet-release-hub-fixture.py" "$H" 2>"$H/srv.err" & SRV=$!
for _ in $(seq 1 100); do [ -s "$H/port" ] && break; sleep 0.05; done
[ -s "$H/port" ] || st_fail "the sandbox hub did not start: $(cat "$H/srv.err")"
HUB="http://127.0.0.1:$(cat "$H/port")"
cp "$H/key" "$WORK/up.pub"
mode() { python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }

# --- A. take ------------------------------------------------------------------
D="$WORK/arts"
out=$(python3 "$FETCH" --hub "$HUB" --pubkey "$WORK/up.pub" --artifacts stable "$D" 2>"$WORK/err"); eq "A: rc 0 [$(cat "$WORK/err")]" 0 "$?"
has "A: codex taken" "$out" "got codex-0.1.0-darwin-arm64"
has "A: tmux taken" "$out" "got tmux-3.7c-darwin-arm64"
case "$out" in *ccquota*) st_fail "A: a ccquota-* was taken — the hub's image carries its own" ;; esac
[ -e "$D/ccquota-darwin-arm64" ] && st_fail "A: ccquota-darwin-arm64 written"
eq "A: bytes" "bytes of codex-0.1.0-linux-amd64" "$(cat "$D/codex-0.1.0-linux-amd64")"
eq "A: 0755" 755 "$(mode "$D/tmux-3.7c-darwin-arm64")"
has "A: said" "$(cat "$WORK/err")" "3 artifact(s)"

# --- B. again -----------------------------------------------------------------
printf 'tampered\n' > "$D/tmux-3.7c-darwin-arm64"
out=$(python3 "$FETCH" --hub "$HUB" --pubkey "$WORK/up.pub" --artifacts "$S" "$D" 2>/dev/null); eq "B: rc 0" 0 "$?"
has "B: a right one kept" "$out" "kept codex-0.1.0-darwin-arm64"
has "B: a wrong one replaced" "$out" "got tmux-3.7c-darwin-arm64"
eq "B: …with the release's bytes" "bytes of tmux-3.7c-darwin-arm64" "$(cat "$D/tmux-3.7c-darwin-arm64")"

# --- C. filter ----------------------------------------------------------------
out=$(python3 "$FETCH" --hub "$HUB" --pubkey "$WORK/up.pub" --artifacts --platforms linux-amd64 "$S" "$WORK/linux" 2>/dev/null); eq "C: rc 0" 0 "$?"
eq "C: only linux-amd64" "got codex-0.1.0-linux-amd64" "$out"

# --- D. refuse ----------------------------------------------------------------
touch "$H/badart"
python3 "$FETCH" --hub "$HUB" --pubkey "$WORK/up.pub" --artifacts "$S" "$WORK/bad" >/dev/null 2>"$WORK/err"; eq "D: altered → rc 1" 1 "$?"
has "D: …says so" "$(cat "$WORK/err")" "digest does not match the manifest"
eq "D: …nothing written" "" "$(ls "$WORK/bad" 2>/dev/null)"
rm -f "$H/badart"; touch "$H/badsig"
python3 "$FETCH" --hub "$HUB" --pubkey "$WORK/up.pub" --artifacts "$S" "$WORK/bad2" >/dev/null 2>"$WORK/err"; eq "D: another key → rc 1" 1 "$?"
has "D: …says so" "$(cat "$WORK/err")" "does not match the pinned key"
rm -f "$H/badsig"

printf 'fleet-release-artifacts-selftest OK (%d checks)\n' "$N"
