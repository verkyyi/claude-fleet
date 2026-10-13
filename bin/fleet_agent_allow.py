#!/usr/bin/env python3
"""fleet_agent_allow.py — which coding agents this login may START (issue #3826).

The hub's subscription allowlists (fleet.cred_allow.node.<machine> ·
fleet.cred_allow.user.<principal>, tokenledger fleet_cred_policy.go) can leave
nothing for an agent — a person whose list names only a Codex account. The
new-session pickers (⌘P's ⚡ row and the ⌘T popup through fleet-quick-dispatch.py,
⌘N through fleet_view.go_new) ask here and show that agent grey with
「管理员暂未开放」, never offer a session that cannot start, never hide the choice.

    fleet_agent_allow.py blocked      the blocked agents, one per line (exit 0)

blocked() is {agent: reason} off GET /v1/node/agents with this login's node token,
kept FLEET_AGENT_ALLOW_SECS (60) in $FLEET_CONF_DIR/global/agent-allow.json. It
fails OPEN: no hub, no token, an older hub (404), a timeout ⇒ {} — the pickers are
then exactly what they were. FLEET_AGENTS_BLOCKED (a comma list) is the selftest's
seam in place of the hub.
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

BIN = Path(__file__).absolute().parent
AGENTS = ("claude", "codex")


def conf_dir():
    return Path(os.environ.get("FLEET_CONF_DIR") or os.path.expanduser("~/.config/claude-fleet"))


def hub_creds():
    url, tok = os.environ.get("CCQUOTA_HUB_URL", ""), os.environ.get("CCQUOTA_TOKEN", "")
    if url and tok:
        return url, tok
    try:
        p = subprocess.run(["bash", "-c", '. "$1/fleet-lib.sh" >/dev/null 2>&1; _fleet_hub_env; '
                            'printf "%s\\t%s" "${CCQUOTA_HUB_URL:-}" "${CCQUOTA_TOKEN:-}"', "_", str(BIN)],
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return "", ""
    u, _, t = (p.stdout or "").partition("\t")
    return url or u, tok or t


def ask_hub():
    """{agent: reason} the hub says are blocked; None when it could not be asked."""
    url, tok = hub_creds()
    if not url or not tok:
        return None
    req = urllib.request.Request(url.rstrip("/") + "/v1/node/agents")
    req.add_header("Authorization", "Bearer " + tok)
    try:
        with urllib.request.urlopen(req, timeout=float(os.environ.get("FLEET_AGENT_ALLOW_TIMEOUT", "3"))) as r:
            doc = json.loads(r.read() or b"{}")
    except (urllib.error.URLError, OSError, ValueError):
        return None
    return {a.get("agent"): a.get("reason") or "policy" for a in doc.get("agents") or []
            if isinstance(a, dict) and a.get("blocked") and a.get("agent") in AGENTS}


def blocked():
    """{agent: reason} of the agents the allowlists leave nothing for; {} = none
    (or unknown — never hide what could not be checked)."""
    seam = os.environ.get("FLEET_AGENTS_BLOCKED")
    if seam is not None:
        return {a: "policy" for a in seam.split(",") if a in AGENTS}
    kept = conf_dir() / "global" / "agent-allow.json"
    ttl = float(os.environ.get("FLEET_AGENT_ALLOW_SECS", "60"))
    try:
        doc = json.loads(kept.read_text(encoding="utf-8"))
        if time.time() - float(doc.get("at", 0)) < ttl and isinstance(doc.get("blocked"), dict):
            return doc["blocked"]
    except (OSError, ValueError, TypeError):
        pass
    got = ask_hub()
    if got is None:
        return {}
    try:
        kept.parent.mkdir(parents=True, exist_ok=True)
        tmp = kept.with_name(kept.name + ".%d" % os.getpid())
        tmp.write_text(json.dumps({"at": time.time(), "blocked": got}), encoding="utf-8")
        os.replace(tmp, kept)
    except OSError:
        pass
    return got


def main(argv):
    if argv[:1] == ["blocked"]:
        for a in blocked():
            print(a)
        return 0
    print(__doc__.strip().splitlines()[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
