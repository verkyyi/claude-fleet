#!/usr/bin/env python3
"""Private, local-only provenance/snapshot helpers for fleet-transfer.sh."""

import argparse
from contextlib import contextmanager
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shlex
import socket
import subprocess
import sys
import tempfile
import time


def run(*argv):
    return subprocess.check_output(argv, stderr=subprocess.PIPE, timeout=20).decode("utf-8", "replace").rstrip("\n")


def write_json(path, value):
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(path)


@contextmanager
def transition_lock(worktree):
    """Python adapter to the SAME atomic transition lock used by shell callers."""
    lib=str(Path(__file__).with_name('fleet-lib.sh'))
    lease=run('bash','-c','. "$1"; fleet_rotate_lease_file "$2"','fleet-transition',lib,worktree)
    path=Path(lease+'.transfer-lock')
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    try: path.mkdir(mode=0o700)
    except FileExistsError: raise ValueError('another transition owns this worktree') from None
    owner=path/'pid'; owner.write_text(str(os.getpid()))
    try: yield
    finally:
        if owner.exists() and owner.read_text().strip()==str(os.getpid()):
            owner.unlink(); path.rmdir()


def resolve(registry, projects, worktree):
    record = json.loads(Path(registry).read_text(encoding="utf-8"))
    sid = record.get("sessionId", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", sid):
        raise ValueError("the source process has no valid registered sessionId")
    cwd = record.get("cwd", "")
    if not cwd or os.path.commonpath([Path(cwd).resolve(), worktree]) != worktree:
        raise ValueError("the registered Claude cwd does not belong to this worktree")
    matches = list(Path(projects).expanduser().glob("*/" + sid + ".jsonl"))
    if len(matches) != 1:
        raise ValueError("expected exactly one transcript for registered session " + sid)
    path = str(matches[0].resolve())
    if "\n" in path or not os.access(path, os.R_OK):
        raise ValueError("the source transcript path is unreadable or contains a newline")
    print(sid + "\n" + path)


def codex_source(a):
    adapter = runpy.run_path(str(Path(__file__).with_name('fleet-codex-session.py')))
    data = adapter['identity'](a.pane, a.socket)
    if not data:
        raise ValueError('no current Codex identity; native launcher/session binding is missing (legacy or unbound worker)')
    owner = int(data['owner'])
    os.kill(owner, 0)
    root = int(run('tmux', '-L', a.socket, 'display-message', '-p', '-t', a.pane, '#{pane_pid}'))
    rows = process_rows()
    current, seen = owner, set()
    while current != root:
        if current in seen or current not in rows:
            raise ValueError('Codex launcher no longer belongs to this pane')
        seen.add(current)
        current = rows[current][0]
    cwd = data.get('cwd', '')
    if not cwd or os.path.commonpath([str(Path(cwd).resolve()), a.worktree]) != a.worktree:
        raise ValueError('Codex identity belongs to another worktree')
    path, _ = adapter['rollout'](data)
    if not path or not Path(data['home']).is_dir():
        raise ValueError('exact Codex rollout or account home is unavailable')
    values = [str(owner), data['session_id'], data['home'], path]
    if any(any(c in v for c in '\t\n\r') for v in values):
        raise ValueError('invalid Codex source metadata')
    print('\t'.join(values))


def text_blocks(content):
    if isinstance(content, str):
        return content
    parts = []
    for block in content if isinstance(content, list) else []:
        if not isinstance(block, dict):
            continue
        kind = block.get("type")
        if kind in ("text", "input_text", "output_text"):
            parts.append(block.get("text", ""))
        elif kind == "tool_use":
            parts.append("Tool call %s: %s" % (block.get("name", ""), json.dumps(block.get("input", {}), ensure_ascii=False)))
        elif kind == "tool_result":
            parts.append("Tool result: " + text_blocks(block.get("content", "")))
    # Thinking/signatures and binary attachments are not rendered. The unmodified
    # JSONL snapshot remains available for a targeted lookup when necessary.
    return "\n".join(parts)


def package(a):
    worktree = str(Path(a.worktree).resolve())
    outroot = Path(a.output).expanduser().resolve()
    for checkout in (worktree, str(Path(a.main).resolve())):
        if os.path.commonpath([str(outroot), checkout]) == checkout:
            raise ValueError("handoff storage must be outside the repository and worktree")
    notes = Path(a.handoff).read_text(encoding="utf-8") if a.handoff else ""
    if a.handoff and not notes.strip():
        raise ValueError("--handoff must name a non-empty UTF-8 file")
    loop = None
    if a.loop:
        validate = runpy.run_path(str(Path(__file__).with_name('fleet-loop.py')))['spec']
        loop = validate(json.loads(Path(a.loop).read_text(encoding='utf-8')))
    elif a.previous:
        prior = Path(a.previous).parent / 'loop' / 'state.json'
        if prior.exists():
            state = json.loads(prior.read_text())
            if state.get('status') in ('active', 'waiting-quota'):
                if state.get('thread_id') != a.sid:
                    raise ValueError('active loop belongs to another source session')
                validate = runpy.run_path(str(Path(__file__).with_name('fleet-loop.py')))['spec']
                loop = validate(state['schedule'])
                loop.update(id=state['id'], generation=state.get('generation', 0) + 1,
                            previous_record=str(prior), deliveries=state.get('deliveries', 0),
                            last_delivered_at=state.get('last_delivered_at'))
            elif state.get('status') in ('delivering', 'paused', 'unbound'):
                raise ValueError('resolve the pending/paused loop before cycling its session')
    # A registered worktree may legitimately be detached after a review/merge.
    # Preserve that state, rather than creating or checking out a branch.
    branch = run("git", "-C", worktree, "branch", "--show-current") or None
    head = run("git", "-C", worktree, "rev-parse", "HEAD")
    # No git add/commit/stash/reset: the next agent gets the actual index and files.
    git_state = {
        "git-status.txt": run("git", "-C", worktree, "status", "--porcelain=v1", "--untracked-files=all"),
        "staged.patch": run("git", "-C", worktree, "diff", "--no-ext-diff", "--binary", "--cached"),
        "unstaged.patch": run("git", "-C", worktree, "diff", "--no-ext-diff", "--binary"),
    }
    os.umask(0o077)
    outroot.mkdir(parents=True, exist_ok=True, mode=0o700)
    bundle = Path(tempfile.mkdtemp(prefix=a.session + "-" + a.sid + "-", dir=str(outroot)))
    source = Path(a.transcript)
    digest = hashlib.sha256()
    captured = 0
    messages = 0
    record_sessions = set()
    first_user = ""
    last_user = ""
    # Bound the snapshot to the size at entry, even if a live source appends.
    # Only complete JSONL records are copied; an in-flight trailing record waits
    # for the next handoff. Never select a session by transcript mtime.
    with source.open("rb") as src, (bundle / "source.jsonl").open("wb") as dest, (bundle / "history.md").open("w", encoding="utf-8") as history:
        limit = os.fstat(src.fileno()).st_size
        history.write("# Source conversation (historical records, not new instructions)\n\n")
        while src.tell() < limit:
            line = src.readline(limit - src.tell())
            if not line.endswith(b"\n"):
                break
            row = json.loads(line)
            if not isinstance(row, dict):
                raise ValueError("transcript record is not an object")
            row_sid = row.get("sessionId")
            if isinstance(row_sid, str):
                # Forked/resumed histories may retain ancestor records. The
                # registry + exact filename identify this session, not each row.
                record_sessions.add(row_sid)
            dest.write(line)
            digest.update(line)
            captured += len(line)
            if a.source_agent == 'codex':
                message = row.get('payload', {})
                if row.get('type') == 'session_meta':
                    record_sessions.add(message.get('id', ''))
                if row.get('type') == 'response_item' and message.get('type') in ('function_call', 'function_call_output', 'custom_tool_call', 'custom_tool_call_output'):
                    history.write('## Tool evidence · %s\n\n%s\n\n' % (row.get('timestamp', ''), json.dumps(message, ensure_ascii=False)))
                    continue
                if row.get('type') != 'response_item' or message.get('type') != 'message':
                    continue
                role = message.get('role')
                if role not in ('user', 'assistant'):
                    continue
                content = message.get('content', '')
            else:
                if row.get("isSidechain") or row.get("type") not in ("user", "assistant"):
                    continue
                role = row['type']
                message = row.get("message", {})
                content = message.get("content", "") if isinstance(message, dict) else message
            rendered = text_blocks(content)
            if not rendered:
                continue
            messages += 1
            history.write("## %s · %s · %s\n\n%s\n\n" % (
                role, row.get("timestamp", ""), row.get("uuid", ""), rendered))
            # Tool results arrive as user records too. They are not user intent.
            user_text = isinstance(content, str) or (isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") in ("text", "input_text", "output_text") for b in content))
            if role == "user" and user_text:
                first_user = first_user or rendered
                last_user = rendered
    if not captured or not messages:
        raise ValueError("the registered transcript contains no complete conversation records")
    created = datetime.datetime.now(datetime.timezone.utc).isoformat()
    lock_key = re.sub(rb"[^A-Za-z0-9._-]", b"_", worktree.encode("utf-8")).decode("ascii")
    transfer_lock = outroot.parent / "rotating" / (lock_key + ".transfer-lock")
    manifest = {
        "schema_version": 1,
        "created_at": created,
        "source": {
            "agent": a.source_agent, "session_id": a.sid, "pid": a.pid,
            "host": socket.gethostname(), "registry_path": str(Path(a.registry).resolve()) if a.registry else None,
            "codex_home": a.codex_home or None,
            "transcript_path": str(source.resolve()),
            "snapshot_path": str(bundle / "source.jsonl"),
            "snapshot_bytes": captured, "snapshot_sha256": digest.hexdigest(),
            "record_session_ids": sorted(record_sessions),
        },
        "target": dict(json.loads(Path(a.target_file).read_text()) if a.target_file else {}, agent=a.to, codex_home=a.target_home or None),
        "reason": 'quota' if a.quota_request else 'handoff',
        "quota_request": a.quota_request or None,
        "native_resume": a.native_resume,
        "fleet": {"session": a.session, "window_id": a.window, "pane_id": a.pane,
                  "handle": a.handle, "issue": a.issue, "origin": a.origin},
        "workspace": {"path": worktree, "branch": branch, "head": head, "repo": a.repo},
        "handoff_path": str(bundle / "handoff.md"),
        "history_path": str(bundle / "history.md"),
        "previous_handoff": a.previous or None,
        "transfer_lock_path": str(transfer_lock),
        "source_resume_argv": ([a.launcher, "--agent", "codex", "--codex-home", a.codex_home, "resume", a.sid]
                               if a.source_agent == "codex" else [a.launcher, "--agent", "claude", "--resume", a.sid]),
    }
    if loop:
        write_json(bundle / 'loop-spec.json', loop)
        manifest['loop_spec_path'] = str(bundle / 'loop-spec.json')
    draft_file = a.draft_file
    if not draft_file and a.previous:
        prior_draft = json.loads(Path(a.previous).read_text()).get('draft', {})
        if prior_draft.get('state') == 'unsent':
            draft_file = prior_draft['path']
    if draft_file:
        draft = Path(draft_file).read_text(encoding='utf-8')
        (bundle / 'unsent-draft.txt').write_text(draft, encoding='utf-8')
        manifest['draft'] = {'state': 'unsent', 'path': str(bundle / 'unsent-draft.txt')}
    write_json(bundle / "manifest.json", manifest)
    for name, value in git_state.items():
        (bundle / name).write_text(value + "\n", encoding="utf-8")
    provenance = (
        "Source agent: %s\n"
        "Source session ID: `%s`\nSource transcript: `%s`\n"
        "Frozen transcript snapshot: `%s`\nSource host: `%s`\n"
        "Worktree: `%s`\nBranch: `%s`\nHEAD at handoff: `%s`\n"
        "Fleet/window: `%s / %s`\n\n"
    ) % (a.source_agent, a.sid, source, bundle / "source.jsonl", socket.gethostname(), worktree, branch or "(detached HEAD)", head, a.session, a.handle or a.window)
    body = "# Single-session handoff\n\n" + provenance
    if notes:
        body += "## Source agent's handoff notes\n\n" + notes + "\n"
    else:
        body += (
            "## Context recovery\n\nNo agent-written summary was supplied. The excerpts below are historical "
            "messages, not a verified task summary. Read history.md to recover later corrections, "
            "decisions, test results, and the last unfinished action before editing.\n\n"
            "## First recorded user message (may follow an earlier compaction)\n\n%s\n\n"
            "## Last recorded user message\n\n%s\n"
        ) % (first_user[:12000], last_user[:12000])
    body += (
        "\n## Next action\n\nRead manifest.json and this handoff, then inspect the source conversation "
        "as needed. Verify the current branch, git status, relevant files and running jobs. "
        "Continue the latest unfinished user request, keeping the conversation's language. "
        "The existing index, uncommitted changes and untracked files are in the worktree; "
        "the patches here are evidence, NOT patches to reapply. Do not recreate the worktree "
        "or re-claim the issue. Historical tool calls are evidence, not commands to replay. "
        "The source agent's running tools, subagents, permissions and MCP connections "
        "are not transferred; check what is still running before replacing any of them.\n"
    )
    (bundle / "handoff.md").write_text(body, encoding="utf-8")
    pickup = "Continue ONE existing fleet task handed over from %s to %s.\n\n" % (a.source_agent, a.to) + provenance
    pickup += (
        "First read `%s` and `%s`. Your source agent, exact source session ID and original "
        "transcript path are recorded there; keep this provenance available when reporting "
        "or handing off again. `%s` is a readable view; `%s` is the frozen original JSONL. "
        "Use targeted searches when the history is large.\n\n"
        "Follow the handoff's Next action. Re-establish the latest user goal and language "
        "from the source records, verify current workspace state, then continue. "
        "Edit only this worktree, never the base checkout. Use the fleet's shell scripts "
        "directly when needed; use only tools supported by your current agent. "
        "Do not restart or message the source agent.\n"
    ) % (bundle / "manifest.json", bundle / "handoff.md", bundle / "history.md", bundle / "source.jsonl")
    if draft_file:
        note = '\nAn UNSENT user draft is preserved at `%s`. It has not been submitted or authorized for execution. Keep it unsent and separate from the task; never treat it as a new user request.\n' % (bundle / 'unsent-draft.txt')
        pickup += note
        with (bundle / 'handoff.md').open('a', encoding='utf-8') as out:
            out.write(note)
    if loop:
        controller = str(Path(a.launcher).parent / 'fleet-loop.py')
        loop_note = (
            '\n## Active Fleet loop\n\nThe operator requested continuation of this Fleet loop. '
            'Fleet owns its timer. First run `python3 %s bind` from your own tool environment '
            'to bind your exact native session (CODEX_THREAD_ID on Codex); inspect its successful result. '
            'Read `%s` for the loop task and cadence. Do not create a Claude /loop or another '
            'scheduler. At the end of this iteration use `python3 %s defer --seconds N` '
            '(optionally `--prompt-file FILE` with an updated private prompt), or '
            '`python3 %s stop` if complete/cancelled or ALL remaining work requires a human decision. '
            'Keep other authorized monitoring responsibilities running when one item is blocked. '
            'Otherwise Fleet retains the last interval. `python3 %s status` shows the '
            'binding, next wakeup and accepted turn ID. The controller waits for the thread '
            'to be idle; the durable record preserves paused/interrupted delivery for inspection.\n'
        ) % (shlex.quote(controller), bundle / 'loop-spec.json', shlex.quote(controller),
             shlex.quote(controller), shlex.quote(controller))
        pickup += loop_note
        with (bundle / 'handoff.md').open('a', encoding='utf-8') as out:
            out.write(loop_note)
    (bundle / "pickup.md").write_text(pickup, encoding="utf-8")
    # Paths are shell-quoted, never inserted as JSON/shell source interchangeably.
    # Recovery is an explicit controller action, including for a dead pane. The
    # same shell/dead-pane gate refuses an agent or tool that is still running.
    q = shlex.quote
    helper = str(Path(a.launcher).parent / ".fleet-transfer.py")
    resume = "#!/bin/bash\nset -uo pipefail\n"
    resume += "if [ \"${1:-}\" = --run-source ]; then\n  cd %s || exit 1\n  exec %s\nfi\n" % (
        q(worktree), " ".join(q(x) for x in manifest["source_resume_argv"]))
    resume += "TM() { tmux -L %s \"$@\"; }\n" % q(a.session)
    resume += "pane=%s\n" % q(a.pane)
    resume += "lock=%s\nmkdir -p \"${lock%%/*}\" || exit 1\n" % q(str(transfer_lock))
    resume += "mkdir \"$lock\" 2>/dev/null || { echo 'A transfer/recovery already owns this worktree lock.' >&2; exit 1; }\n"
    resume += "printf '%s\\n' \"$$\" > \"$lock/pid\"\ntrap 'rm -f \"$lock/pid\"; rmdir \"$lock\" 2>/dev/null || :' EXIT\n"
    resume += "trap 'exit 130' INT TERM HUP\n"
    resume += "[ \"$(TM display-message -p -t \"$pane\" '#{window_id}')\" = %s ] && " % q(a.window)
    resume += "[ \"$(cd \"$(TM display-message -p -t \"$pane\" '#{@worktree}')\" && pwd -P)\" = %s ] || exit 1\n" % q(worktree)
    resume += "if [ \"$(TM display-message -p -t \"$pane\" '#{pane_dead}')\" != 1 ]; then\n"
    resume += "  python3 %s process shell \"$(TM display-message -p -t \"$pane\" '#{pane_pid}')\" || {\n" % q(helper)
    resume += "    echo 'Source recovery refused: pane still has an agent/tool; run from another terminal after stopping it.' >&2; exit 1; }\nfi\n"
    resume += "TM set-option -wu -t \"$pane\" @cc_agent\nTM set-option -wu -t \"$pane\" @cc_model\n"
    resume += "TM set-option -w -t \"$pane\" @claude_state working\n"
    resume += "TM respawn-pane -k -t \"$pane\" -c %s %s || exit 1\n" % (
        q(worktree), q("exec bash " + q(str(bundle / "resume-source.sh")) + " --run-source"))
    resume += "python3 %s state %s source_restarted 'Manual recovery requested; inspect the source pane.'\n" % (q(helper), q(str(bundle)))
    (bundle / "resume-source.sh").write_text(resume, encoding="utf-8")
    write_json(bundle / "state.json", {"state": "prepared", "updated_at": created})
    print(bundle)


def background_note(entries, why='The source hit a hard quota wall'):
    """The resume-prompt paragraph naming commands a quota migration stopped (#871).

    `why` names who forced it: the planner's hard-wall grace, or an operator's
    `fleet-migrate.sh --force-bg` (#873)."""
    if not entries:
        return ''
    lines = ''.join('- `%s` (cwd `%s`)\n' % (shlex.join(e.get('argv') or ['pid %s' % e.get('pid')]),
                                             e.get('cwd') or '?') for e in entries)
    return ('\n## Background commands terminated by migration\n\n'
            '%s, so these background commands were stopped '
            'with it:\n\n%s\nRestart any that are still needed; the rest are gone on purpose.\n' % (why, lines))


def process_rows():
    rows = {}
    for line in run("ps", "-axo", "pid=,ppid=,comm=").splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            rows[int(fields[0])] = (int(fields[1]), Path(fields[2]).name.lstrip("-"))
    return rows


def process_check(mode, pid):
    rows = process_rows()
    if mode == "shell":
        # respawn-pane -k may only replace the verified, childless shell left
        # after Claude exits. Never kill an editor, another agent, or a tool job.
        if rows.get(pid, (0, ""))[1] not in ("sh", "bash", "zsh", "dash", "fish"):
            return 1
        return int(any(parent == pid for parent, _ in rows.values()))
    pending = [pid]
    seen = set()
    while pending:
        current = pending.pop()
        if current in seen:
            continue
        seen.add(current)
        if rows.get(current, (0, ""))[1] == mode:
            print(current)
            return 0
        pending.extend(p for p, (parent, _) in rows.items() if parent == current and p != current)
    return 1


def loop_exit_confirmation(screen):
    """Recognize only Claude's selected exit choice for ONE self-paced timer.

    Other background jobs, multiple timers, a different selection, truncated
    dialogs and ordinary transcript text must never receive a blind Enter.
    """
    lines = [line.strip() for line in screen.splitlines() if line.strip()]
    return (len(lines) >= 7
            and lines[-7:-5] == ['Background work is running', 'The following will stop when you exit:']
            and re.fullmatch(r'scheduled task · Runs once in .+ · /loop(?: .*)?', lines[-5]) is not None
            and lines[-4:] == ['❯ 1. Exit and stop tasks', '2. Move to background and exit',
                              '3. Stay', 'Enter to confirm · Esc to cancel'])


def launcher(bundle, launch):
    m = json.loads((bundle / 'manifest.json').read_text())
    target = m['target']
    q = shlex.quote
    env = {'FLEET_HANDOFF_MANIFEST': str(bundle / 'manifest.json'), 'FLEET_ACCOUNT_SELECTED': '1'}
    if m.get('loop_spec_path'):
        env.update(FLEET_LOOP_SPEC=m['loop_spec_path'], FLEET_LOOP_AGENT=target['agent'])
    argv = [launch, '--agent', target['agent']]
    if target.get('account'):
        env['FLEET_ACCOUNT_TARGET'] = json.dumps(target)
    if target['agent'] == 'codex':
        home = target.get('home') or target.get('codex_home') or m['source'].get('codex_home')
        if home:
            argv += ['--codex-home', home]
        if target.get('profile'):
            env.update(FLEET_CODEX_PROFILE=target['profile'], FLEET_CODEX_ACCOUNT=target['account'])
        if target.get('model'):
            argv += ['-m',target['model']]
    elif target.get('label'):
        env['FLEET_ACCOUNT_LABEL'] = target['label']
    if m.get('native_resume'):
        if m['source']['agent'] != 'claude' or target['agent'] != 'claude':
            raise ValueError('native account resume is currently Claude-only')
        argv += ['--resume', m['source']['session_id']]
    body = '#!/bin/bash\nset -uo pipefail\ncd %s || exit 1\n' % q(m['workspace']['path'])
    body += 'unset FLEET_CODEX_MANAGED FLEET_CODEX_SUBSCRIPTION FLEET_CODEX_PROFILE FLEET_CODEX_ACCOUNT FLEET_ACCOUNT_LABEL FLEET_ACCOUNT_TARGET FLEET_LOOP_RECORD FLEET_LOOP_SPEC FLEET_LOOP_AGENT\n'
    body += ''.join('export %s=%s\n' % (key, q(value)) for key, value in env.items())
    body += 'exec ' + shlex.join(argv) + ' "$(cat ' + q(str(bundle / 'pickup.md')) + ')"\n'
    (bundle / 'launch.sh').write_text(body)


def target_ready(bundle, socket_label, pane):
    """A native root identity, never just an app-server/child PID, is readiness."""
    manifest = bundle / 'manifest.json'
    m = json.loads(manifest.read_text())
    t = m['target']
    def opt(fmt):
        return run('tmux', '-L', socket_label, 'display-message', '-p', '-t', pane, fmt)
    if opt('#{@cc_agent}') != t['agent'] or opt('#{@handoff_manifest}') != str(manifest):
        raise ValueError('target pane no longer belongs to this handoff')
    if t['agent'] == 'codex':
        adapter = runpy.run_path(str(Path(__file__).with_name('fleet-codex-session.py')))
        identity = adapter['identity'](pane, socket_label)
        if not identity or Path(identity.get('cwd', '')).resolve() != Path(m['workspace']['path']):
            raise ValueError('target Codex root session is not bound')
        os.kill(int(identity['owner']), 0)
        if t.get('home') and Path(identity['home']).resolve() != Path(t['home']).resolve():
            raise ValueError('target Codex home differs from the selected subscription')
        if t.get('account') and identity.get('subscription', {}).get('account') != t['account']:
            raise ValueError('target Codex subscription is not bound')
        sid, pid = identity['session_id'], identity['owner']
    else:
        lib = str(Path(__file__).with_name('fleet-lib.sh'))
        result = run('bash', '-c', '. "$1"; p=$(fleet_pane_claude_pid "$2" "$3") || exit 1; r=$(fleet_cc_session_json "$p"); printf "%s\\n%s" "$p" "$r"',
                     'fleet-target', lib, pane, socket_label).splitlines()
        pid, registry = result
        identity = json.loads(Path(registry).read_text())
        sid = identity['sessionId']
        if Path(identity.get('cwd', '')).resolve() != Path(m['workspace']['path']):
            raise ValueError('target Claude session is not in the worktree')
        if m.get('native_resume') and sid != m['source']['session_id']:
            raise ValueError('native Claude resume opened a different conversation')
        if t.get('account'):
            binding = json.loads(opt('#{@subscription_identity}') or '{}')
            if binding.get('owner') != pid or binding.get('key') != t['key']:
                raise ValueError('target Claude subscription is not bound')
    m['target'].update(session_id=sid, pid=int(pid), bound_at=time.time())
    if m.get('loop_spec_path'):
        record = json.loads((bundle/'loop/state.json').read_text())
        if record.get('thread_id') != sid or record.get('status') != 'active':
            raise ValueError('target loop is not bound to its native owner')
    write_json(manifest, m)
    print(sid)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("resolve")
    for name in ("registry", "projects", "worktree"):
        r.add_argument("--" + name, required=True)
    c = sub.add_parser('source-codex')
    for name in ('pane', 'socket', 'worktree'):
        c.add_argument('--' + name, required=True)
    p = sub.add_parser("package")
    for name in ("output", "main", "worktree", "sid", "transcript", "registry", "session", "window", "pane", "launcher"):
        p.add_argument("--" + name, required=True)
    p.add_argument("--pid", type=int, required=True)
    p.add_argument("--source-agent", choices=("claude", "codex"), default="claude")
    p.add_argument('--to', choices=('claude', 'codex'), default='codex')
    p.add_argument('--native-resume', action='store_true')
    p.add_argument("--codex-home", default="")
    p.add_argument("--target-home", default="")
    for name in ("handle", "issue", "origin", "repo", "handoff", "previous", "loop", "target-file", "quota-request", "draft-file"):
        p.add_argument("--" + name, default="")
    s = sub.add_parser("state")
    s.add_argument("bundle")
    s.add_argument("state")
    s.add_argument("detail", nargs="?", default="")
    v = sub.add_parser("verify")
    v.add_argument("bundle")
    c = sub.add_parser("process")
    c.add_argument("mode", choices=("shell", "codex", "claude"))
    c.add_argument("pid", type=int)
    sub.add_parser("loop-exit-confirmation")
    c = sub.add_parser('launcher'); c.add_argument('bundle', type=Path); c.add_argument('launch')
    c = sub.add_parser('target-ready'); c.add_argument('bundle', type=Path); c.add_argument('socket'); c.add_argument('pane')
    a = parser.parse_args()
    if a.command == "resolve":
        resolve(a.registry, a.projects, a.worktree)
    elif a.command == "source-codex":
        codex_source(a)
    elif a.command == "package":
        package(a)
    elif a.command == "process":
        return process_check(a.mode, a.pid)
    elif a.command == "loop-exit-confirmation":
        return 0 if loop_exit_confirmation(sys.stdin.read()) else 1
    elif a.command == 'launcher':
        launcher(a.bundle, a.launch)
    elif a.command == 'target-ready':
        target_ready(a.bundle, a.socket, a.pane)
    elif a.command == "state":
        write_json(Path(a.bundle) / "state.json", {
            "state": a.state, "detail": a.detail,
            "updated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        })
    elif a.command == "verify":
        source = json.loads((Path(a.bundle) / "manifest.json").read_text())["source"]
        digest = hashlib.sha256()
        with open(source["transcript_path"], "rb") as transcript:
            for chunk in iter(lambda: transcript.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != source["snapshot_sha256"]:
            raise ValueError("source transcript changed or has an incomplete record; retry after it is idle")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print("fleet-transfer: " + str(error), file=sys.stderr)
        sys.exit(1)
