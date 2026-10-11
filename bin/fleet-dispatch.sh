#!/bin/bash
# fleet-dispatch.sh — retired (issue #3120, EPIC #3111 C9).
#
# The autofill dispatcher is gone: nothing starts a session on its own from the
# backlog any more, and its daemon (com.claude-fleet.dispatch) went with its
# template. The red-master macOS watcher it also ran lives on the diskguard tick
# now (bin/fleet-macos-watch.sh — files and alerts, never spawns). This shell
# stays one version for a daemon or a hand that still calls it, and does nothing.
# compat-1v: 下一批删
exit 0
