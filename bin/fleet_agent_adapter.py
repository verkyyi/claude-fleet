#!/usr/bin/env python3
"""The agent adapter table (T620, EPIC T580 C4): what is REALLY different between
the coding agents a fleet session can run, one row per agent.

A table, not a framework: each column holds only a fact that differs between the
agents, and every reader asks the table instead of spelling an agent's name
(`[ "$AGENT" = codex ]`). A step one agent does not have is a value saying so
(empty / 0), and the caller takes the "none" road — never a branch on the name.
The later members of T580 add their own columns here (C5 session_id/accept,
C6 deliver, C7/C8 end); none starts a second file.

Shell readers source bin/fleet-agent-adapter.sh, which is GENERATED from this
table (`fleet_agent_adapter.py --emit-sh`, byte for byte; fleet-launch-lib-selftest.sh
holds the two together). Python readers import ADAPTERS / get().

    fleet_agent_adapter.py get <agent> <column>     one value (exit 1 unknown)
    fleet_agent_adapter.py known <agent>            exit 0 when the table has it
    fleet_agent_adapter.py seed <agent> <prompt> [--root R]   the first turn in that agent's spelling
    fleet_agent_adapter.py --emit-sh                the shell copy

Columns
  launcher        the script that starts it (the one door, the Claude launcher, execs it)
  model_env       the fleet setting that pins its model (agent model names differ)
  model_flag      its model flag
  resume_flag     reopen a conversation: `<flag> <id>` (Claude --resume, Codex resume)
  fork_flag       fork one instead (Claude adds --fork-session after the resume; Codex
                  says fork in the resume's place) — see fork_replaces
  fork_replaces   1 = the fork word replaces the resume word, 0 = it follows the id
  continue_flag   reopen the newest conversation here with no id; empty = none (a new one)
  preset_sid_flag start a NEW conversation under an id the fleet chose; empty = none
  sid_window      the window option holding its conversation id
  sid_pending     the option naming the conversation a resume was opened for, until
                  its first hook (JSON with "session_id"); empty = none
  sid_thread      a last fallback id the window carries; empty = none
  seed            how a `/name args` first turn is spelled: slash = passed as typed;
                  skill = an installed `$name` skill, else the prose expansion
  seed_words      1 = the person's own words go in as the first turn and the flow rides
                  the SessionStart hook (@seed_words); 0 = the flow rides the words
  park_resume     1 = a parked session comes back into its own conversation (its
                  transcript beside the worktree); 0 = a fresh one
  ready_check     a fleet-lib function that says this login can run it; empty = none
  trust           where its "trust this folder?" answer is written (fleet-trust.sh):
                  claude-json (~/.claude.json, every spawn) | codex-toml (config.toml,
                  a trusted node; else the pane says so and goes `needs`)
  mcp             how the fleet's tool service is mounted: flags (--mcp-config files)
                  | config (-c mcp_servers.<name>=…)
  deliver         how a message is put into a live session (T626, C6): inbox = the
                  Claude process's peer inbox socket (fleet_peer_send <pid>); queue =
                  the window's app-server thread queue (fleet-codex-session.py send),
                  held while the window has not followed a /clear. Everything around
                  it — the journaled route, the held code, the peer queue, the receipt —
                  is one road: fleet_agent_deliver (fleet-lib.sh).
"""
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

COLUMNS = ("launcher", "model_env", "model_flag", "resume_flag", "fork_flag", "fork_replaces",
           "continue_flag", "preset_sid_flag", "sid_window", "sid_pending", "sid_thread",
           "seed", "seed_words", "park_resume", "ready_check", "trust", "mcp",
           "deliver")

ADAPTERS = {
    "claude": {
        "launcher": "fleet-claude.sh",   # wrap-ok: the table names it; spawners launch the wrapper
        "model_env": "FLEET_MODEL", "model_flag": "--model",
        "resume_flag": "--resume", "fork_flag": "--fork-session", "fork_replaces": "0",
        "continue_flag": "--continue", "preset_sid_flag": "--session-id",
        "sid_window": "@cc_session_id", "sid_pending": "", "sid_thread": "",
        "seed": "slash", "seed_words": "1", "park_resume": "1",
        "ready_check": "", "trust": "claude-json", "mcp": "flags",
        "deliver": "inbox",
    },
    "codex": {
        "launcher": "fleet-codex.sh", "model_env": "FLEET_CODEX_MODEL", "model_flag": "-m",
        "resume_flag": "resume", "fork_flag": "fork", "fork_replaces": "1",
        "continue_flag": "", "preset_sid_flag": "",
        "sid_window": "@codex_session_id", "sid_pending": "@codex_pending", "sid_thread": "@codex_thread_id",
        "seed": "skill", "seed_words": "0", "park_resume": "0",
        "ready_check": "fleet_codex_ready", "trust": "codex-toml", "mcp": "config",
        "deliver": "queue",
    },
}
DEFAULT = "claude"


def get(agent, column):
    """One value; KeyError for an agent or column the table does not have."""
    if column not in COLUMNS:
        raise KeyError(column)
    return ADAPTERS[agent][column]


# --- the deliver column ---------------------------------------------------------------
# One delivery outcome code for every agent (T626, C6): 0 handed over, HELD = it waits
# for the recipient (the caller queues it for the window's identity and the peer queue
# replays it), anything else = refused. Codex's old held code 4 is read one more version
# (fleet_agent_deliver; compat-1v: 下一批删).
HELD = 3


# --- the seed column ----------------------------------------------------------------
# A `/name args` first turn (issue #299) is Claude Code's own expansion. Codex has
# native skills under $CODEX_HOME/skills, invoked as `$name`; an installed plugin's
# skill is listed as <plugin>:<name> (T589). An old Codex with no skills, or a home
# not synced yet, gets the historic prose expansion: conf/codex-preamble.md + the
# command's text. A non-slash prompt passes through verbatim.
PREAMBLE = ("You are a claude-fleet WORKER running on OpenAI Codex CLI. The text below is a Claude Code "
            "skill: slash commands and Claude-only tools (AskUserQuestion, SendMessage, Artifact, "
            "/fleet-handoff, /fleet-context) are not available to you — call each mcp__fleet__<name> it "
            "names as the tool <name> on your fleet MCP server (an mcp__fleet-orch__<name> on your "
            "fleet-orch server, when you have one), never wait on the operator, and every rail "
            "(worktree-only edits, no destructive tmux, land your own PR) applies unchanged.")
_SLASH = re.compile(r"/([A-Za-z0-9_-]+)(?:\s+(.*))?\Z", re.S)


def _plugins(root, *args):
    tool = root / "bin" / "fleet-codex-plugins.py"
    try:
        r = subprocess.run([sys.executable, str(tool if tool.exists() else HERE / tool.name), *args],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return ""
    return r.stdout.strip() if r.returncode == 0 else ""


def _skills_supported():
    v = os.environ.get("FLEET_CODEX_NATIVE_SKILLS", "auto")
    if v in ("1", "true", "yes"):
        return True
    if v in ("0", "false", "no"):
        return False
    # codex-cli 0.157 exposes the model-visible skill list through this debug read;
    # an old build lacks the subcommand: use the historic expansion
    try:
        r = subprocess.run(["codex", "debug", "prompt-input", "$fleet-context"],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return False
    return "<skills_instructions>" in r.stdout


def seed(agent, prompt, root=None):
    """The first turn as this agent takes it. (text, note) — note is one line for
    the pane when a slash seed could not be expanded. root: the install whose
    commands/ and conf/ expand it (the launcher's own)."""
    root = Path(root) if root else HERE.parent
    if get(agent, "seed") != "skill":
        return prompt, ""
    m = _SLASH.match(prompt)
    if not m:
        return prompt, ""
    name, rest = m.group(1), (m.group(2) or "").lstrip()
    home = os.environ.get("CODEX_HOME") or os.path.join(os.path.expanduser("~"), ".codex")
    listed = name if os.access(os.path.join(home, "skills", name, "SKILL.md"), os.R_OK) \
        else _plugins(root, "mention", name, "--codex-home", home)
    if listed and _skills_supported():
        return "$" + listed + (" " + rest if rest else ""), ""
    f = root / "commands" / (name + ".md")
    if not os.access(f, os.R_OK):
        f = Path(_plugins(root, "command", name, "--codex-home", home) or "/nonexistent")
    try:
        body = f.read_text()
    except OSError:
        return prompt, "no commands/%s.md to expand — passing the prompt through verbatim" % name
    try:
        pre = (root / "conf" / "codex-preamble.md").read_text().rstrip("\n")
    except OSError:
        pre = ""
    return (pre or PREAMBLE) + "\n\n" + body.rstrip("\n").replace("$ARGUMENTS", rest), ""


# --- the shell copy -------------------------------------------------------------------
def emit_sh():
    q = lambda s: "'" + s.replace("'", "'\\''") + "'"
    out = ["# shellcheck shell=bash disable=SC2194  # a constant column list on purpose",
           "# fleet-agent-adapter.sh — GENERATED by bin/fleet_agent_adapter.py --emit-sh; do not edit.",
           "# The agent adapter table for shell readers (T620, EPIC T580 C4): see the .py for the",
           "# columns. fleet_agent_known <agent> · fleet_agent_get <agent> <column> · fleet_agent_or_default",
           "# <agent> (an unknown or empty one reads as %s)." % DEFAULT,
           "FLEET_AGENTS=%s" % q(" ".join(ADAPTERS)),
           "# shellcheck disable=SC2034  # read by the sourcing script",
           "FLEET_DELIVER_HELD=%d   # one held code for every agent (deliver column)" % HELD]
    for agent, row in ADAPTERS.items():
        for col in COLUMNS:
            line = "_fa_%s_%s=%s" % (agent, col, q(row[col]))
            if col == "launcher" and agent == DEFAULT:
                line += "   # wrap-ok: the table names it; spawners launch the wrapper"
            out.append(line)
    out += [
        "fleet_agent_known() { case \"${1:-}\" in ''|*[!a-z0-9_]*) return 1 ;; esac; case \" $FLEET_AGENTS \" in *\" $1 \"*) return 0 ;; esac; return 1; }",
        "fleet_agent_or_default() { if fleet_agent_known \"${1:-}\"; then printf '%%s' \"$1\"; else printf %s; fi; }" % DEFAULT,
        "fleet_agent_get() {   # <agent> <column> — prints the value; exit 1 unknown",
        "  fleet_agent_known \"${1:-}\" || return 1",
        "  case \"${2:-}\" in ''|*[!a-z0-9_]*) return 1 ;; esac",
        "  case \" %s \" in *\" $2 \"*) : ;; *) return 1 ;; esac" % " ".join(COLUMNS),
        "  eval \"printf '%s' \\\"\\${_fa_${1}_${2}}\\\"\"",
        "}",
    ]
    return "\n".join(out) + "\n"


def main(argv):
    if argv == ["--emit-sh"]:
        sys.stdout.write(emit_sh())
        return 0
    if len(argv) == 2 and argv[0] == "known":
        return 0 if argv[1] in ADAPTERS else 1
    if len(argv) == 3 and argv[0] == "get":
        try:
            print(get(argv[1], argv[2]))
        except KeyError:
            return 1
        return 0
    if argv[:1] == ["seed"] and (len(argv) == 3 or (len(argv) == 5 and argv[3] == "--root")):
        if argv[1] not in ADAPTERS:
            return 1
        text, note = seed(argv[1], argv[2], argv[4] if len(argv) == 5 else None)
        if note:
            print("fleet-%s: %s" % (argv[1], note), file=sys.stderr)
        sys.stdout.write(text)
        return 0
    print("usage: fleet_agent_adapter.py get <agent> <column> | known <agent> | seed <agent> <prompt> [--root R] | --emit-sh",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
