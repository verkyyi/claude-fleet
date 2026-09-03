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
raw `gh` issue-comment from a fleet pane, issue #483), which self-scope to fleet
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

WHY REWRITE BEATS DENY (issue #528). A PreToolUse deny kills the WHOLE Bash
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
import sys, re, json, os, subprocess

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
# defaults; a fleet that runs off another base exports FLEET_BASE_BRANCH and the
# hook subprocess inherits it, so its base is protected too.
def _base_branches():
    names = {"master", "main"}
    bb = os.environ.get("FLEET_BASE_BRANCH", "").strip()
    if bb:
        names.add(bb)
    return names


# --- ESCAPE HATCHES ----------------------------------------------------------
# A hatch is COMMAND-WIDE, not segment-local (issue #528). The old rails read the
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
    #    swallows the Enter). SELF-SCOPED TO FLEET SERVERS (issue #528): the rail
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

    # Operator-specific rails, if the local overlay defines any (never shipped).
    _run_overlay(masked_seg)


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


def _rewrite(span, new_text, note):
    _REWRITES.append((span[0], span[1], new_text))
    _REWRITE_NOTES.append(note)


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


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        allow()  # fail open

    if data.get("tool_name") != "Bash":
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
    for a, b in _segments(masked):
        check_segment(masked[a:b].lower(), cmd[a:b].lower(), cmd[a:b], (a, b), masked)

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
