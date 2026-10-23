#!/bin/sh
# bin/fleet-ssh-askpass.sh — the SSH_ASKPASS of every fleet session.
#
# fleet-session-wrap.sh exports SSH_ASKPASS_REQUIRE=force with this file as
# SSH_ASKPASS, so a question ssh would ask on /dev/tty — an unknown host's
# yes/no, a key's passphrase — comes here instead of onto the session's pane,
# where nobody is asked: it painted over the agent's screen and ate the
# person's keys (an MCP server's `ssh m4` after mini2's LAN address changed).
# The answer is always no: nothing on stdout, exit 1, so ssh stops with its own
# error («Host key verification failed.»). The one line below goes to ssh's
# stderr — the Bash tool's output, an MCP server's log — never the pane.
printf 'fleet: ssh asked %s — a session cannot answer; add the host key to known_hosts (or pass -o BatchMode=yes)\n' \
  "$(printf '%s' "${1:-a question}" | tr '\n' ' ' | cut -c1-160)" >&2
exit 1
