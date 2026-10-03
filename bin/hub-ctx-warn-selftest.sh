#!/usr/bin/env bash
# hub-ctx-warn-selftest.sh — the hub's context warning (issue #1319, EPIC #1315 C4).
# The hub (no @issue, no @raw, not a panel) has no /fleet-handoff cycle to fire and
# is where the operator types, so at the handoff line its Stop hook (bin/
# set-claude-state.sh) must only WARN:
#
#   CROSS    hub at/over the line → no block (stdout empty), @ctx_warn=1, ONE
#            FLEET_NOTIFY_CMD message naming /fleet-handoff, one `hub-warn` ladder row
#   ONCE     further Stops over the line → no second notification / row
#   FALL     a Stop under the line unsets @ctx_warn; the next climb warns again
#   CLEAR    SessionStart(clear) (handoff-latch-reset-hook.sh) unsets @ctx_warn
#   TOKENS   the line set in tokens (#1317) is the line the hub is judged on
#   PANEL    a dash/plan/backlog window is never warned
#   WORKER   an @issue pane and an @raw scratch keep today's block, no @ctx_warn
#   OFF      FLEET_HUB_CTX_ACTION=off, or auto-handoff off (no line) ⇒ nothing
#   NOCMD    no FLEET_NOTIFY_CMD ⇒ still badged + logged, nothing run
# No real tmux server, no gh, no live Claude.
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
FILES="set-claude-state.sh fleet-hook-conf.sh fleet-lib.sh fleet-lang.sh fleet-ladder-log.sh handoff-latch-reset-hook.sh"
for f in $FILES; do
  [ -f "$BIN/$f" ] || { printf 'selftest: %s not found\n' "$BIN/$f" >&2; exit 2; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hub-ctx-warn-selftest.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/fakepath" "$WORK/inst/bin" "$WORK/conf/fleets/s1" "$WORK/tmp" "$WORK/hub"
for f in $FILES; do cp "$BIN/$f" "$WORK/inst/bin/$f"; done
STATE="$WORK/inst/bin/set-claude-state.sh"
LATCH="$WORK/inst/bin/handoff-latch-reset-hook.sh"
GCONF="$WORK/inst/fleet.conf"
LOG="$WORK/inst/logs/context-ladder.log"
OPTS="$WORK/opts"; NOTES="$WORK/notes"
printf 'FLEET_REPO=acme/widgets\nFLEET_MAIN=%s/main\n' "$WORK" > "$WORK/conf/fleets/s1/conf"

# --- stateful fake tmux: options in $OPTS ("key<TAB>value") ---------------------
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
elif verb in ("send-keys", "list-clients"):
    pass
else:
    sys.exit(1)
FAKE
chmod +x "$WORK/fakepath/tmux"
cat > "$WORK/notify" <<EOF
#!/bin/sh
printf '%s\n---\n' "\$1" >> "$NOTES"
EOF
chmod +x "$WORK/notify"

ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf -- '--- detail ---\n%s\n' "$2" >&2
         printf -- '--- opts ---\n' >&2; cat "$OPTS" >&2 2>/dev/null
         printf -- '--- notes ---\n' >&2; cat "$NOTES" >&2 2>/dev/null; exit 1; }

# conf <handoff%> [extra line…]
conf() { { printf 'FLEET_COMPACT_PREP_PCT=0\nFLEET_AUTO_HANDOFF_PCT=%s\nFLEET_NOTIFY_CMD=%s\n' "$1" "$WORK/notify"
           shift; for l in "$@"; do printf '%s\n' "$l"; done; } > "$GCONF"; }
# reset <window_name> [k=v…] — a fresh pane; no @issue / @raw unless given
reset() {
  printf 'session_name\ts1\n@claude_state\tdone\nwindow_id\t@1\nwindow_name\t%s\n' "$1" > "$OPTS"
  shift; for kv in "$@"; do printf '%s\t%s\n' "${kv%%=*}" "${kv#*=}" >> "$OPTS"; done
  : > "$NOTES"; rm -f "$LOG"
}
setopt() { awk -F'\t' -v k="$1" '$1 != k' "$OPTS" > "$OPTS.n"; printf '%s\t%s\n' "$1" "$2" >> "$OPTS.n"; mv "$OPTS.n" "$OPTS"; }
getopt() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$OPTS"; }
penv() { env -i PATH="$WORK/fakepath:/usr/bin:/bin" HOME="$WORK" TMPDIR="$WORK/tmp" \
           TMUX="$WORK/sock,1,0" TMUX_PANE='%9' FLEET_CONF_DIR="$WORK/conf" FAKE_OPTS="$OPTS" "$@"; }
stop() { OUT=$(cd "$WORK/hub" && printf '{}' | penv sh "$STATE" 'done' 2>&1); }
# notes — how many notifications landed (the notifier runs detached: give it a beat)
notes() { sleep 0.3; [ -f "$NOTES" ] && grep -c '^---$' "$NOTES" | tr -d ' ' || :; }
hubrows() { [ -f "$LOG" ] && grep -c $'\thub-warn\t' "$LOG" || :; }

# ---- CROSS ----------------------------------------------------------------------
conf 55
reset claude-fleet '@ctx_pct=60'
stop
[ -z "$OUT" ] || fail "CROSS: the hub must never be blocked (stdout must stay empty)" "$OUT"
[ "$(getopt @ctx_warn)" = 1 ] || fail "CROSS: @ctx_warn not stamped"
[ "$(getopt @handoff_armed)" = '' ] || fail "CROSS: the hub must not be armed for a handoff cycle"
[ "$(notes)" = 1 ] || fail "CROSS: want exactly 1 notification, got $(notes)"
grep -q '/fleet-handoff' "$NOTES" || fail "CROSS: the notification must name /fleet-handoff"
grep -q 's1:claude-fleet' "$NOTES" && grep -q '60%' "$NOTES" && grep -q '55%' "$NOTES" \
  || fail "CROSS: the notification must name the window, its % and the line"
[ "$(hubrows)" = 1 ] || fail "CROSS: want one hub-warn ladder row, got $(hubrows)"
ok "CROSS: hub over the line → @ctx_warn + one notification + one ladder row, no block"

# ---- ONCE -----------------------------------------------------------------------
setopt @ctx_pct 63; stop; stop
[ -z "$OUT" ] || fail "ONCE: still no block" "$OUT"
[ "$(notes)" = 1 ] || fail "ONCE: re-notified while still over the line ($(notes))"
[ "$(hubrows)" = 1 ] || fail "ONCE: re-logged while still over the line"
ok "ONCE: further Stops over the line stay silent"

# ---- FALL -----------------------------------------------------------------------
setopt @ctx_pct 20; stop
[ "$(getopt @ctx_warn)" = '' ] || fail "FALL: @ctx_warn not cleared under the line"
setopt @ctx_pct 58; stop
[ "$(getopt @ctx_warn)" = 1 ] && [ "$(notes)" = 2 ] || fail "FALL: the next climb must warn again ($(notes))"
# an unmeasured context (fresh session, @ctx_pct unset) neither warns nor clears
setopt @ctx_pct ''; stop
[ "$(getopt @ctx_warn)" = 1 ] || fail "FALL: an unreadable @ctx_pct must not clear the latch"
ok "FALL: under the line clears @ctx_warn; the next climb warns again"

# ---- CLEAR ----------------------------------------------------------------------
OUT=$(cd "$WORK/hub" && printf '{"hook_event_name":"SessionStart","source":"clear"}' \
      | penv FLEET_SKIP_GLOBAL_CONF=1 bash "$LATCH" 2>&1)
[ "$(getopt @ctx_warn)" = '' ] || fail "CLEAR: SessionStart(clear) must unset @ctx_warn" "$OUT"
ok "CLEAR: SessionStart(clear) drops the badge"

# ---- TOKENS ---------------------------------------------------------------------
conf 0 'FLEET_AUTO_HANDOFF_TOKENS=200000'
reset claude-fleet '@ctx_pct=21' '@ctx_limit=1000000'
stop
[ "$(getopt @ctx_warn)" = 1 ] && [ "$(notes)" = 1 ] || fail "TOKENS: 21% ≥ 200k/1M must warn"
grep -q '20%' "$NOTES" || fail "TOKENS: the line named must be the converted 20%"
ok "TOKENS: a token line is converted against @ctx_limit for the hub too"

# ---- PANEL ----------------------------------------------------------------------
conf 55
for p in dash plan backlog; do
  reset "$p" '@ctx_pct=90'; stop
  [ -z "$OUT" ] && [ "$(getopt @ctx_warn)" = '' ] && [ "$(notes)" = 0 ] \
    || fail "PANEL: $p must never be warned" "$OUT"
done
ok "PANEL: dash / plan / backlog are never warned"

# ---- WORKER / SCRATCH -----------------------------------------------------------
reset widgets-12 '@ctx_pct=60' '@issue=12'; stop
case "$OUT" in '{"decision":"block"'*'/fleet-handoff'*) : ;; *) fail "WORKER: today's block must be unchanged" "$OUT" ;; esac
[ "$(getopt @ctx_warn)" = '' ] && [ "$(notes)" = 0 ] || fail "WORKER: a worker gets no hub warning"
reset scratch-3 '@ctx_pct=60' '@raw=1'; stop
case "$OUT" in '{"decision":"block"'*'/fleet-handoff'*) : ;; *) fail "SCRATCH: today's block must be unchanged" "$OUT" ;; esac
[ "$(getopt @ctx_warn)" = '' ] && [ "$(notes)" = 0 ] || fail "SCRATCH: a scratch gets no hub warning"
ok "WORKER: @issue / @raw panes keep their block and get no @ctx_warn"

# ---- OFF ------------------------------------------------------------------------
conf 55 'FLEET_HUB_CTX_ACTION=off'
reset claude-fleet '@ctx_pct=90'; stop
[ -z "$OUT" ] && [ "$(getopt @ctx_warn)" = '' ] && [ "$(notes)" = 0 ] || fail "OFF: FLEET_HUB_CTX_ACTION=off must do nothing" "$OUT"
conf 0
reset claude-fleet '@ctx_pct=90'; stop
[ -z "$OUT" ] && [ "$(getopt @ctx_warn)" = '' ] && [ "$(notes)" = 0 ] || fail "OFF: no handoff line ⇒ no hub warning" "$OUT"
ok "OFF: the off switch, and auto-handoff off, leave the hub untouched"

# ---- NOCMD ----------------------------------------------------------------------
printf 'FLEET_COMPACT_PREP_PCT=0\nFLEET_AUTO_HANDOFF_PCT=55\n' > "$GCONF"
reset claude-fleet '@ctx_pct=60'; stop
[ -z "$OUT" ] && [ "$(getopt @ctx_warn)" = 1 ] && [ "$(notes)" = 0 ] && [ "$(hubrows)" = 1 ] \
  || fail "NOCMD: no notifier ⇒ still badged + logged, nothing run" "$OUT"
ok "NOCMD: without FLEET_NOTIFY_CMD the badge + ladder row still land"

printf 'hub-ctx-warn-selftest: all passed\n'
