#!/usr/bin/env python3
"""fleet_gh_issues.py — a repo's open issues, kept up to date by increments (issue #3529).

The collector's backlog cache was one GraphQL issue listing (300 issues) per repo per TTL
(GraphQL, the whole list every time). With FLEET_GH_SHARE=1 it asks REST for what
CHANGED instead:

    GET repos/<r>/issues?state=all&since=<newest updated_at seen>   + If-None-Match

A 304 (nothing changed) costs no rate-limit budget and writes nothing but the
state's clock; a 200 upserts the open issues it names and drops the closed ones.
Pull requests (the issues API lists them too) are skipped. With no state, or a
full pass older than FLEET_GH_ISSUES_FULL_SECS (6 h — a deleted or transferred
issue never shows up in a `since` listing), it lists every open issue.

It writes, in <dir>, the same two caches the GraphQL listing fed (tmux-dash-collect.sh):
    issues   milestone<TAB>#num<TAB>assignees(≤10 chars|·)<TAB>title
    labels   num<TAB>labels(comma-joined)
newest 300 by number, the shape and order the collector's jq made — and its own
state, issues.json, which is published with them so whichever login fetches next
continues from the same watermark.

Usage: fleet_gh_issues.py sync --repo OWNER/NAME --dir DIR
Exit:  0 changed (caches rewritten) · 3 not modified · 1 failure (caller falls back)
Env:   FLEET_GH_ISSUES_GH (the gh binary; selftest seam) · FLEET_GH_ISSUES_FULL_SECS
"""
import json
import os
import re
import subprocess
import sys
import time

LIMIT = 300
STATE = "issues.json"


def gh_get(url, etag=None):
    """→ (status, headers{lower: value}, body text); status 0 = gh could not run."""
    argv = [os.environ.get("FLEET_GH_ISSUES_GH") or "gh", "api", "-i",
            "-H", "Accept: application/vnd.github+json"]
    if etag:
        argv += ["-H", "If-None-Match: " + etag]
    argv.append(url)
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return 0, {}, ""
    out = p.stdout.decode("utf-8", "replace").replace("\r\n", "\n")
    head, _, body = out.partition("\n\n")
    lines = head.split("\n")
    m = re.match(r"HTTP/\S+\s+(\d+)", lines[0] if lines else "")
    if not m:
        return 0, {}, ""
    hdrs = {}
    for ln in lines[1:]:
        k, sep, v = ln.partition(":")
        if sep:
            hdrs[k.strip().lower()] = v.strip()
    return int(m.group(1)), hdrs, body


def next_url(hdrs):
    for part in hdrs.get("link", "").split(","):
        m = re.match(r'\s*<([^>]+)>;\s*rel="next"', part)
        if m:
            u = m.group(1)
            return u.split("api.github.com/", 1)[-1]  # dist-ok: a REST page link gh hands back, not the fleet's code
    return None


def row(it):
    labels = ",".join(l.get("name", "") for l in it.get("labels") or [])
    ms = (it.get("milestone") or {}).get("title") or "· no milestone"
    who = ",".join(a.get("login", "") for a in it.get("assignees") or [])[:10] or "·"
    title = (it.get("title") or "").replace("\t", " ").replace("\n", " ")
    return [labels, ms, who, title]


def listing(url, etag=None):
    """→ (status, first page etag, items) over every page; status 304 = not modified."""
    st, hdrs, body = gh_get(url, etag)
    if st == 304:
        return 304, etag, []
    if st != 200:
        return st or 1, None, []
    first = hdrs.get("etag")
    items = []
    while True:
        try:
            page = json.loads(body)
        except ValueError:
            return 1, None, []
        if not isinstance(page, list):
            return 1, None, []
        items += page
        url = next_url(hdrs)
        if not url:
            return 200, first, items
        st, hdrs, body = gh_get(url)
        if st != 200:
            return st or 1, None, []


def newest(items, since):
    for it in items:
        u = it.get("updated_at") or ""
        if u > (since or ""):
            since = u
    return since


def write(d, name, text):
    tmp = os.path.join(d, ".%s.%d" % (name, os.getpid()))
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, os.path.join(d, name))


def sync(repo, d):
    now = int(time.time())
    try:
        full_secs = int(os.environ.get("FLEET_GH_ISSUES_FULL_SECS") or 21600)
    except ValueError:
        full_secs = 21600
    try:
        with open(os.path.join(d, STATE), encoding="utf-8") as f:
            st = json.load(f)
        if st.get("repo") != repo or not isinstance(st.get("open"), dict):
            st = None
    except (OSError, ValueError):
        st = None
    if st is None or now - int(st.get("full", 0)) >= full_secs:
        code, _, items = listing("repos/%s/issues?state=open&per_page=100" % repo)
        if code != 200:
            return 1
        st = {"repo": repo, "full": now, "since": newest(items, ""), "etag": None,
              "open": {str(i["number"]): row(i) for i in items if "pull_request" not in i}}
    else:
        since = st.get("since") or ""
        url = "repos/%s/issues?state=all&per_page=100" % repo + ("&since=" + since if since else "")
        code, etag, items = listing(url, st.get("etag"))
        if code == 304:
            return 3
        if code != 200:
            return 1
        for it in items:
            if "pull_request" in it:
                continue
            k = str(it["number"])
            if it.get("state") == "open":
                st["open"][k] = row(it)
            else:
                st["open"].pop(k, None)
        st["since"] = newest(items, since)
        # the etag answers THIS url; a moved watermark is a new url — one more 200
        # there, then 304s
        st["etag"] = etag if st["since"] == since else None
    nums = sorted(st["open"], key=int, reverse=True)[:LIMIT]
    issues = "".join("%s\t#%s\t%s\t%s\n" % (st["open"][n][1], n, st["open"][n][2], st["open"][n][3]) for n in nums)
    labels = "".join("%s\t%s\n" % (n, st["open"][n][0]) for n in nums)
    os.makedirs(d, exist_ok=True)
    write(d, "issues", issues)
    write(d, "labels", labels)
    write(d, STATE, json.dumps(st, ensure_ascii=False, sort_keys=True))
    return 0


def main(argv):
    if len(argv) != 5 or argv[0] != "sync" or argv[1] != "--repo" or argv[3] != "--dir":
        sys.stderr.write("usage: fleet_gh_issues.py sync --repo OWNER/NAME --dir DIR\n")
        return 2
    return sync(argv[2], argv[4])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
