#!/usr/bin/env python3
# fleet-restore-resolve.py — stdin: PIPE-delimited rows
# "window_name|path|issue|claude_state|prci|pfg|raw|origin".  (trailing `raw` =
# issue #214; trailing `origin` = spawn provenance, issue #503)
# stdout: TAB rows
# "WIN<TAB>name<TAB>path<TAB>claude-session-id<TAB>issue<TAB>state<TAB>prci<TAB>pfg<TAB>origin"
# for each work window. The session id is the window's hook-recorded @cc_session_id
# (--sid), else the stem of the NEWEST non-helper transcript in that worktree's
# project dir (issue #1296), or '-' if none.
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
# --lead (issue #789): each input line starts with one extra field, the window's
# repo — `owner/name`, `norepo:<session-id>` for a no-repo session, or empty. A
# non-empty one becomes WIN column 16 (`-` for no-repo), padded after column 15; an
# empty one writes nothing, so a one-repo fleet's rows are byte-identical.
LEAD = "--lead" in sys.argv[2:]


def separate_raw_path(path):
    """Fail closed without the fleet's base; canonicalize aliases/subdirectories."""
    resolved = os.path.realpath(path)
    return (bool(MAIN) and os.path.isabs(path) and os.path.isdir(path)
            and os.path.commonpath((MAIN, resolved)) != MAIN)


# --sid (issue #1296): each input line starts with one more field, BEFORE the
# --lead one: the window's @cc_session_id — the pane's own session id, stamped by
# its SessionStart and Stop hooks. Empty for a window whose CLI predates them.
SID = "--sid" in sys.argv[2:]
HELPER_MARKERS = (
    # fleet_internal_transcript's rubrics + the sleep digest's — keep in lockstep
    # with fleet_is_helper_transcript in fleet-lib.sh (fleet-restore-helper-selftest.sh).
    b"You are a status classifier for a Claude Code",
    b"You are a status classifier for a coding-agent",
    b"You are labeling a Claude Code session for a dashboard",
    b"You write the status card of a paused coding assistant",
)


def project_dir(path):
    """`path`'s Claude project dir: EVERY non-alphanumeric byte becomes '-'
    (fleet_transcript_dir in fleet-lib.sh — '/', '.', '_' AND the rest)."""
    root = os.environ.get("CLAUDE_PROJECTS_DIR") or os.path.expanduser("~/.claude/projects")
    return os.path.join(root, re.sub(r"[^A-Za-z0-9]", "-", path))


def helper_reason(f):
    """'marker' | 'thin' | '' — mirror of fleet_is_helper_transcript (issue #1296)."""
    try:
        with open(f, "rb") as fh:
            head = fh.read(16384)
            if any(m in head for m in HELPER_MARKERS):
                return "marker"
            # Thin = under 50 lines with no tool call; stop reading at line 50 —
            # a long transcript is never thin, however big the file.
            fh.seek(0)
            n, tool = 0, False
            for row in fh:
                n += row.endswith(b"\n")    # newline count, exactly `wc -l`
                if n >= 50:
                    return ""
                tool = tool or b'"type":"tool_use"' in row
    except OSError:
        return ""
    return "" if tool else "thin"


def newest_sid(path, hook_sid=""):
    """The session to resume for a window in `path`, or '-' if none.

    1. `hook_sid` — the pane's own id, recorded by its hooks — when its transcript
       is in this project dir and is not a known helper prompt. Exact, so a
       hub/base checkout shared with an ad-hoc `claude` can no longer be misread.
    2. Else the newest transcript that is not a helper (issue #1296): the fleet's
       own `claude -p` calls ran from inside the worktree and were usually the
       NEWEST file there — that is how four windows came back on a classifier.
       Only thin ones left (short, no tool call)? The newest of them beats none.
    """
    d = project_dir(path)
    if hook_sid:
        f = os.path.join(d, hook_sid + ".jsonl")
        if os.path.isfile(f) and helper_reason(f) != "marker":
            return hook_sid
    files = glob.glob(os.path.join(glob.escape(d), "*.jsonl"))
    thin = ""
    for f in sorted(files, key=os.path.getmtime, reverse=True)[:200]:
        why = helper_reason(f)
        if not why:
            return os.path.basename(f)[:-6]
        if why == "thin" and not thin:
            thin = os.path.basename(f)[:-6]
    return thin or "-"


for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    hook_sid = ''
    if SID:
        hook_sid, _, line = line.partition(SEP)
        try:
            hook_sid = hook_sid if str(uuid.UUID(hook_sid)) == hook_sid.lower() else ''
        except ValueError:
            hook_sid = ''
    lead = ''
    if LEAD:
        lead, _, line = line.partition(SEP)
    norepo_sid = None
    if lead.startswith('norepo:'):
        cand = lead[len('norepo:'):]
        try:
            norepo_sid = cand if str(uuid.UUID(cand)) == cand.lower() else ''
        except ValueError:
            norepo_sid = ''
        lead = '-'
    elif any(c in lead for c in "\t\n\r") or '/' not in lead:
        lead = ''
    sleep_record = ''
    extended = line.split(SEP, 12)
    if (len(extended) == 13 and not extended[10].lstrip().startswith('{')
            and not extended[11].lstrip().startswith('{')):
        sleep_record = extended.pop(11)
        line = SEP.join(extended)
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
    elif norepo_sid is not None:
        # A no-repo session runs in $HOME, whose project dir is shared with every
        # other claude started there: never guess by mtime — its own id or nothing.
        sid = norepo_sid or '-'
    else:
        sid = loop_record.get('thread_id') or newest_sid(path, hook_sid)
    retained = {}
    if sleep_record:
        try:
            retained = json.loads(Path(sleep_record).read_text())
            if (retained.get('state') not in ('preparing','sleeping','waking','failed')
                    or Path(retained['source']['worktree']).resolve() != Path(path).resolve()):
                retained = {}
            else:
                source = retained['source']
                sid = source['session_id']
                suffix = '\t' + source['agent'] + '\t' + (source.get('home') or '-') + '\t' + source['transcript']
                state = 'done'
        except (OSError,ValueError,KeyError,TypeError):
            retained = {}
    if manifest and loop_record and loop_record.get('thread_id') == sid:
        suffix = (suffix or '\tclaude\t-\t-') + '\t' + manifest
    row = f"WIN\t{name}\t{path}\t{sid}\t{issue}\t{state}\t{prci}\t{pfg}\t{origin}{suffix}"
    if raw == "1":
        # Columns 10–12 remain provider/home/transcript, 13 is handoff_manifest.
        # Pad absent metadata so the new raw marker is always column 14 (#680).
        row += "\t-" * (13 - len(row.split("\t"))) + "\t1"
    # Missing/corrupt retained state must stay an actionable placeholder. Never
    # discard its marker and let restore silently start a different conversation.
    if sleep_record:
        row += "\t-" * (14 - len(row.split("\t"))) + "\t" + sleep_record
    if lead:
        row += "\t-" * (15 - len(row.split("\t"))) + "\t" + lead
    print(row)
