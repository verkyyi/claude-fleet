#!/usr/bin/env python3
"""fleet-client-actions.py — open it on the device in the person's hands
(issue #1717, EPIC #1710 C7): the session's side.

  fleet-client-actions.py send --kind open_url (--url U | --rport P [--path /x]
                               [--scheme http] | --from-addr <fleet-open-addr.py
                               payload>) [--tailnet-link L] [--hub-link L] [--wait S]
                               [--cport P --who W]
  fleet-client-actions.py send --kind show_file --file /abs/path [--inline]
  fleet-client-actions.py send --kind notify [--title T] [--body B]
        a session (on a node) hands one action to its person's CURRENT client,
        through the hub (POST /v1/node/client/actions, this node's token). Prints
        ONE JSON line: {"state": none|queued|done|failed|nohub, "result", "client"}
        — none/nohub: nobody to hand it to, the caller opens it its own way.
        Exit 0 = the hub answered (or nohub); 1 = the hub could not be asked.

The device side that long-polled the hub and ran each action (`run`, with its
`notify` / `click` / `jump-pending`) was the old client's (fleet-shell.sh) and
went with it (issue #3008): a thin client's page, file and notification travel
over its own connection — OSC 7502 `open` (fleet-thin.py) and
fleet_thin_lease.py notify — so fleet-open.sh / fleet-show.sh take that road
first and this answers `none` when no client takes the action.
"""
import importlib.util
import json
import os
import sys
import urllib.error
import urllib.request

try:  # the ONE TLS context for the hub: every CA source this computer has (claude-fleet#2878)
    import fleet_tls
    fleet_tls.install()
except ImportError:
    fleet_tls = None

HERE = os.path.dirname(os.path.realpath(__file__))


def lease_module():
    spec = importlib.util.spec_from_file_location("fleet_client_lease", os.path.join(HERE, "fleet-client-lease.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


# ---------------------------------------------------------------------------
# send — the session's side
# ---------------------------------------------------------------------------

def send(a):
    fl = lease_module()
    fc = fl.connect_module()
    # the node token at the address it belongs to — separated, the credential
    # proxy's broker, never the hub itself (issue #2665)
    hub, ntok = fl.node_pair(os.environ.get("FLEET_HUB_URL") or fc.machine_conf_hub()
                             or fc.load_hub_conf().get("url") or "")
    if not hub or not ntok:
        print(json.dumps({"state": "nohub"}))
        return 0
    body = {"kind": a.kind, "wait": a.wait}
    if a.from_addr:
        # fleet-open-addr.py's payload: a `forward` is a page on this machine's
        # loopback, anything else goes as the url
        try:
            p = json.loads(a.from_addr)
        except ValueError:
            p = {}
        if p.get("kind") == "forward" and str(p.get("rport", "")).isdigit():
            a.rport, a.path, a.scheme = int(p["rport"]), p.get("path") or "/", p.get("scheme") or "http"
        elif p.get("kind") == "url" and p.get("url"):
            a.url = p["url"]
            if str(p.get("cport", "")).isdigit():
                a.cport = int(p["cport"])
    if a.kind == "open_url":
        if a.rport:
            body.update(rport=a.rport, path=a.path or "/", scheme=a.scheme or "http")
        else:
            body["url"] = a.url
            if a.cport:
                body.update(cport=a.cport, who=(a.who or "")[:80])
        body["links"] = {k: v for k, v in (("tailnet", a.tailnet_link), ("hub", a.hub_link)) if v}
    elif a.kind == "show_file":
        f = os.path.realpath(a.file)
        try:
            size = os.path.getsize(f)
        except OSError as e:
            sys.stderr.write("fleet-client-actions: %s\n" % e)
            return 2
        body.update(file=f, name=os.path.basename(f), size=size, inline=a.inline)
    else:
        body.update(title=a.title, body=a.body)
    req = urllib.request.Request(hub.rstrip("/") + "/v1/node/client/actions", data=json.dumps(body).encode(),
                                 method="POST", headers={"Authorization": "Bearer " + ntok,
                                                         "Content-Type": "application/json"})
    tmo = float(os.environ.get("FLEET_CLIENT_LEASE_TIMEOUT") or 5) + a.wait
    try:
        with urllib.request.urlopen(req, timeout=tmo) as r:
            d = json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print(json.dumps({"state": "nohub"}))   # a hub from before #1717
            return 0
        why = fl._http_why(e)
        sys.stderr.write("fleet-client-actions: hub answered HTTP %d%s\n" % (e.code, (" — " + why) if why else ""))
        return 1
    except (OSError, ValueError) as e:
        sys.stderr.write("fleet-client-actions: %s\n" % e)
        return 1
    c = d.get("client") or {}
    print(json.dumps({"state": d.get("state") or "none", "id": d.get("id") or "", "result": d.get("result") or "",
                      "client": {k: c.get(k) for k in ("device", "terminal", "caps", "via", "host") if c.get(k)}},
                     ensure_ascii=False))
    return 0


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="fleet-client-actions")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("send")
    s.add_argument("--kind", required=True, choices=["open_url", "show_file", "notify"])
    s.add_argument("--url", default="")
    s.add_argument("--from-addr", default="")
    s.add_argument("--rport", type=int, default=0)
    s.add_argument("--path", default="")
    s.add_argument("--scheme", default="")
    s.add_argument("--tailnet-link", default="")
    s.add_argument("--hub-link", default="")
    s.add_argument("--file", default="")
    s.add_argument("--inline", action="store_true")
    s.add_argument("--title", default="")
    s.add_argument("--body", default="")
    s.add_argument("--wait", type=int, default=0)
    s.add_argument("--cport", type=int, default=0)
    s.add_argument("--who", default="")
    a = ap.parse_args(argv)
    return send(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
