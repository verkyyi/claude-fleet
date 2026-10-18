#!/bin/bash
# fleet-default-audit-selftest.sh — fresh ordinary login, four TSV metrics (#4327).
# Real fleet-install.sh -> fleet-install-apply.sh --bundle, then the host's apply
# on that sandbox package plus its marketplace (fake Claude CLI, no network).
# Selection dependencies: claude-settings.default.json, fleet-hooks-merge.py,
# fleet-agent-defaults.py, config.default.toml, CLAUDE.default.md, AGENTS.default.md,
# mcp.default.json, settings-hooks.json, codex-map.json, fleet-hooks-emit.sh,
# agent-bundle.manifest, fleet-agent-bundle.py, fleet-codex-plugins.py, marketplace.json.
# stdout is ONLY metric<TAB>integer; diagnostics/negative controls go to stderr.
# --inject-key effortLevel|outputStyle|theme|tui adds a removed default in a
# SANDBOX copy, applies the real writer, and must exit 1 with a nonzero metric.
# No daemon, live install, credentials, tmux, or existing login is touched.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 - "$BIN/.." "$@" <<'PY'
import copy
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
keys = {"effortLevel": "high", "outputStyle": "Concise", "theme": "dark", "tui": {}}
args = sys.argv[2:]
if args and (len(args) != 2 or args[0] != "--inject-key" or args[1] not in keys):
    sys.exit("usage: fleet-default-audit-selftest.sh [--inject-key effortLevel|outputStyle|theme|tui]")

# Reviewed default hooks, including the disabled classifier compatibility entry.
# A new registration must be classified before entering the default. where/refocus/worker seed
# are explicit core exceptions; ordinary-session whats-new is deliberately absent.
default_hooks = {
    "set-claude-state.sh", "bash-guard.py", "base-readonly-guard.py",
    "artifact-guard.py", "agent-guard.py", "fleet_loop_mark.py",
    "fleet-codex-session.py", "classify-hook.sh", "handoff-latch-reset-hook.sh",
    "fleet-where-hook.sh", "fleet-worker-start-hook.sh", "fleet-emit.sh",
    "refocus-hook.sh", "fleet-history.sh", "precompact-hook.sh", "session-end-hook.sh",
    # StopFailure: a turn an API error cut off goes on by itself (#4714)
    "fleet-stream-resume.sh",
}

def hooks(data):
    return [h for groups in data["hooks"].values() for g in groups for h in g["hooks"]]

def unexpected_hooks(table):
    bad = set()
    for h in table:
        command = h.get("command", "")
        # The installed client wrapper is plumbing, not a second hook.
        paths = [Path(p).name for p in shlex.split(command)
                 if p.endswith((".sh", ".py")) and Path(p).name != "fleet-hook-run.sh"]
        if h.get("type") != "command" or len(paths) != 1 or paths[0] not in default_hooks:
            bad.add(paths[0] if len(paths) == 1 else command or json.dumps(h, sort_keys=True))
    return bad

def metrics(settings, docs, codex, plugins):
    # Count BEGIN markers (blocks), never both marker lines; an orphan END is
    # also a regression and must not silently read zero.
    blocks = sum(max(t.count("<!-- fleet:agent-defaults begin -->"),
                     t.count("<!-- fleet:agent-defaults end -->")) for t in docs)
    unwanted = unexpected_hooks(hooks(settings)) | unexpected_hooks(codex)
    enabled = {p["id"] for p in plugins if p.get("enabled", True)}
    enabled.update(k for k, v in settings.get("enabledPlugins", {}).items() if v)
    return {"model_ui_settings": sum(k in settings for k in keys),
            "instruction_blocks": blocks,
            "conversation_hooks": len(unwanted),
            "enabled_plugins": len(enabled)}

def emit(result):
    for name, value in result.items():
        print("%s\t%d" % (name, value))

with tempfile.TemporaryDirectory(prefix="fleet-default-audit-selftest.") as work:
    work = Path(work)
    home = work / "home"
    for name in (".claude", ".codex"):
        (home / name).mkdir(parents=True)
    (home / ".claude.json").write_text("{}\n")
    # Deliberately don't inherit FLEET_*, CODEX_HOME, credentials, or a live pane.
    env = {"PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(work),
           "SHELL": "/bin/sh", "PYTHONDONTWRITEBYTECODE": "1",
           "CODEX_HOME": str(home / ".codex"),
           "FLEET_CONF_DIR": str(home / ".config/claude-fleet"),
           "FLEET_NODE_STATE": str(work / "node-state"),
           "FLEET_INSTALL_NO_HUB": "1", "FLEET_INSTALL_NO_NODE": "1",
           "FLEET_INSTALL_NO_RUN": "1", "FLEET_INSTALL_NO_DEPS": "1",
           "FLEET_INSTALL_SRC": root.as_uri()}

    def run(argv, diagnostics=False):
        p = subprocess.run(list(map(str, argv)), env=env, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
        if p.returncode:
            raise RuntimeError("%s: exit %s\n%s%s" % (argv[0], p.returncode, p.stdout, p.stderr))
        return p.stdout + (p.stderr if diagnostics else "")

    try:
        install = run(["sh", root / "bin/fleet-install.sh"], diagnostics=True)
        if "Agent 配置: 已装" not in install:
            raise RuntimeError("default install skipped agent configuration:\n" + install)
        installed = home / ".claude/fleet"
        settings_path = home / ".claude/settings.json"
        settings = json.loads(settings_path.read_text())
        # Prove the installation actually happened; missing everything isn't 0.
        assert settings["permissions"]["defaultMode"] == "bypassPermissions"
        assert "[mcp_servers." in (home / ".codex/config.toml").read_text()
        docs = [(home / p).read_text() if (home / p).exists() else ""
                for p in (".claude/CLAUDE.md", ".codex/AGENTS.md")]

        # Codex consumes emitted launch hooks rather than settings.json. Parse
        # this emitter's JSON-compatible TOML arrays without requiring tomllib
        # (the supported macOS Python 3.9 has none).
        emitted = run(["bash", root / "bin/fleet-hooks-emit.sh", "--target", "codex"])
        codex = []
        for line in emitted.splitlines():
            _, value = line.split("\t", 1)
            for command in re.findall(r'command\s*=\s*("(?:\\.|[^"\\])*")', value):
                codex.append({"type": "command", "command": json.loads(command)})
        for table in (hooks(settings), codex):
            for name in ("fleet-where-hook.sh", "refocus-hook.sh", "base-readonly-guard.py"):
                assert any(name in h["command"] for h in table), "missing core hook: " + name
        client = metrics(settings, docs, codex, [])

        # A fresh hosting login also runs ensure. Simulate Claude's external
        # marketplace API, recording installs/enables instead of invoking Claude.
        cli = work / "claude"
        cli.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ["HOME"]) / ".claude/audit-plugins.json"
s = json.loads(p.read_text()) if p.exists() else {"market": [], "plugins": []}
a = sys.argv[1:]
if a == ["plugin", "marketplace", "list", "--json"]: print(json.dumps(s["market"]))
elif a[:3] == ["plugin", "marketplace", "add"]:
    s["market"] = [{"name": "claude-fleet", "source": "directory", "path": a[3]}]
elif a == ["plugin", "list", "--json"]: print(json.dumps(s["plugins"]))
elif a[:2] == ["plugin", "install"]:
    s["plugins"].append({"id": a[2], "enabled": True, "version": "0.0.0"})
elif a[:2] == ["plugin", "enable"]:
    for plugin in s["plugins"]:
        if plugin["id"] == a[2]: plugin["enabled"] = True
else: sys.exit("unexpected Claude call: " + repr(a))
p.write_text(json.dumps(s))
''')
        cli.chmod(0o755)
        # Exercise the actual host apply's choice of --default flags, rather
        # than hardcoding an ensure invocation that could miss a future default.
        for directory in (".claude-plugin", "plugins"):
            shutil.copytree(root / directory, installed / directory)
        for name in ("fleet-plugins.py", "fleet-codex-plugins.py", "fleet-ui-refresh.sh", "fleet-lib.sh"):
            shutil.copy2(root / "bin" / name, installed / "bin" / name)
        empty = work / "empty"
        empty.mkdir()
        shim = work / "shim"
        shim.mkdir()
        for name in ("tmux", "launchctl", "systemctl", "sudo"):
            tool = shim / name
            tool.write_text("#!/bin/sh\nexit 1\n")
            tool.chmod(0o755)
        env.update(PATH=str(shim) + os.pathsep + env["PATH"],
                   FLEET_INSTALL_CLAUDE=str(cli), FLEET_INSTALL_LOGIN="audit")
        run(["bash", installed / "bin/fleet-install-apply.sh", "--no-daemons",
             "--root", installed, "--tree-from", empty, "--tree-to", installed])
        settings = json.loads(settings_path.read_text())
        docs = [(home / p).read_text() if (home / p).exists() else ""
                for p in (".claude/CLAUDE.md", ".codex/AGENTS.md")]
        plugins = json.loads((home / ".claude/audit-plugins.json").read_text())["plugins"]
        host = metrics(settings, docs, codex, plugins)
        # Both default paths must be clean; a host re-merge cannot conceal a
        # default that appeared in the earlier client installation.
        baseline = {name: max(client[name], host[name]) for name in client}

        def inject(key):
            # Change an actual default file, not the measured output. Use the
            # installed production merge writer on a fresh destination each time.
            defaults = json.loads((root / "conf/claude-settings.default.json").read_text())
            defaults["settings"][key] = keys[key]
            source = work / (key + "-default.json")
            target = work / (key + "-settings.json")
            source.write_text(json.dumps(defaults))
            target.write_text(json.dumps(settings))
            run([sys.executable, installed / "bin/fleet-hooks-merge.py", "defaults",
                 "--defaults", source, "--settings", target, "--config", home / ".claude.json"])
            return metrics(json.loads(target.read_text()), docs, codex, plugins)

        if args:
            result = inject(args[1])
            emit(result)
            sys.exit(1 if any(result.values()) else 0)
        emit(baseline)
        if any(baseline.values()):
            sys.exit(1)
        for key in keys:
            result = inject(key)
            assert result["model_ui_settings"] == 1, (key, result)
            print("negative\t%s\tmodel_ui_settings=1\tREJECTED" % key, file=sys.stderr)
        # Other metrics cannot stay green if a default is restored either.
        block = "<!-- fleet:agent-defaults begin -->\nclaude-fleet\n<!-- fleet:agent-defaults end -->"
        assert metrics(settings, [block, ""], codex, plugins)["instruction_blocks"] == 1
        assert metrics(settings, [block, block], codex, plugins)["instruction_blocks"] == 2
        for hook in ({"type": "command", "command": "bash ~/.claude/fleet/bin/fleet-whats-new.sh --hook"},
                     {"type": "command", "command": "bash /new-injection.sh"},
                     {"type": "prompt", "prompt": "injected text"}):
            changed = copy.deepcopy(settings)
            changed["hooks"]["UserPromptSubmit"][0]["hooks"].append(hook)
            assert metrics(changed, docs, codex, plugins)["conversation_hooks"] == 1
        assert metrics(settings, docs, codex, [{"id": "optional", "enabled": True}])["enabled_plugins"] == 1
        print("PASS\tdefault audit and negative controls", file=sys.stderr)
    except (OSError, ValueError, AssertionError, RuntimeError, subprocess.TimeoutExpired) as e:
        print("FAIL\tdefault audit: %s" % e, file=sys.stderr)
        sys.exit(1)
PY
