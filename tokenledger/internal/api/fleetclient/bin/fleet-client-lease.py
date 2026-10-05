#!/usr/bin/env python3
"""fleet-client-lease.py — one person, one connected client (issue #1715, EPIC #1710 C5).

  fleet-client-lease.py acquire [--lease ID] [--device D] [--terminal T]
  fleet-client-lease.py renew   --lease ID
  fleet-client-lease.py release --lease ID
  fleet-client-lease.py get
  fleet-client-lease.py device            this client's device + terminal (TAB)

Talks to the hub's client lease (POST /v1/fleet/client), signed by this
device's connection certificate (`fleet-client@claude-fleet`) — or, with
FLEET_HUB_TOKEN / hub.json's token, by that token. Prints ONE line,
TAB-separated:

  <state>  <lease id>  <holder's device>  <device it took over from>

state is active (the lease is ours), taken_over (another client holds it — the
third field says which device), released, none (get: nobody holds one) or
nohub. Exit 0 = the hub answered (or nohub: there is no hub here, and with no
hub there is no lease — the machine's one shell is already the only one);
1 = the hub could not be asked (network, a refusal) — the caller keeps what it
had.

The device: FLEET_CLIENT_DEVICE, else — over ssh — the tailnet name of the
address the connection came from (`tailscale whois`), else 未知设备; on the
computer itself, its own name. The terminal: LC_TERMINAL, TERM_PROGRAM, TERM.
"""
import importlib.util
import json
import os
import platform
import subprocess
import sys
import time
import urllib.error
import urllib.request

PATH = "/v1/fleet/client"
NAMESPACE = "fleet-client@claude-fleet"
HERE = os.path.dirname(os.path.realpath(__file__))


def connect_module():
    spec = importlib.util.spec_from_file_location("fleet_connect", os.path.join(HERE, "fleet-connect.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def run(cmd, timeout=3):
    try:
        return subprocess.run(cmd, capture_output=True, timeout=timeout, check=True).stdout.decode().strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def tailnet_name(ip):
    """The tailnet's name for the device at ip, '' when tailscale does not know it."""
    for ts in ("tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"):
        out = run([ts, "whois", "--json", ip])
        if not out:
            continue
        try:
            node = json.loads(out).get("Node") or {}
        except ValueError:
            continue
        name = node.get("ComputedName") or (node.get("Hostinfo") or {}).get("Hostname") or node.get("Name") or ""
        return name.split(".", 1)[0]
    return ""


def device():
    d = os.environ.get("FLEET_CLIENT_DEVICE", "").strip()
    if d:
        return d
    conn = os.environ.get("SSH_CONNECTION", "").split()
    if conn:
        return tailnet_name(conn[0]) or "未知设备"
    if platform.system() == "Darwin":
        d = run(["scutil", "--get", "ComputerName"])
    return d or platform.node().split(".", 1)[0] or "未知设备"


def terminal():
    for n in ("LC_TERMINAL", "TERM_PROGRAM", "TERM"):
        v = os.environ.get(n, "").strip()
        if v:
            return v
    return ""


def out(state, lease="", holder="", took=""):
    print("\t".join(x.replace("\t", " ").replace("\n", " ") for x in (state, lease, holder, took)))


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="fleet-client-lease")
    ap.add_argument("action", choices=["acquire", "renew", "release", "get", "device"])
    ap.add_argument("--lease", default="")
    ap.add_argument("--device", default="")
    ap.add_argument("--terminal", default="")
    a = ap.parse_args(argv)
    if a.action == "device":
        print("%s\t%s" % (device(), terminal()))
        return 0
    if a.action in ("renew", "release") and not a.lease:
        sys.stderr.write("fleet-client-lease: %s needs --lease\n" % a.action)
        return 2
    fc = connect_module()
    conf = fc.load_hub_conf()
    hub = os.environ.get("FLEET_HUB_URL") or fc.machine_conf_hub() or conf.get("url") or ""
    token = os.environ.get("FLEET_HUB_TOKEN") or conf.get("token") or ""
    if not hub:
        out("nohub")
        return 0
    body = {"action": a.action, "lease": a.lease}
    if a.action == "acquire":
        body["device"] = a.device or device()
        body["terminal"] = a.terminal or terminal()
        body["version"] = run(["git", "-C", HERE, "rev-parse", "--short", "HEAD"], 2)
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    else:
        try:
            ts = int(time.time())
            cert, sig = fc.ssh_sign("fleet-client %d" % ts, NAMESPACE)
        except fc.Refused as e:
            sys.stderr.write("fleet-client-lease: %s\n" % e)
            return 1
        body.update(cert=cert, sig=sig, ts=ts)
    req = urllib.request.Request(hub.rstrip("/") + PATH, data=json.dumps(body).encode(), method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=float(os.environ.get("FLEET_CLIENT_LEASE_TIMEOUT") or 8)) as r:
            d = json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            # An older hub without the lease: treat it as none — the client
            # runs as it always has.
            out("nohub")
            return 0
        sys.stderr.write("fleet-client-lease: hub answered HTTP %d\n" % e.code)
        return 1
    except (OSError, ValueError) as e:
        sys.stderr.write("fleet-client-lease: %s\n" % e)
        return 1
    lease = d.get("lease") or {}
    by = d.get("by") or {}
    took = d.get("took_over") or {}
    out(d.get("state") or "none", lease.get("id") or "", by.get("device") or lease.get("device") or "",
        took.get("device") or "")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
