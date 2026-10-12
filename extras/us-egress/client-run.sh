#!/bin/bash
# The token is read from macOS Keychain at launch, never placed in this script/plist.
set -euo pipefail
export FLEET_US_EGRESS_TOKEN
FLEET_US_EGRESS_TOKEN=$(/usr/bin/security find-generic-password -a fleet-us-egress -s fleet-us-egress -w /Library/Keychains/System.keychain)
export PYTHONPATH
PYTHONPATH="$(cd "$(dirname "$0")" && pwd)/lib"
exec /usr/bin/python3 "$(dirname "$0")/us-egress.py" client
