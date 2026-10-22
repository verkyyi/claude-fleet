#!/usr/bin/env python3
"""Retired Agent hook: native subagents may implement work within their task.

# compat-1v: 下一批删
Old sessions may still call this path from their launch-time hook table. Keep
it as a silent success for one compatibility window; new installs do not
register it. Native agent orchestration owns subagent types and isolation.
The separate base-checkout and cross-session guards remain in force.
"""

if __name__ == "__main__":
    raise SystemExit(0)
