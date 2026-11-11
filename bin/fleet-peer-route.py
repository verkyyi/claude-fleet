#!/usr/bin/env python3
"""Resolve a remote bare identity through the hub, independently of inventory lag.

Print full worker_id<TAB>node, or a visible refusal. The node HTTP client keeps
credentials off argv and out of files; the hub enforces the relay's owner scope.
"""
import json
import re
import sys
from urllib.parse import urlencode

import fleet_node_http

UUID = r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}"


def resolve(fid, call=fleet_node_http.call):
    if not re.fullmatch(UUID, fid):
        raise ValueError("INVALID_ARGUMENT: recipient must be a full session identity")
    try:
        code, body = call("GET", "/v1/node/worker-route?" + urlencode({"id": fid}))
    except fleet_node_http.Unreachable:
        raise ValueError("UNAVAILABLE: hub route lookup failed; nothing sent") from None
    try:
        data = json.loads(body)
    except (TypeError, ValueError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    if code != 200:
        if code == 404:
            reason = data.get("reason")
            detail = {"closed": "recipient has closed", "no_route": "recipient is known but has no placed session"}.get(reason, "no known recipient (or hub route lookup is not installed)")
            raise ValueError("NOT_FOUND: " + detail + "; nothing sent")
        if code == 409:
            raise ValueError("AMBIGUOUS: identity has conflicting routes; nothing sent")
        raise ValueError("UNAVAILABLE: hub route lookup returned HTTP %s; nothing sent" % code)
    full, node = data.get("worker_id"), data.get("node", "")
    if not isinstance(full, str) or not re.fullmatch(UUID + "/" + re.escape(fid), full):
        raise ValueError("INVALID_ROUTE: hub did not return this identity's full worker_id; nothing sent")
    if not isinstance(node, str) or re.search(r"[\s\x00-\x1f]", node):
        raise ValueError("INVALID_ROUTE: hub returned an invalid node; nothing sent")
    return full + "\t" + node


if __name__ == "__main__":
    try:
        print(resolve(sys.argv[1] if len(sys.argv) == 2 else ""))
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
