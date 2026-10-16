#!/bin/sh
# selftest-part-of: tmux-spinner.sh tmux-spinner.py fleet-render-watch.py
set -eu
BIN=$(CDPATH='' cd -- "${0%/*}" && pwd)
exec python3 "$BIN/spinner-control-selftest.py"
