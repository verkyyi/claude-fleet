#!/bin/bash
# compact-resume-selftest.sh — the turn after an in-place compaction (issue #1441):
# bin/refocus-hook.sh's SessionStart(compact) spawns bin/fleet-compact-resume.sh on a
# FLEET compaction, which submits /fleet-compact-resume (commands/fleet-compact-resume.md)
# and writes a `resumed` row to context-ladder.log. Driven against a STATEFUL fake tmux
# (window options in a file) and a fake bin/fleet-session-command.sh (the mod's inbox:
# it records the command and exits FAKE_SC_RC).
#
#   MOD        stage compacting → SessionStart(compact) → the inbox gets exactly one
#              /fleet-compact-resume, no keystroke; row `resumed mod`; the restored
#              row's ctx is `-` (the pre-compaction @ctx_pct is stale)
#   RUNNING    inbox rc 6 (taken, still running) ⇒ never typed as well
#   NO MOD     inbox rc 3/4/5 ⇒ Escape · text · Enter as separate send-keys; `send-keys`
#   SELF       a turn running that STARTED after the restore (@claude_state=working,
#              @claude_state_ts newer than @compact_restored_ts) ⇒ nothing sent;
#              `skip:self-continued` — at once, or mid-watch when the turn starts
#              while a stale `working` is being watched (issue #1572)
#   LATE       a STALE `working` (stamped before the restore) that settles to idle
#              with no turn in between ⇒ the resume is sent THEN, once: row
#              `resumed late:mod`, a second sender `skip:dup`
#   STALE      a stale `working` that never settles within FLEET_COMPACT_RESUME_WATCH
#              ⇒ nothing sent; `skip:stale`
#   NATIVE     Claude Code's own compaction (no `compacting` stage, @compact_native) ⇒
#              no sender at all, no `resumed` row
#   OFF        FLEET_COMPACT_RESUME=0 in the fleet overlay ⇒ nothing, no row
#   DUP        a second sender for the same restore ⇒ `skip:dup`, nothing sent
#   SKIPS      needs / codex / transfer pending / typing hold past the deadline
#   BRIEF      --brief prints the worker's check line + the map; a scratch gets its own
# No real tmux server, no gh, no live Claude.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
FILES="refocus-hook.sh fleet-compact-resume.sh fleet-hook-conf.sh fleet-lib.sh fleet-lang.sh fleet-ladder-log.sh"
for f in $FILES; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done
[ -f "$BIN/../commands/fleet-compact-resume.md" ] || { printf 'selftest: commands/fleet-compact-resume.md not found\n' >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/compact-resume-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/fakepath" "$WORK/inst/bin" "$WORK/inst/logs" "$WORK/conf/fleets/s1" "$WORK/tmp" \
  "$WORK/widgets-issue-12" "$WORK/widgets-scratch-3"
for f in $FILES; do cp "$BIN/$f" "$WORK/inst/bin/$f"; done
REFOCUS="$WORK/inst/bin/refocus-hook.sh"
RESUME="$WORK/inst/bin/fleet-compact-resume.sh"
OPTS="$WORK/opts"; SENDLOG="$WORK/send.log"; INBOX="$WORK/inbox.log"
LOG="$WORK/inst/logs/context-ladder.log"
OVERLAY="$WORK/conf/fleets/s1/conf"
git -C "$WORK/widgets-issue-12" init -q -b issue-12 2>/dev/null || git -C "$WORK/widgets-issue-12" init -q
MAP="$(git -C "$WORK/widgets-issue-12" rev-parse --absolute-git-dir)/fleet-recovery-map.md"
printf 'RECOVERY MAP: next step = push the branch\n' > "$MAP"
git -C "$WORK/widgets-scratch-3" init -q -b scratch-3 2>/dev/null || git -C "$WORK/widgets-scratch-3" init -q
SMAP="$(git -C "$WORK/widgets-scratch-3" rev-parse --absolute-git-dir)/fleet-recovery-map.md"
printf 'SCRATCH MAP: next step = draft the issue\n' > "$SMAP"

# the mod's inbox, faked: record the command, exit what the leg asks for
cat > "$WORK/inst/bin/fleet-session-command.sh" <<'SC'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_INBOX"
exit "${FAKE_SC_RC:-0}"
SC

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
    fmt = fmt.replace("#S", "#{session_name}")
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
         printf -- '--- inbox ---\n' >&2; cat "$INBOX" >&2 2>/dev/null
         printf -- '--- send log ---\n' >&2; cat "$SENDLOG" >&2 2>/dev/null
         printf -- '--- ladder ---\n' >&2; cat "$LOG" >&2 2>/dev/null; exit 1; }

# reset [k=v …] — worker window #12 mid fleet compaction (stage compacting), idle.
reset() {
  printf 'session_name\ts1\nwindow_name\tw12\n@issue\t12\n@claude_state\tdone\nwindow_id\t@1\n@compact_stage\tcompacting\n@ctx_pct\t72\n' > "$OPTS"
  for kv in "$@"; do printf '%s\t%s\n' "${kv%%=*}" "${kv#*=}" >> "$OPTS"; done
  : > "$SENDLOG"; : > "$INBOX"; rm -f "$LOG"
  printf 'FLEET_REPO=acme/widgets\nFLEET_MAIN=%s/main\n' "$WORK" > "$OVERLAY"
}
getopt() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$OPTS"; }
penv() { env -i PATH="$WORK/fakepath:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK/tmp" \
           TMUX="$WORK/sock,1,0" TMUX_PANE='%9' FLEET_CONF_DIR="$WORK/conf" \
           FAKE_OPTS="$OPTS" FAKE_SENDLOG="$SENDLOG" FAKE_INBOX="$INBOX" \
           FAKE_SC_RC="${SC_RC:-0}" FAKE_CLIENTS="${FAKE_CLIENTS:-}" \
           FLEET_COMPACT_RESUME_GRACE=0 FLEET_COMPACT_RESUME_TIMEOUT="${RESUME_TIMEOUT:-90}" \
           FLEET_COMPACT_RESUME_WATCH="${RESUME_WATCH:-600}" "$@"; }
# setopt k v — a hook edge / the spinner's reconcile stamping the pane mid-watch.
setopt() { awk -F'\t' -v k="$1" -v v="$2" 'BEGIN{OFS="\t"} $1 == k { $2 = v; d = 1 } { print } END { if (!d) print k, v }' "$OPTS" > "$OPTS.n" && mv "$OPTS.n" "$OPTS"; }
# compact_start — SessionStart(source=compact) in the worktree: the refocus hook.
compact_start() {
  OUT=$(cd "${CWD:-$WORK/widgets-issue-12}" && printf '{"hook_event_name":"SessionStart","source":"compact"}' \
        | penv bash "$REFOCUS" 2>&1)
}
resumed() { grep -c "	resumed	" "$LOG" 2>/dev/null || true; }
# wait_resumed — the sender is detached: wait (≤ 10 s) for its ladder row.
wait_resumed() { local i=0; while [ "$(resumed)" -lt 1 ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done; }
reason() { awk -F'\t' '$3 == "resumed" { r = $9 } END { print r }' "$LOG" 2>/dev/null; }

# ===== MOD =======================================================================
reset
compact_start
case "$OUT" in *'[fleet charter] #12'*'CHECK FIRST'*) : ;; *) fail "MOD: the refocus block must still be emitted" "$OUT" ;; esac
wait_resumed
[ "$(reason)" = mod ] || fail "MOD: want a 'resumed mod' row, got '$(reason)'"
[ "$(grep -c '' "$INBOX")" = 1 ] && grep -q -- '--from compact-resume %9 /fleet-compact-resume$' "$INBOX" \
  || fail "MOD: the inbox must get exactly one /fleet-compact-resume for %9"
[ -s "$SENDLOG" ] && fail "MOD: a command the mod took must never be typed too"
[ "$(getopt @compact_stage)" = restored ] || fail "MOD: stage must be restored"
[ -n "$(getopt @compact_resume_ts)" ] && [ "$(getopt @compact_resume_ts)" -ge "$(getopt @compact_restored_ts)" ] \
  || fail "MOD: @compact_resume_ts must cover @compact_restored_ts"
r=$(awk -F'\t' '$3 == "restored"' "$LOG")
[ "$(printf '%s' "$r" | cut -f7)" = - ] || fail "MOD: the restored row must log ctx '-', not the stale 72" "$r"
ok "MOD: SessionStart(compact) after OUR /compact → one /fleet-compact-resume via the inbox, row 'resumed mod'"

# ===== DUP: a second sender for the same restore =================================
: > "$INBOX"
penv bash "$RESUME" '%9'
[ -s "$INBOX" ] && fail "DUP: a second sender must not post again"
[ "$(reason)" = skip:dup ] || fail "DUP: want skip:dup, got '$(reason)'"
ok "DUP: one restore, one resume turn"

# ===== RUNNING: rc 6 ⇒ taken, never typed ========================================
reset; SC_RC=6 compact_start; SC_RC=6 wait_resumed
[ "$(reason)" = mod ] && [ ! -s "$SENDLOG" ] || fail "RUNNING: rc 6 must count as delivered and type nothing"
ok "RUNNING: inbox rc 6 (still running) is delivered — no keystrokes"

# ===== NO MOD: rc 3 / 4 / 5 ⇒ keystrokes =========================================
for rc in 3 4 5; do
  reset; SC_RC=$rc; compact_start; wait_resumed; SC_RC=0
  [ "$(reason)" = send-keys ] || fail "NO MOD rc=$rc: want 'resumed send-keys', got '$(reason)'"
  [ "$(grep -c '' "$SENDLOG")" = 3 ] && sed -n 1p "$SENDLOG" | grep -q 'Escape$' \
    && sed -n 2p "$SENDLOG" | grep -q -- '-l -- /fleet-compact-resume$' && sed -n 3p "$SENDLOG" | grep -q 'Enter$' \
    || fail "NO MOD rc=$rc: keystrokes must be Escape, the command, Enter — three separate send-keys"
done
ok "NO MOD: inbox rc 3/4/5 → Escape · /fleet-compact-resume · Enter, row 'resumed send-keys'"

# ===== SELF-CONTINUED: a turn that started after the restore (issue #1572) =========
# `working` stamped AFTER the restore: the harness carried on by itself — nothing sent.
reset @claude_state=working "@claude_state_ts=$(( $(date +%s) + 60 ))"
compact_start; wait_resumed
[ "$(reason)" = skip:self-continued ] || fail "SELF: want skip:self-continued, got '$(reason)'"
[ -s "$INBOX" ] || [ -s "$SENDLOG" ] && fail "SELF: nothing may be sent"
ok "SELF: a turn stamped after the restore (state working, fresh ts) → nothing sent, skip:self-continued"
# …and the same verdict when the turn starts MID-WATCH: a stale `working` is being
# watched, then a hook edge stamps the pane after the restore.
reset @claude_state=working "@claude_state_ts=$(( $(date +%s) - 60 ))"
compact_start; sleep 1
[ "$(resumed)" = 0 ] || fail "SELF mid-watch: a stale working must be WATCHED, not decided (got '$(reason)')"
setopt @claude_state_ts "$(( $(getopt @compact_restored_ts) + 1 ))"
wait_resumed
[ "$(reason)" = skip:self-continued ] || fail "SELF mid-watch: want skip:self-continued, got '$(reason)'"
[ -s "$INBOX" ] || [ -s "$SENDLOG" ] && fail "SELF mid-watch: nothing may be sent"
ok "SELF mid-watch: a stale working, then a turn after the restore → skip:self-continued, nothing sent"

# ===== LATE: a stale working that settles with no turn in between (issue #1572) ====
# The pane really sat idle under a `working` nobody cleared: when it settles (a Stop,
# or the spinner's reconcile) the resume goes out THEN — once.
reset @claude_state=working "@claude_state_ts=$(( $(date +%s) - 60 ))"
compact_start; sleep 1
[ "$(resumed)" = 0 ] && [ ! -s "$INBOX" ] || fail "LATE: nothing may be sent while the stale working is watched"
setopt @claude_state 'done'; setopt @claude_state_ts "$(( $(getopt @compact_restored_ts) + 1 ))"
wait_resumed
[ "$(reason)" = late:mod ] || fail "LATE: want 'resumed late:mod', got '$(reason)'"
[ "$(grep -c '' "$INBOX")" = 1 ] && grep -q -- '--from compact-resume %9 /fleet-compact-resume$' "$INBOX" \
  || fail "LATE: exactly one /fleet-compact-resume once the pane settled"
[ -s "$SENDLOG" ] && fail "LATE: a command the mod took must never be typed too"
[ "$(getopt @compact_resume_ts)" -ge "$(getopt @compact_restored_ts)" ] || fail "LATE: @compact_resume_ts must cover the restore"
: > "$INBOX"; penv bash "$RESUME" '%9'
[ -s "$INBOX" ] && fail "LATE: a second sender must not post again"
[ "$(reason)" = skip:dup ] || fail "LATE: the second sender must read skip:dup, got '$(reason)'"
[ "$(resumed)" = 2 ] || fail "LATE: one late row + one dup row, got $(resumed)"
ok "LATE: a stale working that settles idle with no new turn → one late resume (late:mod), then skip:dup"
# no mod: the late resume types the keystrokes, row late:send-keys
reset @claude_state=working "@claude_state_ts=$(( $(date +%s) - 60 ))"
SC_RC=3 compact_start; sleep 1
setopt @claude_state 'done'; setopt @claude_state_ts "$(( $(getopt @compact_restored_ts) + 1 ))"
SC_RC=3 wait_resumed; SC_RC=0
[ "$(reason)" = late:send-keys ] && [ "$(grep -c '' "$SENDLOG")" = 3 ] \
  || fail "LATE no mod: want late:send-keys with Escape · text · Enter, got '$(reason)'"
ok "LATE no mod: the late resume is typed (late:send-keys)"

# ===== STALE: a stale working that never settles ===================================
reset @claude_state=working "@claude_state_ts=$(( $(date +%s) - 60 ))"
RESUME_WATCH=0 compact_start; wait_resumed
[ "$(reason)" = skip:stale ] || fail "STALE: want skip:stale at the watch bound, got '$(reason)'"
[ -s "$INBOX" ] || [ -s "$SENDLOG" ] && fail "STALE: nothing may be sent into a pane that cannot be read"
ok "STALE: a working stamped before the restore that never settles → skip:stale, nothing sent"

# ===== NATIVE: Claude Code's own compaction ======================================
reset @compact_stage= @compact_native="$(date +%s)"
compact_start; sleep 1.5
[ "$(resumed)" = 0 ] || fail "NATIVE: Claude Code's own compaction carries on by itself — no resumed row"
[ -s "$INBOX" ] || [ -s "$SENDLOG" ] && fail "NATIVE: nothing may be sent"
ok "NATIVE: a compaction the fleet did not type spawns no sender"

# ===== OFF =======================================================================
reset; printf 'FLEET_COMPACT_RESUME=0\n' >> "$OVERLAY"
compact_start; sleep 1.5
[ "$(resumed)" = 0 ] || fail "OFF: FLEET_COMPACT_RESUME=0 must write no row"
[ -s "$INBOX" ] || [ -s "$SENDLOG" ] && fail "OFF: FLEET_COMPACT_RESUME=0 must send nothing"
[ "$(getopt @compact_stage)" = restored ] || fail "OFF: the stage still completes"
ok "OFF: FLEET_COMPACT_RESUME=0 → no action, no row (the stage still completes)"

# ===== SKIPS ======================================================================
for c in 'needs:@claude_state=needs' 'codex:@cc_agent=codex' "transfer:@agent_transfer_pending_until=$(( $(date +%s) + 600 ))"; do
  why=${c%%:*}; kv=${c#*:}
  reset "$kv"; compact_start; wait_resumed
  [ "$(reason)" = "skip:$why" ] || fail "SKIP $why: want skip:$why, got '$(reason)'"
  [ -s "$INBOX" ] || [ -s "$SENDLOG" ] && fail "SKIP $why: nothing may be sent"
done
reset
FAKE_CLIENTS="$(date +%s) @1" RESUME_TIMEOUT=0 compact_start
wait_resumed
[ "$(reason)" = skip:typing ] || fail "TYPING: held past the deadline ⇒ skip:typing, got '$(reason)'"
[ -s "$INBOX" ] || [ -s "$SENDLOG" ] && fail "TYPING: nothing may be sent while the operator types"
ok "SKIPS: needs / codex / transfer pending / typing hold → nothing sent, one skip row each"

# ===== BRIEF =====================================================================
reset @compact_stage=restored
out=$(cd "$WORK/widgets-issue-12" && penv bash "$RESUME" --brief 2>&1)
case "$out" in *'[fleet compact-resume] worker #12'*'CHECK FIRST'*'next step = push the branch'*'git status'*) : ;;
  *) fail "BRIEF: a worker gets its check line, the map and git state" "$out" ;; esac
printf 'session_name\ts1\n@raw\t1\nwindow_id\t@3\n' > "$OPTS"
out=$(cd "$WORK/widgets-scratch-3" && penv bash "$RESUME" --brief 2>&1)
case "$out" in *'[fleet compact-resume] scratch'*'CHECK FIRST'*'next step = draft the issue'*) : ;;
  *) fail "BRIEF: a scratch gets its own check line + its map" "$out" ;; esac
grep -q 'mcp__fleet__brief.*kind: resume' "$BIN/../commands/fleet-compact-resume.md" \
  || fail "BRIEF: the command must call the brief tool with kind: resume (it runs fleet-compact-resume.sh --brief, #1811)"
ok "BRIEF: --brief restates the worker / scratch check line with the recovery map"

printf 'compact-resume-selftest: all legs PASS\n'
