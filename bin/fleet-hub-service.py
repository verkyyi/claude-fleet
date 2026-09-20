#!/usr/bin/env python3
"""Install and inspect the persistent Fleet Hub launchd service on macOS."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

LABEL = "com.claude-fleet.hub"
BIN = Path(__file__).absolute().parent


def launch_agent(home, python, entrypoint, state_dir, resource_url, port):
    url = urlsplit(resource_url)
    if url.scheme != "https" or not url.hostname or url.path != "/mcp" or url.username or url.password or url.query or url.fragment:
        raise ValueError("resource URL must be https://<host>[:port]/mcp")
    if not 1 <= port <= 65535:
        raise ValueError("port must be between 1 and 65535")
    path = ":".join([str(home / ".local/bin"), str(python.parent), "/opt/homebrew/bin",
                     "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    return {
        "Label": LABEL,
        "ProgramArguments": [str(python), str(entrypoint), "--state-dir", str(state_dir),
                             "serve", "--transport", "streamable-http", "--auth", "grant-token",
                             "--host", "127.0.0.1", "--port", str(port), "--resource-url", resource_url],
        "EnvironmentVariables": {"HOME": str(home), "PATH": path, "LANG": "en_US.UTF-8",
                                 "TMPDIR": tempfile.gettempdir(), "PYTHONDONTWRITEBYTECODE": "1"},
        "WorkingDirectory": str(state_dir), "RunAtLoad": True, "KeepAlive": True,
        "ThrottleInterval": 5, "ExitTimeOut": 20, "ProcessType": "Standard", "Umask": 0o077,
        "StandardOutPath": str(state_dir / "logs/hub.stdout.log"),
        "StandardErrorPath": str(state_dir / "logs/hub.stderr.log"),
    }


def launchctl(*args, check=True):
    return subprocess.run(["launchctl", *args], text=True, capture_output=True, timeout=30, check=check)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("install", "status", "restart", "stop"))
    parser.add_argument("--python", type=Path, help="Hub venv Python, required for install")
    parser.add_argument("--state-dir", type=Path, default=Path.home() / ".config/claude-fleet/hub")
    parser.add_argument("--resource-url")
    parser.add_argument("--port", type=int, default=8766)
    args = parser.parse_args(argv)
    if sys.platform != "darwin":
        parser.error("this service installer targets macOS launchd")
    target = "gui/" + str(os.getuid()) + "/" + LABEL
    home = Path.home()
    plist = home / "Library/LaunchAgents" / (LABEL + ".plist")
    try:
        if args.command == "install":
            if not args.python or not args.resource_url:
                parser.error("install requires --python and --resource-url")
            python = args.python.expanduser().absolute()
            if not python.is_file() or not os.access(python, os.X_OK):
                raise ValueError("Hub Python interpreter is not executable")
            subprocess.run([str(python), "-c", "from mcp.server import MCPServer; import jwt, uvicorn"],
                           check=True, timeout=20)
            state = args.state_dir.expanduser().absolute()
            state.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.chmod(state, 0o700)
            (state / "logs").mkdir(exist_ok=True, mode=0o700)
            data = plistlib.dumps(launch_agent(home, python, BIN / "fleet-hub.py", state, args.resource_url, args.port))
            plist.parent.mkdir(parents=True, exist_ok=True)
            if plist.exists() and plist.read_bytes() != data:
                shutil.copy2(plist, str(plist) + ".bak." + str(time.time_ns()))
            temporary = plist.with_suffix(".plist.new")
            temporary.write_bytes(data)
            temporary.chmod(0o600)
            os.replace(temporary, plist)
            if launchctl("print", target, check=False).returncode == 0:
                launchctl("bootout", target)
            launchctl("bootstrap", "gui/" + str(os.getuid()), str(plist))
            print(json.dumps({"label": LABEL, "plist": str(plist), "resource_url": args.resource_url,
                              "state_dir": str(state), "listener": "127.0.0.1:" + str(args.port)}))
        elif args.command == "restart":
            launchctl("kickstart", "-k", target)
            print("restarted " + LABEL)
        elif args.command == "stop":
            launchctl("bootout", target)
            print("stopped " + LABEL + "; plist retained for a later bootstrap/login")
        else:
            result = launchctl("print", target, check=False)
            details = [line.strip() for line in result.stdout.splitlines()
                       if line.strip().startswith(("state =", "pid =", "last exit code =", "runs ="))]
            print(json.dumps({"label": LABEL, "loaded": result.returncode == 0, "details": details,
                              "plist": str(plist)}))
            return int(result.returncode != 0)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
