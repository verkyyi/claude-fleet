#!/usr/bin/env bash
# bin-inventory: 人工入口 — 旧会话 hook 表里的静默兼容入口（#4324），下一批删
# fleet-whats-new.sh — removed (issue #4904). A session launched before #4324
# still has `fleet-whats-new.sh --hook` in the hook table it read at its start:
# it runs this every turn, so this stays and exits 0 quietly for one version.
# compat-1v: 下一批删
exit 0
