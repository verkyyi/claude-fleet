#!/usr/bin/env python3
"""fleet-client-behind.py <client version> — is the person's client behind? (issue #3826)

A thin client (fleet-thin.py) brings the `version=` of its .client-version as
FLEET_CLIENT_VER to the home's `fleet-remote-view.sh attach --thin`, which asks
this. The hub's GET /version names the client it hands out (client_version —
stable's commit, #1805); a different one prints ONE line for the 看台's top line,
「客户端不是最新（abc1234，最新 def5678）— 在你自己的电脑上运行 fleet update …」,
and nothing otherwise.

Fails quiet: no hub URL, no answer, no client_version, an empty or same version ⇒
nothing printed, exit 0. /version is public — no token. The answer is kept
FLEET_CLIENT_BEHIND_SECS (600) in $FLEET_CONF_DIR/global/hub-version.json.
FLEET_HUB_CLIENT_VERSION is the selftest's seam in place of the hub.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

BIN = Path(__file__).absolute().parent


def hub_url():
    url = os.environ.get("FLEET_HUB_URL") or os.environ.get("CCQUOTA_HUB_URL") or ""
    if url:
        return url
    try:
        p = subprocess.run(["bash", "-c", '. "$1/fleet-lib.sh" >/dev/null 2>&1; _fleet_hub_env; '
                            'printf "%s" "${CCQUOTA_HUB_URL:-${FLEET_HUB_URL:-}}"', "_", str(BIN)],
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    return (p.stdout or "").strip()


def latest():
    """The hub's client_version, "" when unknown."""
    seam = os.environ.get("FLEET_HUB_CLIENT_VERSION")
    if seam is not None:
        return seam
    conf = Path(os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet"))
    kept = conf / "global" / "hub-version.json"
    ttl = float(os.environ.get("FLEET_CLIENT_BEHIND_SECS", "600"))
    try:
        doc = json.loads(kept.read_text(encoding="utf-8"))
        if time.time() - float(doc.get("at", 0)) < ttl:
            return str(doc.get("client_version") or "")
    except (OSError, ValueError, TypeError):
        pass
    url = hub_url()
    if not url:
        return ""
    try:
        with urllib.request.urlopen(url.rstrip("/") + "/version", timeout=3) as r:
            cv = str(json.loads(r.read() or b"{}").get("client_version") or "")
    except (urllib.error.URLError, OSError, ValueError, AttributeError):
        return ""
    try:
        kept.parent.mkdir(parents=True, exist_ok=True)
        tmp = kept.with_name(kept.name + ".%d" % os.getpid())
        tmp.write_text(json.dumps({"at": time.time(), "client_version": cv}), encoding="utf-8")
        os.replace(tmp, kept)
    except OSError:
        pass
    return cv


def main(argv):
    mine = (argv[0] if argv else "").strip()
    if not re.fullmatch(r"[0-9A-Za-z._-]{1,64}", mine):
        return 0
    want = latest()
    if not re.fullmatch(r"[0-9A-Za-z._-]{1,64}", want) or want == mine:
        return 0
    try:
        line = subprocess.run(["sh", str(BIN / "fleet-ui-lang.sh"), "t", "view_client_behind_fmt", mine[:7], want[:7]],
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        line = ""
    if line:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
