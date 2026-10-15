#!/usr/bin/env python3
"""fleet-cn-probe-result.py — the China probe's ONE result (issue #4303).

bin/fleet-cn-probe.sh records every stage it walks as one row of
<run dir>/stages.tsv; bin/fleet-cn-probe-diag.sh feeds its read-only readings in
as `DIAG <key>\t<value>` lines. This turns both into <run dir>/result.json (and
diag.json) — 0600, redacted — and prints the probe's verdict FROM that JSON, so
the text a person reads, the exit code and the file the patrol keeps are one
conclusion, never three.

    fleet-cn-probe-result.py redact                      stdin → stdout, redacted
    fleet-cn-probe-result.py render <run dir> [--oks T]  stages.tsv (+ diag.json)
        → result.json; prints `RESULT <path>`, `CLASS <class> <reason>` and the
        verdict line (`通：…` / `不通：卡在 <layer> — <detail>`); exit 0 pass · 1 not
    fleet-cn-probe-result.py diag <run dir> <run id> <login> <machine>
        `DIAG <key>\t<value>` lines on stdin → diag.json (every key present,
        `unknown` when nothing read it); prints `DIAG <path>` and one line a key
    fleet-cn-probe-result.py classify-cert <text>       env / product for a cert FAIL

A stage's class (issue #4303): `product` — the product failed a real person's
road; `env` — the test road itself is not there (the client box, its login, the
drill identity expired, the pod off the roster): not a product verdict; `probe` —
the probe's own machinery failed (no tmux, a step that did not run). Only a run
with no failed stage is a pass; env and probe are never a pass.

stages.tsv, one row a stage: result · layer · class · reason_code · start ·
end (epoch s) · evidence (a path under the run dir, or empty) · detail.
"""
import json
import os
import re
import sys
import time

# ---- redaction --------------------------------------------------------------
# A credential never enters a run dir: these are cut wherever they appear. The
# words a refusal says («no upstream credential», «Permission denied») survive;
# image digests (sha256:…) and commit shas are not credentials and stay.
_SECRET_KEYS = (r"(?:[A-Za-z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|COOKIE|API_?KEY|PRIVATE_?KEY|SESSION_?KEY)"
                r"|token|secret|password|passwd|cookie|set-cookie|authorization|api[_-]?key|access[_-]?key"
                r"|private[_-]?key|session[_-]?key|approve[_-]?code|join[_-]?code|invite|cred)")
_RULES = [
    (re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----", re.S), "[REDACTED-PRIVATE-KEY]"),
    (re.compile(r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{6,}"), r"\1 [REDACTED]"),
    (re.compile(r"(?i)(\b" + _SECRET_KEYS + r"\b[\"']?\s*[:=]\s*[\"']?)([^\s\"',;&]+)"), r"\1[REDACTED]"),
    (re.compile(r"(?i)([?&](?:token|key|secret|code|sig|signature)=)[^\s&\"']+"), r"\1[REDACTED]"),
    (re.compile(r"\bsk-[A-Za-z0-9_-]{8,}"), "[REDACTED-API-KEY]"),
    (re.compile(r"\b(?:ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{16,}|\bgithub_pat_[A-Za-z0-9_]{20,}"), "[REDACTED-GH-TOKEN]"),
    (re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{8,}"), "[REDACTED-TOKEN]"),
    (re.compile(r"\bfd_[A-Za-z0-9_-]{6,}"), "[REDACTED-CODE]"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}"), "[REDACTED-JWT]"),
    (re.compile(r"\b(ssh-(?:ed25519|rsa|dss)|ecdsa-sha2-nistp\d+)(-cert-v01@openssh\.com)?\s+AAAA[A-Za-z0-9+/=]{20,}"), r"\1\2 [REDACTED-KEY]"),
]


def redact(s):
    s = s if isinstance(s, str) else str(s)
    for rx, rep in _RULES:
        s = rx.sub(rep, s)
    return s


def write_private(path, data):
    """Write a 0600 file by one rename (the run dir itself is 0700)."""
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def iso(t):
    try:
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(float(t))))
    except (TypeError, ValueError):
        return "unknown"


# ---- render -----------------------------------------------------------------
def read_stages(run_dir):
    rows = []
    try:
        with open(os.path.join(run_dir, "stages.tsv"), encoding="utf-8", errors="replace") as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) < 8:
                    continue
                res, layer, cls, reason, t0, t1, ev = p[:7]
                detail = "\t".join(p[7:])
                try:
                    secs = max(0, int(t1) - int(t0))
                except ValueError:
                    secs = None
                rows.append({"result": res, "layer": layer, "class": cls, "reason_code": reason,
                             "start": iso(t0), "end": iso(t1), "secs": secs,
                             "evidence": ev or None, "detail": redact(detail)})
    except OSError:
        pass
    return rows


def render(run_dir, oks):
    stages = read_stages(run_dir)
    run_id = os.path.basename(os.path.normpath(run_dir))
    first = next((s for s in stages if s["result"] == "fail"), None)
    diag = None
    dp = os.path.join(run_dir, "diag.json")
    if os.path.exists(dp):
        try:
            with open(dp) as f:
                diag = json.load(f)
        except ValueError:
            diag = {"error": "diag.json unreadable"}
    if not stages:
        # the probe ended before it recorded anything: its own error, never a pass
        first = {"result": "fail", "layer": "probe", "class": "probe", "reason_code": "no_stages",
                 "detail": "the probe recorded no stage", "secs": None, "evidence": None}
    starts = [s["start"] for s in stages if s.get("start") not in (None, "unknown")]
    ends = [s["end"] for s in stages if s.get("end") not in (None, "unknown")]
    res = {
        "run_id": run_id,
        "verdict": "pass" if first is None else "fail",
        "class": "none" if first is None else first["class"],
        "reason_code": "ok" if first is None else first["reason_code"],
        "stuck": None if first is None else first["layer"],
        "detail": "" if first is None else first["detail"],
        "oks": redact(oks),
        "started": starts[0] if starts else "unknown",
        "ended": ends[-1] if ends else "unknown",
        "stages": stages,
        "diag": diag,
    }
    path = os.path.join(run_dir, "result.json")
    write_private(path, res)
    print("RESULT %s" % path)
    print("CLASS %s %s" % (res["class"], res["reason_code"]))
    if first is None:
        print("通：%s" % res["oks"])
        return 0
    print("不通：卡在 %s — %s" % (res["stuck"], res["detail"]))
    return 1


# ---- diag -------------------------------------------------------------------
# Every key the diagnosis owes, present in every diag.json — `unknown` when no
# reading reached it (the source said why in `<key>.why` where it could).
DIAG_KEYS = [
    "target.login", "target.machine", "target.pod_name", "target.pod_uid", "target.pod_phase",
    "target.pod_started", "target.pod_restarts", "target.pod_node",
    "version.hub", "version.hub_commit", "version.hub_client", "version.client",
    "version.node_runtime", "version.ccquota", "image.ref", "image.digest",
    "identity.principal", "identity.valid_until", "identity.cert", "identity.roster",
    "admit.verdict", "admit.denier", "admit.why", "admit.cpu", "admit.mem", "admit.disk",
    "admit.user_pod", "admit.last_open",
    "cred.trust", "cred.route_claude", "cred.route_codex", "cred.proxy_start",
    "cred.last_nocred", "cred.last_forward", "cred.upstream",
    "opener.state", "opener.reason", "opener.runtime_mode",
]


def diag(run_dir, run_id, login, machine):
    got, sources = {}, {}
    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line.startswith("DIAG "):
            continue
        kv = line[5:].split("\t", 1)
        k = kv[0].strip()
        v = kv[1].strip() if len(kv) > 1 else ""
        if not k or not re.match(r"^[a-z_]+\.[a-z_]+$", k):
            continue
        if k.startswith("source."):
            sources[k[7:]] = redact(v)
            continue
        if v == "":
            continue
        got.setdefault(k, redact(v))   # the first reading of a key wins (the most direct source)
    got.setdefault("target.login", login)
    got.setdefault("target.machine", machine)
    d = {"run_id": run_id, "detected_at": iso(time.time()), "read_only": True,
         "sources": sources, "readings": {}}
    for k in DIAG_KEYS:
        d["readings"][k] = got.get(k, "unknown")
    for k, v in got.items():
        if k not in d["readings"]:
            d["readings"][k] = v
    path = os.path.join(run_dir, "diag.json")
    write_private(path, d)
    print("DIAG %s" % path)
    for k in DIAG_KEYS:
        print("  %-22s %s" % (k, d["readings"][k][:200]))
    return 0


def classify_cert(text):
    """A cert stage that did not pass: the drill identity ran out (env) or the hub
    refused a live one (product)."""
    if re.search(r"已过期|expired|unknown principal|no such (person|principal)|not a person|身份.*(删|不存在)", text, re.I):
        print("env identity_expired")
    elif not text.strip():
        print("probe cert_unread")
    else:
        print("product cert_refused")
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "redact":
        sys.stdout.write(redact(sys.stdin.read()))
        return 0
    if cmd == "render" and len(argv) >= 3:
        oks = ""
        if len(argv) >= 5 and argv[3] == "--oks":
            oks = argv[4]
        return render(argv[2], oks)
    if cmd == "diag" and len(argv) == 6:
        return diag(*argv[2:6])
    if cmd == "classify-cert" and len(argv) == 3:
        return classify_cert(argv[2])
    print("fleet-cn-probe-result: redact | render <run dir> [--oks T] | diag <run dir> <run id> <login> <machine> | classify-cert <text>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
