#!/usr/bin/env python3
"""fleet hub set|get|unset|settings|users|accounts|invite|machines — the hub's settings, people list, login records, invites and machines (claude-fleet#1986).

    fleet hub settings                   every hub setting: what applies, from where
    fleet hub get <key>                  one setting's value
    fleet hub set <key> <value>          change it — applies at once, audited
    fleet hub unset <key>                back to the default
    fleet users list                     who may sign in with GitHub (= fleet hub users)
    fleet users add <name> [--machine-login <login>]
    fleet users remove <name>
    fleet hub accounts                   every person the hub records and their logins
    fleet hub accounts rekey <from> <to> hand an old identity's logins to <to>
                                         (gh:<id> or a bare GitHub ID); runs nothing
    fleet hub accounts forget <principal> drop a record that never reached a machine
    fleet hub accounts relogin <principal> <machine> <login>
                                         give them a new login there (the old one stays)
    fleet hub accounts rename <principal> <machine>
                                         set the person record's login to their login on
                                         <machine> (after a relogin; no forget + adopt)
    fleet hub invite [<github login>]    an install command that lets one new person in
                                         (7 days, used once; only that GitHub user if named)
    fleet hub invite --list              every invite and its state
    fleet hub invite --revoke <id>       stop an unused one
    fleet hub machines                   every machine: status, sessions, load, and its logins:
                                         备用 N · 已用 M / 上限 K (fleet.spares, claude-fleet#2263)

Keys: hub.public_meter hub.public_badges pool.skip_pct pool.move_when_full
fleet.auto_assign fleet.spot fleet.routes_extra fleet.machine_names fleet.spares fleet.spare_max
fleet.node_user_cap.<machine> user.<id>.machine_login (and the fleet.* keys PUT /v1/fleet/settings already took).

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
ACCOUNTS_PATH = "/v1/fleet/accounts"
INVITES_PATH = "/v1/fleet/invites"
NODES_PATH = "/v1/nodes"
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
            moved = resp.get("moved_login")
            if isinstance(moved, dict):
                # The login was the hub's under an identity from before GitHub
                # sign-in (claude-fleet#2094).
                print(moved_line(moved, resp.get("added")))
            if not a.machine_login:
                # #2090: signed in, but `fleet login` cannot sign a certificate for them yet
                sys.stderr.write("warning: no --machine-login — %s can open the hub but cannot connect to a machine yet"
                                 " (unless fleet.auto_assign opens one); set it with: fleet users add %s --machine-login <login>\n"
                                 % (a.name, a.name))
        users_print(resp, a.json)
    else:
        resp = call(a, "DELETE", USERS_PATH + "?login=" + urllib.parse.quote(a.name))
        if not a.json:
            print("removed %s (GitHub ID %s) — their next request is refused; %s device(s) revoked" %
                  (resp.get("removed"), resp.get("github_id"), resp.get("devices_revoked", 0)))
        users_print(resp, a.json)


def moved_line(m, to_name=None):
    hosts = "、".join(m.get("hosts") or []) or "无机器"
    return "已把 %s（%s）从旧身份 %s 转给 %s" % (m.get("login"), hosts, m.get("from"), to_name or m.get("to"))


# --- invites (claude-fleet#2261) ------------------------------------------------

def invite_main(a):
    if a.list:
        resp = call(a, "GET", INVITES_PATH)
        if a.json:
            print(json.dumps(resp, indent=2, ensure_ascii=False))
            return
        fmt = "%-14s %-9s %-16s %-20s %s"
        print(fmt % ("id", "state", "for", "expires", "made by / used by"))
        for i in resp.get("invites") or []:
            who = i.get("created_by", "") + (" → " + i["used_by"] if i.get("used_by") else "")
            print(fmt % (i.get("id", ""), i.get("state", ""), i.get("github_login") or "anyone",
                         (i.get("expires_at") or "")[:19], who))
        return
    if a.revoke:
        resp = call(a, "DELETE", INVITES_PATH + "?id=" + urllib.parse.quote(a.revoke))
        print(json.dumps(resp, indent=2, ensure_ascii=False) if a.json else "revoked %s" % resp.get("id"))
        return
    body = {}
    if a.login:
        body["github_login"] = a.login.lstrip("@")
    resp = call(a, "POST", INVITES_PATH, body)
    if a.json:
        print(json.dumps(resp, indent=2, ensure_ascii=False))
        return
    # The code is in this answer and nowhere else: print it once, to the
    # admin's own terminal, for them to send.
    who = "GitHub 用户 %s" % resp["github_login"] if resp.get("github_login") else "一位新同事"
    print("把这一行发给%s（%s 前有效，用一次即失效）：\n\n  %s\n" % (who, (resp.get("expires_at") or "")[:10], resp.get("command", "")))
    print("撤销：fleet hub invite --revoke %s" % resp.get("id", ""))


# --- machines (claude-fleet#2263) ----------------------------------------------

def machines_main(a):
    resp = call(a, "GET", NODES_PATH)
    if a.json:
        print(json.dumps(resp, indent=2, ensure_ascii=False))
        return
    rows = resp.get("machines") or []
    spares_on = any(m.get("spare") is not None for m in rows)
    # the logins under each machine (claude-fleet#2333); the machine link is no login
    logins = {}
    for n in resp.get("nodes") or []:
        if not n.get("machine_link") and n.get("os_user"):
            logins.setdefault(n.get("hostname", ""), set()).add(n["os_user"])
    fmt = "%-22s %-12s %-9s %-10s %-6s %s"
    print(fmt % ("machine", "status", "sessions", "load/core", "连接", "账号"))
    for m in rows:
        name = m.get("hostname", "")
        if m.get("alias"):
            name = "%s (%s)" % (m["alias"], name)
        load = "-"
        if m.get("ncpu"):
            load = "%.2f" % (float(m.get("load1") or 0) / m["ncpu"])
        sess = m.get("sessions")
        spare = m.get("spare")
        acct = "、".join(sorted(logins.get(m.get("hostname", ""), ()))) or "-"
        if spare is not None:
            acct += " · 备用 %d · 已用 %s / 上限 %s" % (spare, m.get("logins_used", "?"), m.get("login_cap", "?"))
        links = m.get("links")
        print(fmt % (name, m.get("status", ""), "?" if sess is None else sess, load,
                     "-" if links is None else links, acct))
    if not spares_on:
        print("\n备用账号没开（fleet hub set fleet.spares on 打开；每个备用都是那台电脑上的一个 macOS 账号）")


# --- login records -------------------------------------------------------------

def accounts_main(a):
    if a.action == "list":
        resp = call(a, "GET", ACCOUNTS_PATH)
        if a.json:
            print(json.dumps(resp, indent=2, ensure_ascii=False))
            return
        by = {}
        for ac in resp.get("accounts") or []:
            by.setdefault(ac.get("principal_id"), []).append("%s:%s" % (ac.get("hostname"), ac.get("state")))
        fmt = "%-24s %-16s %-16s %s"
        print(fmt % ("principal", "login", "name", "machines"))
        for p in resp.get("principals") or []:
            pid = p.get("principal_id", "")
            print(fmt % (pid, p.get("login", ""), p.get("display_name", "") or "-", " ".join(by.get(pid, [])) or "-"))
        spares = resp.get("spares") or []
        if spares:
            # opened ahead of a newcomer (claude-fleet#2263); `forget` takes the principal
            print("\nspare logins (备用):")
            for ac in spares:
                print(fmt % (ac.get("principal_id", ""), ac.get("login", ""), "-",
                             "%s:%s" % (ac.get("hostname"), ac.get("state"))))
        return
    if a.action == "rekey":
        if not a.principal or not a.to:
            die("fleet hub accounts rekey <from principal> <to: gh:<id> | GitHub ID>", 2)
        resp = call(a, "POST", ACCOUNTS_PATH, {"action": "rekey", "principal_id": a.principal, "to_principal_id": a.to})
        if a.json:
            print(json.dumps(resp, indent=2, ensure_ascii=False))
        else:
            print(moved_line(resp))
        return
    if a.action == "relogin":
        if not a.principal or not a.to or not a.login:
            die("fleet hub accounts relogin <principal> <machine> <login>", 2)
        resp = call(a, "POST", ACCOUNTS_PATH, {"action": "relogin", "principal_id": a.principal,
                                               "hostname": a.to, "login": a.login})
        if a.json:
            print(json.dumps(resp, indent=2, ensure_ascii=False))
        else:
            print("relogin %s on %s → %s: create queued (the old login is left as is; undo: adopt it back)"
                  % (a.principal, a.to, a.login))
        return
    if a.action == "rename":
        if not a.principal or not a.to:
            die("fleet hub accounts rename <principal> <machine>", 2)
        resp = call(a, "POST", ACCOUNTS_PATH, {"action": "rename", "principal_id": a.principal, "hostname": a.to})
        if a.json:
            print(json.dumps(resp, indent=2, ensure_ascii=False))
        elif resp.get("changed"):
            print("rename %s: login %s → %s (as on %s)" % (a.principal, resp.get("from", ""), resp.get("login", ""), a.to))
        else:
            print("rename %s: login already %s (as on %s) — nothing changed" % (a.principal, resp.get("login", ""), a.to))
        return
    if not a.principal:
        die("fleet hub accounts forget <principal> [--host <machine>]", 2)
    body = {"action": "forget", "principal_id": a.principal}
    if a.host:
        body["hostname"] = a.host
    resp = call(a, "POST", ACCOUNTS_PATH, body)
    if a.json:
        print(json.dumps(resp, indent=2, ensure_ascii=False))
    else:
        print("forgot %s%s" % (a.principal, " on " + a.host if a.host else ""))


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
    ac = sub.add_parser("accounts", parents=[common], help="the people the hub records and their logins")
    ac.add_argument("action", choices=["list", "rekey", "forget", "relogin", "rename"], nargs="?", default="list")
    ac.add_argument("principal", nargs="?")
    ac.add_argument("to", nargs="?", help="rekey: the new id · relogin / rename: the machine")
    ac.add_argument("login", nargs="?", help="relogin: the new login")
    ac.add_argument("--host", help="forget: only the record on this machine")
    iv = sub.add_parser("invite", parents=[common], help="an install command that lets one new person in")
    iv.add_argument("login", nargs="?", help="only this GitHub user may use it")
    iv.add_argument("--list", action="store_true", help="every invite and its state")
    iv.add_argument("--revoke", metavar="ID", help="stop an unused invite")
    sub.add_parser("machines", parents=[common], help="every machine, with its spare logins")
    a = ap.parse_args(argv)
    if a.cmd in (None, "settings"):
        settings_list(a)
    elif a.cmd == "get":
        settings_get(a)
    elif a.cmd == "set":
        settings_set(a, a.value)
    elif a.cmd == "unset":
        settings_set(a, "")
    elif a.cmd == "accounts":
        accounts_main(a)
    elif a.cmd == "invite":
        invite_main(a)
    elif a.cmd == "machines":
        machines_main(a)
    else:
        if a.action == "rm":
            a.action = "remove"
        users_main(a)


if __name__ == "__main__":
    main(sys.argv[1:])
