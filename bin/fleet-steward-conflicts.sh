#!/bin/bash
# fleet-steward-conflicts.sh — what the steward should TELL you before two
# batches collide (issue #2673, EPIC #2668 C5). A pure probe: it reads, prints and
# changes nothing — never autofill, the caps or dispatch. «只报不限»: the steward
# renders its answer as `kind=normal` rows of the decision list (C1's format);
# how many batches run at once is never limited here.
#
# Three readings, each on its own:
#   ① overlaps — every OPEN PR of every hosted repo (the pr-refresh cache
#      `prmap_<slug>`; no cache ⇒ one REST `/pulls?state=open`), its changed files
#      (our own cache `prfiles.json` beside it; a PR missing there, or older than
#      FLEET_STEWARD_FILES_TTL, is refilled by REST `/pulls/N/files` — at most
#      FLEET_STEWARD_FILES_BUDGET (10) PRs a run, missing ones first, then the
#      oldest), grouped by batch: a PR's batch is its issue's EPIC parent (branch
#      `issue-<N>` → the collector's `parents` cache), a PR with none is a batch of
#      its own. A (repo, path) touched by PRs of TWO OR MORE batches is one overlap;
#      two PRs of the same batch touching one file is the driver's business, never
#      reported. `first` = the lowest PR number (opened first — the default advice
#      is «先合较早开的那个»).
#   ② ci — REST `/actions/runs?status=queued` per repo: how many runs wait and
#      how long the oldest has (`null` when no repo answered). A run queued longer
#      than FLEET_STEWARD_CI_STUCK (86400 s) is one GitHub never started — counted
#      as `stuck`, kept out of `queued` and `oldest_secs`.
#   ③ quota — `fleet-quotawatch.sh --status` + the pool's cached rows
#      (`account.quota`: label 5h% 7d% headroom% …). `pct` = the best account's
#      headroom %. A watch that reads nothing (never / stale / blind, or fresh with
#      no rows) is `state: blind`, pct null — «额度读不到», never «额度充足»
#      (#2588 / #2630 fix the empty read itself). `off` = no pool configured.
#
# Usage:
#   fleet-steward-conflicts.sh [--json] [--session <fleet>] [--repo <owner/name>]…
#     --json     {overlaps:[{repo,path,prs,batches,first}], ci:{queued,oldest_secs,stuck},
#                 quota:{state,pct,watch}, rest:{files,lists,deferred}}
#     (default)  the same, as a few lines in the login's language
# Repos: --repo (repeatable), else every repo the fleet hosts (fleet_repos of
# --session / $FLEET_SESSION / the pane's session / the only fleet conf there is).
# Env: FLEET_STEWARD_FILES_BUDGET (10) FLEET_STEWARD_FILES_TTL (900 s)
#      FLEET_STEWARD_CI_STUCK (86400 s)
#      FLEET_STEWARD_QUOTA_CMD (seam: replaces `fleet-quotawatch.sh --status`)
# Exit: 0 printed · 2 usage · 3 no repo to look at.
set -uo pipefail
case "$0" in */*) BIN="${0%/*}" ;; *) BIN=. ;; esac
BIN="$(cd "${BIN:-/}" && pwd)"
[ -f "$BIN/../fleet.conf" ] && . "$BIN/../fleet.conf"
. "$BIN/fleet-lib.sh"

JSON=0 SESS="${FLEET_SESSION:-}" REPOS=''
while [ $# -gt 0 ]; do
  case "$1" in
    --json)    JSON=1 ;;
    --session) SESS="${2:-}"; shift ;;
    --repo)    REPOS="$REPOS$(fleet_norm_repo "${2:-}")"$'\n'; shift ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *)         printf 'fleet-steward-conflicts: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$REPOS" ]; then
  [ -n "$SESS" ] || SESS=$(fleet_current_session 2>/dev/null)
  if [ -z "$SESS" ]; then   # a daemon: the login's only fleet, if it has just one
    for d in "$FLEET_CONF_DIR"/fleets/*/; do
      [ -d "$d" ] || continue
      [ -n "$SESS" ] && { SESS=''; break; }
      SESS=$(basename "$d")
    done
  fi
  [ -n "$SESS" ] && REPOS=$(fleet_repos "$SESS")
fi
[ -n "$REPOS" ] || { printf 'fleet-steward-conflicts: no repo to look at (pass --repo or --session)\n' >&2; exit 3; }

# repo<TAB>its cache dir, one a line — the python half never builds a cache path
MAN=''
while IFS= read -r r; do
  [ -n "$r" ] || continue
  MAN="$MAN$r	$(fleet_cache_dir "$(fleet_slug "$r")")"$'\n'
done <<EOF_REPOS
$REPOS
EOF_REPOS

if [ -n "${FLEET_STEWARD_QUOTA_CMD:-}" ]; then QS=$(sh -c "$FLEET_STEWARD_QUOTA_CMD" 2>/dev/null)
else QS=$(bash "$BIN/fleet-quotawatch.sh" --status 2>/dev/null); fi
QROWS="$(fleet_cache_global)/account.quota"

# the text mode's words (fleet-ui-lang.sh is the one table)
UI=''; [ "$JSON" = 1 ] || UI=$(sh "$BIN/fleet-ui-lang.sh" dump steward_conf_ | tr '\0\001' '\036\037')

STEWARD_MAN="$MAN" STEWARD_QS="$QS" STEWARD_QROWS="$QROWS" STEWARD_JSON="$JSON" STEWARD_UI="$UI" \
exec python3 - <<'PY'
import calendar, json, os, re, subprocess, time

env = os.environ
now = int(time.time())
def num(v, d):
    try:
        return int(v)
    except (TypeError, ValueError):
        return d
BUDGET = max(0, num(env.get("FLEET_STEWARD_FILES_BUDGET"), 10))
TTL = max(0, num(env.get("FLEET_STEWARD_FILES_TTL"), 900))
rest = {"files": 0, "lists": 0, "deferred": 0}

def gh_api(path):
    """One REST read (`gh api`, paginated); None when gh says no."""
    try:
        p = subprocess.run(["gh", "api", "--paginate", path], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return None
    out = p.stdout.strip()
    try:
        return json.loads(out) if out else None
    except ValueError:   # --paginate on an array endpoint: pages back to back
        try:
            return json.loads("[" + re.sub(r"\]\s*\[", ",", out)[1:-1] + "]")
        except ValueError:
            return None

def read_lines(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().splitlines()
    except OSError:
        return None

def epoch(iso):
    try:
        return calendar.timegm(time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return None

repos = []
for line in env.get("STEWARD_MAN", "").splitlines():
    if "\t" in line:
        r, d = line.split("\t", 1)
        repos.append((r, d))

# ---- ① overlaps --------------------------------------------------------------
want = []   # (repo, dir, cache, pr, batch)
caches = {}
for repo, d in repos:
    prs = []   # (number, branch)
    rows = read_lines(os.path.join(d, "prmap"))
    if rows is not None:
        for row in rows:
            f = row.split("\t")
            if len(f) >= 3 and f[2] == "OPEN" and f[1].startswith("#") and f[1][1:].isdigit():
                prs.append((int(f[1][1:]), f[0]))
    else:
        rest["lists"] += 1
        got = gh_api("repos/%s/pulls?state=open&per_page=100" % repo) or []
        for p in got if isinstance(got, list) else []:
            if isinstance(p, dict) and isinstance(p.get("number"), int):
                prs.append((p["number"], (p.get("head") or {}).get("ref") or ""))
    parents = {}
    for row in read_lines(os.path.join(d, "parents")) or []:
        f = row.split("\t")
        if len(f) >= 2 and f[0].isdigit() and f[1].isdigit():
            parents[int(f[0])] = int(f[1])
    cpath = os.path.join(d, "prfiles.json")
    try:
        with open(cpath, encoding="utf-8") as f:
            cache = json.load(f)
        if not isinstance(cache, dict):
            cache = {}
    except (OSError, ValueError):
        cache = {}
    open_now, n0 = {str(n) for n, _ in prs}, len(cache)
    cache = {k: v for k, v in cache.items() if k in open_now and isinstance(v, dict)}
    caches[repo] = (cpath, cache, n0)
    for n, branch in prs:
        m = re.search(r"(?:^|[-/])issue-(\d+)$", branch or "")
        par = parents.get(int(m.group(1))) if m else None
        batch = "%s#%d" % (repo, par) if par else "%s!pr%d" % (repo, n)
        want.append((repo, n, batch))

# refill: missing first, then the oldest past TTL — never more than BUDGET a run
def age(repo, n):
    ent = caches[repo][1].get(str(n))
    return None if ent is None else now - num(ent.get("ts"), 0)
need = []
for repo, n, _ in want:
    a = age(repo, n)
    if a is None:
        need.append((0, -1, repo, n))
    elif a >= TTL:
        need.append((1, -a, repo, n))
need.sort()
dirty = set()
for i, (_, _, repo, n) in enumerate(need):
    if rest["files"] >= BUDGET:
        rest["deferred"] = len(need) - i
        break
    rest["files"] += 1
    got = gh_api("repos/%s/pulls/%d/files?per_page=100" % (repo, n))
    if isinstance(got, list):
        files = sorted({x.get("filename") for x in got if isinstance(x, dict) and x.get("filename")})
        caches[repo][1][str(n)] = {"ts": now, "files": files}
        dirty.add(repo)
for repo, (cpath, cache, n0) in caches.items():
    if repo in dirty or len(cache) != n0:
        try:
            tmp = "%s.%d" % (cpath, os.getpid())
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(cache, f, sort_keys=True)
            os.replace(tmp, cpath)
        except OSError:
            pass

touch = {}   # (repo, path) -> {pr: batch}
for repo, n, batch in want:
    ent = caches[repo][1].get(str(n))
    for path in (ent or {}).get("files") or []:
        touch.setdefault((repo, path), {})[n] = batch
overlaps = []
for (repo, path), prs in sorted(touch.items()):
    batches = sorted(set(prs.values()))
    if len(batches) < 2:
        continue
    overlaps.append({
        "repo": repo, "path": path, "prs": sorted(prs),
        # an EPIC's batch by name; a PR with no EPIC parent (its own batch) is null, last
        "batches": sorted([None if "!pr" in b else b for b in batches], key=lambda b: (b is None, b or "")),
        "first": min(prs),
    })

# ---- ② ci queue --------------------------------------------------------------
STUCK = max(1, num(env.get("FLEET_STEWARD_CI_STUCK"), 86400))
queued, stuck, oldest, answered = 0, 0, None, False
for repo, _ in repos:
    got = gh_api("repos/%s/actions/runs?status=queued&per_page=100" % repo)
    if not isinstance(got, dict):
        continue
    answered = True
    runs = [r for r in got.get("workflow_runs") or [] if isinstance(r, dict)]
    queued += max(num(got.get("total_count"), 0), len(runs))
    for run in runs:
        t = epoch(run.get("created_at"))
        if t is None:
            continue
        w = max(0, now - t)
        if w >= STUCK:   # GitHub never started it: not a queue anyone waits in
            stuck += 1
            continue
        oldest = w if oldest is None or w > oldest else oldest
queued -= stuck
ci = {"queued": queued, "oldest_secs": oldest, "stuck": stuck} if answered \
    else {"queued": None, "oldest_secs": None, "stuck": None}

# ---- ③ quota -----------------------------------------------------------------
watch = (env.get("STEWARD_QS", "").split("\t") or [""])[0].strip() or "unknown"
pct = None
for row in read_lines(env.get("STEWARD_QROWS", "")) or []:
    f = row.split("\t")
    if len(f) >= 4:
        try:
            h = float(f[3])
        except ValueError:
            continue
        pct = h if pct is None or h > pct else pct
if watch == "off":
    quota = {"state": "off", "pct": None}
elif watch in ("fresh", "carry") and pct is not None:
    quota = {"state": "ok", "pct": int(round(pct))}
else:
    quota = {"state": "blind", "pct": None}
quota["watch"] = watch

out = {"overlaps": overlaps, "ci": ci, "quota": quota, "rest": rest}
if env.get("STEWARD_JSON") == "1":
    print(json.dumps(out, ensure_ascii=False, sort_keys=True))
    raise SystemExit(0)

ui = {}
parts = env.get("STEWARD_UI", "").split("\x1e")
for i in range(0, len(parts) - 1, 2):
    ui[parts[i]] = parts[i + 1]
def t(key, *a):
    s = ui.get(key, key)
    for v in a:
        s = s.replace("\x1f", str(v), 1)
    return s
def dur(s):
    return "%dm" % (s // 60) if s < 3600 else "%dh%02dm" % (s // 3600, s % 3600 // 60)
if not overlaps:
    print(t("steward_conf_none"))
for o in overlaps:
    who = " ".join("#%d" % n for n in o["prs"])
    print(t("steward_conf_overlap_fmt", "%s:%s" % (o["repo"], o["path"]), who, "#%d" % o["first"]))
if ci["queued"] is None:
    print(t("steward_conf_ci_blind"))
else:
    print(t("steward_conf_ci_fmt", ci["queued"], dur(ci["oldest_secs"] or 0)))
if quota["state"] == "ok":
    print(t("steward_conf_quota_fmt", "%d%%" % quota["pct"]))
elif quota["state"] == "off":
    print(t("steward_conf_quota_off"))
else:
    print(t("steward_conf_quota_blind", watch))
PY
