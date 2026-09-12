#!/bin/sh
# fleet-trust.sh — pre-answer Claude Code's per-directory "trust this folder?"
# dialog for a fleet's OWN checkout, so an unattended worker pane never parks on it
# (issue #563).
#
#   fleet-trust.sh grant --main <FLEET_MAIN> [<dir>...]   trust the base checkout,
#                                                         plus each <dir> that is a
#                                                         worktree OF that checkout
#   fleet-trust.sh check <dir>                             trusted | untrusted | unknown
#                                                         (exit 0 / 1 / 2)
#   fleet-trust.sh file                                    print the config path
#
# WHAT CLAUDE CODE DOES (verified on 2.1.269, the build that shipped this fix): on
# start it resolves the cwd to its project root — a linked git WORKTREE resolves to
# its MAIN checkout (the git common dir's parent), which is why the MacBook's
# ~/.claude.json had no `…-issue-<N>` entries yet every spawned worker went straight
# to /fleet-claim — then does an EXACT-KEY lookup, no ancestor walk:
#   projects[<root>].hasTrustDialogAccepted === true
# If that is not true it shows "Quick safety check: Is this a project you created
# or one you trust?" and waits. A fleet pane has nobody to press Enter: on
# 2026-09-12 two autofill-dispatched workers on the macmini sat on that dialog for
# 7+ minutes — slot "filled", nothing running, nothing logged — because THAT
# machine's FLEET_MAIN entry read false. So the one key a fleet needs is its base
# checkout, and the launcher (bin/fleet-claude.sh) calls `grant` on every spawn;
# the worktree itself is written too, so a future build that keys on the cwd is
# covered as well.
#
# RAILS
#   * SCOPED: `grant` writes ONLY the given main checkout and dirs that are
#     worktrees of it (`git rev-parse --git-common-dir` == <main>/.git). Anything
#     else is refused (exit 3), never trusted. This is per-directory trust, kept
#     per-directory — not a blanket --dangerously-* flag.
#   * ATOMIC + LOSSLESS: read → merge → write a temp file beside the target →
#     rename. ~/.claude.json is ALSO written by every running claude process, so the
#     file is never truncated in place, and the rename is guarded by a
#     compare-and-swap on the file's identity (inode/size/mtime) between read and
#     rename — a change in that window discards our temp and retries from a fresh
#     read, so a concurrent writer's keys survive. Every other key in the file, and
#     every other key of the project entry, is preserved byte-for-byte in value.
#   * NEVER CLOBBERS: an unparseable config is left alone (exit 5) — Claude Code
#     owns its own recovery. A MISSING config is created (0600) with just our
#     entry: that is the shape claude itself would write, and it is what an
#     unattended first spawn on a fresh machine needs.
#   * Idempotent: an already-trusted path is a no-op (no write, no output).
#
# Output: `grant` prints each path it newly trusted, one per line (nothing when
# nothing changed); notes go to stderr. python3 does the JSON (already a fleet
# dependency — the collector needs it); without it, `grant` exits 2 and `check`
# says `unknown`. Config path: $CLAUDE_CONFIG_DIR/.claude.json when that is set
# (Claude Code keeps .claude.json in its config dir), else ~/.claude.json.
#
# Selftest seam: FLEET_TRUST_RACE_HOOK=<sh command> runs between the read and the
# write of the FIRST attempt — bin/fleet-trust-selftest.sh uses it to inject a
# concurrent writer. Unset in production.
set -u

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2; }
note()  { printf 'fleet-trust: %s\n' "$*" >&2; }

cfg_file() {
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then printf '%s/.claude.json' "$CLAUDE_CONFIG_DIR"
  else printf '%s/.claude.json' "$HOME"; fi
}

# physical (symlink-resolved) path of an existing directory — what claude keys on
# (its /tmp entries read /private/tmp on macOS); empty if it does not exist.
phys() { [ -d "$1" ] && (cd "$1" 2>/dev/null && pwd -P); }

# 0 if <dir> ($1, physical) is <main> ($2, physical) itself or a worktree of it.
belongs() {
  [ "$1" = "$2" ] && return 0
  _cd=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$_cd" in /*) : ;; *) _cd="$1/$_cd" ;; esac
  _cd=$(cd "$_cd" 2>/dev/null && pwd -P) || return 1
  [ "$_cd" = "$2/.git" ]
}

# --- the JSON edit, in python3 (stdin: one path per line; argv: config path) ----
# Exit: 0 ok (changed paths on stdout) · 2 no python · 4 gave up racing · 5 not JSON
PY_GRANT='
import json, os, sys, time, subprocess
path = sys.argv[1]
targets = [l.rstrip("\n") for l in sys.stdin if l.strip()]
def ident(st): return None if st is None else (st.st_ino, st.st_size, st.st_mtime_ns)
def stat_or_none(p):
    try: return os.stat(p)
    except FileNotFoundError: return None
for attempt in range(8):
    st = stat_or_none(path)
    raw = b""
    if st is not None:
        with open(path, "rb") as f: raw = f.read()
        # the identity we compare against is the file we actually READ
        st = stat_or_none(path)
    mode = (st.st_mode & 0o777) if st is not None else 0o600
    try:
        data = json.loads(raw.decode("utf-8")) if raw.strip() else {}
    except (ValueError, UnicodeDecodeError):
        sys.stderr.write("fleet-trust: %s is not valid JSON — leaving it alone\n" % path); sys.exit(5)
    if not isinstance(data, dict):
        sys.stderr.write("fleet-trust: %s is not a JSON object — leaving it alone\n" % path); sys.exit(5)
    projects = data.get("projects")
    if not isinstance(projects, dict):
        projects = {}; data["projects"] = projects
    changed = []
    for t in targets:
        ent = projects.get(t)
        if not isinstance(ent, dict):
            ent = {}; projects[t] = ent
        if ent.get("hasTrustDialogAccepted") is not True:
            ent["hasTrustDialogAccepted"] = True; changed.append(t)
    if not changed:
        sys.exit(0)
    hook = os.environ.get("FLEET_TRUST_RACE_HOOK")
    if hook and attempt == 0:
        subprocess.run(hook, shell=True)
    tmp = "%s.fleet-trust.%d.tmp" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False); f.write("\n")
        os.chmod(tmp, mode)
        if ident(stat_or_none(path)) != ident(st):
            os.unlink(tmp); time.sleep(0.05 * (attempt + 1)); continue   # someone wrote meanwhile: retry
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise
    for t in changed: print(t)
    sys.exit(0)
sys.stderr.write("fleet-trust: %s kept changing under us — gave up after 8 attempts\n" % path); sys.exit(4)
'

PY_CHECK='
import json, sys
path, target = sys.argv[1], sys.argv[2]
try:
    with open(path, "rb") as f: data = json.loads(f.read().decode("utf-8"))
    v = data.get("projects", {}).get(target, {}).get("hasTrustDialogAccepted")
except FileNotFoundError:
    print("unknown"); sys.exit(2)
except (ValueError, AttributeError, UnicodeDecodeError):
    print("unknown"); sys.exit(2)
if v is True: print("trusted"); sys.exit(0)
print("untrusted"); sys.exit(1)
'

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  file) cfg_file; echo ;;

  check)
    d="${1:-}"; [ -n "$d" ] || { usage; exit 2; }
    command -v python3 >/dev/null 2>&1 || { echo unknown; exit 2; }
    p=$(phys "$d") || { echo unknown; exit 2; }
    python3 -c "$PY_CHECK" "$(cfg_file)" "$p"
    ;;

  grant)
    main=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --main) [ $# -ge 2 ] || { usage; exit 2; }; main="$2"; shift 2 ;;
        --main=*) main="${1#--main=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) note "unknown flag $1"; usage; exit 2 ;;
        *) break ;;
      esac
    done
    [ -n "$main" ] || { note "grant needs --main <FLEET_MAIN>"; usage; exit 2; }
    command -v python3 >/dev/null 2>&1 || { note "python3 not found — cannot edit $(cfg_file)"; exit 2; }
    mp=$(phys "$main") || { note "refusing: --main $main is not a directory"; exit 3; }
    [ -d "$mp/.git" ] || { note "refusing: --main $mp is not a git checkout"; exit 3; }
    refused=0
    targets="$mp"
    for d in "$@"; do
      dp=$(phys "$d") || { note "refusing $d: not a directory"; refused=1; continue; }
      [ "$dp" = "$mp" ] && continue
      if belongs "$dp" "$mp"; then targets="$targets
$dp"
      else note "refusing $dp: not a worktree of $mp (only the fleet's own checkout is pre-trusted)"; refused=1; fi
    done
    printf '%s\n' "$targets" | python3 -c "$PY_GRANT" "$(cfg_file)" || exit $?
    [ "$refused" = 0 ] || exit 3
    ;;

  -h|--help|'') usage; [ "$cmd" = '' ] && exit 2; exit 0 ;;
  *) note "unknown command $cmd"; usage; exit 2 ;;
esac
