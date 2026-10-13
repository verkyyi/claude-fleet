#!/bin/sh
# fleet-hub-notify "<message>" — the hub's FLEET_NOTIFY_CMD (claude-fleet#4086).
# The hub runs `<FLEET_NOTIFY_CMD> "<message>"` with no shell, so the command is
# one path; the work is `ccquota notify` (cmd/ccquota/notify.go): kf-notify
# (FLEET_NOTIFY_KF_*) or a robot webhook (FLEET_NOTIFY_WEBHOOK), read from the
# environment only. Neither set ⇒ nothing sent, exit 0.
exec ccquota notify -- "$@"
