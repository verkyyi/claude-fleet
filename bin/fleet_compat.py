"""fleet_compat — the one reader of conf/compat-ours.conf (issue #3577).

A setting the programs used to carry as a built-in default (our relay's
address) now has none. For ONE version, a machine of ours that has not set
the key yet keeps the old value — but only when the hub it is configured for
is one the file names, so a machine pointed at any other hub never gets ours.
compat-1v: 下一批删 (the file and this module together).
"""
import os
from urllib.parse import urlsplit

PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "conf", "compat-ours.conf")


def read(path=None):
    out = {}
    try:
        with open(path or PATH) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


def default(key, hub, path=None):
    """The old built-in value of `key` when `hub` (a URL) is one of ours, else ''."""
    host = (urlsplit(hub or "").hostname or "").lower()
    c = read(path)
    if not host or host not in c.get("FLEET_COMPAT_HUB_HOSTS", "").lower().split():
        return ""
    return c.get(key, "")


def hosts(path=None):
    """Every host the file names — the hubs and the relay's — for a check that
    used to have them built in (fleet-credsep's adopt)."""
    c = read(path)
    out = set(c.get("FLEET_COMPAT_HUB_HOSTS", "").lower().split())
    h = (urlsplit(c.get("FLEET_CRED_RELAY_URL", "")).hostname or "").lower()
    if h:
        out.add(h)
    return sorted(out)
