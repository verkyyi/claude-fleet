#!/bin/bash
# steward-charter-selftest.sh — hermetic tests for the issue #286 steward-charter
# machinery:
#   • bin/steward-charter.sh <sess> — the SHARED resolver that concatenates the
#     LAYERED steward charter low→high: built-in (the /fleet-steward skill's charter
#     region) + gated repo charter ($FLEET_MAIN/.fleet/steward.md, behind
#     FLEET_REPO_CHARTER=1, default OFF/fail-closed) + always-trusted fleet overlay
#     ($FLEET_CONF_DIR/fleets/<sess>/steward.md). Later layer wins → overlay printed
#     AFTER the repo charter.
#   • bin/steward-readopt-hook.sh — the /clear re-adopt hook, which must re-inject
#     the SAME resolver output (parity: no drift between spawn and /clear recovery),
#     gated to source==clear AND a @steward=1 pane.
#   • the REAL commands/fleet-steward.md carries the begin/end charter markers so the
#     resolver's built-in tier is non-empty in production.
# No network, no gh, no real tmux server — a tmux PATH-shim fakes the two
# display-message queries the hook makes. Pure files + subprocess calls.
#
# Exit 0 = pass; non-zero = fail (prints the failing assertion).
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/steward-charter-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

pass=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2; exit 1; }

# Hermetic env: a temp conf dir + main tree, and a FIXTURE built-in skill so the
# tests don't ride the real charter's evolving prose. fleet_load_conf no-ops on a
# missing conf, so these exported values survive the resolver's source of fleet-lib.
export FLEET_CONF_DIR="$WORK/conf"
export FLEET_MAIN="$WORK/main"
SESS="mysess"
mkdir -p "$FLEET_MAIN/.fleet" "$FLEET_CONF_DIR/fleets/$SESS"

SKILL="$WORK/fleet-steward.md"
cat > "$SKILL" <<'EOF'
# /fleet-steward — procedure (must NOT leak into the built-in tier)

## 0. Resolve fleet + guard seat
run steward-charter.sh — this line lives ABOVE the marker and must be excluded.

<!-- fleet:charter-begin -->
BUILTIN-ORDERS: dispatch, never implement.
<!-- fleet:charter-end -->

trailing procedure text, also excluded.
EOF
export FLEET_STEWARD_SKILL="$SKILL"

REPO_MD="$FLEET_MAIN/.fleet/steward.md"
OVERLAY_MD="$FLEET_CONF_DIR/fleets/$SESS/steward.md"

# ===== built-in tier: only the charter region, procedure excluded =================
unset FLEET_REPO_CHARTER
out=$("$BIN/steward-charter.sh" "$SESS")
case "$out" in *BUILTIN-ORDERS*) : ;; *) fail "built-in tier must emit the skill's charter region" "$out" ;; esac
case "$out" in *"Resolve fleet + guard seat"*) fail "the skill PROCEDURE must NOT leak into the charter" "$out" ;; esac
case "$out" in *"charter-begin"*|*"charter-end"*) fail "the begin/end markers must be stripped" "$out" ;; esac
case "$out" in *"trailing procedure text"*) fail "text after the end marker must be excluded" "$out" ;; esac
ok "built-in tier = the skill's charter region only (procedure + markers excluded)"

# ===== no files, gate off ⇒ built-in only, no file-layer headers ==================
case "$out" in *"repo steward charter"*) fail "no repo file → no repo header" "$out" ;; esac
case "$out" in *"fleet overlay steward charter"*) fail "no overlay file → no overlay header" "$out" ;; esac
ok "no charter files → built-in only (steward runs on the built-in default)"

# ===== overlay only ⇒ printed, labelled operator/wins, after the built-in =========
printf 'OVERLAY-ORDERS: prefer small PRs\n' > "$OVERLAY_MD"
out=$("$BIN/steward-charter.sh" "$SESS")
case "$out" in *OVERLAY-ORDERS*) : ;; *) fail "overlay charter must be printed" "$out" ;; esac
case "$out" in *"overlay"*"operator"*) : ;; *) fail "overlay layer must be labelled operator" "$out" ;; esac
b_at=$(printf '%s\n' "$out" | grep -n 'BUILTIN-ORDERS'  | head -1 | cut -d: -f1)
o_at=$(printf '%s\n' "$out" | grep -n 'OVERLAY-ORDERS' | head -1 | cut -d: -f1)
[ -n "$b_at" ] && [ -n "$o_at" ] && [ "$b_at" -lt "$o_at" ] \
  || fail "overlay (higher precedence) must be printed AFTER the built-in tier" "$out"
ok "fleet overlay (operator, always trusted) prints after the built-in tier"

# ===== repo file present but gate OFF (default) ⇒ NOT printed ======================
printf 'REPO-ORDERS: injected via a PR\n' > "$REPO_MD"
unset FLEET_REPO_CHARTER
out=$("$BIN/steward-charter.sh" "$SESS")
case "$out" in *REPO-ORDERS*) fail "repo charter must be SKIPPED when the gate is off (fail-closed)" "$out" ;; esac
case "$out" in *OVERLAY-ORDERS*) : ;; *) fail "overlay must still print with the gate off" "$out" ;; esac
ok "repo charter is fail-closed: skipped unless FLEET_REPO_CHARTER=1"

# ===== gate ON ⇒ repo printed, and overlay comes AFTER it (later wins) =============
export FLEET_REPO_CHARTER=1
out=$("$BIN/steward-charter.sh" "$SESS")
case "$out" in *REPO-ORDERS*) : ;; *) fail "repo charter must print when FLEET_REPO_CHARTER=1" "$out" ;; esac
r_at=$(printf '%s\n' "$out" | grep -n 'REPO-ORDERS'    | head -1 | cut -d: -f1)
o_at=$(printf '%s\n' "$out" | grep -n 'OVERLAY-ORDERS' | head -1 | cut -d: -f1)
[ -n "$r_at" ] && [ -n "$o_at" ] && [ "$r_at" -lt "$o_at" ] \
  || fail "overlay (higher precedence) must be printed AFTER the repo charter" "$out"
ok "gate on → repo charter first, overlay after (later layer wins on conflict)"

# ===== gate ON but repo file absent ⇒ silent skip, overlay still prints ============
rm -f "$REPO_MD"
out=$("$BIN/steward-charter.sh" "$SESS")
case "$out" in *REPO-ORDERS*) fail "a removed repo charter must not linger" "$out" ;; esac
case "$out" in *OVERLAY-ORDERS*) : ;; *) fail "overlay must still print" "$out" ;; esac
ok "missing repo charter is skipped silently even with the gate on"

# ===== unknown session, no files ⇒ built-in only, no error ========================
rm -f "$OVERLAY_MD"
unset FLEET_REPO_CHARTER
out=$("$BIN/steward-charter.sh" "no-such-sess") || fail "missing files must not error"
case "$out" in *BUILTIN-ORDERS*) : ;; *) fail "built-in must still print for an unknown session" "$out" ;; esac
case "$out" in *OVERLAY-ORDERS*|*REPO-ORDERS*) fail "unknown session must not pick up file layers" "$out" ;; esac
ok "unknown session → built-in only, no error"

# ===== hook/skill parity: the /clear hook re-injects the SAME resolver output =====
# A tmux PATH-shim answers the hook's two display-message queries (@steward=1 and
# the session name) so we exercise the real hook without a live tmux server.
SHIM="$WORK/shimbin"; mkdir -p "$SHIM"
cat > "$SHIM/tmux" <<SH
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    *'@steward'*)      echo 1;         exit 0 ;;
    *'session_name'*)  echo "$SESS";   exit 0 ;;
  esac
done
exit 0
SH
chmod +x "$SHIM/tmux"

printf 'OVERLAY-ORDERS: prefer small PRs\n' > "$OVERLAY_MD"   # give parity a file layer too
resolver_out=$("$BIN/steward-charter.sh" "$SESS")
hook_out=$(PATH="$SHIM:$PATH" TMUX=fake TMUX_PANE=%9 FLEET_READOPT_SOURCE=clear \
  HOME="$WORK/home" "$BIN/steward-readopt-hook.sh" </dev/null)
case "$hook_out" in *"[fleet steward re-adopt]"*) : ;; *) fail "hook must emit its re-adopt preamble" "$hook_out" ;; esac
# The resolver output must appear VERBATIM inside the hook output (no drift).
case "$hook_out" in *"$resolver_out"*) : ;; *) fail "hook must embed the resolver output verbatim (parity)" "$(printf 'HOOK:\n%s\nRESOLVER:\n%s' "$hook_out" "$resolver_out")" ;; esac
ok "hook/skill parity: /clear hook re-injects the exact steward-charter.sh output"

# ===== hook gate: a non-@steward pane (a worker) gets NOTHING ======================
cat > "$SHIM/tmux" <<SH
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    *'@steward'*)      echo "";        exit 0 ;;
    *'session_name'*)  echo "$SESS";   exit 0 ;;
  esac
done
exit 0
SH
chmod +x "$SHIM/tmux"
hook_out=$(PATH="$SHIM:$PATH" TMUX=fake TMUX_PANE=%9 FLEET_READOPT_SOURCE=clear \
  HOME="$WORK/home" "$BIN/steward-readopt-hook.sh" </dev/null)
[ -z "$hook_out" ] || fail "a worker (@steward unset) pane must NEVER be handed the charter" "$hook_out"
ok "hook gate: a non-@steward pane gets nothing (worker safety)"

# ===== hook gate: source != clear ⇒ nothing =======================================
# (restore a @steward=1 shim; only the source differs)
cat > "$SHIM/tmux" <<SH
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    *'@steward'*)      echo 1;         exit 0 ;;
    *'session_name'*)  echo "$SESS";   exit 0 ;;
  esac
done
exit 0
SH
chmod +x "$SHIM/tmux"
hook_out=$(PATH="$SHIM:$PATH" TMUX=fake TMUX_PANE=%9 FLEET_READOPT_SOURCE=startup \
  HOME="$WORK/home" "$BIN/steward-readopt-hook.sh" </dev/null)
[ -z "$hook_out" ] || fail "the hook must re-adopt on /clear ONLY, not on startup/resume/compact" "$hook_out"
ok "hook gate: re-adopt fires on source=clear only"

# ===== the REAL skill file carries the charter markers (built-in tier non-empty) ==
unset FLEET_STEWARD_SKILL
real=$("$BIN/steward-charter.sh" "no-such-sess")
[ -n "$real" ] || fail "the REAL commands/fleet-steward.md must expose a non-empty charter region (begin/end markers present)"
case "$real" in *"three responsibilities"*) : ;; *) fail "the real built-in charter should carry the three responsibilities" "$real" ;; esac
ok "the shipped /fleet-steward skill has the begin/end markers → non-empty built-in tier"

printf '\nselftest OK: %s assertions passed (steward charter resolver + readopt parity, issue #286)\n' "$pass"
exit 0
