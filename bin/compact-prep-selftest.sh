#!/bin/bash
# compact-prep-selftest.sh — hermetic test for compact-in-place-before-handoff
# (issue #1269, EPIC #1262 R1): bin/set-claude-state.sh's Stop path,
# bin/fleet-compact-send.sh and bin/refocus-hook.sh's `restored` step, driven
# against a STATEFUL fake tmux (window options live in a file, so one leg's writes
# are the next leg's reads — the way a real pane carries @compact_stage).
#
# What is pinned:
#   THREE STEPS  ctx 70 → 75 → (SessionStart compact) → 30: prep (one block
#                decision asking for the recovery map), compacting (exactly one
#                `/compact …` typed, Esc / text / Enter as separate send-keys),
#                restored (the refocus block carries the check line + map path) —
#                each exactly once, and the 30% Stop re-arms without a 4th step.
#   GAP / REARM  over the line again inside 600 s, or never having dropped below
#                it, ⇒ no new prep.
#   HANDOFF      at/over FLEET_AUTO_HANDOFF_PCT the original handoff nudge fires and
#                compaction stays out of it.
#   SCOPE / OFF  scratch, a codex pane, a needs stop, stop_hook_active on a fresh
#                prep, and FLEET_COMPACT_PREP_PCT=0 ⇒ nothing.
#   DEDUP        a prep stage whose sender ran < 60 s ago spawns no second sender.
#   TYPING HOLD  an operator keypress at this window holds the keystrokes; held past
#                the deadline ⇒ nothing typed and the stage stays `prep` (#571).
#   STALE        a prep/compacting stage seen below the line is dropped.
# No real tmux server, no gh, no live Claude.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
for f in set-claude-state.sh fleet-hook-conf.sh fleet-lib.sh fleet-lang.sh fleet-compact-send.sh refocus-hook.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/compact-prep-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/fakepath" "$WORK/inst/bin" "$WORK/conf/fleets/s1" "$WORK/tmp" "$WORK/widgets-issue-12"
for f in set-claude-state.sh fleet-hook-conf.sh fleet-lib.sh fleet-lang.sh fleet-compact-send.sh refocus-hook.sh; do
  cp "$BIN/$f" "$WORK/inst/bin/$f"
done
STATE="$WORK/inst/bin/set-claude-state.sh"
REFOCUS="$WORK/inst/bin/refocus-hook.sh"
GCONF="$WORK/inst/fleet.conf"
OPTS="$WORK/opts"; SENDLOG="$WORK/send.log"
git -C "$WORK/widgets-issue-12" init -q -b issue-12 2>/dev/null || git -C "$WORK/widgets-issue-12" init -q
GITDIR=$(git -C "$WORK/widgets-issue-12" rev-parse --absolute-git-dir)
MAP="$GITDIR/fleet-recovery-map.md"
printf 'FLEET_REPO=acme/widgets\nFLEET_MAIN=%s/main\nFLEET_BASE_BRANCH=trunk\n' "$WORK" > "$WORK/conf/fleets/s1/conf"

# --- stateful fake tmux: options in $OPTS ("key<TAB>value"), send-keys logged ----
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
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        for k, v in d.items(): f.write("%s\t%s\n" % (k, v))
    os.replace(tmp, path)
verb = a[0] if a else ""
if verb == "display-message":
    d = load(); fmt = a[-1]
    print(re.sub(r"#\{([^}]*)\}", lambda m: d.get(m.group(1), ""), fmt))
elif verb == "set-window-option":
    d = load(); unset = "-u" in a
    rest = [x for x in a[1:] if x != "-u"]
    i = rest.index("-t"); rest = rest[:i] + rest[i+2:]
    if unset: d.pop(rest[0], None)
    else: d[rest[0]] = rest[1] if len(rest) > 1 else ""
    save(d)
elif verb == "send-keys":
    with open(os.environ["FAKE_SENDLOG"], "a") as f: f.write(" ".join(a) + "\n")
elif verb == "list-clients":
    sys.stdout.write(os.environ.get("FAKE_CLIENTS", "").replace("\\n", "\n"))
else:
    sys.exit(1)
FAKE
chmod +x "$WORK/fakepath/tmux"

ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2
         printf -- '--- opts ---\n' >&2; cat "$OPTS" >&2 2>/dev/null
         printf -- '--- send log ---\n' >&2; cat "$SENDLOG" >&2 2>/dev/null; exit 1; }

# conf <prep%> [<handoff%>] — the GLOBAL conf the hook resolves through fleet-hook-conf.
conf() {
  { printf 'FLEET_HANDOFF_DEFER_SECS=30\n'
    [ -n "${1:-}" ] && printf 'FLEET_COMPACT_PREP_PCT=%s\n' "$1"
    [ -n "${2:-}" ] && printf 'FLEET_AUTO_HANDOFF_PCT=%s\n' "$2"
  } > "$GCONF"; }
# reset [k=v …] — a fresh worker window #12 (claude, done), plus overrides.
reset() {
  printf 'session_name\ts1\n@issue\t12\n@claude_state\tdone\nwindow_id\t@1\n' > "$OPTS"
  for kv in "$@"; do printf '%s\t%s\n' "${kv%%=*}" "${kv#*=}" >> "$OPTS"; done
  : > "$SENDLOG"
}
setopt() { python3 - "$OPTS" "$1" "$2" <<'PY'
import sys
p, k, v = sys.argv[1:]
d = dict(l.rstrip("\n").split("\t", 1) for l in open(p) if "\t" in l)
d[k] = v
open(p, "w").write("".join("%s\t%s\n" % kv for kv in d.items()))
PY
}
getopt() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$OPTS"; }
# stop [<payload>] — one Stop hook (set-claude-state.sh done) from the worktree.
stop() {
  OUT=$(cd "$WORK/widgets-issue-12" && printf '%s' "${1:-"{}"}" | env -i PATH="$WORK/fakepath:/usr/bin:/bin" \
        HOME="$WORK" TMPDIR="$WORK/tmp" TMUX="$WORK/sock,1,0" TMUX_PANE='%9' \
        FLEET_CONF_DIR="$WORK/conf" FAKE_OPTS="$OPTS" FAKE_SENDLOG="$SENDLOG" \
        FAKE_CLIENTS="${FAKE_CLIENTS:-}" FLEET_COMPACT_SEND_GRACE=0 \
        FLEET_COMPACT_SEND_TIMEOUT="${SEND_TIMEOUT:-90}" \
        sh "$STATE" 'done' 2>&1)
}
# compact_start — SessionStart(source=compact): the refocus hook.
compact_start() {
  OUT=$(cd "$WORK/widgets-issue-12" && printf '{"hook_event_name":"SessionStart","source":"compact"}' \
        | env -i PATH="$WORK/fakepath:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK/tmp" \
          TMUX="$WORK/sock,1,0" TMUX_PANE='%9' FLEET_SKIP_GLOBAL_CONF=1 \
          FLEET_CONF_DIR="$WORK/conf" FAKE_OPTS="$OPTS" FAKE_SENDLOG="$SENDLOG" \
          bash "$REFOCUS" 2>&1)
}
# wait_sent <n> — the detached sender is async: wait (≤ 10 s) for its n-th Enter.
wait_sent() { local i=0
  while [ "$(grep -c 'Enter$' "$SENDLOG" 2>/dev/null)" -lt "$1" ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done; }
sent() { grep -c -- '/compact ' "$SENDLOG" 2>/dev/null || true; }
blocked() { case "$OUT" in *'"decision":"block"'*) return 0 ;; esac; return 1; }

# ===== THREE STEPS: 70 → 75 → compact → 30 ======================================
conf '' ''                       # nothing set ⇒ the 70 default, handoff off
reset @ctx_pct=70
stop
blocked || fail "70% (= default prep line) must block with the recovery-map request" "$OUT"
case "$OUT" in *'compact-prep threshold'*"$MAP"*'issue #12'*) : ;;
  *) fail "prep directive must name the threshold, the map file and the issue" "$OUT" ;; esac
printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' || fail "prep output must be valid JSON" "$OUT"
[ "$(getopt @compact_stage)" = prep ] || fail "step 1 must stamp @compact_stage=prep"
[ "$(getopt @compact_rearm)" = 0 ] || fail "step 1 must disarm (@compact_rearm=0)"
ok "STEP 1 ctx 70 → prep: one block decision naming $MAP"

setopt @ctx_pct 75; printf 'map\n' > "$MAP"
stop '{"stop_hook_active":true}'  # the map turn ends: this is the next idle Stop
blocked && fail "the map turn's Stop must NOT block again" "$OUT"
wait_sent 1
[ "$(sent)" = 1 ] || fail "step 2 must type exactly one /compact"
grep -q -- "/compact Keep the fleet RECOVERY MAP.*$MAP" "$SENDLOG" || fail "/compact must ask to keep the map, naming its file"
[ "$(grep -c '' "$SENDLOG")" = 3 ] && sed -n 1p "$SENDLOG" | grep -q 'Escape$' && sed -n 3p "$SENDLOG" | grep -q 'Enter$' \
  || fail "keystrokes must be Escape, the text, Enter — three separate send-keys"
[ "$(getopt @compact_stage)" = compacting ] || fail "step 2 must stamp @compact_stage=compacting"
ok "STEP 2 ctx 75, idle → exactly one /compact (Esc · text · Enter), stage compacting"

stop                             # a Stop before the compaction lands
blocked && fail "a compacting stage must not block" "$OUT"
sleep 0.5; [ "$(sent)" = 1 ] || fail "a compacting stage must not type a second /compact"

compact_start
case "$OUT" in *'[fleet charter] #12'*'CHECK FIRST'*"$MAP"*) : ;;
  *) fail "SessionStart(compact) must re-state the charter with the map check" "$OUT" ;; esac
[ "$(getopt @compact_stage)" = restored ] || fail "step 3 must stamp @compact_stage=restored"
compact_start
case "$OUT" in *'CHECK FIRST'*) fail "a second (auto) compaction must not repeat the check" "$OUT" ;; esac
ok "STEP 3 SessionStart(compact) → restored + check line, once"

setopt @ctx_pct 30
stop
blocked && fail "30% must not block" "$OUT"
[ "$(getopt @compact_stage)" = restored ] || fail "restored must stay visible below the line"
[ "$(getopt @compact_rearm)" = 1 ] || fail "a Stop below the line must re-arm"
[ "$(sent)" = 1 ] || fail "no extra /compact after the cycle"
ok "ctx 30 → re-armed, stage stays restored, nothing else sent"

# ===== GAP / REARM ===============================================================
setopt @ctx_pct 76; stop
blocked && fail "re-armed but < 600 s since the last compaction must NOT prep" "$OUT"
reset @ctx_pct=76 @compact_stage=restored @compact_rearm=0 @compact_ts=1
stop
blocked && fail "never back below the line (@compact_rearm=0) must NOT prep" "$OUT"
reset @ctx_pct=76 @compact_stage=restored @compact_rearm=1 @compact_ts=1
stop
blocked || fail "re-armed + old compaction must prep again" "$OUT"
ok "GAP/REARM ≥600 s apart and only after dropping below the line"

# ===== HANDOFF line wins =========================================================
conf 70 80
reset @ctx_pct=85
stop
case "$OUT" in *'auto-handoff threshold'*) : ;; *) fail "ctx ≥ handoff line must take the original handoff nudge" "$OUT" ;; esac
case "$OUT" in *'compact-prep'*) fail "compaction must stay out above the handoff line" "$OUT" ;; esac
[ -z "$(getopt @compact_stage)" ] || fail "above the handoff line no compact stage is stamped"
reset @ctx_pct=79
stop
case "$OUT" in *'compact-prep threshold'*) : ;; *) fail "70 ≤ 79 < 80 must prep" "$OUT" ;; esac
conf 90 80
reset @ctx_pct=85
stop
case "$OUT" in *'compact-prep'*) fail "prep line above the handoff line ⇒ empty band, never prep" "$OUT" ;; esac
ok "HANDOFF ctx ≥ handoff % → handoff nudge, no compaction; band = [prep, handoff)"

# ===== SCOPE / OFF ===============================================================
conf '' ''
reset @ctx_pct=80 @issue= @raw=1;              stop; blocked && fail "scratch must not compact" "$OUT"
reset @ctx_pct=80 @cc_agent=codex;             stop; blocked && fail "codex pane must not compact" "$OUT"
reset @ctx_pct=80 @claude_state=needs;         stop; blocked && fail "a needs stop must not be hijacked" "$OUT"
reset @ctx_pct=80; stop '{"stop_hook_active":true}'; blocked && fail "stop_hook_active must not start a prep" "$OUT"
conf 0 ''
reset @ctx_pct=95;                             stop; blocked && fail "FLEET_COMPACT_PREP_PCT=0 must be off" "$OUT"
[ -z "$(getopt @compact_stage)" ] || fail "off must stamp nothing"
ok "SCOPE/OFF scratch · codex · needs · stop_hook_active · 0 ⇒ nothing"

# ===== DEDUP =====================================================================
conf '' ''
reset @ctx_pct=75 @compact_stage=prep @compact_send_ts="$(date +%s)"
stop; sleep 0.5
[ "$(sent)" = 0 ] || fail "a sender < 60 s ago must not be re-spawned"
ok "DEDUP prep stage re-sends at most once per 60 s"

# ===== TYPING HOLD ===============================================================
reset @ctx_pct=75 @compact_stage=prep
FAKE_CLIENTS="$(date +%s) @1" SEND_TIMEOUT=1 stop
sleep 3
[ "$(sent)" = 0 ] && ! grep -q Escape "$SENDLOG" || fail "operator typing at this window must hold every keystroke"
[ "$(getopt @compact_stage)" = prep ] || fail "a held send must leave the stage at prep for the next Stop"
setopt @compact_send_ts 1        # past the 60 s dedup: the next Stop retries
FAKE_CLIENTS="$(date +%s) @2" stop; wait_sent 1
[ "$(sent)" = 1 ] || fail "a keypress on ANOTHER window must not hold"
ok "TYPING HOLD keypress at this window holds the /compact; another window does not"

# ===== STALE stage below the line =================================================
reset @ctx_pct=20 @compact_stage=compacting @compact_rearm=0
stop
[ -z "$(getopt @compact_stage)" ] || fail "a compacting stage seen below the line must be dropped"
[ "$(getopt @compact_rearm)" = 1 ] || fail "below the line re-arms"
ok "STALE compacting below the line → dropped + re-armed"

printf 'compact-prep-selftest: PASS\n'
