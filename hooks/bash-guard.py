#!/usr/bin/env python3
"""
bash-guard.py — a GENERIC PreToolUse deny-list for Bash commands, the fleet's
last line of defense.

Why it exists: a fleet runs its workers on `bypassPermissions` (issue #355), so
Claude Code never prompts before a Bash call. For the handful of commands that
are genuinely irreversible, this deny-list is the only thing between a stray
token and a destroyed working tree. It ships GENERIC rails only — the ones that
are dangerous in ANY repo (rm -rf on / ~ .git; a force-push onto the base
branch) — plus the fleet messaging rails (raw `tmux` send-keys, issue #437; a
raw `gh` issue-comment from a fleet pane, issue #483) and the fleet-delete rail
(a `tmux` kill-server / kill-session / session kill-window aimed at a FLEET's
server, issue #1841 — judged by bin/tmux-shim/tmux), which self-scope to fleet
context. Operator-specific rails (prod hosts, DB/k8s guards) live in a local
overlay, `~/.claude/hooks/bash-guard-local.py`, that this skeleton runs if
present and NEVER ships (see the OVERLAY section at the bottom).

Register it (matcher "Bash") — see hooks/settings-hooks.json. It is merged into
`~/.claude/settings.json`, so it runs everywhere: worker, operator hub, scratch.

Contract (Claude Code hooks):
  - stdin: JSON with {tool_name, tool_input:{command,...}}
  - exit 0  -> allow
  - exit 0 + a hookSpecificOutput JSON on stdout -> allow a REWRITTEN command
  - exit 2  -> BLOCK; stderr is shown to the model so it can course-correct
  - ANY error here -> exit 0 (fail OPEN) so a guard bug never bricks a session.

WHY REWRITE BEATS DENY (#528). A PreToolUse deny kills the WHOLE Bash
call. Every messaging-rail block observed in the fleet's transcripts (56 of
them) hit a COMPOUND command — median 1.2 KB, up to 34 statements — so a batch
that commits, probes, writes files and only THEN posts a report lost all of it,
including hand-authored report bodies that had to be regenerated. Claude Code
lets a PreToolUse hook return `updatedInput` instead, so the messaging rails now
REWRITE the one offending statement onto the sanctioned wrapper and let the
other 33 run. A rail that can repair the command has no reason to throw work
away; the genuinely irreversible rails (rm -rf, force-push) still deny.

FALSE-POSITIVE DISCIPLINE — the hard-won engineering this skeleton keeps:
  * QUOTED AND HEREDOC TEXT IS DATA, NOT CODE. The command is MASKED before
    matching (see _mask): single-quoted spans, double-quoted spans and heredoc
    bodies are blanked, while `$(...)`/backtick substitutions inside them stay
    live. Without this a *document* whose line happens to begin with a guarded
    command — a runbook, a test fixture, a report quoting the rail itself — is
    denied though nothing would ever run. Masking preserves LENGTH, so every
    offset still indexes the original command and a rewrite can splice it.
  * The command is split into statement SEGMENTS on ; \\n && || | AFTER masking,
    so tokens from a commit message or an unrelated statement can't combine
    across segments (e.g. "-rf" in a message + "master" elsewhere).
  * Rules match the git/tmux SUBCOMMAND (a real `git push`), not just the word
    "push" appearing anywhere in the line. Command position is read from the
    MASKED text (a quoted "send-keys" is an argument, not a subcommand); a
    dangerous ARGUMENT is read from the raw text so quoting can't hide it.
  * Short-option bundles are matched as whole flag tokens (-rf, -Rf), so a
    dangerous letter inside `-print0` or a path does NOT trip a flag rule.
  * The messaging rails self-scope to the ACTUAL hazard: the issue-comment rail
    fires only when the target issue has a LIVE BOUND WORKER to be relayed
    into, and the send-keys rail only when the target tmux server is a FLEET
    server (an isolated `-L scratch` / `-S /tmp/...` test socket — the idiom
    CLAUDE.md prescribes for testing tmux tooling — is not a hazard).
  * The guard fails OPEN on any internal error — a deny-list bug must never take
    every session down with it.
"""
import sys, re, json, os, shlex, subprocess

# The rewritten command, if a rail repaired one; emitted as updatedInput.
_TOOL_INPUT = {}
_REWRITE_NOTES = []

WRAPPER = "~/.claude/fleet/bin/fleet-comment.sh"


def allow():
    sys.exit(0)


def allow_with(command, tool_input):
    """Allow a REWRITTEN command via the PreToolUse updatedInput contract."""
    updated = dict(tool_input)
    updated["command"] = command
    sys.stdout.write(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "permissionDecisionReason":
                "bash-guard: rewritten onto the sanctioned fleet wrapper — "
                + "; ".join(_REWRITE_NOTES),
            "updatedInput": updated,
        }
    }))
    sys.exit(0)


def block(reason):
    sys.stderr.write(
        "⛔ BLOCKED by ~/.claude/fleet/hooks/bash-guard.py: %s\n"
        "This command is irreversible and is denied even in bypass mode.\n"
        "If it is truly intended, run it yourself in a terminal, or add an\n"
        "exception in ~/.claude/hooks/bash-guard-local.py.\n"
        % reason
    )
    sys.exit(2)


# --- MASKING -----------------------------------------------------------------
# Blank out every span that is DATA rather than code, preserving length so all
# offsets keep indexing the original command. Single quotes, double quotes and
# heredoc bodies are data; a `$(...)` or backtick substitution inside them is
# code again and is left live (and rescanned, so a heredoc nested in a command
# substitution — the `--body "$(cat <<'EOF' … EOF)"` idiom — is masked too).
def _mask(cmd):
    out = list(cmd)
    n = len(cmd)

    def blank(a, b):
        # Newlines are blanked too — that is the point: a masked heredoc body must
        # not segment, so its lines fuse into the statement that opened it.
        for k in range(max(a, 0), min(b, n)):
            out[k] = " "

    def read_heredoc_tag(i):
        """At `<<`: return (next_i, delimiter, strip_tabs) or (next_i, None, False)."""
        j = i + 2
        strip = False
        if j < n and cmd[j] == "-":
            strip = True
            j += 1
        while j < n and cmd[j] in " \t":
            j += 1
        if j < n and cmd[j] in "'\"":
            q = cmd[j]
            k = cmd.find(q, j + 1)
            if k < 0:
                return j, None, False
            return k + 1, cmd[j + 1:k], strip
        m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", cmd[j:])
        if not m:
            return j, None, False
        return j + m.end(), m.group(0), strip

    def consume_heredocs(i, pending):
        """At the newline that opens the bodies. Blank each body; return new i."""
        pos = i + 1
        for delim, strip in pending:
            start = pos
            while True:
                eol = cmd.find("\n", pos)
                line = cmd[pos:eol if eol >= 0 else n]
                probe = line.lstrip("\t") if strip else line
                if probe.rstrip("\r") == delim:
                    blank(start, pos)          # body only; keep the terminator
                    pos = (eol + 1) if eol >= 0 else n
                    break
                if eol < 0:                    # unterminated heredoc
                    blank(start, n)
                    pos = n
                    break
                pos = eol + 1
        del pending[:]
        return pos

    i = 0
    stack = []          # 'dq' (double quote) | 'sub' ($( … ) or ` … `)
    pending = []        # heredoc delimiters awaiting their body
    while i < n:
        c = cmd[i]
        top = stack[-1] if stack else None
        if c == "\\" and i + 1 < n:
            if top == "dq":
                blank(i, i + 2)
            i += 2
            continue
        if c == "$" and i + 1 < n and cmd[i + 1] == "(":
            stack.append("sub")
            i += 2
            continue
        if c == "`":
            if top == "sub":
                stack.pop()
            else:
                stack.append("sub")
            i += 1
            continue
        if c == ")" and top == "sub":
            stack.pop()
            i += 1
            continue
        if top == "dq":
            if c == '"':
                stack.pop()
            else:
                blank(i, i + 1)
            i += 1
            continue
        if c == '"':
            stack.append("dq")
            i += 1
            continue
        if c == "'":
            j = cmd.find("'", i + 1)
            if j < 0:
                j = n
            blank(i + 1, j)
            i = j + 1
            continue
        if c == "<" and cmd.startswith("<<", i) and not cmd.startswith("<<<", i):
            i, delim, strip = read_heredoc_tag(i)
            if delim is not None:
                pending.append((delim, strip))
            continue
        if c == "\n" and pending:
            i = consume_heredocs(i, pending)
            continue
        i += 1
    return "".join(out)


def _segments(masked):
    """Statement spans (start, end) of the masked command."""
    spans, pos = [], 0
    for m in re.finditer(r"&&|\|\||\||;|\n", masked):
        spans.append((pos, m.start()))
        pos = m.end()
    spans.append((pos, len(masked)))
    return [(a, b) for a, b in spans if masked[a:b].strip()]


# A short-option bundle (e.g. -rf, -Rf) containing letter `c`; anchored so only
# real flag tokens match and a trailing non-letter (e.g. -print0) does NOT.
def has_short_flag(seg, c):
    return re.search(r"(?:^|\s)-[a-zA-Z]*" + c + r"[a-zA-Z]*(?=\s|$)", seg) is not None


# The segment's COMMAND (after optional `sudo` / `VAR=val` prefixes) is `name`.
# Anchoring here means a dangerous word inside a message, an echo, or another
# command's arguments cannot trigger a rule.
def cmd_is(seg, name):
    return re.match(r"\s*(?:sudo\s+|\w+=\S+\s+)*" + name + r"\b", seg) is not None


# Base branches a force-push must never touch. master/main are the near-universal
# defaults; a fleet that runs off another base has FLEET_BASE_BRANCH in its CONF,
# and that is where it must be read from (issue #561): nothing exports the conf
# into a pane's environment, so the env is only honoured as an explicit override
# (a selftest seam, or an operator who exports it by hand). Resolved via fleet-lib
# for the pane's session, the way base-readonly-guard.py resolves FLEET_MAIN — and
# only on the force-push path (this is called after the `git push` regex matched),
# so the bash subprocess stays off the per-command hot path. Any failure → the
# defaults alone (fail open, as everywhere in this rail).
def _fleet_base_branch():
    bb = os.environ.get("FLEET_BASE_BRANCH", "").strip()
    if bb or not os.environ.get("TMUX"):
        return bb
    lib = os.path.expanduser(
        os.environ.get("FLEET_LIB", "~/.claude/fleet/bin/fleet-lib.sh")
    )
    if not os.path.exists(lib):
        return ""
    try:
        out = subprocess.run(
            ["bash", "-c",
             'source "$1" >/dev/null 2>&1 || exit 9; '
             'S=$(fleet_current_session 2>/dev/null); '
             '[ -n "$S" ] && fleet_load_conf "$S" >/dev/null 2>&1; '
             'printf "%s" "${FLEET_BASE_BRANCH:-}"',
             "_", lib],
            capture_output=True, text=True, timeout=5,
        )
        return out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        return ""


def _base_branches():
    names = {"master", "main"}
    bb = _fleet_base_branch()
    if bb:
        names.add(bb)
    return names


# --- ESCAPE HATCHES ----------------------------------------------------------
# A hatch is COMMAND-WIDE, not segment-local (#528). The old rails read the
# inline `VAR=1` prefix off the one segment it sat on, so on a compound command
# the operator had to repeat it on every offending statement and an `export` did
# nothing at all — the block message said "prefix it" and the retry was denied
# again. Now: the process environment counts, and an inline assignment anywhere
# in the command counts for the whole command.
def _hatched(masked_cmd, var):
    if os.environ.get(var, "").strip() == "1":
        return True
    return re.search(r"(?:^|[\s;&|(])" + var.lower() + r"=1(?=\s|$)",
                     masked_cmd.lower()) is not None


def _conf_dir():
    return os.environ.get("FLEET_CONF_DIR", "").strip() or os.path.expanduser(
        "~/.config/claude-fleet"
    )


def _is_fleet_session(sess):
    """True iff <sess> names a fleet — fleet-up writes its conf; an ad-hoc tmux
    session on the default socket is NOT a fleet."""
    if not sess:
        return False
    cd = _conf_dir()
    return os.path.isfile(os.path.join(cd, "fleets", sess, "conf")) or os.path.isfile(
        os.path.join(cd, sess + ".conf")
    )


def _current_session():
    if not os.environ.get("TMUX"):
        return ""
    cmd = ["tmux", "display-message", "-p"]
    pane = os.environ.get("TMUX_PANE", "")
    if pane:
        cmd += ["-t", pane]
    cmd.append("#{session_name}")
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""


# Is this hook running inside a FLEET pane? True when the seat exports FLEET_MAIN
# (free), else when the pane's tmux session owns a fleet conf. Only consulted
# after a rule's cheap regex already matched, so the tmux subprocess stays off
# the hot path. Any failure ⇒ False (fail open — a non-fleet session keeps raw gh).
def _in_fleet_pane():
    if os.environ.get("FLEET_MAIN", "").strip():
        return True
    return _is_fleet_session(_current_session())


# Does <issue> have a LIVE BOUND WORKER on this fleet's repo — i.e. is there
# anything for an unmarked comment to be relayed INTO? This is the actual hazard
# the rail guards (issue #483); without a bound worker a raw comment is inert.
# Reuses the bridge's own resolver so the guard and the relay agree on what
# "bound" means. Any failure ⇒ True (assume the hazard and rewrite: the rewrite
# is lossless, so guessing wrong costs nothing).
def _issue_has_live_worker(issue):
    lib = os.path.expanduser(
        os.environ.get("FLEET_LIB", "~/.claude/fleet/bin/fleet-lib.sh")
    )
    bridge = os.path.join(os.path.dirname(lib), "fleet-issue-bridge.sh")
    if not (os.path.exists(lib) and os.path.exists(bridge)):
        return True
    # Resolve the repo via fleet-lib, then ask the BRIDGE ITSELF (a read-only
    # side door — sourcing the bridge would run its dispatch and fire a poll tick).
    script = (
        'source "$1" >/dev/null 2>&1 || exit 9\n'
        'S=$(fleet_current_session 2>/dev/null)\n'
        'R=$(fleet_repo_cached "$S" 2>/dev/null)\n'
        '[ -n "$R" ] || R="${FLEET_REPO:-}"\n'
        '[ -n "$R" ] || exit 9\n'
        'bash "$2" --find-window "$3" "$R" 2>/dev/null\n'
    )
    try:
        out = subprocess.run(
            ["bash", "-c", script, "_", lib, bridge, str(issue)],
            capture_output=True, text=True, timeout=10,
        )
    except Exception:
        return True
    if out.returncode == 9:
        return True
    return bool(out.stdout.strip())


# --- RULES -------------------------------------------------------------------
def check_segment(masked_seg, raw_seg, orig_seg, span, masked_cmd):
    """One statement. `masked_seg` is the lower-cased MASKED text (command
    position is read here, so quoted data cannot pose as a subcommand);
    `raw_seg` is the lower-cased ORIGINAL (a dangerous ARGUMENT is read here, so
    quoting cannot hide it); `orig_seg` keeps the original CASE and is the only
    text a rewrite may splice back — lower-casing a report body would corrupt it.
    Deny via block(); repair via _rewrite()."""

    # 1) Force-push touching the base branch — must be an actual `git push`.
    if re.match(r"\s*(?:sudo\s+|\w+=\S+\s+)*git\b(?:\s+(?:-\S+|\S+=\S+))*\s+push\b", masked_seg):
        branch_re = r"\b(?:%s)\b" % "|".join(re.escape(b.lower()) for b in _base_branches())
        forced = (
            "--force" in raw_seg
            or "--force-with-lease" in raw_seg
            or has_short_flag(raw_seg, "f")              # -f / -fv etc.
            or re.search(r"\+\S*" + branch_re, raw_seg)  # +master refspec
        )
        if forced and re.search(branch_re, raw_seg):
            block("force-push targeting the base branch (base = shared truth)")

    # 2) rm -rf on root / home / a .git dir — must be an `rm` command (so `git rm`
    #    is exempt), with real recursive AND force flags and a bare dangerous target.
    if cmd_is(masked_seg, "rm"):
        recursive = ("--recursive" in raw_seg) or has_short_flag(raw_seg, "r")
        force     = ("--force" in raw_seg)     or has_short_flag(raw_seg, "f")
        if recursive and force:
            # bare dangerous target as its own arg — tolerates a trailing slash,
            # a `*`, and surrounding quotes ("/", "$HOME", ~/); but NOT a subpath
            # (/usr/..., $HOME/.cache) which stays allowed.
            if re.search(r"(?:^|\s|[\x22\x27])(?:/|~|\$home|\$\{home\})/?\*?[\x22\x27]?(?:\s|$)", raw_seg):
                block("rm -rf targeting filesystem root or $HOME")
            if re.search(r"(?:^|\s)\S*\.git(?:\s|/|$)", raw_seg):
                block("rm -rf touching a .git directory (use `git worktree remove`)")

    # 3) Inter-agent messaging must go through the issue-bridge, not a raw
    #    send-keys into a live Claude TUI — send-keys is racy (bracketed-paste
    #    swallows the Enter). SELF-SCOPED TO FLEET SERVERS (#528): the rail
    #    exists to protect a live worker's TUI, and a tmux server that hosts no
    #    fleet has no TUI to corrupt. `-S <path>` is by definition a custom socket
    #    (fleet tooling always uses `-L <session>`) and `-L <label>` is a fleet
    #    only when that label owns a fleet conf — so the isolated-socket test
    #    idiom CLAUDE.md prescribes ("test tmux tooling on an isolated socket —
    #    tmux -L scratch …") stops being collateral: 12 of the 13 blocks this
    #    rail produced were exactly that. FLEET_ALLOW_SENDKEYS=1 remains the
    #    hatch for driving a REAL fleet pane from sanctioned plumbing.
    if cmd_is(masked_seg, "tmux") and re.search(r"(?:^|\s)send-keys(?=\s|$)", masked_seg):
        if not _hatched(masked_cmd, "FLEET_ALLOW_SENDKEYS") and _sendkeys_targets_fleet(masked_seg):
            block(
                "inter-agent messaging must go through `fleet-comment.sh "
                "--to-worker` (the issue-bridge), not a raw tmux send-keys into a "
                "LIVE FLEET pane (bracketed-paste eats the Enter). An isolated "
                "test socket (-S <path>, or -L <label> with no fleet conf) is not "
                "guarded. Set FLEET_ALLOW_SENDKEYS=1 (env or inline, anywhere in "
                "the command) only for sanctioned fleet plumbing"
            )

    # 3b) A delete aimed at a FLEET's tmux server (issue #1841, EPIC #1851 C2):
    #    kill-server / kill-session / killing a session's window, on `-L <fleet>`,
    #    `-S` to its socket or the ambient fleet server. The session's PATH already
    #    leads to bin/tmux-shim, which refuses it at run time; this is the same
    #    rule read BEFORE the statement runs — so an absolute `/opt/…/tmux` or a
    #    PATH a snapshot reordered is caught too — and it asks the shim itself
    #    (FLEET_TMUX_SHIM_CHECK=1), so the two cannot drift. A test server
    #    (-L scratch, a -S path) passes; FLEET_ALLOW_TMUX_DESTROY=1 is the hatch.
    #    A login shell (`bash -lc '…'`, Codex's `zsh -lc`) runs macOS path_helper,
    #    which puts /opt/homebrew/bin back in front of the shim — so the quoted
    #    script of a `<shell> -c` is read here too (raw_seg: quoting hides nothing).
    if re.search(r"(?:^|[\s'\x22;&|(])(?:kill-(?:ser|ses|w|p)\S*|killw|killp)(?=[\s'\x22;&|)]|$)", raw_seg) \
            and re.search(r"(?:^|[\s/'\x22;&|(])tmux(?=\s)", raw_seg) \
            and not _hatched(masked_cmd, "FLEET_ALLOW_TMUX_DESTROY"):
        why = _tmux_destroy_refused(orig_seg)
        if why:
            block(why)

    # 4) A raw `gh` issue-comment from a FLEET pane is REWRITTEN onto
    #    fleet-comment.sh (issue #483, repaired-not-denied in #528). Every fleet
    #    actor comments as the SAME gh account, so the issue-bridge cannot tell a
    #    worker's own unmarked comment from a real human handback — an unmarked
    #    comment on a bound issue passes the trust gate and is relayed BACK into
    #    that worker as a spurious self-turn. The wrapper stamps the no-relay /
    #    provenance markers the bridge filters on, so provenance must be stamped
    #    at the SOURCE.
    #
    #    Two changes make that cost nothing. (a) SCOPE: the rail fires only when
    #    the target issue actually has a live bound worker — of the 43 blocks it
    #    produced, 36 came from scratch panes with no binding at all and only ONE
    #    was the pane's own issue, so it was denying overwhelmingly inert
    #    commands. (b) REPAIR: instead of killing a 34-statement batch, the one
    #    offending statement is rewritten onto the wrapper (defaulting to --note,
    #    the record-only mode) and everything else runs untouched.
    m = re.match(r"\s*(?:sudo\s+|\w+=\S+\s+)*gh\b((?:\s+(?:-\S+|\S+=\S+))*)\s+issue\s+comment\b",
                 masked_seg)
    if m:
        if _hatched(masked_cmd, "FLEET_ALLOW_RAW_COMMENT") or not _in_fleet_pane():
            return
        issue = _comment_issue_number(masked_seg[m.end():])
        if issue is None:
            block(
                "raw gh issue-comment from a fleet pane, and the issue could not "
                "be read as a plain number to rewrite it. Post through "
                "`~/.claude/fleet/bin/fleet-comment.sh <issue> --note --body …` "
                "(or --to-worker to deliberately drive the bound worker)"
            )
        if not _issue_has_live_worker(issue):
            return          # nothing bound to relay into ⇒ the comment is inert
        _rewrite(span, _wrapper_form(orig_seg, masked_seg),
                 "#%s has a live bound worker; stamped --note (no-relay) so it "
                 "cannot relay back as a spurious turn" % issue)

    # 5) A pkill that would sweep up other sessions' processes. Every fleet pane
    #    runs as the same user, so a loose pattern is a fleet-wide kill: on
    #    2026-10-03 a worker's `pkill -f "cat" -P $$` closed 16 sibling windows.
    #    BSD pkill (macOS) stops option parsing at the first pattern, so the
    #    trailing `-P $$` became two more PATTERNS, and the pattern `cat` matched
    #    every worker's `zsh -c '… "$(cat task_issue-N.txt)"'` pane shell.
    #    FLEET_ALLOW_BROAD_PKILL=1 is the hatch.
    if (cmd_is(masked_seg, "pkill") or cmd_is(masked_seg, "killall")) \
            and not _hatched(masked_cmd, "FLEET_ALLOW_BROAD_PKILL"):
        why = _broad_kill(orig_seg)
        if why:
            block(why + " — every fleet pane runs as this user, so this can kill "
                  "OTHER sessions. Kill by pid (`kill <pid>`, `kill %1`), put every "
                  "option BEFORE the pattern, and give -f a specific pattern or a "
                  "-P/-g/-t scope. FLEET_ALLOW_BROAD_PKILL=1 if truly intended")

    # Operator-specific rails, if the local overlay defines any (never shipped).
    _run_overlay(masked_seg)


# pkill options that take a value (BSD and procps), as a separate token or glued.
_PKILL_VALUE_OPTS = set("FGMNPUcgjstu")
# Options that confine the match to a known process set. NOT -u/-U/-G: every
# fleet pane runs as the one user, so a user/group filter narrows nothing.
_PKILL_SCOPE_OPTS = set("FPgjst")
# Process names whose killall takes down fleet panes (their shells / the TUI).
_KILLALL_FLEET = {"claude", "tmux", "zsh", "bash", "sh", "login"}


def _broad_kill(orig_seg):
    """Why this pkill/killall statement is too broad, or None."""
    try:
        toks = shlex.split(orig_seg, comments=False)
    except ValueError:
        return None
    while toks and (toks[0] == "sudo" or re.match(r"\w+=", toks[0])):
        toks.pop(0)
    if not toks:
        return None
    name, args = os.path.basename(toks[0]), toks[1:]
    if name == "killall":
        if any(a == "-m" or (a.startswith("-") and not a.startswith("--") and "m" in a[1:]
                             and a[1:].isalpha() and a[1:].islower()) for a in args):
            return "killall -m (regex over every process name)"
        hit = [a for a in args if not a.startswith("-") and a.lower() in _KILLALL_FLEET]
        return ("killall %s" % hit[0]) if hit else None
    full = scoped = False
    patterns = []
    i = 0
    while i < len(args):
        a = args[i]
        if patterns:
            if a.startswith("-") and len(a) > 1:
                return ("pkill option %r AFTER the pattern — BSD/macOS pkill reads it "
                        "as another pattern, not an option" % a)
            patterns.append(a)
        elif a == "--":
            patterns.extend(args[i + 1:])
            break
        elif a.startswith("--"):
            opt = a[2:].split("=", 1)[0]
            full = full or opt == "full"
            scoped = scoped or opt in ("parent", "pgroup", "session", "terminal",
                                       "pidfile")
            if "=" not in a and opt in ("signal", "parent", "pgroup", "session",
                                        "terminal", "euid", "uid", "group", "pidfile",
                                        "ns", "nslist"):
                i += 1
        elif a.startswith("-") and len(a) > 1:
            body = a[1:]
            if body.isdigit() or (len(body) > 1 and body.isupper()):
                pass                                  # a signal: -9 / -HUP / -SIGKILL
            else:
                for j, c in enumerate(body):
                    full = full or c == "f"
                    scoped = scoped or c in _PKILL_SCOPE_OPTS
                    if c in _PKILL_VALUE_OPTS:
                        if j == len(body) - 1:
                            i += 1                    # value is the next token
                        break                         # value glued on (-P123)
        else:
            patterns.append(a)
        i += 1
    if len(patterns) > 1:
        return "pkill given several patterns %r (each one matches on its own)" % patterns
    if full and not scoped and patterns:
        core = re.sub(r"[\\^$.*+?()\[\]{}|]", "", patterns[0])
        if len(core) < 8:
            return "pkill -f %r matches any command line containing it" % patterns[0]
    return None


_TMUX_SHIM = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "tmux-shim", "tmux")


_SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}


def _tmux_destroy_refused(orig_seg, depth=0):
    """The shim's refusal for this `tmux … kill-*` statement — or for one inside
    the script of a `<shell> -c '…'` — or None (allowed, not a tmux command, or
    anything unreadable — fail open: the shim on PATH still stands at run time)."""
    try:
        toks = shlex.split(orig_seg, comments=False)
    except ValueError:
        return None
    if depth < 3 and toks and os.path.basename(toks[0]) in _SHELLS:
        for k, t in enumerate(toks[1:], 1):
            if re.fullmatch(r"-[a-z]*c[a-z]*", t) and k + 1 < len(toks):
                for part in re.split(r"(?:;|&&|\|\||\||&|\n)+", toks[k + 1]):
                    why = _tmux_destroy_refused(part, depth + 1)
                    if why:
                        return why
                break
        return None
    env = dict(os.environ)
    while toks and (toks[0] in ("sudo", "command", "exec", "env", "nohup")
                    or re.match(r"[A-Za-z_]\w*=", toks[0])):
        t = toks.pop(0)
        if "=" in t and t not in ("sudo", "command", "exec", "env", "nohup"):
            k, v = t.split("=", 1)
            env[k] = v
    if not toks or os.path.basename(toks[0]) != "tmux" or not os.access(_TMUX_SHIM, os.X_OK):
        return None
    env["FLEET_TMUX_SHIM_CHECK"] = "1"
    env.pop("FLEET_ALLOW_TMUX_DESTROY", None)
    try:
        r = subprocess.run([_TMUX_SHIM] + toks[1:], env=env, capture_output=True,
                           text=True, timeout=10)
    except Exception:
        return None
    if r.returncode != 1:
        return None
    return (r.stderr.strip() or "a delete aimed at a fleet's tmux server")


def _sendkeys_targets_fleet(masked_seg):
    """True iff the send-keys goes to a tmux server that hosts a fleet."""
    m = re.search(r"(?:^|\s)-s\s+(\S+)", masked_seg)
    if m:
        return False                      # a custom socket path is never a fleet's
    m = re.search(r"(?:^|\s)-l\s+(\S+)", masked_seg)
    if m:
        return _is_fleet_session(m.group(1).strip("'\""))
    return _in_fleet_pane()               # the ambient server ($TMUX)


def _comment_issue_number(rest):
    """The issue positional of `gh issue comment …`, or None if it is not a bare
    number (a URL would be mangled by the wrapper's digit-strip, so refuse)."""
    toks = rest.split()
    skip_val = {"--body", "-b", "--body-file", "-f", "--repo", "-r", "--editor"}
    i = 0
    while i < len(toks):
        t = toks[i]
        if t.startswith("-"):
            if "=" not in t and t.lower() in skip_val:
                i += 2
            else:
                i += 1
            continue
        return t if t.isdigit() else None
    return None


def _wrapper_form(orig_seg, masked_seg):
    """`gh [flags] issue comment …` → `<wrapper> --note …`, arguments untouched.

    Spliced from `orig_seg` (original case, original quoting) so the body survives
    verbatim; the match offsets come from the masked text, which is the same
    length. gh's own flags on the `gh` command itself (`gh --repo …`) are dropped
    with the head — the wrapper takes `--repo` as its own flag, which the argument
    tail already carries when it was written that way."""
    m = re.match(r"(\s*)((?:sudo\s+|\w+=\S+\s+)*)gh\b(?:\s+(?:-\S+|\S+=\S+))*\s+issue\s+comment\b",
                 masked_seg)
    lead, prefix = m.group(1), orig_seg[m.end(1):m.end(2)]
    return "%s%s%s --note%s" % (lead, prefix, WRAPPER, orig_seg[m.end():])


_REWRITES = []


# --- SHARED DEPENDENCIES (issue #885) ---------------------------------------
# fleet-deps-link.sh makes a new worktree's node_modules a SYMLINK into the base
# checkout's. An install / add / remove there would write straight through the
# link into the base's live tree — every other worktree borrowing it included.
# So a package-manager command that mutates node_modules, run in (or above) a
# linked directory, is denied with the one sanctioned way out: --unlink first.
# Self-scoping: only a worktree whose git dir carries the fleet-deps-links
# manifest can trip it, so every other repo and session pays one regex.
_PM_MUTATING = {
    "npm":  {"install", "i", "in", "ins", "inst", "insta", "instal", "isnt", "isntall",
             "add", "ci", "clean-install", "ic", "install-clean", "isntall-clean",
             "install-test", "it", "install-ci-test", "cit", "clean-install-test", "sit",
             "uninstall", "un", "unlink", "remove", "rm", "r", "update", "up", "upgrade",
             "udpate", "dedupe", "ddp", "prune", "rebuild", "rb", "link", "ln"},
    "pnpm": {"install", "i", "add", "remove", "rm", "uninstall", "un", "update", "up",
             "upgrade", "prune", "rebuild", "rb", "link", "ln", "unlink", "dedupe", "import"},
    "yarn": {"", "install", "add", "remove", "upgrade", "up", "link", "unlink", "dedupe",
             "import"},
    "bun":  {"install", "i", "add", "a", "remove", "rm", "update", "link", "unlink"},
}
_PM_DIR_FLAGS = {"--prefix", "-c", "--dir", "--cwd"}
_PM_RE = re.compile(r"\s*\(*\s*(?:sudo\s+|\w+=\S+\s+)*(npm|pnpm|yarn|bun)(?=\s|$)")


def _unq(tok):
    return tok.strip("\"'").rstrip(")")


def _expand(path, cwd):
    path = os.path.expanduser(_unq(path))
    return os.path.normpath(path if os.path.isabs(path) else os.path.join(cwd, path))


def _cd_target(masked_seg, orig_seg, cwd):
    """If the segment is `cd <dir>` / `pushd <dir>`, the new cwd; else None."""
    m = re.match(r"\s*\(*\s*(?:cd|pushd)(?:\s+(\S+))?\s*\)*\s*$", masked_seg)
    if not m:
        return None
    if not m.group(1):
        return os.path.expanduser("~")
    return _expand(orig_seg[m.start(1):m.end(1)], cwd)


def _worktree_links(start):
    """(worktree_root, [linked rel dirs]) for the worktree holding <start>, or None."""
    d = start
    while True:
        g = os.path.join(d, ".git")
        if os.path.isfile(g):
            with open(g) as fh:
                line = fh.readline().strip()
            if not line.startswith("gitdir:"):
                return None
            gd = line[len("gitdir:"):].strip()
            gd = gd if os.path.isabs(gd) else os.path.join(d, gd)
            mf = os.path.join(gd, "fleet-deps-links")
            if not os.path.isfile(mf):
                return None
            with open(mf) as fh:
                links = [l.strip() for l in fh if l.strip()]
            return (d, links) if links else None
        if os.path.isdir(g):
            return None                  # a main checkout: fleet never links there
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def check_shared_deps(masked_seg, orig_seg, cwd):
    m = _PM_RE.match(masked_seg)
    if not m:
        return
    pm = m.group(1)
    toks = orig_seg[m.end():].split()
    eff, sub, i = cwd, None, 0
    while i < len(toks):
        t = _unq(toks[i]).lower()
        if t in ("-g", "--global", "--location=global"):
            return                       # a global install never touches the worktree
        if t in _PM_DIR_FLAGS and i + 1 < len(toks):
            eff = _expand(toks[i + 1], cwd)
            i += 2
            continue
        if "=" in t and t.split("=", 1)[0] in _PM_DIR_FLAGS:
            eff = _expand(toks[i].split("=", 1)[1], cwd)
            i += 1
            continue
        if t.startswith("-"):
            i += 1
            continue
        if sub is None:
            sub = t
        i += 1
    if (sub or "") not in _PM_MUTATING[pm]:
        return
    wl = _worktree_links(eff)
    if not wl:
        return
    root, links = wl
    # The project the command acts on: the nearest package.json at or above eff.
    proj = eff
    while proj != root and not os.path.isfile(os.path.join(proj, "package.json")):
        up = os.path.dirname(proj)
        if up == proj:
            break
        proj = up
    prel = os.path.relpath(proj, root)
    if prel.startswith(".."):
        return
    hit = []
    for l in links:
        nm = os.path.normpath(os.path.join(l, "node_modules"))
        if (prel == "." or l == prel or l.startswith(prel + "/")
                or prel == nm or prel.startswith(nm + "/")):
            hit.append(l)
    if not hit:
        return
    sys.stderr.write(
        "⛔ BLOCKED by ~/.claude/fleet/hooks/bash-guard.py: `%s %s` here would write "
        "into SHARED dependencies.\n"
        "node_modules in %s is a link into the base checkout (fleet-deps-link, issue "
        "#885) — installing through it changes the base's tree and every worktree "
        "borrowing it.\n"
        "这里是共享依赖，先 `~/.claude/fleet/bin/fleet-deps-link.sh --unlink %s` "
        "(removes the LINK only), then install as usual.\n"
        % (pm, sub or "", ", ".join(hit), os.path.join(root, prel) if prel != "." else root)
    )
    sys.exit(2)


def _rewrite(span, new_text, note):
    _REWRITES.append((span[0], span[1], new_text))
    _REWRITE_NOTES.append(note)


# --- HEAVY-JOB QUEUE (issue #1295) ------------------------------------------
# A dozen sessions pushing at once — each push running a full gate that fans out
# `xargs -P 5` — drag the shared machine down together (EPIC #1291). So a heavy
# statement is PREFIXED with bin/fleet-heavy.sh, a machine-wide semaphore (3
# slots across every login), the same rewrite-not-refuse move as #483/#528:
#     cd x && git push origin b | tail   →   cd x && <fleet-heavy.sh> --label git-push --wait 60 -- git push origin b | tail
# Prefix only: the statement's own text, quoting, heredoc and redirections are
# untouched (they attach to the wrapper, whose child inherits them). Scoped to
# FLEET panes; FLEET_HEAVY=0 (env, global settings, or inline) turns it off.
# The default regex is mirrored from fleet-lib.sh's FLEET_HEAVY_RE_DEFAULT
# (fleet-heavy-selftest.sh holds the two in lockstep).
HEAVY_RE_DEFAULT = (r"git\b(?:\s+(?:-[Cc]\s+\S+|-\S+))*\s+push\b"
                    r"|(?:python3?\s+-m\s+)?pytest\b"
                    r"|npm\s+(?:run\s+)?test\b"
                    r"|(?:(?:ba|z)?sh\s+)?(?:\S*/)?(?:run-selftests|local-prod-gate|pre-pr)\.sh\b")
# LIGHT beats heavy (issue #1313): a test run aimed at one file / node / name
# filter is seconds of work, and queuing it behind three multi-minute gates left
# sessions idle for nothing. Matched first, at the same command position; a hit
# passes the statement through untouched. FLEET_HEAVY_LIGHT_RE replaces it (set
# `(?!)` to make every heavy match queue again). Mirrored from fleet-lib.sh's
# FLEET_HEAVY_LIGHT_RE_DEFAULT. One statement is one segment (split at | && ; \n),
# so `.*` never reaches past a pipe. Still heavy: bare pytest / a directory, any
# xdist fan-out (-n, --numprocesses, --dist, -p xdist), npm test without a file /
# -t filter, run-selftests.sh with no name, a glob, or an option (--shard).
HEAVY_LIGHT_RE_DEFAULT = (
    r"(?:python3?\s+-m\s+)?pytest\b"
    r"(?!.*\s(?:-n|--numprocesses|--dist)(?![A-Za-z-])|.*\s-p\s*xdist\b)"
    r"(?=.*\s(?:-k|\S*::|\S+\.py(?:\s|$)))"
    r"|npm\s+(?:run\s+)?test\b"
    r"(?=.*\s--\s(?:.*\s)?(?:-t\b|--testNamePattern\b|\S+\.[cm]?[jt]sx?(?:\s|$)))"
    r"|(?:(?:ba|z)?sh\s+)?(?:\S*/)?run-selftests\.sh(?:\s+[A-Za-z][^\s*?\[<>&]*)+"
    r"(?=\s*(?:\d*[<>&]|$))")
# Shell keywords, subshell/group openers and VAR=val assignments sit BEFORE the
# insertion point (the assignment then reaches the wrapper and so its child).
_HEAVY_LEAD = re.compile(
    r"\s*(?:(?:if|then|do|else|elif|while|until|!|\{|\()\s*)*"
    r"(?:\w+=(?:\"[^\"]*\"|'[^']*'|\S)*\s+)*")
# Transparent command prefixes: the wrapper goes before them, the match after.
_HEAVY_PASS = r"(?:(?:time|nohup|nice(?:\s+-n\s*-?\d+)?|timeout\s+\S+)\s+)*"
_HEAVY_KEYS = ("FLEET_HEAVY", "FLEET_HEAVY_RE", "FLEET_HEAVY_WAIT", "FLEET_HEAVY_LIGHT_RE")
_HEAVY_CONF = None


def _heavy_conf():
    """FLEET_HEAVY* from env > $FLEET_CONF_DIR/fleet.settings > install fleet.conf —
    the order fleet-lib.sh reads them in, without forking a shell per Bash call."""
    global _HEAVY_CONF
    if _HEAVY_CONF is not None:
        return _HEAVY_CONF
    import shlex
    conf = {}
    here = os.path.dirname(os.path.abspath(__file__))
    for path in (os.path.join(here, "..", "fleet.conf"),
                 os.path.join(_conf_dir(), "fleet.settings"),
                 os.path.join(_conf_dir(), "fleet.conf")):   # the machine's one file (#1623)
        try:
            with open(path) as f:
                for line in f:
                    m = re.match(r"\s*(?:export\s+)?(FLEET_HEAVY(?:_RE|_WAIT|_LIGHT_RE)?)=(.*)$", line)
                    if m:
                        try:
                            toks = shlex.split(m.group(2), comments=True)
                        except ValueError:
                            continue
                        conf[m.group(1)] = toks[0] if toks else ""
        except OSError:
            pass
    for k in _HEAVY_KEYS:
        if k in os.environ:
            conf[k] = os.environ[k]
    _HEAVY_CONF = conf
    return conf


def _heavy_bin():
    p = os.environ.get("FLEET_HEAVY_BIN", "").strip() or os.path.expanduser(
        "~/.claude/fleet/bin/fleet-heavy.sh")
    return p if os.access(p, os.X_OK) else ""


def _heavy_label(text):
    toks = text.split()
    if not toks:
        return "heavy"
    head = os.path.basename(toks[0])
    if head in ("git", "npm", "python", "python3", "bash", "sh", "zsh") and len(toks) > 1:
        tail = os.path.basename(toks[-1])
        head = tail if head.endswith("sh") else head + "-" + tail
    return re.sub(r"[^A-Za-z0-9._-]", "-", head)[:40] or "heavy"


def check_heavy(masked_seg, span, masked_cmd, tool_input):
    """Prefix fleet-heavy.sh onto a heavy statement. `masked_seg` keeps CASE."""
    conf = _heavy_conf()
    if conf.get("FLEET_HEAVY", "1").strip() == "0":
        return
    if re.search(r"(?:^|[\s;&|(])fleet_heavy=0(?=\s|$)", masked_cmd.lower()):
        return
    lead = _HEAVY_LEAD.match(masked_seg).end()
    if re.match(r"\S*fleet-heavy\.sh(?=\s|$)", masked_seg[lead:]):
        return                                   # already wrapped
    light_re = conf.get("FLEET_HEAVY_LIGHT_RE", "").strip() or HEAVY_LIGHT_RE_DEFAULT
    try:
        light = re.match(_HEAVY_PASS + "(?:" + light_re + ")", masked_seg[lead:])
    except re.error:
        light = re.match(_HEAVY_PASS + "(?:" + HEAVY_LIGHT_RE_DEFAULT + ")", masked_seg[lead:])
    if light:
        return                                   # light test run: never queued (#1313)
    user_re = conf.get("FLEET_HEAVY_RE", "").strip() or HEAVY_RE_DEFAULT
    try:
        m = re.match(_HEAVY_PASS + "(" + user_re + ")", masked_seg[lead:])
    except re.error:
        m = re.match(_HEAVY_PASS + "(" + HEAVY_RE_DEFAULT + ")", masked_seg[lead:])
    if not m:
        return
    wrapper = _heavy_bin()
    if not wrapper or not _in_fleet_pane():
        return
    label = _heavy_label(m.group(1))
    args = ["--label", label]
    if not tool_input.get("run_in_background"):
        # A foreground call dies at the Bash tool's timeout (default 2 min), so
        # queue for at most half of it — the command still gets to run.
        try:
            tmo = int(tool_input.get("timeout") or 120000)
        except (TypeError, ValueError):
            tmo = 120000
        try:
            cap = int(conf.get("FLEET_HEAVY_WAIT", "") or 1800)
        except ValueError:
            cap = 1800
        args += ["--wait", str(max(10, min(cap, tmo // 2000)))]
    import shlex
    pos = span[0] + lead
    _rewrite((pos, pos), "%s %s -- " % (shlex.quote(wrapper), " ".join(args)),
             "queued heavy `%s` behind the machine-wide slot cap (fleet-heavy.sh)" % label)


# --- OVERLAY -----------------------------------------------------------------
# Operator-specific rules (prod hosts, DB/k8s rails, anything host-local) live in
# ~/.claude/hooks/bash-guard-local.py and are NEVER committed here. The overlay,
# if present, defines:
#
#     def check_segment(seg, ctx):
#         # seg: one lower-cased statement segment
#         # ctx.block(reason)        -> deny (exit 2)
#         # ctx.cmd_is(seg, name)    -> segment's command is `name`
#         # ctx.has_short_flag(seg, c) -> a -xNx flag bundle contains letter c
#         if ctx.cmd_is(seg, "kubectl") and "delete namespace" in seg:
#             ctx.block("kubectl delete namespace")
#
# A missing overlay is skipped silently; an overlay that raises is ignored
# (fail-open) — but an overlay's ctx.block() propagates as a real deny.
class _Ctx:
    block = staticmethod(block)
    cmd_is = staticmethod(cmd_is)
    has_short_flag = staticmethod(has_short_flag)


_OVERLAY = None
_OVERLAY_LOADED = False


def _load_overlay():
    global _OVERLAY, _OVERLAY_LOADED
    if _OVERLAY_LOADED:
        return _OVERLAY
    _OVERLAY_LOADED = True
    path = os.path.expanduser("~/.claude/hooks/bash-guard-local.py")
    if not os.path.exists(path):
        return None
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location("bash_guard_local", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _OVERLAY = mod
    except SystemExit:
        raise
    except Exception:
        _OVERLAY = None  # a broken overlay must not brick the guard
    return _OVERLAY


def _run_overlay(seg):
    mod = _load_overlay()
    if mod is None or not hasattr(mod, "check_segment"):
        return
    try:
        mod.check_segment(seg, _Ctx)
    except SystemExit:
        raise                  # an overlay block() is a real deny — honor it
    except Exception:
        pass                   # any other overlay error → fail open


# --- DIRECT-SCRIPT RAIL (issue #1812, EPIC #1813 C10) --------------------------
# A WORKER session reaches the fleet through its tool service (bin/fleet-mcp.py,
# mounted as `fleet`: mcp__fleet__<tool>), never by running the script the tool
# wraps — while the old road stays open, new skills and old habits mix and the
# call log cannot say which session did what. ONE table, two roads: a Bash
# statement whose COMMAND is one of these scripts, and a call to one of the mod's
# retired tools (mod/fleet/hooks/tools.ts, gone in mod 0.4.0) by its MCP name.
#
#   FLEET_DIRECT_SCRIPTS=log    (default) allow, and append a line to
#                               logs/mcp-bypass.log — the week of record
#   FLEET_DIRECT_SCRIPTS=block  deny, naming the tool to call instead
#   FLEET_DIRECT_SCRIPTS=off    neither
#   FLEET_ALLOW_DIRECT_SCRIPTS=1  the escape hatch (env or inline): allowed,
#                               logged as `hatch`
#
# The seat is the whole scope: only a worker seat (fleet_seat — a bound issue in
# its own worktree) is logged or blocked; the operator's hub, a scratch draft and
# a person's own shell never are. Only the COMMAND word counts (a `grep`/`cat`/
# `sed` of the script is not a call), and only the live install's copy or a bare
# name — a worker on this repo running its own branch's bin/ is testing, not
# bypassing. The log carries the script and the tool, never the command line.
_DIRECT_TOOLS = {
    # script            : (tool, first-argument predicate or None)
    "fleet-children.sh": ("children", None),
    "fleet-repo.sh": ("repos", ("list",)),
    "dash-issue-session.sh": ("spawn", None),
    "fleet-await.sh": ("await", None),
    "fleet-peer-send.sh": ("send", None),
    "fleet-report-parent.sh": ("report", None),
    "fleet-comment.sh": ("comment", None),
    "set-claude-state.sh": ("ask", ("blocked",)),
    "fleet-evidence.sh": ("evidence", None),
    "fleet-handoff-file.sh": ("handoff", None),
    "fleet-pr-verdict.sh": ("pr_verdict", None),
    "fleet-pr-merge.sh": ("pr_merge", None),
    "fleet-claim-brief.sh": ("brief", None),
    "fleet-issue-file.sh": ("file_issue", None),
    "fleet-gh.sh": ("gh", None),
}
# The mod's retired tools, by the name Claude showed them under.
_RETIRED_TOOLS = {
    "mcp__fleet__fleet_status": "status",
    "mcp__fleet__fleet_spawn": "spawn",
    "mcp__fleet__fleet_await": "await",
}
_DIRECT_WRAPPERS = {"bash", "sh", "zsh", "exec", "command", "env", "nohup", "time"}
_DIRECT_KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until"}
_DIRECT_SEAT = None


def _fleet_conf_value(key):
    """<key> from env > install fleet.conf > fleet.settings > the machine's
    fleet.conf (#1623) — the order _heavy_conf reads FLEET_HEAVY* in."""
    if key in os.environ:
        return os.environ[key].strip()
    val = None
    here = os.path.dirname(os.path.abspath(__file__))
    for path in (os.path.join(here, "..", "fleet.conf"),
                 os.path.join(_conf_dir(), "fleet.settings"),
                 os.path.join(_conf_dir(), "fleet.conf")):
        try:
            with open(path) as f:
                for line in f:
                    m = re.match(r"\s*(?:export\s+)?" + key + r"=(.*)$", line)
                    if m:
                        try:
                            toks = shlex.split(m.group(1), comments=True)
                        except ValueError:
                            continue
                        val = toks[0] if toks else ""
        except OSError:
            pass
    return (val or "").strip()


def _direct_mode():
    m = _fleet_conf_value("FLEET_DIRECT_SCRIPTS").lower()
    return m if m in ("log", "block", "off") else "log"


def _install_roots():
    roots = [os.path.expanduser("~/.claude/fleet"),
             os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")]
    out = []
    for r in roots:
        try:
            out.append(os.path.realpath(r))
        except Exception:
            pass
    return out


def _direct_script(orig_seg, cwd):
    """(script, tool) when this statement RUNS a covered script, else None."""
    try:
        toks = shlex.split(orig_seg, comments=True)
    except ValueError:
        toks = orig_seg.split()
    # `(cd x && …`, `if …; then …`, `X=$(script …)`: what RUNS is the word
    # after the openers, keywords, assignments and pass-through wrappers.
    i, word = 0, None
    while i < len(toks):
        t = toks[i].lstrip("({!")
        sub = re.match(r"^(?:[A-Za-z_][A-Za-z0-9_]*=)?[\"']?\$\((.+)$", t)
        if sub:
            t = sub.group(1)
        elif (not t or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t) or t in _DIRECT_WRAPPERS
              or t in _DIRECT_KEYWORDS
              or (t.startswith("-") and i > 0 and toks[i - 1] in _DIRECT_WRAPPERS)):
            i += 1
            continue
        word = t.rstrip(")")
        break
    if not word:
        return None
    entry = _DIRECT_TOOLS.get(os.path.basename(word))
    if entry is None:
        return None
    tool, first = entry
    if first is not None:
        nxt = toks[i + 1] if i + 1 < len(toks) else ""
        if nxt not in first:
            return None
    if "/" in word:
        home = os.path.expanduser("~")
        path = re.sub(r"^\$\{?HOME\}?(?=/)", lambda _m: home, word)
        path = os.path.expanduser(path)
        if not os.path.isabs(path):
            path = os.path.join(cwd, path)
        try:
            path = os.path.realpath(path)
        except Exception:
            return None
        if not any(path.startswith(r + os.sep) for r in _install_roots()):
            return None              # a worktree's own bin/: testing, not bypassing
    return os.path.basename(word), "mcp__fleet__" + tool


def _direct_seat(cwd):
    """(seat, issue) of THIS pane via fleet-lib's fleet_seat; any failure ⇒ ('', '')
    — fail open: a guard that cannot tell the seat never blocks."""
    global _DIRECT_SEAT
    if _DIRECT_SEAT is not None:
        return _DIRECT_SEAT
    _DIRECT_SEAT = ("", "")
    if os.environ.get("FLEET_HUB", "").strip() == "1":
        return _DIRECT_SEAT
    lib = os.path.expanduser(
        os.environ.get("FLEET_LIB", "~/.claude/fleet/bin/fleet-lib.sh"))
    if not os.path.exists(lib):
        return _DIRECT_SEAT
    script = ('source "$1" >/dev/null 2>&1 || exit 9\n'
              'printf "%s|%s" "$(fleet_seat 2>/dev/null)" '
              '"$(fleet_pane_fmt "#{@issue}" 2>/dev/null)"\n')
    try:
        out = subprocess.run(["bash", "-c", script, "_", lib], cwd=cwd or None,
                             capture_output=True, text=True, timeout=10)
        if out.returncode == 0:
            seat, _, issue = out.stdout.strip().partition("|")
            _DIRECT_SEAT = (seat.strip(), issue.strip())
    except Exception:
        pass
    return _DIRECT_SEAT


def _bypass_log(verdict, issue, script, tool):
    path = os.environ.get("FLEET_MCP_BYPASS_LOG", "").strip() or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "logs", "mcp-bypass.log")
    import time
    line = "%s\t%s\tissue=%s\tscript=%s\ttool=%s\n" % (
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), verdict,
        issue or "-", script, tool)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as f:
            f.write(line)
    except OSError:
        pass


def check_direct(script, tool, masked_cmd, cwd):
    """The one verdict for both roads: log / block / hatch, worker seat only."""
    mode = _direct_mode()
    if mode == "off":
        return
    seat, issue = _direct_seat(cwd)
    if seat != "worker":
        return
    if _hatched(masked_cmd, "FLEET_ALLOW_DIRECT_SCRIPTS"):
        _bypass_log("hatch", issue, script, tool)
        return
    if mode != "block":
        _bypass_log("logged", issue, script, tool)
        return
    _bypass_log("blocked", issue, script, tool)
    sys.stderr.write(
        "⛔ BLOCKED by ~/.claude/fleet/hooks/bash-guard.py: a worker session calls the "
        "fleet through its tools — use %s instead of %s (issue #1812).\n"
        "Codex shows the same tool as `fleet` → %s. Arguments: docs/FLEET-MCP.md.\n"
        "Truly need the script itself? Prefix FLEET_ALLOW_DIRECT_SCRIPTS=1.\n"
        % (tool, script, tool[len("mcp__fleet__"):])
    )
    sys.exit(2)


# --- a session's client is the test identity (issue #1931, EPIC #1906 C12) ------
#
# A session that starts a REAL client — `fleet` / `fleet <machine>` / `fleet shell`
# / fleet-shell.sh, here or through `ssh <host> …` — as the person takes the
# person's one client lease: on 2026-10-06 a drill (#1901) did exactly that from m4
# and the operator's MacBook dropped to its standby screen again and again. Inside
# a session the client asks as the test identity by default (fleet-client-lease.py),
# but the `fleet` on PATH may be an older install that does not, and over ssh the
# session's environment does not travel — so a client start must SAY it:
# `--test-identity` / FLEET_CLIENT_IDENTITY=test passes; FLEET_ALLOW_PERSON_CLIENT=1
# is the hatch. The operator's hub pane (FLEET_HUB=1) and a person's shell are
# never touched.
_SSH_ARG_OPTS = set("bcDEeFIiJLlmOoPpQRSWw")
_FLEET_NOT_CLIENT = {"-h", "--help", "help", "doctor"}


def _client_start(toks, i):
    """True when toks[i:] starts a client as the person; i is the command word."""
    word = os.path.basename(toks[i].rstrip(")"))
    rest = toks[i + 1:]
    if word == "fleet-shell.sh":
        return "--test-identity" not in rest
    if word != "fleet":
        return False
    if rest and rest[0] == "--test-identity":
        return False
    sub = rest[0] if rest else ""
    if sub in ("", "shell"):
        return True
    if sub.startswith("-") or sub in _FLEET_NOT_CLIENT:
        return False
    # a word naming a command this install has is a command (over ssh too: the
    # remote install is not knowable here), any other word a machine
    for r in _install_roots():
        for ext in ("py", "sh"):
            if os.path.exists(os.path.join(r, "bin", "fleet-%s.%s" % (sub, ext))):
                return False
    return True


def _client_forms(orig_seg):
    """(kind, assigned identity) for this statement: kind local / remote / None."""
    try:
        toks = shlex.split(orig_seg, comments=True)
    except ValueError:
        toks = orig_seg.split()
    i, ident = 0, ""
    while i < len(toks):
        t = toks[i].lstrip("({!")
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", t)
        if m:
            if m.group(1) == "FLEET_CLIENT_IDENTITY":
                ident = m.group(2).strip().lower()
            i += 1
            continue
        if not t or t in _DIRECT_WRAPPERS or t in _DIRECT_KEYWORDS or (
                t.startswith("-") and i > 0 and toks[i - 1] in _DIRECT_WRAPPERS):
            i += 1
            continue
        break
    if i >= len(toks):
        return None, ident
    toks[i] = toks[i].lstrip("({!")
    if os.path.basename(toks[i]) in ("ssh", "autossh"):
        j = i + 1
        while j < len(toks) and toks[j].startswith("-"):
            opt = toks[j]
            j += 1
            if len(opt) == 2 and opt[1] in _SSH_ARG_OPTS:
                j += 1
        j += 1                            # the host
        if j >= len(toks):
            return None, ident
        rem = toks[j:]
        if len(rem) == 1 and " " in rem[0]:
            try:
                rem = shlex.split(rem[0])
            except ValueError:
                rem = rem[0].split()
        k = 0
        while k < len(rem) and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", rem[k]) or rem[k] in _DIRECT_WRAPPERS):
            if rem[k].startswith("FLEET_CLIENT_IDENTITY="):
                ident = rem[k].split("=", 1)[1].strip().lower()
            k += 1
        if k < len(rem) and _client_start(rem, k):
            return "remote", ident
        return None, ident
    if _client_start(toks, i):
        return "local", ident
    return None, ident


def check_client_identity(orig_seg, masked_cmd, cwd):
    if os.environ.get("FLEET_HUB", "").strip() == "1":
        return
    kind, ident = _client_forms(orig_seg)
    if kind is None or ident == "test":
        return
    in_session = bool(os.environ.get("FLEET_WORKER_CRED", "").strip()) or \
        _direct_seat(cwd)[0] == "worker"
    if not in_session or _hatched(masked_cmd, "FLEET_ALLOW_PERSON_CLIENT"):
        return
    where = "over ssh (this session's environment does not travel)" if kind == "remote" \
        else "without --test-identity"
    sys.stderr.write(
        "⛔ BLOCKED by ~/.claude/fleet/hooks/bash-guard.py: a session starts a real client %s — "
        "it would take the person's one client lease and drop their screen to standby (issue #1931).\n"
        "Run it as the test identity: `fleet --test-identity …` (or FLEET_CLIENT_IDENTITY=test), "
        "or point it at a fake hub.\n"
        "Truly the person's client, on purpose? Prefix FLEET_ALLOW_PERSON_CLIENT=1.\n" % where)
    sys.exit(2)


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        allow()  # fail open

    name = data.get("tool_name") or ""
    if name in _RETIRED_TOOLS:          # the same rule on the MCP road (#1812)
        try:
            check_direct(name, "mcp__fleet__" + _RETIRED_TOOLS[name], "",
                         data.get("cwd") or os.getcwd())
        except SystemExit:
            raise
        except Exception:
            pass
        allow()
    if name != "Bash":
        allow()
    ti = data.get("tool_input") or {}
    if not isinstance(ti, dict):
        allow()
    cmd = ti.get("command", "")
    if not cmd:
        allow()

    # Quoted / heredoc text is data: mask it (length-preserving) before matching,
    # then split the MASKED command into statement segments so unrelated tokens
    # can't combine.
    masked = _mask(cmd)
    cwd = data.get("cwd") or os.getcwd()
    for a, b in _segments(masked):
        check_segment(masked[a:b].lower(), cmd[a:b].lower(), cmd[a:b], (a, b), masked)
        # Shared-deps rail (#885) follows `cd` across statements, so the common
        # `cd pkg && npm install` is judged in pkg, not the pane's cwd.
        try:
            nxt = _cd_target(masked[a:b], cmd[a:b], cwd)
            if nxt is not None:
                cwd = nxt
            else:
                check_shared_deps(masked[a:b].lower(), cmd[a:b], cwd)
        except SystemExit:
            raise
        except Exception:
            pass                         # fail open, as every rail here
        try:
            check_client_identity(cmd[a:b], masked, cwd)
        except SystemExit:
            raise
        except Exception:
            pass                         # fail open
        try:
            hit = _direct_script(cmd[a:b], cwd)
            if hit:
                check_direct(hit[0], hit[1], masked, cwd)
        except SystemExit:
            raise
        except Exception:
            pass                         # fail open
        try:
            check_heavy(masked[a:b], (a, b), masked, ti)
        except Exception:
            pass                         # a queue bug must never cost the command

    if _REWRITES:
        out = cmd
        for a, b, new in sorted(_REWRITES, reverse=True):
            out = out[:a] + new + out[b:]
        allow_with(out, ti)
    allow()


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        sys.exit(0)  # never brick a session on a guard bug
