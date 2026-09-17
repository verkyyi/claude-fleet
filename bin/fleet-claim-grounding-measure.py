#!/usr/bin/env python3
"""Reproducible, read-only Claude /fleet-claim measurements (issue #461).

Method v1 is documented in docs/CLAIM-MEASUREMENT.md. It identifies command
shapes, not effects: no transcript command is ever executed. JSON reports only
metrics and detection reasons, never issue bodies, commands or assistant text.
"""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import shlex
import statistics
import sys


def timestamp(value):
    try:
        stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return stamp.replace(tzinfo=timezone.utc) if stamp.tzinfo is None else stamp
    except (AttributeError, TypeError, ValueError):
        return None


def text_content(content):
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    return "\n".join(c.get("text", "") for c in content
                     if isinstance(c, dict) and c.get("type") == "text" and isinstance(c.get("text"), str))


def claim_prompt(text):
    return bool(re.match(
        r"\s*(?:/(?:fleet:)?fleet-claim(?:\s|$)|"
        r"(?:<command-message>[^<]*</command-message>\s*)?"
        r"<command-name>/(?:fleet:)?fleet-claim</command-name>)", text))


def shell_tokens(command):
    # Non-POSIX mode retains quotes so echo '>' cannot look like a redirect.
    try:
        lex = shlex.shlex(command, posix=False, punctuation_chars=";&|()<>\n")
        lex.whitespace = " \t\r"
        lex.whitespace_split = True
        return list(lex)
    except ValueError:
        return []


def shell_surface(command):
    """Hide literal heredoc bodies from shell executable/redirection matching."""
    lines, pending = [], []
    for line in command.splitlines(keepends=True):
        if pending:
            delimiter, strip_tabs = pending[0]
            candidate = line.rstrip("\r\n")
            if strip_tabs:
                candidate = candidate.lstrip("\t")
            if candidate == delimiter:
                pending.pop(0)
            continue
        lines.append(line)
        # Deliberately limited to literal delimiters, the normal worker shape.
        for match in re.finditer(r"(?<!<)<<(-?)\s*(['\"]?)([A-Za-z_]\w*)\2", line):
            pending.append((match[3], bool(match[1])))
    return "".join(lines)


def write_reason(tool):
    name, args = tool.get("name", ""), tool.get("input", {})
    if not isinstance(args, dict):
        return None
    if name in ("Write", "Edit", "MultiEdit", "NotebookEdit", "apply_patch"):
        return name
    if name != "Bash":
        return None
    command = args.get("command", "")
    if not isinstance(command, str):
        return None
    surface = shell_surface(command)
    tokens = shell_tokens(surface)
    for i, token in enumerate(tokens):
        if token in (">", ">>", "&>", "&>>") and i+1 < len(tokens):
            target = tokens[i+1].strip("\"'")
            if target != "&" and not target.startswith("/dev/"):
                return "Bash: file redirection"
        # Only executable-position tokens; mentions inside echo/quotes don't count.
        if i and not re.fullmatch(r"[;&|()\n]+", tokens[i-1]):
            continue
        executable = Path(token).name
        end = next((j for j in range(i+1, len(tokens))
                    if re.fullmatch(r"[;&|()\n]+", tokens[j])), len(tokens))
        tail = tokens[i+1:end]
        if executable == "apply_patch":
            return "Bash: apply_patch"
        if executable in ("sed", "perl") and any(
            re.match(r"^-[^-]*i", arg) or arg.startswith("--in-place") for arg in tail
        ):
            return "Bash: in-place edit"
        if executable == "tee" and any(not t.startswith("-") and not t.strip("\"'").startswith("/dev/") for t in tail):
            return "Bash: tee file"
    # Python here-docs/-c are common under bypass permissions. A bare python3 -
    # (or a read-only heredoc) is NOT a write. This remains a source-shape heuristic.
    if re.search(r"(?:^|[\n;&|])\s*(?:\S*/)?python(?:3(?:\.\d+)?)?\s", surface):
        if re.search(r"\.(?:write_text|write_bytes)\s*\(", command) or re.search(
            r"\bopen\s*\([^\n]*?,\s*(?:mode\s*=\s*)?['\"][wax][^'\"]*['\"]", command
        ):
            return "Bash: Python file write"
    return None


SCAFFOLD = re.compile(
    r"fleet-(?:claim-brief|lib)\.sh|fleet_(?:current_session|load_conf|seat|worker_charter|worker_prompt_body)\b|"
    r"\bgh\s+issue\s+(?:view|edit)\b")
CHARTER = re.compile(r"(?:CHARTER|CLAUDE|AGENTS)\.md|fleet-claim\.md|fleet\.conf|charter", re.I)


def preamble_tool(tool):
    args = tool.get("input", {})
    if not isinstance(args, dict):
        return False
    if tool.get("name") == "Read":
        return bool(CHARTER.search(str(args.get("file_path", ""))))
    if tool.get("name") != "Bash":
        return False
    command = args.get("command", "")
    if not isinstance(command, str):
        return False
    for part in re.split(r"[;\n]|&&|\|\|", command):
        part = part.strip()
        if not part or part.startswith("#"):
            continue
        if SCAFFOLD.search(part):
            continue
        if re.match(r"^[A-Za-z_]\w*=", part) and "$(" in part:
            return False
        if re.match(r"^(?:echo|printf|pwd|true|export|test|if|then|fi|:)\b|^\[|^[A-Za-z_]\w*=", part):
            continue
        if re.match(r"^(?:cat|head|sed)\b", part) and CHARTER.search(part):
            continue
        return False
    return True


def number(value):
    return value if type(value) is int and value >= 0 else None


def analyze(path):
    requests, aliases = {}, {}
    first_user = None
    started = None
    bad_lines = 0
    missing_ids = 0
    with path.open(encoding="utf-8") as stream:
        for lineno, line in enumerate(stream, 1):
            try:
                row = json.loads(line)
            except ValueError:
                bad_lines += 1
                continue
            if not isinstance(row, dict) or row.get("isSidechain"):
                continue
            message = row.get("message", {})
            if not isinstance(message, dict):
                continue
            if row.get("type") == "user" and first_user is None:
                first_user = text_content(message.get("content"))
                if not claim_prompt(first_user):
                    return None, "not a claim seed"
                started = timestamp(row.get("timestamp"))
            if row.get("type") != "assistant" or first_user is None:
                continue
            msg_id = message.get("id")
            if not isinstance(msg_id, str):
                msg_id = None
            key = aliases.get(msg_id) or row.get("requestId") or msg_id
            if not isinstance(key, str) or not key:
                key = f"line:{lineno}"
                missing_ids += 1
            if isinstance(msg_id, str):
                aliases[msg_id] = key
            req = requests.setdefault(key, {"tools": {}, "output": None, "context": None, "write": None})
            usage = message.get("usage") or {}
            if isinstance(usage, dict):
                output = number(usage.get("output_tokens"))
                if output is not None:
                    req["output"] = max(req["output"] or 0, output)
                read = number(usage.get("cache_read_input_tokens"))
                create = number(usage.get("cache_creation_input_tokens"))
                if read is not None and create is not None:
                    req["context"] = max(req["context"] or 0, read+create)
            content = message.get("content", [])
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                tool_id = block.get("id")
                if not isinstance(tool_id, str) or not tool_id:
                    tool_id = json.dumps(block, sort_keys=True)
                req["tools"][tool_id] = block
                reason = write_reason(block)
                if reason and req["write"] is None:
                    req["write"] = (reason, timestamp(row.get("timestamp")))
    if first_user is None or not requests:
        return None, "no claim requests"
    phases = {"preamble": [], "grounding": []}
    phase = "preamble"
    first_write = None
    for key, req in requests.items():
        if req["write"]:
            reason, stamp = req["write"]
            elapsed = (stamp-started).total_seconds() if stamp and started and stamp >= started else None
            first_write = {"request_id": key, "reason": reason, "elapsed_seconds": elapsed,
                           "context_tokens": req["context"]}
            break
        if not all(preamble_tool(t) for t in req["tools"].values()):
            phase = "grounding"
        phases[phase].append(req["output"])
    metrics = {name: {"turns": len(values), "output_tokens": (
        sum(values) if all(v is not None for v in values) else None)} for name, values in phases.items()}
    return {"path": str(path), "started_at": started.astimezone(timezone.utc).isoformat() if started else None,
            "unique_requests": len(requests), "malformed_lines": bad_lines,
            "rows_without_request_id": missing_ids, **metrics, "first_write": first_write}, None


def summarize(sessions):
    complete = [s for s in sessions if s["first_write"] is not None]
    result = {}
    for phase, metric in (("preamble", "turns"), ("preamble", "output_tokens"),
                          ("grounding", "turns"), ("grounding", "output_tokens"),
                          ("first_write", "elapsed_seconds"), ("first_write", "context_tokens")):
        values = [s[phase][metric] for s in complete if s[phase][metric] is not None]
        result[f"{phase}.{metric}"] = {"median": statistics.median(values) if values else None,
                                      "samples": len(values)}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", type=Path, help="JSONL files or directories (recursive)")
    parser.add_argument("--projects-dir", type=Path, default=Path.home()/".claude/projects")
    parser.add_argument("--project-glob", default="*claude-fleet-issue-*", help="project directory glob for default discovery")
    parser.add_argument("--limit", type=int, default=10, help="latest claim sessions by start time; 0 = all (default: 10)")
    parser.add_argument("--json", action="store_true", help="metrics and selection diagnostics as JSON")
    args = parser.parse_args()
    if args.limit < 0:
        parser.error("--limit must be nonnegative")
    if args.paths:
        paths = set()
        for path in args.paths:
            if not path.exists():
                parser.error(f"path does not exist: {path}")
            paths.update(path.rglob("*.jsonl") if path.is_dir() else [path])
    else:
        paths = args.projects_dir.glob(args.project_glob+"/*.jsonl")
    paths = sorted({p.resolve() for p in paths})
    sessions, skipped = [], []
    for path in paths:
        try:
            session, why = analyze(path)
        except (OSError, UnicodeError) as exc:
            session, why = None, f"unreadable: {type(exc).__name__}"
        if session is not None:
            sessions.append(session)
        else:
            skipped.append({"path": str(path), "reason": why})
    sessions.sort(key=lambda s: (s["started_at"] or "", s["path"]), reverse=True)
    matched = len(sessions)
    if args.limit:
        sessions = sessions[:args.limit]
    report = {"method_version": 1, "files_scanned": len(paths), "matched_sessions": matched,
              "selected_sessions": len(sessions), "complete_sessions": sum(s["first_write"] is not None for s in sessions),
              "sessions": sessions, "skipped": skipped, "medians": summarize(sessions)}
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(f"Claim measurement v1: {len(sessions)}/{matched} sessions selected; "
              f"{report['complete_sessions']} with a detected first write; {len(skipped)} files skipped.")
        print("Turns = unique assistant requests. Write/phase detection is heuristic; see docs/CLAIM-MEASUREMENT.md.")
        print("Medians exclude sessions without a detected write; missing metrics stay unknown.")
        print("\nmetric                              median      samples")
        for metric, value in report["medians"].items():
            shown = f"{value['median']:.1f}" if value["median"] is not None else "unknown"
            print(f"{metric:35} {shown:>10} {value['samples']:>10}")
        print("\nSelected transcripts (use --json for per-session metrics and skipped reasons):")
        for s in sessions:
            status = s["first_write"]["reason"] if s["first_write"] else "no detected write"
            print(f"  {s['path']} — {status}")
    return 0 if sessions else 1


if __name__ == "__main__":
    sys.exit(main())
