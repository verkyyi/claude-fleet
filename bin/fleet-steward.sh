#!/bin/bash
# fleet-steward.sh — retired (issue #3118, EPIC #3111 C7). The fleet no longer opens,
# reopens or revives a resident steward seat: nothing keeps a session open, and no
# setting brings one back. A person who wants the role types
# /fleet-steward in any session that binds no issue (take_role).
#
# This shell stays for one version so an older caller (a daemon, a session started
# before the release) runs quietly instead of failing: every subcommand prints
# nothing and exits 0. # compat-1v: 下一批删
exit 0
