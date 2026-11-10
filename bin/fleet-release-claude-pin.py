#!/usr/bin/env python3
"""fleet-release-claude-pin.py — keep release.json's Claude Code pin current by itself
(operator, 2026-11-10; the hand bumps it replaces: #5607 → 2.1.318, #5619 → 2.1.322).

`.github/workflows/claude-pin.yml` runs this once a day:

    plan [--release release.json] [--soak-hours 24] [--allow-major]
         [--open-pr <ver>] [--npm URL] [--mirror URL] [--hub URL] [--now EPOCH]

reads the pin (`components.claude.version`), npm's `latest` dist-tag and every
version's publish time for @anthropic-ai/claude-code, and picks the TARGET: the
highest X.Y.Z with  pin < X.Y.Z <= latest  that is

  - in the same major as the pin (--allow-major lifts it — the operator's opt-in),
  - published at least --soak-hours ago (24) — a release a day is normal, so the
    newest is often still soaking and the one before it is the target,
  - not deprecated, and
  - whole: @anthropic-ai/claude-code-{darwin-arm64,linux-x64,linux-arm64}@X.Y.Z on
    registry.npmjs.org AND registry.npmmirror.com (the hub's two registries,
    CCQUOTA_FLEET_RELEASE_NPM), and — when the hub answers — every
    claude-X.Y.Z-{darwin-arm64,linux-amd64,linux-arm64} its
    /v1/fleet/release/artifacts?want= says it carries or would fetch. An
    unreachable hub is a note, not a stop: the train's own gate
    (`fleet-stable.sh move`, gate 7 — BREAK-IT release-artifact-missing) asks it
    again before stable moves.

Never a downgrade, never the pin itself. Prints key=value lines (also appended to
$GITHUB_OUTPUT when set):

    action=current|soak|hold|blocked|bump   reason=<one line>
        (soak = the newest above the pin is younger than the soak; hold = a major
        without the opt-in, or deprecated; blocked = old enough but not whole)
    current=<pin> latest=<npm latest> target=<ver or empty>
    pr_action=none|open|update|keep|close   (with --open-pr <the open PR's version>)

    bump --to <ver> [--release release.json] [--doc docs/dev/MANAGED-NODE.md]
        rewrites the pin in release.json and the §7 example (exactly one line each,
        refuses a non-increase); prints the old version.
    changelog --from <old> --to <new> [--file CHANGELOG.md | --url URL] [--max-chars N]
        the CHANGELOG.md sections with old < version <= new, newest first.

Exit 0 (any verdict) · 2 usage / unreadable pin / npm unreachable.
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

PKG = "@anthropic-ai/claude-code"
NPM = "https://registry.npmjs.org"
MIRROR = "https://registry.npmmirror.com"
CHANGELOG_URL = "https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md"  # dist-ok: Anthropic's changelog for the PR body, not the fleet's code
# the fleet's platforms (fleet-node-update.py pinned-artifacts) → npm's package suffix
PLATFORMS = (("darwin-arm64", "darwin-arm64"), ("linux-amd64", "linux-x64"), ("linux-arm64", "linux-arm64"))
VER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
PIN_RE = re.compile(r'("claude":\s*\{"version":\s*")([^"]+)(")')
UA = "claude-fleet-claude-pin"


def die(msg, code=2):
    sys.stderr.write("fleet-release-claude-pin: %s\n" % msg)
    sys.exit(code)


def ver(s):
    """(major, minor, patch) for a plain X.Y.Z, else None (a prerelease is never a target)."""
    m = VER_RE.match(s or "")
    return tuple(int(x) for x in m.groups()) if m else None


def fetch(url, timeout=20):
    """(status, body bytes); status 0 = unreachable. A seam: the selftest swaps it."""
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, b""
    except (urllib.error.URLError, OSError, ValueError):
        return 0, b""


def fetch_json(url):
    st, body = fetch(url)
    if st != 200:
        return st, None
    try:
        return st, json.loads(body)
    except ValueError:
        return st, None


def iso_epoch(s):
    """npm's `time` value ("2026-11-10T01:58:41.811Z") → epoch seconds, else None."""
    try:
        return time.mktime(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone
    except (TypeError, ValueError):
        return None


def read_pin(path):
    try:
        with open(path) as f:
            v = json.load(f)["components"]["claude"]["version"]
    except (OSError, ValueError, KeyError, TypeError) as e:
        die("%s: no components.claude.version (%s)" % (path, e))
    if not ver(v):
        die("%s: the pin %r is not X.Y.Z" % (path, v))
    return v


def candidates(doc, current, now, soak_secs, allow_major):
    """From the registry document: (latest, [(ver, why-not-or-None), …] newest first)
    of every version above the pin and at most `latest` — why-not names a soak, a
    major or a deprecation; None = a target if its packages are whole."""
    latest = ((doc.get("dist-tags") or {}).get("latest")) or ""
    lv, cv = ver(latest), ver(current)
    out = []
    if not lv:
        return latest, out
    times, versions = doc.get("time") or {}, doc.get("versions") or {}
    for v in sorted((v for v in versions if ver(v)), key=ver, reverse=True):
        t = ver(v)
        if not (cv < t <= lv):
            continue
        meta = versions.get(v) or {}
        pub = iso_epoch(times.get(v))
        if t[0] != cv[0] and not allow_major:
            why = "major %d → %d needs the operator's opt-in" % (cv[0], t[0])
        elif meta.get("deprecated"):
            why = "deprecated on npm"
        elif pub is None:
            why = "no publish time on npm"
        elif now - pub < soak_secs:
            why = "soaking: published %.1f h ago, needs %.0f h" % ((now - pub) / 3600.0, soak_secs / 3600.0)
        else:
            why = None
        out.append((v, why))
    return latest, out


def whole(v, npm, mirror, hub):
    """(ok, problems, notes): every platform package on both registries, and the hub's word."""
    problems, notes = [], []
    for reg in (npm, mirror):
        if not reg:
            continue
        for _, suffix in PLATFORMS:
            st, d = fetch_json("%s/%s-%s/%s" % (reg, PKG, suffix, v))
            if st != 200 or not isinstance(d, dict) or not (d.get("dist") or {}).get("integrity"):
                problems.append("%s-%s@%s missing on %s (%s)" % (PKG.split("/")[1], suffix, v, reg.split("//")[-1], st or "unreachable"))
    if hub:
        want = ["claude-%s-%s" % (v, p) for p, _ in PLATFORMS]
        st, d = fetch_json("%s/v1/fleet/release/artifacts?want=%s" % (hub.rstrip("/"), ",".join(want)))
        if st != 200 or not isinstance(d, dict):
            notes.append("hub artifacts unreadable (%s) — the train's gate asks it again" % (st or "unreachable"))
        else:
            have = set(d.get("artifacts") or []) | set(d.get("fetchable") or [])
            gone = [n for n in want if n not in have]
            if gone:
                problems.append("the hub can neither serve nor fetch " + ", ".join(gone))
            else:
                notes.append("hub: all three carried or fetchable")
    return not problems, problems, notes


def pr_action(action, target, current, latest, open_pr):
    """What to do with the ONE bump PR (head branch claude-pin)."""
    if not open_pr:
        return "open" if action == "bump" else "none"
    p = ver(open_pr)
    if not p or p <= ver(current):
        return "close"  # the pin is already there (a hand bump, or this PR's twin merged)
    if action == "bump":
        return "keep" if open_pr == target else "update"
    if ver(latest) and p > ver(latest):
        return "close"  # npm's latest went back below it: a pulled release
    return "keep"


def plan(o):
    current = read_pin(o.get("release") or "release.json")
    soak = float(o.get("soak-hours") or 24) * 3600
    now = float(o.get("now") or time.time())
    npm, mirror = o.get("npm", NPM), o.get("mirror", MIRROR)
    st, doc = fetch_json("%s/%s" % (npm, PKG))
    if st != 200 or not isinstance(doc, dict):
        die("npm %s/%s unreadable (%s)" % (npm, PKG, st or "unreachable"))
    latest, cands = candidates(doc, current, now, soak, "allow-major" in o)
    target, notes, action, reason = "", [], "", ""
    if not ver(latest):
        action, reason = "blocked", "npm latest %r is not X.Y.Z" % latest
    elif not cands:
        action, reason = "current", "already current (%s)" % current
    else:
        blocked = []
        for v, why in cands:
            if why:
                continue
            ok, problems, n = whole(v, npm, mirror, o.get("hub", ""))
            if ok:
                target, notes = v, n
                break
            blocked.append("%s: %s" % (v, "; ".join(problems)))
        if target:
            action, reason = "bump", "%s → %s (npm latest %s)" % (current, target, latest)
            if blocked:
                reason += "; newer not whole yet — " + " | ".join(blocked)
        elif blocked:
            action, reason = "blocked", " | ".join(blocked)
        else:
            top = cands[0]
            action = "soak" if top[1].startswith("soaking") else "hold"
            reason = "%s: %s; pin stays %s" % (top[0], top[1], current)
    lines = [("action", action), ("reason", reason), ("current", current), ("latest", latest),
             ("target", target), ("pr_action", pr_action(action, target, current, latest, o.get("open-pr", ""))),
             ("notes", "; ".join(notes))]
    out = "".join("%s=%s\n" % (k, v.replace("\n", " ")) for k, v in lines)
    sys.stdout.write(out)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(out)


def bump(o):
    to = o.get("to") or die("bump needs --to <ver>")
    if not ver(to):
        die("--to %r is not X.Y.Z" % to)
    rel, doc = o.get("release") or "release.json", o.get("doc") or "docs/dev/MANAGED-NODE.md"
    old = read_pin(rel)
    if ver(to) <= ver(old):
        die("refusing %s → %s: never a downgrade or a no-op" % (old, to))
    for path in (rel, doc):
        with open(path) as f:
            text = f.read()
        new, n = PIN_RE.subn(lambda m: m.group(1) + to + m.group(3), text)
        if n != 1:
            die("%s: %d claude pin lines, want exactly 1" % (path, n))
        with open(path, "w") as f:
            f.write(new)
    if read_pin(rel) != to:
        die("%s does not read %s after the edit" % (rel, to))
    print(old)


def changelog(o):
    lo, hi = ver(o.get("from")), ver(o.get("to"))
    if not lo or not hi:
        die("changelog needs --from and --to as X.Y.Z")
    if o.get("file"):
        with open(o["file"]) as f:
            text = f.read()
    else:
        st, body = fetch(o.get("url") or CHANGELOG_URL)
        if st != 200:
            print("_(CHANGELOG.md unreadable: %s — see %s)_" % (st or "unreachable", CHANGELOG_URL))
            return
        text = body.decode("utf-8", "replace")
    keep, out = False, []
    for line in text.splitlines():
        m = re.match(r"^##\s+(\S+)", line)
        if m:
            v = ver(m.group(1))
            keep = bool(v) and lo < v <= hi
            if keep:
                out.append("### " + m.group(1))
            continue
        if keep and line.strip():
            out.append(line)
    res = "\n".join(out) if out else "_(no CHANGELOG.md section for %s..%s)_" % (o["from"], o["to"])
    cap = int(o.get("max-chars") or 40000)
    if len(res) > cap:
        res = res[:cap].rsplit("\n", 1)[0] + "\n\n_(cut at %d characters — the rest: %s)_" % (cap, CHANGELOG_URL)
    print(res)


def opts(args, flags=("allow-major",)):
    o, i = {}, 0
    while i < len(args):
        a = args[i]
        if not a.startswith("--"):
            die("unexpected %r" % a)
        k = a[2:]
        if k in flags:
            o[k] = "1"
            i += 1
            continue
        if i + 1 >= len(args):
            die("%s needs a value" % a)
        o[k] = args[i + 1]
        i += 2
    return o


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        return 0
    cmd, o = argv[0], opts(argv[1:])
    if cmd == "plan":
        plan(o)
    elif cmd == "bump":
        bump(o)
    elif cmd == "changelog":
        changelog(o)
    else:
        die("unknown command %r (plan | bump | changelog)" % cmd)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
