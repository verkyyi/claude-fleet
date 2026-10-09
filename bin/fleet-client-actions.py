#!/usr/bin/env python3
"""fleet-client-actions.py — open it on the device in the person's hands
(issue #1717, EPIC #1710 C7).

  fleet-client-actions.py send --kind open_url (--url U | --rport P [--path /x]
                               [--scheme http] | --from-addr <fleet-open-addr.py
                               payload>) [--tailnet-link L] [--hub-link L] [--wait S]
  fleet-client-actions.py send --kind show_file --file /abs/path [--inline]
  fleet-client-actions.py send --kind notify [--title T] [--body B]
        a session (on a node) hands one action to its person's CURRENT client,
        through the hub (POST /v1/node/client/actions, this node's token). Prints
        ONE JSON line: {"state": none|queued|done|failed|nohub, "result", "client"}
        — none/nohub: nobody to hand it to, the caller opens it its own way.
        Exit 0 = the hub answered (or nohub); 1 = the hub could not be asked.

  fleet-client-actions.py notify --title T [--body B] [--jump <key>] [--session S]
        THIS device's notification, raised by the client itself (issue #1951,
        EPIC #1949 C2): bin/fleet-alerts.sh fleet_alerts_notify calls it for a
        session that newly waits on you — the title says who, the body what it
        asks. The same `notify` below (iterm2 / notify / a bottom line), plus a
        click that goes there: `--jump` is the list's key (`wid:<worker_id>`).
        terminal-notifier on PATH (notify): its -execute runs the jump. Any other
        notifier (osascript, iTerm2's OSC 9) can only bring the terminal forward,
        so the jump waits as the server's @notify_jump and the client's next
        focus-in (conf/tmux-shell.conf) takes it — within FLEET_NOTIFY_JUMP_SECS
        (60; 0 = never). iterm2 also gets OSC 1337 RequestAttention (the Dock).
        FLEET_NOTIFY=0: nothing. Seam: FLEET_CLIENT_NOTIFY_CMD gets the title and
        body, and the click as FLEET_NOTIFY_CLICK in its environment.
  fleet-client-actions.py jump-pending [--session S]
        the focus-in half: take @notify_jump when it is young enough, and jump.

  fleet-client-actions.py run --session S
        the client's side (bin/fleet-shell.sh starts one per server): long-polls
        the hub for its lease's actions (POST /v1/fleet/client/actions, this
        device's connection certificate) and does each on THIS device:

  open_url   the device can open it (caps open_url — the client runs on the
             device itself): `open` / `xdg-open` — a page on the session's
             machine's loopback (rport) first forwarded over the client's ssh
             master to that machine (the warm one, #1631, else one of its own),
             exactly as fleet-open-addr.py's `forward` asks;
             an iTerm2 at the far end of an ssh (caps iterm2, no open_url): the
             forwarded address goes through fleet-open.sh — iTerm2's escape to
             that terminal, which opens it on the person's computer;
             neither (caps link only — a phone ssh'd into a machine running the
             client): no attempt to open; a line at the bottom of the client
             with a link to tap — the page's tailnet address for a device on
             the tailnet, the hub's for one that is not (via public), the URL
             itself for a page anywhere else — or, with none of those,
             「回到电脑上再看」 and the link kept in links.pending.
  show_file  fetched from that machine (`cat` over the master) — into
             ~/Downloads and opened (show_file); through fleet-show.sh (iterm2,
             --inline kept); else 「回到电脑上再看」 + links.pending.
  notify     iterm2: OSC 9 to the terminal (iTerm2 posts it); notify: the
             system's own (osascript / notify-send); else a line at the bottom.

Nothing runs unless it checks (open.secret's rule, on this road): the payload's
HMAC-SHA256 under THIS lease's action key (handed to this client alone on
acquire / renewal, kept 0600 in FLEET_CLIENT_KEY_FILE), the payload's lease is
this client's current one, its timestamp is within 5 minutes, and its id was
not run before. Anything else is refused and logged, never executed. Every
action gets one line in <cache>/tmp/actions.log: time · id · kind · result.

Seams (tests): FLEET_CLIENT_OPEN_CMD (the opener), FLEET_CLIENT_NOTIFY_CMD,
FLEET_CLIENT_ESCAPE_CMD (writes a raw escape to the client in use),
FLEET_CLIENT_FLEET_OPEN / FLEET_CLIENT_FLEET_SHOW, FLEET_CLIENT_ACTIONS_CONNECT
(opens a master), FLEET_REMOTE_SSH_CMD (the ssh for -O / slaves),
FLEET_CLIENT_ACTIONS_POLL (one poll, instead of the hub), FLEET_CLIENT_DOWNLOADS.
"""
import hashlib
import hmac
import importlib.util
import json
import os
import platform
import shlex
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.realpath(__file__))
BIN = os.path.dirname(os.path.abspath(__file__))
SKEW = 300


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
    if a.kind == "open_url":
        if a.rport:
            body.update(rport=a.rport, path=a.path or "/", scheme=a.scheme or "http")
        else:
            body["url"] = a.url
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


# ---------------------------------------------------------------------------
# run — the client's side
# ---------------------------------------------------------------------------

class Client:
    def __init__(self, session):
        self.sess = session
        self.dir = os.environ.get("FLEET_CLIENT_DIR") or os.environ.get("TMPDIR") or "/tmp"
        self.keyf = os.environ.get("FLEET_CLIENT_KEY_FILE") or os.path.join(self.dir, "client.key")
        self.log = os.path.join(self.dir, "actions.log")
        self.seen = []
        self.fl = None

    # -- state ---------------------------------------------------------------
    def read(self, name):
        try:
            with open(os.path.join(self.dir, name)) as f:
                return f.read().strip()
        except OSError:
            return ""

    def lease(self):
        return self.read("client.lease")

    def where(self):
        try:
            with open(os.path.join(self.dir, "client.where.json")) as f:
                w = json.load(f)
            return w if isinstance(w, dict) else {}
        except (OSError, ValueError):
            return {}

    def note(self, aid, kind, result):
        line = "%s\t%s\t%s\t%s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), aid or "-", kind or "-", result)
        try:
            with open(self.log, "a") as f:
                f.write(line)
        except OSError:
            pass

    def alive(self):
        return subprocess.call(["tmux", "-L", self.sess, "has-session", "-t", "=" + self.sess],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0

    # -- the hub -------------------------------------------------------------
    def poll(self, lease, wait):
        seam = os.environ.get("FLEET_CLIENT_ACTIONS_POLL")
        if seam:
            out = subprocess.run(shlex.split(seam) + [lease], capture_output=True, text=True).stdout
            try:
                return json.loads(out or "{}")
            except ValueError:
                return {}
        return self.hub({"action": "poll", "lease": lease, "wait": wait}, wait + 10)

    def done(self, lease, aid, ok, result):
        if os.environ.get("FLEET_CLIENT_ACTIONS_POLL"):
            return
        self.hub({"action": "done", "lease": lease, "id": aid, "ok": ok, "result": result}, 8)

    def hub(self, body, tmo):
        if self.fl is None:
            self.fl = lease_module()
        fc = self.fl.connect_module()
        conf = fc.load_hub_conf()
        hub = os.environ.get("FLEET_HUB_URL") or fc.machine_conf_hub() or conf.get("url") or ""
        if not hub:
            return {"state": "nohub"}
        token = os.environ.get("FLEET_HUB_TOKEN") or conf.get("token") or ""
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        else:
            try:
                ts = int(time.time())
                cert, sig = fc.ssh_sign("fleet-client %d" % ts, self.fl.NAMESPACE)
            except fc.Refused as e:
                return {"state": "error", "why": str(e)}
            body.update(cert=cert, sig=sig, ts=ts)
        req = urllib.request.Request(hub.rstrip("/") + self.fl.PATH + "/actions", data=json.dumps(body).encode(),
                                     method="POST", headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=tmo) as r:
                return json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            return {"state": "nohub" if e.code == 404 else "error", "why": "HTTP %d" % e.code}
        except (OSError, ValueError) as e:
            return {"state": "error", "why": str(e)}

    # -- the check -----------------------------------------------------------
    def verify(self, sa, lease):
        """The action, or (None, why) — nothing unsigned, foreign or replayed runs."""
        try:
            with open(self.keyf) as f:
                key = f.read().strip()
        except OSError:
            key = ""
        payload, sig = (sa or {}).get("payload"), (sa or {}).get("sig")
        if not isinstance(payload, str) or not isinstance(sig, str) or not sig:
            return None, "refused: unsigned"
        if not key:
            return None, "refused: no action key"
        want = hmac.new(key.encode(), payload.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(want, sig):
            return None, "refused: bad signature"
        try:
            a = json.loads(payload)
        except ValueError:
            return None, "refused: not JSON"
        if not isinstance(a, dict) or a.get("lease") != lease:
            return None, "refused: another lease's"
        if abs(time.time() - float(a.get("ts") or 0)) > SKEW:
            return None, "refused: stale"
        if a.get("id") in self.seen:
            return None, "refused: replayed"
        self.seen = (self.seen + [a.get("id")])[-256:]
        return a, ""

    # -- doing it ------------------------------------------------------------
    def this_machine(self, label):
        me = platform.node().split(".", 1)[0]
        if not label:
            return False
        if label.split(".", 1)[0] == me:
            return True
        return any(x == "%s=%s" % (me, label) for x in (os.environ.get("FLEET_NODE_ALIASES") or "").split())

    def ssh_host(self, label):
        for x in (os.environ.get("FLEET_REMOTE_SSH") or "").split():
            if x.startswith(label + "="):
                return x.split("=", 1)[1]
        return label

    def sshc(self):
        return shlex.split(os.environ.get("FLEET_REMOTE_SSH_CMD") or "ssh")

    def master(self, label):
        """A control socket to that machine: the warm loop's, else one of ours."""
        host = self.ssh_host(label)
        for sock in (os.path.join(self.dir, "warm", label + ".sock"), os.path.join(self.dir, "actions", label + ".sock")):
            if os.path.exists(sock) and subprocess.call(self.sshc() + ["-S", sock, "-O", "check", host],
                                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0:
                return sock
        os.makedirs(os.path.join(self.dir, "actions"), exist_ok=True)
        sock = os.path.join(self.dir, "actions", label + ".sock")
        try:
            os.unlink(sock)
        except OSError:
            pass
        conn = shlex.split(os.environ.get("FLEET_CLIENT_ACTIONS_CONNECT") or "") or ["python3", os.path.join(BIN, "fleet-connect.py")]
        args = [label, "-o", "ControlMaster=yes", "-o", "ControlPath=" + sock, "-o", "ControlPersist=10m",
                "-o", "SessionType=none", "-o", "ForkAfterAuthentication=yes", "-o", "StdinNull=yes",
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
        try:
            subprocess.run(conn + args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=30)
        except (OSError, subprocess.SubprocessError):
            return ""
        return sock if os.path.exists(sock) else ""

    def local_url(self, a):
        """(url, why) — a page this device can reach: as is, or forwarded."""
        if not a.get("rport"):
            return a.get("url") or "", ""
        rport, path = int(a["rport"]), a.get("path") or "/"
        scheme = "https" if a.get("scheme") == "https" else "http"
        if self.this_machine(a.get("machine")):
            return "%s://127.0.0.1:%d%s" % (scheme, rport, path), ""
        sock = self.master(a.get("machine") or "")
        if not sock:
            return "", "no connection to %s" % a.get("machine")
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        lport = s.getsockname()[1]
        s.close()
        if subprocess.call(self.sshc() + ["-S", sock, "-O", "forward", "-L", "127.0.0.1:%d:127.0.0.1:%d" % (lport, rport),
                                          self.ssh_host(a["machine"])],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0:
            return "", "forward to %s:%d failed" % (a.get("machine"), rport)
        return "%s://127.0.0.1:%d%s" % (scheme, lport, path), ""

    def opener(self, target):
        seam = os.environ.get("FLEET_CLIENT_OPEN_CMD")
        cmd = shlex.split(seam) if seam else (["open"] if sys.platform == "darwin" else ["xdg-open"])
        try:
            return subprocess.call(cmd + [target], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0
        except OSError:
            return False

    def shell_env(self):
        """The environment fleet-open / fleet-show need to write to THIS
        server's client in use: $TMUX on our socket, a pane of our session."""
        env = dict(os.environ, FLEET_OPEN_CLIENT="0", FLEET_SHOW_CLIENT="0")
        try:
            sock = subprocess.run(["tmux", "-L", self.sess, "display-message", "-p", "-t", "=" + self.sess,
                                   "#{socket_path}"], capture_output=True, text=True, timeout=5).stdout.strip()
            pane = subprocess.run(["tmux", "-L", self.sess, "list-panes", "-s", "-t", "=" + self.sess, "-F",
                                   "#{pane_id}"], capture_output=True, text=True, timeout=5).stdout.split()
        except (OSError, subprocess.SubprocessError):
            sock, pane = "", []
        if sock:
            env["TMUX"] = "%s,0,0" % sock
        if pane:
            env["TMUX_PANE"] = pane[0]
        return env

    def run_script(self, var, script, args):
        cmd = shlex.split(os.environ.get(var) or "") or ["bash", os.path.join(BIN, script)]
        try:
            r = subprocess.run(cmd + args, env=self.shell_env(), capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.SubprocessError) as e:
            return False, str(e)
        return r.returncode == 0, (r.stdout.strip().splitlines() or [""])[-1]

    def escape(self, data):
        """Write a raw escape to the terminal of the client in use."""
        seam = os.environ.get("FLEET_CLIENT_ESCAPE_CMD")
        cmd = shlex.split(seam) if seam else ["bash", os.path.join(BIN, "fleet-client-escape.sh")]
        try:
            r = subprocess.run(cmd, input=data, env=self.shell_env(), capture_output=True, timeout=20)
        except (OSError, subprocess.SubprocessError):
            return False
        return r.returncode == 0

    def bottom_line(self, text):
        """A line at the bottom of every client of this server (a link to tap)."""
        try:
            names = subprocess.run(["tmux", "-L", self.sess, "list-clients", "-t", "=" + self.sess, "-F",
                                    "#{client_name}"], capture_output=True, text=True, timeout=5).stdout.split()
        except (OSError, subprocess.SubprocessError):
            names = []
        for c in names:
            subprocess.call(["tmux", "-L", self.sess, "display-message", "-c", c, "-d", "30000", "--",
                             text.replace("#", "##")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            with open(os.path.join(self.dir, "links.shown"), "a") as f:
                f.write("%s\t%s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), text))
        except OSError:
            pass
        return True

    def later(self, what, link):
        try:
            with open(os.path.join(self.dir, "links.pending"), "a") as f:
                f.write("%s\t%s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), link or what))
        except OSError:
            pass
        self.bottom_line("%s：回到电脑上再看（已记进待看列表）" % what)
        return True, "later"

    def link_for(self, a, via):
        """The address a device that cannot open anything is given to tap."""
        links = a.get("links") or {}
        if not a.get("rport") and a.get("url"):
            return a["url"], "url"
        if via == "public":
            return (links.get("hub") or "", "hub") if links.get("hub") else ("", "")
        if links.get("tailnet"):
            return links["tailnet"], "tailnet"
        if links.get("hub"):
            return links["hub"], "hub"
        return "", ""

    def tmux(self, *args):
        """A command on THIS server — the one whose list the jump goes to."""
        try:
            return subprocess.run(["tmux", "-L", self.sess, *args], capture_output=True, text=True,
                                  timeout=5).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return ""

    def click(self, key):
        """The argv a notification's click runs: the list's own jump to `key`
        (fleet-quickopen.py jump, the ⌘P road), on this server."""
        sock = self.tmux("display-message", "-p", "#{socket_path}")
        if not key or not sock:
            return []
        return ["env", "TMUX=%s,0,0" % sock, "python3", os.path.join(BIN, "fleet-quickopen.py"), "jump", key]

    def notify_local(self, title, body, key):
        """(ok, result) — a notification raised here, with a click that jumps."""
        w = self.where()
        caps = w.get("caps") or []
        click = self.click(key)
        seam = os.environ.get("FLEET_CLIENT_NOTIFY_CMD")
        tn = shutil.which("terminal-notifier") if not seam and sys.platform == "darwin" else None
        if click and "notify" in caps and tn:
            cmd = [tn, "-title", title, "-message", body or title, "-group", "fleet-" + key,
                   "-activate", "com.googlecode.iterm2", "-execute", shlex.join(click)]
            try:
                ok = subprocess.call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0
            except OSError:
                ok = False
            return (True, "notified") if ok else (False, "the notifier failed")
        # No click of its own: the focus-in the click causes takes the jump — only
        # while the terminal is NOT in front (focus-events: tmux's `focused` flag);
        # in front, the person sees the bar's 「! n 等你」 and nothing is armed.
        away = "focused" not in self.tmux("list-clients", "-F", "#{client_flags}")
        if click and away and ("notify" in caps or "iterm2" in caps):
            self.tmux("set-option", "-g", "@notify_jump", "%d %s" % (time.time(), key))
        if "iterm2" in caps and away:
            self.escape(b"\033]1337;RequestAttention=yes\a")
        if seam and click:
            os.environ["FLEET_NOTIFY_CLICK"] = shlex.join(click)
        return self.do({"kind": "notify", "title": title, "body": body})

    def jump_pending(self):
        """The focus-in half: a click on a notification that could not run one."""
        val = self.tmux("show-options", "-gqv", "@notify_jump")
        if not val:
            return False
        self.tmux("set-option", "-gu", "@notify_jump")
        at, _, key = val.partition(" ")
        try:
            young = time.time() - float(at) <= float(os.environ.get("FLEET_NOTIFY_JUMP_SECS") or 60)
        except ValueError:
            young = False
        if not young or not key:
            return False
        cmd = self.click(key)
        return bool(cmd) and subprocess.call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0

    def do(self, a):
        """(ok, result) — the action done on this device."""
        w = self.where()
        caps, via = w.get("caps") or [], w.get("via") or ""
        kind = a.get("kind")
        if kind == "open_url":
            if "open_url" in caps:
                url, why = self.local_url(a)
                if not url:
                    return False, why
                return (True, "opened") if self.opener(url) else (False, "the opener failed")
            if "iterm2" in caps:
                url, why = self.local_url(a)
                if not url:
                    return False, why
                ok, out = self.run_script("FLEET_CLIENT_FLEET_OPEN", "fleet-open.sh", [url])
                return (ok and out.startswith("sent:iterm2")), "iterm2" if out.startswith("sent:iterm2") else out
            link, src = self.link_for(a, via)
            if not link:
                return self.later("这个网页", "%s:%s%s" % (a.get("machine"), a.get("rport"), a.get("path") or ""))
            self.bottom_line("打开：%s" % link)
            return True, "link:" + src
        if kind == "show_file":
            name = os.path.basename(a.get("name") or a.get("file") or "file")
            if "show_file" not in caps and "iterm2" not in caps:
                return self.later("文件 %s（在 %s 上）" % (name, a.get("machine")), "%s:%s" % (a.get("machine"), a.get("file")))
            if "show_file" in caps:
                dest_dir = os.environ.get("FLEET_CLIENT_DOWNLOADS") or os.path.expanduser("~/Downloads")
            else:
                dest_dir = os.path.join(self.dir, "files")
            path, why = self.fetch(a, dest_dir, name)
            if not path:
                return False, why
            if "show_file" in caps:
                return (True, "opened") if self.opener(path) else (False, "the opener failed")
            args = (["--inline"] if a.get("inline") else []) + ["--", path]
            ok, out = self.run_script("FLEET_CLIENT_FLEET_SHOW", "fleet-show.sh", args)
            return ok, "iterm2" if ok else out
        if kind == "notify":
            title, body = a.get("title") or "fleet", a.get("body") or ""
            if "iterm2" in caps:
                msg = ("%s: %s" % (title, body) if body else title).replace("\a", " ").replace("\033", " ")
                return (True, "iterm2") if self.escape(("\033]9;%s\a" % msg).encode()) else (False, "the escape failed")
            if "notify" in caps:
                seam = os.environ.get("FLEET_CLIENT_NOTIFY_CMD")
                if seam:
                    cmd = shlex.split(seam) + [title, body]
                elif sys.platform == "darwin":
                    cmd = ["osascript", "-e", "on run a\ndisplay notification (item 2 of a) with title (item 1 of a)\nend run",
                           title, body]
                else:
                    cmd = ["notify-send", title, body]
                try:
                    ok = subprocess.call(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0
                except OSError:
                    ok = False
                return (True, "notified") if ok else (False, "the notifier failed")
            self.bottom_line("%s %s" % (title, body))
            return True, "line"
        return False, "unknown kind %s" % kind

    def fetch(self, a, dest_dir, name):
        """(local path, why): the file, from the machine the action came from."""
        src = a.get("file") or ""
        local = self.this_machine(a.get("machine")) and os.path.isfile(src)
        os.makedirs(dest_dir, exist_ok=True)
        base, ext = os.path.splitext(name)
        dest, n = os.path.join(dest_dir, name), 1
        while os.path.exists(dest):
            dest, n = os.path.join(dest_dir, "%s (%d)%s" % (base, n, ext)), n + 1
        if local:
            shutil.copyfile(src, dest)
            return dest, ""
        sock = self.master(a.get("machine") or "")
        if not sock:
            return "", "no connection to %s" % a.get("machine")
        with open(dest + ".part", "wb") as f:
            rc = subprocess.call(self.sshc() + ["-S", sock, self.ssh_host(a["machine"]), "cat -- " + shlex.quote(src)],
                                 stdout=f, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
        if rc != 0:
            os.unlink(dest + ".part")
            return "", "could not fetch %s from %s" % (src, a.get("machine"))
        os.replace(dest + ".part", dest)
        return dest, ""

    def one_round(self, wait):
        lease = self.lease()
        if not lease or os.path.exists(os.path.join(self.dir, "client.standby")):
            return False
        d = self.poll(lease, wait)
        for sa in d.get("actions") or []:
            a, why = self.verify(sa, lease)
            if a is None:
                self.note("", "", why)
                continue
            try:
                ok, result = self.do(a)
            except Exception as e:  # one action never stops the loop
                ok, result = False, "error: %s" % e
            self.note(a.get("id"), a.get("kind"), result)
            self.done(lease, a.get("id"), ok, result)
        return d.get("state") == "active"


def run(a):
    c = Client(a.session)
    pidf = os.path.join(c.dir, "actions.pid")
    if not a.once:
        try:
            p = int(open(pidf).read().strip())
            if p != os.getpid():
                os.kill(p, 0)
                return 0   # one loop per server
        except (OSError, ValueError):
            pass
        with open(pidf, "w") as f:
            f.write("%d\n" % os.getpid())
        # the code this loop started from (issue #2345): `fleet-shell.sh reload`
        # restarts it when the files on disk are no longer that
        try:
            with open(pidf + ".code", "w") as f:
                f.write(os.environ.get("FLEET_ACTIONS_CODE", "") + "\n")
        except OSError:
            pass
    try:
        while True:
            if not a.once and not c.alive():
                return 0
            active = c.one_round(0 if a.once else 25)
            if a.once:
                return 0
            if not active:
                time.sleep(float(os.environ.get("FLEET_CLIENT_ACTIONS_IDLE") or 3))
    finally:
        if not a.once:
            try:
                if int(open(pidf).read().strip()) == os.getpid():
                    os.unlink(pidf)
            except (OSError, ValueError):
                pass


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
    n = sub.add_parser("notify")
    n.add_argument("--title", required=True)
    n.add_argument("--body", default="")
    n.add_argument("--jump", default="")
    n.add_argument("--session", default=os.environ.get("FLEET_SHELL_SESSION") or "fleet-shell")
    j = sub.add_parser("jump-pending")
    j.add_argument("--session", default=os.environ.get("FLEET_SHELL_SESSION") or "fleet-shell")
    r = sub.add_parser("run")
    r.add_argument("--session", default=os.environ.get("FLEET_SHELL_SESSION") or "fleet-shell")
    r.add_argument("--once", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd == "send":
        return send(a)
    if a.cmd == "notify":
        if os.environ.get("FLEET_NOTIFY", "1") == "0":
            return 0
        c = Client(a.session)
        ok, result = c.notify_local(a.title, a.body, a.jump)
        c.note("", "notify-local", result)
        return 0 if ok else 1
    if a.cmd == "jump-pending":
        return 0 if Client(a.session).jump_pending() else 1
    return run(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
