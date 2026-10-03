#!/bin/bash
# ctx-token-line-selftest.sh — hermetic test for context lines set in TOKENS
# (issue #1317, EPIC #1315 C2): FLEET_AUTO_HANDOFF_TOKENS / FLEET_COMPACT_PREP_TOKENS
# converted per Stop against the pane's @ctx_limit, winning over the *_PCT keys.
#
# What is pinned:
#   CONVERT    fleet_ctx_line: 350000 of 1M → 35, of 200k → 100 (clamped: can never
#              fire), rounded UP, and a bad / zero input returns 1 (caller keeps PCT).
#   LOCKSTEP   the `sh` copies of that arithmetic — set-claude-state.sh (the Stop
#              hook) and fleet-doctor.sh's _ctx_line — agree with the lib on a table.
#   HOOK       a token line beats the PCT key; no @ctx_limit ⇒ the PCT key; a 200k
#              window turns 350000 into 100% ⇒ no nudge at 99%; the compact-prep line
#              converts the same way; PCT-only output is byte-for-byte unchanged.
#   DOCTOR     the handoff row prints "<tokens> tok → <pct>% of <window>" for both
#              lines; WARNs when a token line is at/over the window, when
#              compact-prep ≥ handoff, and when handoff ≥ Claude's auto-compaction.
# No real tmux server, no gh, no live Claude.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
FILES="set-claude-state.sh fleet-hook-conf.sh fleet-lib.sh fleet-lang.sh fleet-compact-send.sh fleet-doctor.sh"
for f in $FILES; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ctx-token-line-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/fakepath" "$WORK/inst/bin" "$WORK/inst/logs" "$WORK/conf/fleets/s1" "$WORK/tmp" "$WORK/home" "$WORK/wt"
for f in $FILES; do cp "$BIN/$f" "$WORK/inst/bin/$f"; done
STATE="$WORK/inst/bin/set-claude-state.sh"
DOCTOR="$WORK/inst/bin/fleet-doctor.sh"
GCONF="$WORK/inst/fleet.conf"
OPTS="$WORK/opts"
printf 'FLEET_REPO=acme/widgets\nFLEET_MAIN=%s/main\nFLEET_BASE_BRANCH=trunk\n' "$WORK" > "$WORK/conf/fleets/s1/conf"

ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2
         printf -- '--- opts ---\n' >&2; cat "$OPTS" >&2 2>/dev/null; exit 1; }

# ===== CONVERT ===================================================================
line() { bash -c '. "$1" >/dev/null 2>&1; fleet_ctx_line "$2" "$3"' _ "$BIN/fleet-lib.sh" "$1" "$2"; }
[ "$(line 350000 1000000)" = 35 ]  || fail "350000 of 1M must be 35, got '$(line 350000 1000000)'"
[ "$(line 350000 200000)" = 100 ]  || fail "350000 of 200k must clamp to 100, got '$(line 350000 200000)'"
[ "$(line 200000 200000)" = 100 ]  || fail "a line AT the window is 100"
[ "$(line 350001 1000000)" = 36 ]  || fail "a token line rounds UP (never fires before that many tokens)"
[ "$(line 1 1000000)" = 1 ]        || fail "1 token of 1M rounds up to 1"
line 0 1000000 >/dev/null && fail "0 tokens must return 1 (keep the PCT key)"
line 350000 '' >/dev/null && fail "no limit must return 1"
line 35k 1000000 >/dev/null && fail "a non-numeric line must return 1"
line 350000 0 >/dev/null && fail "a zero limit must return 1"
ok "CONVERT 350000 of 1M → 35 · of 200k → 100 · rounded up · bad input → rc 1"

# ===== LOCKSTEP: doctor's _ctx_line ==============================================
DOCFN=$(sed -n '/^_ctx_line() {/,/^}/p' "$BIN/fleet-doctor.sh")
[ -n "$DOCFN" ] || fail "fleet-doctor.sh must define _ctx_line"
for pair in "350000 1000000" "350000 200000" "550000 1000000" "1 7" "999999 1000000" "123457 200000" "5 3"; do
  # shellcheck disable=SC2086
  set -- $pair
  a=$(line "$1" "$2"); b=$(sh -c "$DOCFN"'
_ctx_line "$1" "$2"' _ "$1" "$2")
  [ "$a" = "$b" ] || fail "doctor _ctx_line($1,$2)=$b but fleet_ctx_line=$a"
done
ok "LOCKSTEP doctor _ctx_line == fleet_ctx_line on the table"

# --- stateful fake tmux (options in $OPTS) ---------------------------------------
cat > "$WORK/fakepath/tmux" <<'FAKE'
#!/usr/bin/env python3
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
    with open(path, "w") as f:
        for k, v in d.items(): f.write("%s\t%s\n" % (k, v))
verb = a[0] if a else ""
if verb == "display-message":
    d = load(); print(re.sub(r"#\{([^}]*)\}", lambda m: d.get(m.group(1), ""), a[-1]))
elif verb == "list-panes":
    d = load(); print(re.sub(r"#\{([^}]*)\}", lambda m: d.get(m.group(1), ""), a[-1]))
elif verb == "set-window-option":
    d = load(); unset = "-u" in a
    rest = [x for x in a[1:] if x != "-u"]
    i = rest.index("-t"); rest = rest[:i] + rest[i+2:]
    if unset: d.pop(rest[0], None)
    else: d[rest[0]] = rest[1] if len(rest) > 1 else ""
    save(d)
elif verb in ("send-keys", "list-clients"):
    pass
else:
    sys.exit(1)
FAKE
chmod +x "$WORK/fakepath/tmux"

# conf KEY=V … — the GLOBAL conf the hook resolves through fleet-hook-conf.
conf() { printf 'FLEET_HANDOFF_DEFER_SECS=0\n' > "$GCONF"; for kv in "$@"; do printf '%s\n' "$kv" >> "$GCONF"; done; }
reset() {
  printf 'session_name\ts1\n@issue\t12\n@claude_state\tdone\nwindow_id\t@1\npane_id\t%%9\nsocket_path\t%s/sock\n' "$WORK" > "$OPTS"
  for kv in "$@"; do printf '%s\t%s\n' "${kv%%=*}" "${kv#*=}" >> "$OPTS"; done
}
stop() {
  OUT=$(cd "$WORK/wt" && printf '{}' | env -i PATH="$WORK/fakepath:/usr/bin:/bin" \
        HOME="$WORK/home" TMPDIR="$WORK/tmp" TMUX="$WORK/sock,1,0" TMUX_PANE='%9' \
        FLEET_CONF_DIR="$WORK/conf" FAKE_OPTS="$OPTS" sh "$STATE" 'done' 2>&1)
}
thr() { printf '%s' "$OUT" | sed -n 's/.*(>= \([0-9]*\)% \([a-z-]*\) threshold).*/\1 \2/p' | head -1; }

# ===== HOOK ======================================================================
conf FLEET_AUTO_HANDOFF_PCT=90 FLEET_AUTO_HANDOFF_TOKENS=550000 FLEET_COMPACT_PREP_PCT=0
reset @ctx_pct=55 @ctx_limit=1000000; stop
[ "$(thr)" = "55 auto-handoff" ] || fail "550000 of 1M must nudge at 55% (beating PCT 90)" "$OUT"
reset @ctx_pct=54 @ctx_limit=1000000; stop
[ -z "$OUT" ] || fail "54% < the 55% token line must not nudge" "$OUT"
reset @ctx_pct=95 @ctx_limit=200000; stop
[ "$(thr)" = "100 auto-handoff" ] && fail "a 200k window turns 550000 into 100% — 95% must not nudge" "$OUT"
[ -z "$OUT" ] || fail "550000 in a 200k window can never fire" "$OUT"
reset @ctx_pct=91; stop
[ "$(thr)" = "90 auto-handoff" ] || fail "no @ctx_limit ⇒ the PCT key (90) decides" "$OUT"
reset @ctx_pct=60 @ctx_limit=bogus; stop
[ -z "$OUT" ] || fail "a non-numeric @ctx_limit ⇒ the PCT key (90): 60% must not nudge" "$OUT"
conf FLEET_AUTO_HANDOFF_PCT=0 FLEET_AUTO_HANDOFF_TOKENS=550000 FLEET_COMPACT_PREP_PCT=0
reset @ctx_pct=56 @ctx_limit=1000000; stop
[ "$(thr)" = "55 auto-handoff" ] || fail "a token line turns handoff ON even with PCT=0" "$OUT"
ok "HOOK handoff: token line beats PCT · 200k ⇒ never · no/bad @ctx_limit ⇒ PCT"

conf FLEET_AUTO_HANDOFF_TOKENS=550000 FLEET_COMPACT_PREP_TOKENS=350000
reset @ctx_pct=36 @ctx_limit=1000000; stop
[ "$(thr)" = "35 compact-prep" ] || fail "350000 of 1M must compact-prep at 35% (not the 70 default)" "$OUT"
reset @ctx_pct=34 @ctx_limit=1000000; stop
[ -z "$OUT" ] || fail "34% < 35% must not prep" "$OUT"
reset @ctx_pct=60 @ctx_limit=1000000; stop
[ "$(thr)" = "55 auto-handoff" ] || fail "60% ≥ the 55% handoff line: handoff, not compaction" "$OUT"
ok "HOOK compact-prep: 350000 of 1M → 35%, band [35, 55)"

# PCT only: the output is exactly what the PCT path always printed.
conf FLEET_AUTO_HANDOFF_PCT=55 FLEET_COMPACT_PREP_PCT=0
reset @ctx_pct=60 @ctx_limit=1000000; stop
case "$OUT" in '{"decision":"block","reason":"Context is at 60% (>= 55% auto-handoff threshold). Run /fleet-handoff now'*) : ;;
  *) fail "PCT-only must read exactly as before" "$OUT" ;; esac
reset @ctx_pct=60 @ctx_limit=200000; stop
[ "$(thr)" = "55 auto-handoff" ] || fail "PCT-only ignores @ctx_limit" "$OUT"
ok "HOOK PCT-only behaviour unchanged (window size ignored)"

# ===== DOCTOR ====================================================================
run_doctor() {
  env -u FLEET_SKIP_GLOBAL_CONF -u FLEET_GLOBAL_MAX_SESSIONS -u CLAUDE_AUTOCOMPACT_PCT_OVERRIDE \
      PATH="$WORK/fakepath:$PATH" FLEET_CONF_DIR="$WORK/conf" HOME="$WORK/home" FAKE_OPTS="$OPTS" \
    sh "$DOCTOR" 2>/dev/null | grep -E '^  (PASS|WARN|FAIL)  handoff +s1:' | grep -v 'demote'
}
conf FLEET_AUTO_HANDOFF_TOKENS=550000 FLEET_COMPACT_PREP_TOKENS=350000
reset @ctx_limit=1000000
out=$(run_doctor)
case "$out" in *PASS*'auto-handoff at 550000 tok → 55% of 1000000'*'compact-prep 350000 tok → 35% of 1000000'*) : ;;
  *) fail "doctor 1M: must PASS with both token lines converted" "$out" ;; esac
reset @ctx_limit=200000
out=$(run_doctor)
case "$out" in *WARN*'FLEET_AUTO_HANDOFF_TOKENS=550000'*'never fire'*'550000 tok → 100% of 200000'*) : ;;
  *) fail "doctor 200k: a token line at/over the window must WARN" "$out" ;; esac
conf FLEET_AUTO_HANDOFF_PCT=55 FLEET_COMPACT_PREP_PCT=60
reset @ctx_limit=1000000
out=$(run_doctor)
case "$out" in *WARN*'compact-prep (60%) is not below the handoff line (55%)'*) : ;;
  *) fail "doctor: compact-prep ≥ handoff must WARN" "$out" ;; esac
conf FLEET_AUTO_HANDOFF_TOKENS=980000 FLEET_COMPACT_PREP_PCT=35
out=$(run_doctor)
case "$out" in *WARN*"handoff line (98%) is not below Claude's own auto-compaction (95%"*) : ;;
  *) fail "doctor: handoff ≥ Claude's auto-compaction must WARN" "$out" ;; esac
conf FLEET_AUTO_HANDOFF_PCT=55 FLEET_COMPACT_PREP_PCT=35
out=$(run_doctor)
case "$out" in *PASS*'auto-handoff at 55% · compact-prep 35%'*) : ;;
  *) fail "doctor PCT-only must PASS with the plain % ladder" "$out" ;; esac
ok "DOCTOR prints tokens → % per window · WARNs on never-fires / empty band / ≥ Claude's compaction"

printf 'ctx-token-line-selftest: PASS\n'
