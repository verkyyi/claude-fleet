#!/bin/sh
# classify-hook.sh — retired with the screen classifier (issue #2543). The agent
# reports its own state (OSC 7501, issue #2537), so nothing reads a screen to guess
# it any more. Kept as a quiet shell for one version: a session started before the
# release still runs it from its Stop hook table (CONTRIBUTING «老会话兼容»).
# compat-1v: 下一批删
exit 0
