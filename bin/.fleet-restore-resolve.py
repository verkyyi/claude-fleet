#!/usr/bin/env python3
# fleet-restore-resolve.py — stdin: PIPE-delimited rows
# "window_name|path|issue|claude_state|prci|pfg|raw|origin".  (trailing `raw` =
# issue #214; trailing `origin` = spawn provenance, issue #503)
# stdout: TAB rows
# "WIN<TAB>name<TAB>path<TAB>claude-session-id<TAB>issue<TAB>state<TAB>prci<TAB>pfg<TAB>origin"
# for each work window. The session id is the stem of the NEWEST transcript in that
# worktree's project dir (same slug convention the collector uses), or '-' if none.
#
# The trailing state/prci/pfg fields (issue #153) carry per-window RUNTIME state so
# restore() can re-stamp it after `claude --resume` (otherwise a restored worker
# comes back with a blank @claude_state — the attention layer reads it as "stuck
# idle"). Each is passed through verbatim, defaulting to '-' (= nothing to restore)
# when tmux reported the option empty. Old maps (pre-#153, 5-field WIN rows) parse
# fine — the missing fields just default to '-'.
#
# INPUT is PIPE-delimited, not tab: it comes straight from a tmux `-F` format, and
# tmux < 3.5 sanitizes CONTROL chars in format output (a literal tab becomes '_'),
# so a tab-split saw one column and dropped every row. A printable '|' survives
# every tmux version and does not occur in this fleet's window names / worktree
# paths / issues. OUTPUT stays TAB-delimited — it's the on-disk restore map, read
# back with awk -F'\t'.
#
# One special input: a row whose name is the sentinel "__HUB__" is the fleet's
# operator hub pane (issue #143). It lives in the 'plan' window — a PANEL that WIN
# rows exclude — so its transcript would never be captured. For it we emit a
# "HUB<TAB>path<TAB>id" row instead of a WIN row, so restore() rebuilds the
# hub via hub-session.sh (`claude --resume`) rather than as a work window.
from pathlib import Path
import sys, glob, os, re, json, uuid

PANELS = {"plan", "dash", "backlog"}
HUB = "__HUB__"
SEP = "|"  # input field delimiter — printable so it survives tmux (see header)
MAIN = os.path.realpath(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1] else ""


def separate_raw_path(path):
    """Fail closed without the fleet's base; canonicalize aliases/subdirectories."""
    resolved = os.path.realpath(path)
    return (bool(MAIN) and os.path.isabs(path) and os.path.isdir(path)
            and os.path.commonpath((MAIN, resolved)) != MAIN)


def newest_sid(path):
    """Stem of the newest transcript in `path`'s project dir, or '-' if none.

    CAVEAT (hub, issue #143): a worker's `path` is its OWN issue-<N> worktree,
    so it holds exactly one session's transcripts — newest == that worker's. The
    hub's `path` is the SHARED base checkout (FLEET_MAIN); if something else
    (e.g. an ad-hoc `claude` the user ran there) wrote a newer transcript, this
    picks THAT up instead. The resume then loads the wrong conversation. The
    restore fallback only catches an *invalid* id, not a valid-but-wrong one.
    Acceptable for now (matches the worker heuristic and the issue's spec); a
    fully robust fix would capture the hub pane's own session id directly
    (SessionStart hook, or matching the pane's claude PID to its open transcript).
    """
    slug = re.sub(r"[/._]", "-", path)
    files = glob.glob(os.path.expanduser(f"~/.claude/projects/{slug}/*.jsonl"))
    if not files:
        return "-"
    newest = max(files, key=os.path.getmtime)
    return os.path.basename(newest)[:-6]  # strip .jsonl


for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split(SEP, 11)
    manifest = ''
    # The final JSON stays opaque (it may itself contain a pipe). New snapshots
    # place the optional handoff path before it; old rows remain readable.
    if len(parts) > 10 and parts[10].lstrip().startswith('{'):
        parts = parts[:10] + [SEP.join(parts[10:])]
    elif len(parts) > 11:
        manifest = parts.pop(10)
    name = parts[0] if len(parts) > 0 else ""
    path = parts[1] if len(parts) > 1 else ""
    issue = parts[2] if len(parts) > 2 and parts[2] else "-"
    state = parts[3] if len(parts) > 3 and parts[3] else "-"
    prci = parts[4] if len(parts) > 4 and parts[4] else "-"
    pfg = parts[5] if len(parts) > 5 and parts[5] else "-"
    raw = parts[6] if len(parts) > 6 and parts[6] else ""
    origin = parts[7] if len(parts) > 7 and parts[7] else "-"
    if not name or not path:
        continue
    if name == HUB:
        print(f"HUB\t{path}\t{newest_sid(path)}")
        continue
    if name in PANELS:
        continue
    # Raw windows have their own scratch worktrees since #290. Only legacy raw
    # windows in the shared base (or an unknown base) remain unsafe to infer by
    # cwd. A live loop supplies exact provenance and keeps its existing exception.
    loop_record = {}
    if manifest:
        try:
            loop_record = json.loads((Path(manifest).parent/'loop/state.json').read_text())
            if (loop_record.get('status') not in ('active', 'waiting-quota') or not loop_record.get('thread_id')
                    or Path(loop_record['worktree']).resolve() != Path(path).resolve()):
                loop_record = {}
        except (OSError,ValueError,KeyError,TypeError): pass
    if raw == "1" and not loop_record and not separate_raw_path(path):
        continue
    agent = parts[8] if len(parts) > 8 else ""
    suffix = ""
    sid = "-"
    if agent == "codex":
        home, transcript = "-", "-"
        try:
            data = json.loads(parts[10])
            candidate = data["session_id"]
            if (str(uuid.UUID(candidate)) == candidate.lower() and data["owner"] == parts[9]
                    and parts[9].isdigit() and os.path.isabs(data["home"])):
                fields = (candidate, data["home"], data.get("transcript", ""))
                if not any(any(c in field for c in "\t\n\r") for field in fields):
                    sid, home, transcript = fields
        except (ValueError, KeyError, IndexError, TypeError, AttributeError):
            pass
        suffix = f"\tcodex\t{home}\t{transcript or '-'}"
    else:
        sid = loop_record.get('thread_id') or newest_sid(path)
    if manifest and loop_record and loop_record.get('thread_id') == sid:
        suffix = (suffix or '\tclaude\t-\t-') + '\t' + manifest
    row = f"WIN\t{name}\t{path}\t{sid}\t{issue}\t{state}\t{prci}\t{pfg}\t{origin}{suffix}"
    if raw == "1":
        # Columns 10–12 remain provider/home/transcript, 13 is handoff_manifest.
        # Pad absent metadata so the new raw marker is always column 14 (#680).
        row += "\t-" * (13 - len(row.split("\t"))) + "\t1"
    print(row)
