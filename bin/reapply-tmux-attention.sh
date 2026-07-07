#!/bin/sh
# reapply-tmux-attention.sh — ensure ~/.tmux.conf sources the attention layer.
# Run once at install, and again after anything regenerates ~/.tmux.conf.
# Idempotent: does nothing if the source line is already present.
BIN=$(cd "$(dirname "$0")" && pwd)
FLEET=$(cd "$BIN/.." && pwd)
CONF="$HOME/.tmux.conf"
LINE="if-shell '[ -f $FLEET/conf/tmux-attention.conf ]' 'source-file $FLEET/conf/tmux-attention.conf'"

[ -f "$CONF" ] || : > "$CONF"
if grep -qF 'tmux-attention.conf' "$CONF"; then
  echo "already present in $CONF"
else
  { echo ""; echo "# --- claude-fleet: Claude session attention layer ---"; echo "$LINE"; } >> "$CONF"
  echo "appended source line to $CONF"
fi
tmux source-file "$CONF" 2>/dev/null && echo "reloaded" || echo "(tmux not running; will apply on next start)"
