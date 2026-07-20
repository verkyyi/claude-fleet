#!/bin/sh
# dash-popup-wait.sh — the dash's "pause repaint while a modal popup is open"
# guard (issue #308), made self-healing against a leaked flag (issue #431).
#
# A tmux display-popup is a CLIENT-SIDE overlay that does NOT freeze the panes
# under it, so the dash's 1Hz reload keeps re-rendering right beneath the popup
# and that churn flashes THROUGH it (worst where the popup edge clips a
# double-width CJK cell). The modal popup binds (conf/tmux-attention.conf) raise
# a server-global @popup_open flag for the popup's lifetime; this guard sits in
# the dash reload loop (bin/tmux-dashboard.sh) between the sleep and `bash $ROWS`
# and busy-waits while the flag says a popup is open, so the dash emits NO frame
# — no under-popup churn — until the popup closes.
#
# THE FLAG IS AN EPOCH, NOT A BOOLEAN (issue #431). Each popup OPEN stamps
# @popup_open with `date +%s` (the open moment); each CLOSE resets it to 0. This
# guard trusts the flag only while it is FRESH — `now - @popup_open < MAX_AGE`.
# Why: the one path that leaks the flag is the popup dying before its trailing
# `set 0` runs — the client detaches / switches fleets / disconnects mid-popup
# (a Termius drop, a `detach-client -E` fleet-switch), interrupting the whole
# key-command chain. A `client-detached` hook (conf/tmux-attention.conf) clears
# the flag on the dominant path, but a timestamp is the belt-and-suspenders: a
# STRANDED value simply ages out, so a leaked flag can NEVER stall the dash for
# more than MAX_AGE — instead of freezing it ~20s per reload forever (the
# reported bug). A genuinely-open popup keeps suppressing the repaint the whole
# time it is open (up to MAX_AGE); held longer, it costs at most a repaint per
# poll past the cap — never a freeze.
#
# Value semantics (read each poll, so a close resumes the dash instantly):
#   fresh epoch  (now - v < MAX_AGE)  → popup open → keep pausing.
#   0 / empty / non-numeric           → closed     → repaint now.
#   stale epoch  (now - v >= MAX_AGE)  → leaked     → repaint now (self-heal).
# Anything we cannot verify (date fails, garbage value) falls through to a
# repaint — the guard fails SAFE toward painting, never toward freezing.
#
# Tunables (env, inherited from bin/tmux-dashboard.sh):
#   FLEET_DASH_POPUP_MAX_AGE  seconds a set flag is trusted before it is treated
#                             as leaked (default 30 — the issue #431 example N).
#   FLEET_DASH_POPUP_POLL     re-check interval ≈ resume latency (default 0.2s).
#
# Bare `tmux` on purpose: run from the dash pane's reload, it inherits $TMUX and
# so targets THIS fleet's socket (issue #159). Exit 0 always.
set -u

MAX_AGE="${FLEET_DASH_POPUP_MAX_AGE:-30}"
POLL="${FLEET_DASH_POPUP_POLL:-0.2}"

# A non-numeric MAX_AGE would break the arithmetic below — fall back to the
# default rather than risk a broken comparison that could freeze the dash.
case "$MAX_AGE" in ''|*[!0-9]*) MAX_AGE=30 ;; esac

while :; do
  v=$(tmux show-option -gqv @popup_open 2>/dev/null)
  # closed: empty, the literal 0, or anything non-numeric → repaint immediately.
  case "$v" in
    ''|0) break ;;
    *[!0-9]*) break ;;
  esac
  now=$(date +%s 2>/dev/null)
  case "$now" in ''|*[!0-9]*) break ;; esac   # can't verify freshness → repaint (fail safe)
  # stale/leaked flag ages out (issue #431); a fresh one keeps the dash paused.
  [ "$(( now - v ))" -ge "$MAX_AGE" ] && break
  sleep "$POLL"
done

exit 0
