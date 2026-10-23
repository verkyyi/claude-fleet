#!/usr/bin/env python3
"""Provider choice at dispatch acceptance, independent of agent definitions.

The envelope is non-secret request data. A hub task/generation may be attached
by the authority; neither labels nor destination defaults may rewrite it.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid

PROVIDERS = ("claude", "codex")
SOURCES = ("explicit", "template", "label", "fleet", "default")


def provider(value):
    if value not in PROVIDERS:
        raise ValueError("coding agent must be claude or codex")
    return value


def validate(value):
    if not isinstance(value, dict) or type(value.get("version")) is not int or value["version"] != 1:
        raise ValueError("unsupported dispatch version")
    if set(value) - {"version", "request_id", "requested_agent", "resolved_agent", "agent_source", "task", "generation", "attempt_id"}:
        raise ValueError("unknown dispatch field")
    provider(value.get("resolved_agent"))
    if value.get("requested_agent") not in (*PROVIDERS, "default"):
        raise ValueError("invalid requested coding agent")
    if value.get("agent_source") not in SOURCES:
        raise ValueError("invalid coding agent source")
    if value["requested_agent"] == "default" and value["agent_source"] == "explicit":
        raise ValueError("default choice cannot have explicit provenance")
    if not re.fullmatch(r"[A-Za-z0-9._:-]{1,128}", value.get("request_id", "")):
        raise ValueError("dispatch needs a request idempotency key")
    if value["requested_agent"] != "default" and (
            value["requested_agent"] != value["resolved_agent"] or value["agent_source"] != "explicit"):
        raise ValueError("contradictory explicit coding agents")
    if "task" in value:
        if not re.fullmatch(r"T[1-9][0-9]*", value["task"]) or type(value.get("generation")) is not int or value["generation"] < 1:
            raise ValueError("accepted task needs task ID and generation")
        if value.get("attempt_id") != "task:%s:g%d" % (value["task"], value["generation"]):
            raise ValueError("dispatch attempt does not match generation")
    elif "generation" in value or "attempt_id" in value:
        raise ValueError("dispatch generation requires an accepted task")
    return value


def resolve(explicit=(), template="", label="", default="", accepted=None, request_id=""):
    choices = {provider(v) for v in explicit}
    if len(choices) > 1:
        raise ValueError("contradictory explicit coding agents")
    if accepted is not None:
        value = validate(accepted)
        if choices and value["resolved_agent"] not in choices:
            raise ValueError("coding agent conflicts with accepted dispatch")
        return value
    chosen = next(iter(choices), "")
    source = "explicit"
    if not chosen:
        for source, hint in (("template", template), ("label", label), ("fleet", default), ("default", "claude")):
            if hint:
                chosen = provider(hint)
                break
    return validate(dict(version=1, request_id=request_id or str(uuid.uuid4()),
                         requested_agent=chosen if choices else "default",
                         resolved_agent=chosen, agent_source=source))


def placement_check(value, task, code):
    """Do not replace an existing record or open locally after an uncertain send."""
    validate(value)
    if task and value.get("task") != task:
        raise ValueError("existing task requires its accepted dispatch; implicit adoption is refused")
    if code not in (0, 10):
        raise ValueError("dispatch placement did not succeed; no local fallback")


def read_current(task):
    """Use the existing authenticated task reader, with no local status cache."""
    result = subprocess.run(["bash", str(Path(__file__).with_name("fleet-task-record.sh")), "get", task],
                            capture_output=True, text=True, timeout=15,
                            env=dict(os.environ, FLEET_HUB_TIMEOUT="10"))
    if result.returncode:
        raise ValueError("dispatch task authorization unavailable; start refused")
    response = json.loads(result.stdout)
    return response.get("task") if isinstance(response, dict) else None


def check_current(value, *, read=None):
    """Refuse a cancelled/stale accepted start, without adopting legacy input.

    This read is a last-moment fence, not a claim that a process has exited or
    a substitute for atomic launch/stop execution-domain admission.
    """
    if value is None:
        return
    validate(value)
    if not value.get("task"):
        return
    try:
        record = (read or read_current)(value["task"])
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        raise ValueError("dispatch task authorization unavailable; start refused") from exc
    if (not isinstance(record, dict) or record.get("authority_version") != 1
            or (record.get("task") or record.get("id")) != value["task"]
            or record.get("generation") != value["generation"]
            or record.get("attempt_id") != value["attempt_id"]
            or record.get("resolved_agent") != value["resolved_agent"]
            or record.get("cancel_request")
            or record.get("state") == "cancelled" or record.get("outcome") == "cancelled"):
        raise ValueError("dispatch task authorization changed or cancelled; start refused")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--agent", action="append", default=[])
    p.add_argument("--template", default="")
    p.add_argument("--label", default="")
    p.add_argument("--default", default="")
    p.add_argument("--accepted", default="")
    p.add_argument("--request-id", default="")
    p.add_argument("--placement-code", type=int)
    p.add_argument("--task", default="")
    p.add_argument("--with-agent", action="store_true", help="print the resolved agent before the JSON envelope")
    p.add_argument("--check-current", action="store_true", help="refuse a cancelled/stale accepted task before starting")
    a = p.parse_args()
    try:
        value = resolve(a.agent, a.template, a.label, a.default,
                        json.loads(a.accepted) if a.accepted else None, a.request_id)
        if a.placement_code is not None:
            placement_check(value, a.task, a.placement_code)
        if a.check_current:
            check_current(value)
    except (ValueError, TypeError) as e:
        p.error(str(e))
    if a.with_agent:
        print(value["resolved_agent"])
    print(json.dumps(value, separators=(",", ":")))


if __name__ == "__main__":
    main()
