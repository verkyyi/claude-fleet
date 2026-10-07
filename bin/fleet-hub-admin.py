#!/usr/bin/env python3
"""fleet hub set|get|unset|settings|users — the hub's settings and people list (claude-fleet#1986).

    fleet hub settings                   every hub setting: what applies, from where
    fleet hub get <key>                  one setting's value
    fleet hub set <key> <value>          change it — applies at once, audited
    fleet hub unset <key>                back to the default
    fleet users list                     who may sign in with GitHub (= fleet hub users)
    fleet users add <name> [--machine-login <login>]
    fleet users remove <name>

Keys: hub.public_meter hub.public_badges pool.skip_pct pool.move_when_full
fleet.auto_assign fleet.spot fleet.routes_extra user.<id>.machine_login (and the
fleet.* keys PUT /v1/fleet/settings already took).

Auth, read from the environment and never written down: CCQUOTA_VIEWER_TOKEN
(the operator's token), else FLEET_HUB_SESSION — the value of the `ccq_sess`
cookie a signed-in admin's browser holds. The hub is --hub <url>, else
$CCQUOTA_HUB_URL / $FLEET_HUB_URL / fleet.conf / hub.json.

Exit 0 done · 1 the hub refused (its reason printed) · 2 usage · 3 no hub / no
credential / unreachable.
"""
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

CONF_DIR = os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet")
SETTINGS_PATH = "/v1/fleet/settings"
USERS_PATH = "/v1/fleet/users"
MIGRATED = "hub.legacy_migrated."


def die(msg, rc=1):
    print("fleet hub · " + msg, file=sys.stderr)
    sys.exit(rc)


def env_file_val(path, key):
    try:
        with open(path) as f:
            for line in f:
                m = re.match(r"\s*(?:export\s+)?%s=(.*)$" % re.escape(key), line)
                if m:
                    return m.group(1).split(" #")[0].strip().strip("\"'")
    except OSError:
        pass
    return ""


def hub_url(arg):
    url = arg or os.environ.get("CCQUOTA_HUB_URL") or os.environ.get("FLEET_HUB_URL") \
        or env_file_val(os.path.join(CONF_DIR, "fleet.conf"), "FLEET_HUB_URL") \
        or env_file_val(os.path.join(CONF_DIR, "node.env"), "CCQUOTA_HUB_URL")
    if not url:
        try:
            with open(os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
                                   "claude-fleet", "hub.json")) as f:
                d = json.load(f)
            url = str(d.get("url") or "") if isinstance(d, dict) else ""
        except (OSError, ValueError):
            url = ""
    return url.rstrip("/")


def auth_headers():
    tok = os.environ.get("CCQUOTA_VIEWER_TOKEN") or ""
    if tok:
        return {"Authorization": "Bearer " + tok}
    sess = os.environ.get("FLEET_HUB_SESSION") or ""
    if sess:
        return {"Cookie": "ccq_sess=" + sess.strip()}
    die("no credential — set CCQUOTA_VIEWER_TOKEN, or FLEET_HUB_SESSION to your signed-in "
        "browser's ccq_sess cookie (an admin's)", 3)


def call(a, method, path, body=None):
    url = hub_url(a.hub)
    if not url:
        die("no hub configured — pass --hub <url> or set FLEET_HUB_URL", 3)
    hdr = dict(auth_headers(), Accept="application/json")
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        hdr["Content-Type"] = "application/json"
    req = urllib.request.Request(url + path, data=data, method=method, headers=hdr)
    try:
        with urllib.request.urlopen(req, timeout=a.timeout) as r:
            code, raw = r.status, r.read()
    except urllib.error.HTTPError as e:
        code, raw = e.code, e.read()
    except (urllib.error.URLError, OSError, ValueError) as e:
        die("could not reach %s: %s" % (url, e), 3)
    try:
        resp = json.loads(raw.decode() or "{}")
    except ValueError:
        resp = {"error": raw.decode(errors="replace")[:200]}
    if code >= 300:
        why = resp.get("error", resp) if isinstance(resp, dict) else resp
        die("the hub answered %s: %s" % (code, why), 1)
    return resp


# --- settings ------------------------------------------------------------------

def hub_rows(resp):
    return {r["key"]: r for r in resp.get("hub") or [] if isinstance(r, dict) and "key" in r}


def settings_list(a):
    resp = call(a, "GET", SETTINGS_PATH)
    if a.json:
        print(json.dumps(resp, indent=2, ensure_ascii=False))
        return
    rows = hub_rows(resp)
    other = {k: v for k, v in (resp.get("settings") or {}).items()
             if not k.startswith(MIGRATED) and k not in rows}
    w = max([len(k) for k in list(rows) + list(other)] + [3])
    for k in sorted(rows):
        print("%-*s  %-8s %s" % (w, k, rows[k].get("source", ""), rows[k].get("value", "")))
    for k in sorted(other):
        print("%-*s  %-8s %s" % (w, k, "set", other[k]))


def settings_get(a):
    resp = call(a, "GET", SETTINGS_PATH)
    row = hub_rows(resp).get(a.key)
    if row is not None:
        print(row.get("value", ""))
        return
    v = (resp.get("settings") or {}).get(a.key)
    if v is None:
        die("%s is not set" % a.key, 1)
    print(v)


def settings_set(a, value):
    resp = call(a, "PUT", SETTINGS_PATH, {"key": a.key, "value": value})
    if a.json:
        print(json.dumps(resp, indent=2, ensure_ascii=False))
        return
    row = hub_rows(resp).get(a.key)
    now = row.get("value", "") if row is not None else (resp.get("settings") or {}).get(a.key, "")
    print("%s = %s" % (a.key, now if now != "" else "(default)"))


# --- people --------------------------------------------------------------------

def users_print(resp, as_json):
    if as_json:
        print(json.dumps(resp, indent=2, ensure_ascii=False))
        return
    users = resp.get("users") or []
    listed = {u.get("github_id") for u in users}
    fmt = "%-20s %-10s %-15s %-14s %s"
    print(fmt % ("login", "github id", "role", "machine login", "last seen"))
    for u in users:
        role = u.get("role", "") + (" (deploy)" if u.get("deploy") else "")
        print(fmt % (u.get("login", ""), u.get("github_id", ""), role,
                     u.get("machine_login") or "-", (u.get("last_seen") or "never")[:19]))
    for ad in resp.get("admins") or []:
        if ad.get("github_id") not in listed:
            print(fmt % (ad.get("login", ""), ad.get("github_id") or "?", "admin (deploy)", "-",
                         "never" if ad.get("pinned") else "not resolved yet"))


def users_main(a):
    if a.action == "list":
        users_print(call(a, "GET", USERS_PATH), a.json)
        return
    if not a.name:
        die("fleet users %s <GitHub username>" % a.action, 2)
    if a.action == "add":
        body = {"login": a.name}
        if a.machine_login:
            body["machine_login"] = a.machine_login
        resp = call(a, "POST", USERS_PATH, body)
        if not a.json:
            print("%s %s (GitHub ID %s) — they can sign in now" %
                  ("added" if resp.get("created") else "already on the list:", resp.get("added"), resp.get("github_id")))
        users_print(resp, a.json)
    else:
        resp = call(a, "DELETE", USERS_PATH + "?login=" + urllib.parse.quote(a.name))
        if not a.json:
            print("removed %s (GitHub ID %s) — their next request is refused; %s device(s) revoked" %
                  (resp.get("removed"), resp.get("github_id"), resp.get("devices_revoked", 0)))
        users_print(resp, a.json)


def main(argv):
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--hub", help="the hub's URL")
    common.add_argument("--json", action="store_true", help="print the hub's answer as JSON")
    common.add_argument("--timeout", type=float, default=20)
    ap = argparse.ArgumentParser(prog="fleet hub", description=__doc__.split("\n")[0], parents=[common])
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("settings", parents=[common], help="every hub setting")
    g = sub.add_parser("get", parents=[common], help="one setting")
    g.add_argument("key")
    s = sub.add_parser("set", parents=[common], help="change a setting")
    s.add_argument("key")
    s.add_argument("value")
    u = sub.add_parser("unset", parents=[common], help="back to the default")
    u.add_argument("key")
    us = sub.add_parser("users", parents=[common], help="who may sign in with GitHub")
    us.add_argument("action", choices=["list", "add", "remove", "rm"], nargs="?", default="list")
    us.add_argument("name", nargs="?")
    us.add_argument("--machine-login", help="the OS login that is theirs on the machines")
    a = ap.parse_args(argv)
    if a.cmd in (None, "settings"):
        settings_list(a)
    elif a.cmd == "get":
        settings_get(a)
    elif a.cmd == "set":
        settings_set(a, a.value)
    elif a.cmd == "unset":
        settings_set(a, "")
    else:
        if a.action == "rm":
            a.action = "remove"
        users_main(a)


if __name__ == "__main__":
    main(sys.argv[1:])
