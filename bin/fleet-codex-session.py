#!/usr/bin/env python3
"""Codex session identity, bounded rollout telemetry and native queue delivery.

Identity comes from SessionStart, never from the newest file in a worktree. A
single JSON window option binds it to the launcher's lifetime and CODEX_HOME.
Rollouts are an unstable upstream interface: missing/malformed data is unknown.
No credentials or conversation text are stored by this adapter.
"""
import argparse
import glob
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import uuid


def tmux(args, socket=""):
    prefix = ["tmux"] + (["-L", socket] if socket else [])
    return subprocess.run(prefix + args, text=True, capture_output=True,
                          timeout=3, check=True).stdout.strip()


def valid_id(value):
    try:
        return str(uuid.UUID(value)) == value.lower()
    except (ValueError, TypeError, AttributeError):
        return False


def saved_identity(raw, owner):
    if not raw:
        return {}
    data = json.loads(raw)
    if (not isinstance(data, dict) or data.get("owner") != owner
            or not owner.isdigit() or not valid_id(data.get("session_id"))
            or not isinstance(data.get("home"), str) or not os.path.isabs(data["home"])):
        return {}
    return data


def identity(pane, socket=""):
    if not pane or (not socket and not os.environ.get("TMUX")):
        return {}
    raw = tmux(["display-message", "-p", "-t", pane,
                "#{@cc_agent}|#{@cc_launcher_pid}|#{@codex_identity}"], socket)
    agent, owner, record = raw.split("|", 2)
    if agent != "codex":
        return {}
    return saved_identity(record, owner)


def meta(path, sid):
    try:
        with open(path, "rb") as stream:
            first = json.loads(stream.readline(2 * 1024 * 1024))
        payload = first.get("payload", {})
        if first.get("type") == "session_meta" and payload.get("id", payload.get("session_id")) == sid:
            return payload
    except (OSError, ValueError, AttributeError, TypeError):
        pass
    return None


def rollout(data):
    sid = data.get("session_id", "")
    if not valid_id(sid):
        return "", {}
    hinted = data.get("transcript", "")
    if isinstance(hinted, str) and hinted:
        header = meta(hinted, sid)
        if header is not None:
            return hinted, header
    home = data.get("home", "")
    if not isinstance(home, str) or not os.path.isabs(home):
        return "", {}
    # Exact UUID only. A subagent or newer unrelated rollout can never win.
    matches = glob.glob(os.path.join(glob.escape(home), "sessions", "*", "*", "*", "*" + sid + ".jsonl"))
    matches += glob.glob(os.path.join(glob.escape(home), "archived_sessions", "*" + sid + ".jsonl"))
    for path in matches:
        header = meta(path, sid)
        if header is not None:
            return path, header
    return "", {}


def number(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def telemetry(data):
    path, header = rollout(data)
    result = {"agent": "codex", "session_id": data.get("session_id", ""),
              "model": data.get("model", ""), "live_tokens": None, "limit": None,
              "pct": -1, "output_tokens": None, "transcript": path,
              "source": "unknown", "limit_source": "unknown"}
    if not path:
        return result
    try:
        with open(path, "rb") as stream:
            stream.seek(0, 2)
            start = max(0, stream.tell() - 2 * 1024 * 1024)
            stream.seek(start)
            if start:
                stream.readline()  # discard the first partial record
            lines = stream.readlines()
        for line in lines:
            try:
                record = json.loads(line)
                payload = record.get("payload", {})
                if not isinstance(payload, dict):
                    continue
                if record.get("type") == "turn_context":
                    result["model"] = payload.get("model") or result["model"]
                if record.get("type") != "event_msg" or payload.get("type") != "token_count":
                    continue
                info = payload.get("info")
                if not isinstance(info, dict):
                    continue
                last = info.get("last_token_usage") or {}
                total = info.get("total_token_usage") or {}
                # Codex input_tokens ALREADY includes cached_input_tokens.
                live = number(last.get("total_tokens"))
                if live is None:
                    inp, out = number(last.get("input_tokens")), number(last.get("output_tokens"))
                    live = inp + out if inp is not None and out is not None else None
                limit = number(info.get("model_context_window"))
                result.update(live_tokens=live, limit=limit,
                              output_tokens=number(total.get("output_tokens")))
            except (ValueError, TypeError, AttributeError):
                continue
    except OSError:
        return result
    if result["live_tokens"] is not None and result["limit"]:
        result.update(pct=result["live_tokens"] * 100 // result["limit"],
                      source="codex-rollout", limit_source="codex")
    return result


def hook():
    owner = os.environ.get("FLEET_CODEX_LAUNCHER_PID", "")
    pane = os.environ.get("TMUX_PANE", "")
    if not owner.isdigit() or not pane or not os.environ.get("TMUX"):
        return
    payload = json.load(sys.stdin)
    if not isinstance(payload, dict) or not valid_id(payload.get("session_id")):
        return
    current = tmux(["display-message", "-p", "-t", pane,
                    "#{@cc_agent}|#{@cc_launcher_pid}"])
    if current != "codex|" + owner:
        return
    if payload.get("hook_event_name") == "SessionStart":
        data = {"session_id": payload["session_id"], "owner": owner,
                "home": str(Path(os.environ.get("CODEX_HOME", "~/.codex")).expanduser().resolve()),
                "transcript": payload.get("transcript_path", ""),
                "cwd": payload.get("cwd", ""), "model": payload.get("model", ""),
                "remote": os.environ.get("FLEET_CODEX_REMOTE", "")}
        if os.environ.get('FLEET_CODEX_SUBSCRIPTION'):
            subscription = json.loads(os.environ['FLEET_CODEX_SUBSCRIPTION'])
            data['subscription'] = {key: subscription[key] for key in ('account', 'profile', 'home')}
    else:
        data = identity(pane)
        if data.get("session_id") != payload["session_id"]:
            return
    stats = telemetry(data)
    if stats["transcript"]:
        data["transcript"] = stats["transcript"]
    if stats["model"]:
        data["model"] = stats["model"]
    cmds = [["set-option", "-w", "-t", pane, "@codex_identity", json.dumps(data, separators=(",", ":"))],
            ["set-option", "-w", "-t", pane, "@codex_session_id", data["session_id"]]]
    for name, value in (("@ctx_pct", stats["pct"] if stats["pct"] >= 0 else ""),
                        ("@ctx_limit", stats["limit"] or ""), ("@cc_model", data.get("model", ""))):
        cmds.append(["set-option", "-w", "-t", pane, name, str(value)])
    # Compare and stamp within one tmux command queue. An old hook cannot stamp
    # a replacement launch after a slow rollout read.
    test = "#{&&:#{==:#{@cc_agent},codex},#{==:#{@cc_launcher_pid}," + owner + "}}"
    tmux(["if-shell", "-F", "-t", pane, test, " ; ".join(shlex.join(c) for c in cmds)])


def context(args):
    data = identity(args.pane, args.socket) if args.pane else {}
    if args.session:
        data = {"session_id": args.session, "home": args.home or os.environ.get("CODEX_HOME", os.path.expanduser("~/.codex")),
                "transcript": args.transcript or ""}
    stats = telemetry(data)
    pct = stats["pct"]
    threshold, armed = 0, False
    if args.pane:
        try:
            armed = tmux(['display-message', '-p', '-t', args.pane, '#{@handoff_armed}'], args.socket) == '1'
            if os.environ.get('TMUX') and not args.socket:
                value = subprocess.run(['bash', str(Path(__file__).with_name('fleet-hook-conf.sh')),
                                        'FLEET_AUTO_HANDOFF_PCT'], capture_output=True, text=True, timeout=3)
                threshold = int(value.stdout.strip() or '0') if value.returncode == 0 else 0
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    stats.update(verdict="UNKNOWN" if pct < 0 else "HANDOFF" if pct >= (threshold or 80) else "WATCH" if pct >= 50 else "OK",
                 warn_pct=50, handoff_pct=threshold or 80, auto_handoff_pct=threshold, armed=armed)
    if args.json:
        print(json.dumps(stats, separators=(",", ":")))
    elif args.quiet:
        print(stats["verdict"])
    else:
        print("context   unknown" if pct < 0 else "context   %s%% (%s / %s tokens) src=codex-rollout" % (pct, stats["live_tokens"], stats["limit"]))
        print("session   " + (stats["session_id"] or "unknown") + " · " + (stats["model"] or "unknown model"))
        print("handoff   fleet-transfer.sh --window PANE --to codex --handoff NOTES --after-turn")
        print("verdict:  " + stats["verdict"])
    return 0 if stats["verdict"] == "OK" else 1


def send(args):
    data = identity(args.pane, args.socket)
    if not data:
        raise ValueError("no current Codex session identity")
    # --remote is mandatory: an embedded `codex queue` process is not the TUI's
    # server. Never report delivery into an unrelated server as success.
    remote = data.get("remote", "")
    if not remote.startswith("unix://") or remote == "unix://":
        raise ValueError("Codex queue needs this worker's explicit local app-server endpoint")
    text = sys.stdin.read()
    if not text.strip():
        raise ValueError("empty message")
    env = dict(os.environ, CODEX_HOME=data["home"])
    p = subprocess.run(["codex", "queue", "--remote", remote, "--thread", data["session_id"], "--message", text],
                       env=env, text=True, capture_output=True, timeout=15)
    if p.returncode:
        raise ValueError(p.stderr.strip() or "Codex queue failed")
    print("queued → Codex " + data["session_id"])
    return 0


def collect(args):
    for line in sys.stdin:
        try:
            session, window, agent, owner, raw = line.rstrip("\n").split("|", 4)
            if agent != "codex":
                continue
            data = json.loads(raw)
            sid = data.get("session_id", "")
            if not valid_id(sid) or data.get("owner") != owner:
                continue
            key = "codex_%s_%s_%s_%s" % (session, window, owner, sid)
            if "/" in key or "\n" in key:
                continue
            stats = telemetry(data)
            # Keys include lifetime AND session, so /new and a replacement
            # launcher cannot display the predecessor's cache while refreshing.
            dest = Path(args.cache) / ("ctx_" + key)
            temp = dest.with_name(dest.name + "." + str(os.getpid()))
            model = str(stats["model"] or "unknown").replace("\t", " ").replace("\n", " ")
            temp.write_text("%s\t%s\t%s\n" % (model, stats["live_tokens"] if stats["pct"] >= 0 else "", stats["limit"] or ""))
            os.replace(temp, dest)
        except (OSError, ValueError, TypeError, AttributeError):
            continue
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("hook", "context", "send", "identity", "collect", "saved", "locate"))
    parser.add_argument("--pane", default=os.environ.get("TMUX_PANE", ""))
    parser.add_argument("--socket", default="")
    parser.add_argument("--session", default="")
    parser.add_argument("--home", default="")
    parser.add_argument("--transcript", default="")
    parser.add_argument("--cache", default="")
    parser.add_argument("--identity", default="{}")
    parser.add_argument("--owner", default="")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("-q", "--quiet", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "hook":
            hook()
            return 0
        if args.command == "identity":
            print(json.dumps(identity(args.pane, args.socket)))
            return 0
        if args.command == "collect":
            return collect(args)
        if args.command == "saved":
            data = saved_identity(args.identity, args.owner)
            path, _ = rollout(data)
            values = (data.get("session_id", ""), data.get("home", ""), os.path.dirname(path), path)
            if any(not isinstance(v, str) or any(c in v for c in "\t\n\r") for v in values):
                raise ValueError("invalid session metadata fields")
            print("\t".join(v or "-" for v in values))
            return 0
        if args.command == "locate":
            path, _ = rollout({"session_id": args.session, "home": args.home, "transcript": args.transcript})
            if not path:
                return 1
            print(path)
            return 0
        return context(args) if args.command == "context" else send(args)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as exc:
        if args.command == "hook":
            return 0  # telemetry must never fail a turn
        if args.command == "context":
            # A missing identity is unknown, never a fallback to Claude's file.
            args.pane = ""
            return context(args)
        print("fleet-codex-session: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
