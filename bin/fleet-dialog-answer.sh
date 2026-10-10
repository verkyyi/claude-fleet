#!/bin/sh
# fleet-dialog-answer.sh — answer a session's open choice dialog on the person's
# behalf, through the one guarded road (issue #2958): bin/fleet_dialog_answer.py
# is the whole of it (its header is the spec); the `answer_dialog` fleet tool runs this.
exec python3 "$(cd "$(dirname "$0")" && pwd)/fleet_dialog_answer.py" "$@"
