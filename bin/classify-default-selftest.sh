#!/bin/bash
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
python3 - "$BIN" <<'PY'
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

source = Path(sys.argv[1])
checks = 0

with tempfile.TemporaryDirectory(prefix="fleet-classify-default-") as directory:
    root = Path(directory)
    binary = root / "bin"
    binary.mkdir()
    home = root / "home"
    home.mkdir()
    marker = root / "calls"
    completion = root / "complete"
    shutil.copy2(source / "classify-sessions.sh", binary / "classify-sessions.sh")
    shutil.copy2(source / "classify-hook.sh", binary / "classify-hook.sh")
    (binary / "fleet-lib.sh").write_text(
        'trap \'printf done > "$PROBE_DONE"\' EXIT\n'
        '[ ! -f "$HOME/classifier.conf" ] || . "$HOME/classifier.conf"\n'
        'fleet_helper_claude_auth() { printf "auth\\n" >> "$PROBE_CALLS"; }\n')
    for name in ("claude", "curl", "tmux"):
        executable = binary / name
        executable.write_text('#!/bin/sh\nprintf "%s\\n" "$0" >> "$PROBE_CALLS"\n'
                              '[ "${1:-}" != display-message ] || { printf "@1\\n"; exit 0; }\nexit 1\n')
        executable.chmod(0o700)
    environment = {
        "PATH": str(binary) + ":/usr/bin:/bin", "HOME": str(home),
        "TMPDIR": directory, "PROBE_CALLS": str(marker), "PROBE_DONE": str(completion), "CLASSIFY_SETTLE": "0",
    }

    def run(arguments, settings=None, data=""):
        return subprocess.run(["bash", str(binary / "classify-sessions.sh"), *arguments],
                              env=dict(environment, **(settings or {})), input=data,
                              capture_output=True, text=True, timeout=5)

    def check(condition, message):
        global checks
        assert condition, message
        checks += 1

    for agent in ("claude", "codex"):
        for backend in (None, "off"):
            settings = {"FLEET_AGENT": agent}
            if backend is not None:
                settings["CLASSIFY_BACKEND"] = backend
            result = run(["--window", "@1"], settings)
            check(result.returncode == 0 and not result.stdout and not result.stderr,
                  "disabled classifier must be a quiet successful no-op")
            check(not marker.exists() and not (root / "logs").exists(),
                  "disabled classifier must not authenticate, capture, call a model or create state")

    (home / "classifier.conf").write_text("CLASSIFY_BACKEND=off\n")
    result = run(["--window", "@1"], {"CLASSIFY_BACKEND": "haiku"})
    check(result.returncode == 0 and not marker.exists() and not (root / "logs").exists(),
          "resolved configuration off must precede helper work")
    (home / "classifier.conf").write_text("CLASSIFY_BACKEND=haiku\n")
    result = run(["--window", "@1"], {"CLASSIFY_BACKEND": "off"})
    check(result.returncode == 0 and "auth" in marker.read_text().splitlines(),
          "explicit configuration must retain the legacy opt-in path")
    marker.unlink()
    completion.unlink()
    result = run(["--prep-capture"], {"CLASSIFY_BACKEND": "haiku"},
                 "recap\nspinner (running Stop hooks 1/2)\n  ⎿ Tip: discarded\nkept\n")
    check(result.returncode == 0 and result.stdout == "recap\nkept\n" and not marker.exists() and not completion.exists(),
          "capture cleanup must remain usable without authenticating or inspecting a pane")
    (home / "classifier.conf").unlink()
    result = subprocess.run(["sh", str(binary / "classify-hook.sh")],
                            env=dict(environment, TMUX="fixture,1,0", TMUX_PANE="%1"),
                            capture_output=True, text=True, timeout=5)
    deadline = time.monotonic() + 5
    while not completion.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    check(result.returncode == 0 and completion.exists(), "legacy Stop entry must finish its disabled classifier")
    check(marker.read_text().splitlines() == [str(binary / "tmux")],
          "legacy Stop entry may resolve its window but must not authenticate, capture or infer")

print("classify-default-selftest: PASS (%s checks)" % checks)
PY
