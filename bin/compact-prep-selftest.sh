#!/bin/bash
# compact-prep-selftest.sh — hermetic test for compact-in-place-before-handoff
# (issue #1269, EPIC #1262 R1): bin/set-claude-state.sh's Stop path,
# bin/fleet-compact-send.sh and bin/refocus-hook.sh's `restored` step, driven
# against a STATEFUL fake tmux (window options live in a file, so one leg's writes
# are the next leg's reads — the way a real pane carries @compact_stage).
#
# What is pinned:
#   THREE STEPS  ctx 55 → 75 → (SessionStart compact) → 30: prep (one block
#                decision asking for the recovery map), compacting (exactly one
#                `/compact …` typed, Esc / text / Enter as separate send-keys),
#                restored (the refocus block carries the check line + map path) —
#                each exactly once, and the 30% Stop re-arms without a 4th step.
#   GAP / REARM  over the line again inside 600 s, or never having dropped below
#                it, ⇒ no new prep.
#   HANDOFF      at/over FLEET_AUTO_HANDOFF_PCT the original handoff nudge fires and
#                compaction stays out of it.
#   SCOPE / OFF  the hub (no @issue, no @raw), a codex pane (worker or scratch), a
#                needs stop, stop_hook_active on a fresh prep, and
#                FLEET_COMPACT_PREP_PCT=0 ⇒ nothing.
#   SCRATCH      (#1318) an @raw=1 window walks the same three steps: its map goes
#                to its worktree's git dir, or — no git dir — to
#                $FLEET_CONF_DIR/fleets/<sess>/recovery/w<window-id>.md; the refocus
#                restates the MAP (not an issue charter); the cap hands it off.
#   ORCH         (#2937) @fleet_role orchestrator: prep, the handoff nudge and the cap
#                — not the hub's warning; a steward window stays out.
#   DEDUP        a prep stage whose sender ran < 60 s ago spawns no second sender.
#   TYPING HOLD  an operator keypress at this window holds the keystrokes; held past
#                the deadline ⇒ nothing typed and the stage stays `prep` (#571).
#   STALE        a prep/compacting stage seen below the line is dropped.
#   CAP (#1316)  each fleet compaction bumps @compact_count; at the prep line a
#                count of 0/1 preps, a count of FLEET_COMPACT_MAX (default 3) gets
#                the handoff block instead ("compacted in place N times"), through
#                the same latch + typing hold; SessionStart clear/startup zeroes
#                the count (compact/resume keep it); FLEET_COMPACT_MAX=0 is
#                byte-identical to no cap; codex untouched; scratch capped too.
# No real tmux server, no gh, no live Claude.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
for f in set-claude-state.sh fleet-hook-conf.sh fleet-lib.sh fleet-lang.sh fleet-compact-send.sh refocus-hook.sh handoff-latch-reset-hook.sh; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/compact-prep-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/fakepath" "$WORK/inst/bin" "$WORK/conf/fleets/s1" "$WORK/tmp" "$WORK/widgets-issue-12" \
  "$WORK/widgets-scratch-3" "$WORK/nogit"
for f in set-claude-state.sh fleet-hook-conf.sh fleet-lib.sh fleet-lang.sh fleet-compact-send.sh refocus-hook.sh handoff-latch-reset-hook.sh; do
  cp "$BIN/$f" "$WORK/inst/bin/$f"
done
STATE="$WORK/inst/bin/set-claude-state.sh"
REFOCUS="$WORK/inst/bin/refocus-hook.sh"
LATCH="$WORK/inst/bin/handoff-latch-reset-hook.sh"
GCONF="$WORK/inst/fleet.conf"
OPTS="$WORK/opts"; SENDLOG="$WORK/send.log"
git -C "$WORK/widgets-issue-12" init -q -b issue-12 2>/dev/null || git -C "$WORK/widgets-issue-12" init -q
GITDIR=$(git -C "$WORK/widgets-issue-12" rev-parse --absolute-git-dir)
MAP="$GITDIR/fleet-recovery-map.md"
git -C "$WORK/widgets-scratch-3" init -q -b scratch-3 2>/dev/null || git -C "$WORK/widgets-scratch-3" init -q
SGITDIR=$(git -C "$WORK/widgets-scratch-3" rev-parse --absolute-git-dir)
SMAP="$SGITDIR/fleet-recovery-map.md"
CMAP="$WORK/conf/fleets/s1/recovery/w1.md"      # a scratch with NO git dir (#1318)
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
# a format: innermost #{name} from the table; #{?cond,a,b} picks a or b — tmux's
# conditional, which the fleet's session read is since #1489
# (`#{?#{session_group},#{session_group},#{session_name}}`)
def _fx(d, f):
    r = re.compile(r"#\{([^#{}]*)\}")
    while True:
        m = r.search(f)
        if not m:
            return f
        k = m.group(1)
        if k.startswith("?"):
            p = k[1:].split(",", 2) + ["", ""]
            v = p[1] if p[0] else p[2]
        else:
            v = d.get(k, "")
        f = f[:m.start()] + v + f[m.end():]
verb = a[0] if a else ""
if verb == "display-message":
    d = load(); fmt = a[-1]
    print(_fx(d, fmt))
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

# conf <prep%> [<handoff%>] [<compact max>] — the GLOBAL conf the hook resolves
# through fleet-hook-conf.
conf() {
  { printf 'FLEET_HANDOFF_DEFER_SECS=30\n'
    [ -n "${1:-}" ] && printf 'FLEET_COMPACT_PREP_PCT=%s\n' "$1"
    [ -n "${2:-}" ] && printf 'FLEET_AUTO_HANDOFF_PCT=%s\n' "$2"
    [ -n "${3:-}" ] && printf 'FLEET_COMPACT_MAX=%s\n' "$3"
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
  OUT=$(cd "${CWD:-$WORK/widgets-issue-12}" && printf '%s' "${1:-"{}"}" | env -i PATH="$WORK/fakepath:/usr/bin:/bin" \
        HOME="$WORK" TMPDIR="$WORK/tmp" TMUX="$WORK/sock,1,0" TMUX_PANE='%9' \
        FLEET_CONF_DIR="$WORK/conf" FAKE_OPTS="$OPTS" FAKE_SENDLOG="$SENDLOG" \
        FAKE_CLIENTS="${FAKE_CLIENTS:-}" FLEET_COMPACT_SEND_GRACE=0 \
        FLEET_COMPACT_SEND_TIMEOUT="${SEND_TIMEOUT:-90}" \
        sh "$STATE" 'done' 2>&1)
}
# compact_start — SessionStart(source=compact): the refocus hook.
compact_start() {
  OUT=$(cd "${CWD:-$WORK/widgets-issue-12}" && printf '{"hook_event_name":"SessionStart","source":"compact"}' \
        | env -i PATH="$WORK/fakepath:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK/tmp" \
          TMUX="$WORK/sock,1,0" TMUX_PANE='%9' FLEET_SKIP_GLOBAL_CONF=1 \
          FLEET_CONF_DIR="$WORK/conf" FAKE_OPTS="$OPTS" FAKE_SENDLOG="$SENDLOG" \
          bash "$REFOCUS" 2>&1)
}
# session_start <source> — SessionStart(<source>): the latch-reset hook.
session_start() {
  OUT=$(printf '{"hook_event_name":"SessionStart","source":"%s"}' "$1" \
        | env -i PATH="$WORK/fakepath:/usr/bin:/bin" HOME="$WORK" TMUX="$WORK/sock,1,0" TMUX_PANE='%9' \
          FAKE_OPTS="$OPTS" FAKE_SENDLOG="$SENDLOG" sh "$LATCH" 2>&1)
}
# wait_sent <n> — the detached sender is async: wait (≤ 10 s) for its n-th Enter.
wait_sent() { local i=0
  while [ "$(grep -c 'Enter$' "$SENDLOG" 2>/dev/null)" -lt "$1" ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done; }
sent() { grep -c -- '/compact ' "$SENDLOG" 2>/dev/null || true; }
blocked() { case "$OUT" in *'"decision":"block"'*) return 0 ;; esac; return 1; }

# ===== THREE STEPS: 55 → 75 → compact → 30 ======================================
conf '' ''                       # nothing set ⇒ the defaults: prep 55, handoff 80 (#1571)
reset @ctx_pct=54
stop
blocked && fail "54% (under the default 55 prep line) must not block" "$OUT"
reset @ctx_pct=55
stop
blocked || fail "55% (= default prep line) must block with the recovery-map request" "$OUT"
case "$OUT" in *'compact-prep threshold'*"$MAP"*'issue #12'*) : ;;
  *) fail "prep directive must name the threshold, the map file and the issue" "$OUT" ;; esac
printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' || fail "prep output must be valid JSON" "$OUT"
[ "$(getopt @compact_stage)" = prep ] || fail "step 1 must stamp @compact_stage=prep"
[ "$(getopt @compact_rearm)" = 0 ] || fail "step 1 must disarm (@compact_rearm=0)"
ok "STEP 1 ctx 55 (default line) → prep: one block decision naming $MAP"

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
[ "$(getopt @compact_count)" = 1 ] || fail "a completed fleet compaction must bump @compact_count to 1"
compact_start
case "$OUT" in *'CHECK FIRST'*) fail "a second (auto) compaction must not repeat the check" "$OUT" ;; esac
[ "$(getopt @compact_count)" = 1 ] || fail "a compaction the fleet did not type must not count"
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
conf '' 0                        # handoff off: 80% sits in the compaction band
reset @ctx_pct=80 @issue=;                     stop; blocked && fail "the hub / a panel (no @issue, no @raw) must not compact" "$OUT"
reset @ctx_pct=80 @issue= @raw=1 @cc_agent=codex; stop; blocked && fail "a codex scratch must not compact" "$OUT"
reset @ctx_pct=80 @cc_agent=codex;             stop; blocked && fail "codex pane must not compact" "$OUT"
reset @ctx_pct=80 @claude_state=needs;         stop; blocked && fail "a needs stop must not be hijacked" "$OUT"
reset @ctx_pct=80; stop '{"stop_hook_active":true}'; blocked && fail "stop_hook_active must not start a prep" "$OUT"
conf 0 0
reset @ctx_pct=95;                             stop; blocked && fail "FLEET_COMPACT_PREP_PCT=0 must be off" "$OUT"
[ -z "$(getopt @compact_stage)" ] || fail "off must stamp nothing"
ok "SCOPE/OFF hub · codex (worker + scratch) · needs · stop_hook_active · 0 ⇒ nothing"

# ===== SCRATCH: compact in place too (issue #1318) ================================
# The scratch-section output IS the 上线证据 of #1318: each line names the step.
conf '' ''
for leg in git nogit; do
  if [ $leg = git ]; then CWD="$WORK/widgets-scratch-3"; M="$SMAP"; else CWD="$WORK/nogit"; M="$CMAP"; fi
  export CWD
  rm -f "$M"; rm -rf "$WORK/conf/fleets/s1/recovery"
  reset @ctx_pct=72 @issue= @raw=1
  stop
  blocked || fail "scratch ($leg) at the prep line must block with the recovery-map request" "$OUT"
  case "$OUT" in *'compact-prep threshold'*"$M"*'scratch session'*) : ;;
    *) fail "scratch ($leg) prep must name $M and say scratch, not an issue" "$OUT" ;; esac
  case "$OUT" in *'issue #'*) fail "scratch ($leg) prep must not name an issue" "$OUT" ;; esac
  printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' || fail "scratch prep output must be valid JSON" "$OUT"
  [ "$(getopt @compact_stage)" = prep ] || fail "scratch ($leg) step 1 must stamp prep"
  [ -d "$(dirname "$M")" ] || fail "scratch ($leg) prep must create the map's directory $(dirname "$M")"
  ok "SCRATCH[$leg] step 1 ctx 72 → prep, map → ${M#"$WORK"/}"

  printf 'goal: drive EPIC #77\nnext: merge PR #78\n' > "$M"
  setopt @ctx_pct 75; stop '{"stop_hook_active":true}'
  wait_sent 1
  [ "$(sent)" = 1 ] || fail "scratch ($leg) step 2 must type exactly one /compact"
  grep -q -- "/compact Keep the fleet RECOVERY MAP.*$M" "$SENDLOG" || fail "scratch ($leg) /compact must name the map file"
  [ "$(getopt @compact_stage)" = compacting ] || fail "scratch ($leg) step 2 must stamp compacting"
  ok "SCRATCH[$leg] step 2 idle → exactly one /compact naming the map, stage compacting"

  compact_start
  case "$OUT" in *'[fleet recovery map] scratch'*'CHECK FIRST'*"$M"*'drive EPIC #77'*'merge PR #78'*) : ;;
    *) fail "scratch ($leg) SessionStart(compact) must restate the map inline" "$OUT" ;; esac
  case "$OUT" in *'[fleet charter]'*) fail "scratch ($leg) must not get an issue charter" "$OUT" ;; esac
  printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' || fail "scratch refocus must be valid JSON" "$OUT"
  [ "$(getopt @compact_stage)" = restored ] || fail "scratch ($leg) step 3 must stamp restored"
  [ "$(getopt @compact_count)" = 1 ] || fail "scratch ($leg) compaction must count"
  compact_start
  [ -z "$OUT" ] || fail "scratch ($leg): an auto compaction (not ours) stays silent" "$OUT"
  ok "SCRATCH[$leg] step 3 SessionStart(compact) → restored, map restated (no charter), counted"
  unset CWD
done
# FLEET_REFOCUS=0 silences the scratch restatement too (stage still completes).
CWD="$WORK/nogit"; export CWD
reset @issue= @raw=1 @compact_stage=compacting
printf 'FLEET_REFOCUS=0\n' >> "$WORK/conf/fleets/s1/conf"
compact_start
sed -i.bak '/^FLEET_REFOCUS=0$/d' "$WORK/conf/fleets/s1/conf"
[ -z "$OUT" ] || fail "FLEET_REFOCUS=0 must silence the scratch restatement" "$OUT"
[ "$(getopt @compact_stage)" = restored ] || fail "FLEET_REFOCUS=0 still completes the stage"
unset CWD
# A worker's map path is unchanged: still its worktree's git dir.
reset @ctx_pct=72; stop
case "$OUT" in *"$MAP"*'issue #12, branch, PR'*) : ;; *) fail "the worker prep is unchanged by #1318" "$OUT" ;; esac
ok "SCRATCH FLEET_REFOCUS=0 silences it; a worker's map path + directive are unchanged"

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

# ===== CAP: compact twice, then hand off (issue #1316) ===========================
conf '' '' 2                     # prep 55 + handoff 80 by default; cap 2 set here
for n in 0 1; do
  reset @ctx_pct=72 @compact_count=$n @compact_rearm=1 @compact_ts=1
  stop
  case "$OUT" in *'compact-prep threshold). The fleet will compact'*) : ;;
    *) fail "count $n at the prep line must still prep" "$OUT" ;; esac
  [ "$(getopt @compact_stage)" = prep ] || fail "count $n must stamp prep"
done
ok "CAP count 0/1 at the prep line → prep, as before"

reset @ctx_pct=72 @compact_count=2 @compact_stage=restored @compact_rearm=1 @compact_ts=1
stop
printf '%s\n' "$OUT"
blocked || fail "count 2 at the prep line must block" "$OUT"
case "$OUT" in *'compacted in place 2 times (FLEET_COMPACT_MAX=2)'*'Run /fleet-handoff now (cycle mode'*) : ;;
  *) fail "count 2 must get the handoff block naming the count" "$OUT" ;; esac
case "$OUT" in *'RECOVERY MAP'*) fail "count 2 must not also ask for a recovery map" "$OUT" ;; esac
printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' || fail "cap output must be valid JSON" "$OUT"
[ "$(getopt @handoff_armed)" = 1 ] || fail "the cap handoff must set the @handoff_armed latch"
[ "$(getopt @compact_stage)" = restored ] || fail "the cap handoff must not start a compact stage"
stop; blocked && fail "the latched pane must not be re-nudged" "$OUT"
sleep 0.5; [ "$(sent)" = 0 ] || fail "past the cap no /compact may ever be typed"
ok "CAP count 2, same 72% reading → handoff block ('compacted in place 2 times'), latched, no prep"

reset @ctx_pct=50 @compact_count=2; stop
blocked && fail "count 2 below the prep line must not block" "$OUT"
conf 70 80 2
reset @ctx_pct=75 @compact_count=2; stop
case "$OUT" in *'compacted in place 2 times'*) : ;; *) fail "cap fires inside [prep, handoff)" "$OUT" ;; esac
reset @ctx_pct=85 @compact_count=2; stop
case "$OUT" in *'(>= 80% auto-handoff threshold)'*) : ;; *) fail "at the handoff line the plain handoff still owns it" "$OUT" ;; esac
conf '' '' 3
reset @ctx_pct=72 @compact_count=2; stop
case "$OUT" in *'compact-prep threshold). The fleet will compact'*) : ;; *) fail "FLEET_COMPACT_MAX=3 lets a 3rd compaction prep" "$OUT" ;; esac
reset @ctx_pct=72 @compact_count=3; stop
case "$OUT" in *'compacted in place 3 times (FLEET_COMPACT_MAX=3)'*) : ;; *) fail "count 3 hits a cap of 3" "$OUT" ;; esac
conf '' ''                       # unset ⇒ the default cap 3 (#1571)
reset @ctx_pct=72 @compact_count=2; stop
case "$OUT" in *'compact-prep threshold). The fleet will compact'*) : ;; *) fail "the default cap 3 lets a 3rd compaction prep" "$OUT" ;; esac
reset @ctx_pct=72 @compact_count=3; stop
case "$OUT" in *'compacted in place 3 times (FLEET_COMPACT_MAX=3)'*) : ;; *) fail "unset cap ⇒ the default 3" "$OUT" ;; esac
ok "CAP band [prep, handoff) only; the plain handoff keeps its line; FLEET_COMPACT_MAX moves the cap (default 3)"

conf '' '' 2
reset @ctx_pct=60 @compact_count=2; FAKE_CLIENTS="$(date +%s) @1" stop   # under the hold ceiling, prep+10
blocked && fail "operator typing must hold the cap handoff" "$OUT"
[ -n "$(getopt @handoff_deferred_ts)" ] && [ -z "$(getopt @handoff_armed)" ] || fail "a held cap handoff stamps the hold, no latch"
[ -z "$(getopt @compact_stage)" ] || fail "a held cap handoff must not fall back to compacting"
reset @ctx_pct=72 @compact_count=2; stop '{"stop_hook_active":true}'
blocked && fail "stop_hook_active must not start the cap handoff" "$OUT"
reset @ctx_pct=72 @compact_count=2 @cc_agent=codex; stop
blocked && fail "a codex pane is untouched by the cap" "$OUT"
reset @ctx_pct=72 @compact_count=2 @issue=; stop
blocked && fail "the hub is untouched by the cap" "$OUT"
reset @ctx_pct=72 @compact_count=2 @issue= @raw=1; CWD="$WORK/widgets-scratch-3" stop
case "$OUT" in *'compacted in place 2 times (FLEET_COMPACT_MAX=2)'*) : ;; *) fail "a scratch at the cap must get the handoff block (#1318)" "$OUT" ;; esac
[ "$(getopt @handoff_armed)" = 1 ] || fail "the scratch cap handoff must latch"
ok "CAP typing hold · stop_hook_active · codex · hub untouched · scratch capped (#1318)"

# ===== ORCHESTRATOR: the ladder runs there too (issue #2937) =====================
# @fleet_role orchestrator (@norepo, no @issue / @raw) used to fall to the hub
# warning — one notice, no action — and its context only grew. Now: prep at the
# line (its own map wording), the handoff nudge at the handoff line, the cap.
conf '' ''
reset @ctx_pct=60 @issue= @fleet_role=orchestrator; CWD="$WORK/nogit" stop
case "$OUT" in *'compact-prep threshold'*'orchestrator session'*) : ;;
  *) fail "the orchestrator at the prep line must be asked for its recovery map" "$OUT" ;; esac
[ "$(getopt @compact_stage)" = prep ] || fail "the orchestrator's prep must stamp prep"
reset @ctx_pct=82 @issue= @fleet_role=orchestrator; CWD="$WORK/nogit" stop
case "$OUT" in *'auto-handoff threshold). Run /fleet-handoff now'*) : ;;
  *) fail "the orchestrator at the handoff line must be told to run /fleet-handoff" "$OUT" ;; esac
[ "$(getopt @handoff_armed)" = 1 ] || fail "the orchestrator's handoff nudge must latch"
[ -z "$(getopt @ctx_warn)" ] || fail "the orchestrator is not the hub: no @ctx_warn notice instead of the action"
reset @ctx_pct=60 @compact_count=3 @issue= @fleet_role=orchestrator; CWD="$WORK/nogit" stop
case "$OUT" in *'compacted in place 3 times'*) : ;; *) fail "the orchestrator at the cap must be handed off" "$OUT" ;; esac
reset @ctx_pct=60 @issue= @fleet_role=steward; CWD="$WORK/nogit" stop
blocked && fail "the steward is not on the orchestrator's ladder" "$OUT"
ok "ORCH prep at 55 · /fleet-handoff at 80 (latched, no hub warning) · cap 3 → handoff · steward untouched"

# SessionStart: clear/startup zero the count; compact/resume keep it.
for src in compact resume; do
  reset @compact_count=2; session_start "$src"
  [ "$(getopt @compact_count)" = 2 ] || fail "SessionStart($src) must keep @compact_count"
done
for src in clear startup; do
  reset @compact_count=2; session_start "$src"
  [ -z "$(getopt @compact_count)" ] || fail "SessionStart($src) must zero @compact_count"
done
reset @ctx_pct=72 @compact_count=2; session_start clear; setopt @ctx_pct 72; stop
case "$OUT" in *'compact-prep threshold). The fleet will compact'*) : ;; *) fail "after the handoff's clear the fresh session compacts again" "$OUT" ;; esac
ok "CAP SessionStart clear/startup → count zeroed (fresh session preps again); compact/resume keep it"

# FLEET_COMPACT_MAX=0 ⇒ byte for byte the uncapped hook, whatever the count.
conf '' ''  0
reset @ctx_pct=72; stop; base_out=$OUT; base_opts=$(grep -v '_ts	' "$OPTS")
reset @ctx_pct=72 @compact_count=7; stop
[ "$OUT" = "$base_out" ] || fail "FLEET_COMPACT_MAX=0 must emit exactly the uncapped output" "$OUT"
[ "$(grep -v '_ts	' "$OPTS" | grep -v '^@compact_count	')" = "$base_opts" ] || fail "FLEET_COMPACT_MAX=0 must write exactly the uncapped options"
ok "CAP FLEET_COMPACT_MAX=0 → byte-identical to no cap (count 7 still preps)"

printf 'compact-prep-selftest: PASS\n'
