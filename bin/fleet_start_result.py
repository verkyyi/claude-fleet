#!/usr/bin/env python3
"""Run an accepted start and persist a refusal on that same Task (T1328).
No retry, adoption or outcome mutation: the Hub fences generation and execution.
"""
import json
import os
import subprocess
import sys
import tempfile


def record_failure(dispatch, reason):
    import fleet_node_http
    if not fleet_node_http.usable():
        return
    task = dispatch.get("task")
    if not task:
        return
    code, _ = fleet_node_http.call("POST", "/v1/node/tasks/%s/start-failed" % task,
                                  json.dumps(dict(generation=dispatch["generation"], reason=reason[-2000:])))
    if code not in (200, 409):
        print("fleet: could not save start failure (HTTP %s); retry/delete remains available" % code, file=sys.stderr)


def main(argv):
    # Keep stdout streaming (the caller may be waiting on the window receipt).
    # A file avoids pipe deadlock and bounds how much stderr is read into memory.
    with tempfile.TemporaryFile(mode="w+") as err:
        p = subprocess.run(argv, stderr=err)
        err.seek(0, 2)
        err.seek(max(0, err.tell() - 8000))
        reason = err.read()
    sys.stderr.write(reason)
    if p.returncode:
        try:
            record_failure(json.loads(os.environ.get("FLEET_DISPATCH") or "{}"),
                           reason.strip() or "Start refused (exit %d)" % p.returncode)
        except Exception as error:  # failure persistence must preserve the original refusal
            print("fleet: start failure could not be saved (%s)" % type(error).__name__, file=sys.stderr)
    return p.returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
