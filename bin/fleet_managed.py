"""Is this login one a managed node's ops service maintains? (claude-fleet#4594)

The python twin of fleet_node_manages (bin/fleet-daemon-lib.sh): the machine
daemon took the login over — `account adopt` wrote it into accounts.json with
`managed: true`. Such a login is the fleet's to keep running, its connection
certificate included, so nothing it prints may tell a person to run
`fleet login`: the ops service renews it (fleet-login.py keep, on the login's
diskguard tick), and what it cannot renew is an ops breakage, never a scan.

No accounts.json (every computer that is not a managed node) ⇒ False.
  FLEET_NODE_STATE      the daemon's state dir (default /var/db/fleet-node)
  FLEET_INSTALL_LOGIN   the login asked about (default $USER, else the uid's)
"""
import getpass
import json
import os

# What a managed login says instead of 「fleet login」.
OPS_WORD = "运维会自动续期（托管登录，不需要你登录或扫码）"
# What it says when even the device key cannot renew: an ops matter, still not the person's.
OPS_LAPSED = "已报运维处理（托管登录，不需要你登录或扫码）"


def login():
    return os.environ.get("FLEET_INSTALL_LOGIN") or os.environ.get("USER") or getpass.getuser()


def managed(who=None):
    path = os.path.join(os.environ.get("FLEET_NODE_STATE") or "/var/db/fleet-node", "accounts.json")
    try:
        with open(path) as f:
            a = json.load(f)
    except (OSError, ValueError):
        return False
    e = a.get(who or login()) if isinstance(a, dict) else None
    return isinstance(e, dict) and bool(e.get("managed"))
