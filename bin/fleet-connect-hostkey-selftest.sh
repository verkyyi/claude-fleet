#!/bin/bash
# fleet-connect-hostkey-selftest.sh — a new person's first `fleet connect`
# asks no host-key question (issue #2983): the hub lists each machine's sshd
# host keys beside its routes, and bin/fleet-connect.py writes them into
# ~/.ssh/fleet-known-hosts under the HostKeyAlias ssh checks (fleet-<alias>).
#
# Legs: write_known_hosts writes the machine's lines, replaces only its own,
# drops a malformed key and writes nothing when the hub listed none;
# ssh_command points UserKnownHostsFile at the file only then. Then against a
# REAL sshd (run as `sshd -i` from a ProxyCommand — no listening socket),
# with BatchMode so a question fails instead of waiting, judged by ssh's own
# -v words: no listed key → ssh's host-key refusal (what the newcomer was
# asked); the listed key → "is known and matches", no question; a different
# listed key → "HOST IDENTIFICATION HAS CHANGED", refused. The sshd legs skip where
# there is no /usr/sbin/sshd or it will not run unprivileged.
set -uo pipefail
BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/selftest-lib.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-connect-hostkey-selftest.XXXXXX") || exit 2
trap 'rm -rf "${WORK:?}"' EXIT INT TERM HUP
export HOME="$WORK/home"
mkdir -p "$HOME/.ssh"
export FLEET_KNOWN_HOSTS="$WORK/fleet-known-hosts"
unset FLEET_CERT

st_tally

for k in host other user; do ssh-keygen -q -t ed25519 -N '' -C "c-$k" -f "$WORK/$k" || exit 2; done
HOSTPUB=$(cut -d' ' -f1-2 "$WORK/host.pub")
OTHERPUB=$(cut -d' ' -f1-2 "$WORK/other.pub")

# ── 1 — the file and the command, as functions ──────────────────────────────
out=$(python3 - "$BIN/fleet-connect.py" "$HOSTPUB" "$OTHERPUB" <<'EOF'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fc", sys.argv[1]); fc = importlib.util.module_from_spec(spec); spec.loader.exec_module(fc)
hk, other = sys.argv[2], sys.argv[3]
path = fc.known_hosts_path()
open(path, "w").write("fleet-m9 %s\nfleet-mac-a %s\n" % (other, other))
m = {"hostname": "mini", "alias": "mac-a", "host_keys": [hk, "ssh-ed25519 AAAA\nfleet-m9 x", "nope", 7]}
print(fc.write_known_hosts(m), open(path).read().replace("\n", "|"))
print(fc.write_known_hosts({"hostname": "mac-b"}), fc.write_known_hosts({"alias": "mac-b", "host_keys": []}))
route = {"kind": "direct", "name": "tailnet", "host": "127.0.0.1", "port": 22}
print(" ".join(fc.ssh_command(m, route, "alice", "", known_hosts=True)))
print(" ".join(fc.ssh_command(m, route, "alice", "")))
EOF
)
[ "$(sed -n 1p <<<"$out")" = "True fleet-m9 $OTHERPUB|fleet-mac-a $HOSTPUB|" ] \
  && st_ok_all "write_known_hosts: this machine's lines replaced, another's kept, a bad key dropped" \
  || st_miss "write_known_hosts: $(sed -n 1p <<<"$out")"
[ "$(sed -n 2p <<<"$out")" = "False False" ] && st_ok_all "write_known_hosts: no listed key → nothing written" \
  || st_miss "no keys: $(sed -n 2p <<<"$out")"
[[ "$(sed -n 3p <<<"$out")" == *"HostKeyAlias=fleet-mac-a "*"UserKnownHostsFile=$FLEET_KNOWN_HOSTS ~/.ssh/known_hosts"* ]] \
  && st_ok_all "ssh_command: the fleet's known_hosts first, then the person's own" || st_miss "ssh_command: $(sed -n 3p <<<"$out")"
[[ "$(sed -n 4p <<<"$out")" != *UserKnownHostsFile* ]] && st_ok_all "ssh_command: no keys → ssh's own known_hosts, as before" \
  || st_miss "ssh_command without keys: $(sed -n 4p <<<"$out")"

python3 - "$BIN/fleet-connect.py" "$HOSTPUB" "$OTHERPUB" <<'EOF' && st_ok_all "pod rebuild: refresh cached pins and automatic routes from hub, retain strict trust offline" || st_miss "pod rebuild cache refresh"
import copy, importlib.util, sys, time
from unittest.mock import patch
spec = importlib.util.spec_from_file_location("fc", sys.argv[1])
fc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fc)
new_key, old_key = sys.argv[2:]
hub = "https://hub.example"
old = {"hostname": "pod", "login": "alice", "host_keys": [old_key], "target_host_keys": [old_key], "relay": True,
       "routes": [{"name": "entry", "host": "door.example", "port": 22022, "jump": "fleet-jump", "target": "u-pod1.fleet-workers.svc.cluster.local"}]}
fresh = dict(old, host_keys=[new_key], target_host_keys=[new_key])
route = fc.route_rec(fc.route_rows(old, hub)[0])
cache = {"last": "pod", "machines": {"pod": {"hub": hub, "machine": old, "label": "pod", "login": "alice",
         "at": time.time(), "route": route, "routes": [route]}}}

def measure(rows, *arguments):
    for row in rows:
        row["ms"] = [1]
    return rows

for pin in ("entry", "relay", ""):
    for supplied in (True, False):
        info = {"machines": [fresh]}
        with patch.object(fc, "load_cache", return_value=copy.deepcopy(cache)), patch.object(fc, "save_cache"), \
             patch.object(fc, "pin_for", return_value=pin), patch.object(fc, "fetch_routes", return_value=info) as fetch, \
             patch.object(fc, "measure", side_effect=measure), patch.object(fc, "run_ssh", return_value=0) as run:
            assert fc.connect("pod", hub, "", False, False, False, [], info=info if supplied else None) == 0
            chosen, selected = run.call_args.args[:2]
            assert chosen["host_keys"] == [new_key], (pin, supplied, chosen)
            if selected["name"] == "entry":
                assert selected["target_host_keys"] == [new_key]
            assert fetch.call_count == (0 if supplied else 1)

with patch.object(fc, "load_cache", return_value=copy.deepcopy(cache)), patch.object(fc, "pin_for", return_value="entry"), \
     patch.object(fc, "fetch_routes", side_effect=OSError("offline")), patch.object(fc, "run_ssh", return_value=0) as run:
    fc.connect("pod", hub, "", False, False, False, [])
    chosen, selected = run.call_args.args[:2]
    assert chosen["host_keys"] == [old_key]
    assert selected["target_host_keys"] == [old_key]
EOF

# ── 1b — ssh ended 255 on a direct route: was it the key? (T743) ──────────────
python3 - "$BIN/fleet-connect.py" "$HOSTPUB" "$OTHERPUB" > "$WORK/1b.out" 2>&1 <<'EOF2'
import importlib.util, io, sys
from unittest.mock import patch
spec = importlib.util.spec_from_file_location("fc", sys.argv[1]); fc = importlib.util.module_from_spec(spec); spec.loader.exec_module(fc)
new, old = sys.argv[2], sys.argv[3]
route = {"kind": "direct", "name": "entry", "host": "203.0.113.7", "port": 22022}
def run(scan, hub_keys, rcs):
    m = {"hostname": "mini", "alias": "mac-a", "host_keys": [old]}
    err = io.StringIO()
    with patch.object(fc, "fleet_clientlog", object()), patch.object(fc, "clog"), \
         patch.object(fc, "scan_host_keys", return_value=scan), \
         patch.object(fc, "fetch_routes", return_value={"machines": [dict(m, host_keys=hub_keys)]}), \
         patch.object(fc, "run_logged", side_effect=list(rcs)) as rl, patch.object(sys, "stderr", err):
        rc = fc.run_ssh(m, route, "alice", "https://hub.example", False, [])
    return rc, rl.call_count, err.getvalue(), "".join(l for l in open(fc.known_hosts_path()) if l.startswith("fleet-mac-a "))
# the hub's fresh word names the answering key: rewritten, one retry, a grey line
rc, n, err, kh = run([new], [new], [255, 0])
assert (rc, n) == (0, 2) and "已按 hub 更新" in err and new in kh and old not in kh, (rc, n, err, kh)
# the answering key is nobody fleet knows: stop, words, no retry
rc, n, err, kh = run([new], [old], [255, 0])
assert (rc, n) == (255, 1) and "停下了：203.0.113.7:22022 给出的钥匙不是 fleet 记的 mac-a" in err \
    and fc.key_fp(new) in err and fc.key_fp(old) in err, (rc, n, err)
# the listed key answers: not a key problem, ssh's own 255 stands
rc, n, err, kh = run([old], [old], [255, 0])
assert (rc, n, err) == (255, 1, ""), (rc, n, err)
# nothing answers the scan, or the check is off: left to ssh
rc, n, err, kh = run([], [new], [255, 0])
assert (rc, n, err) == (255, 1, ""), (rc, n, err)
print("ok")
EOF2
[ "$(tail -1 "$WORK/1b.out")" = ok ] \
  && st_ok_all "ssh 255 on a direct route: hub names the new key → rewritten + one retry; nobody's key → stopped with both fingerprints; a listed key / no answer → ssh's own" \
  || st_miss "host-key diagnosis: $(tail -5 "$WORK/1b.out")"

# ── 2 — a real sshd ─────────────────────────────────────────────────────────
SSHD=/usr/sbin/sshd
if [ ! -x "$SSHD" ] || ! command -v ssh >/dev/null 2>&1; then
  echo "skip real sshd legs: no $SSHD / ssh"
else
  cp "$WORK/user.pub" "$WORK/authorized_keys"
  cat > "$WORK/sshd_config" <<EOF
HostKey $WORK/host
PidFile $WORK/pid
StrictModes no
UsePAM no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile $WORK/authorized_keys
EOF
  if ! "$SSHD" -t -f "$WORK/sshd_config" >"$WORK/sshd-t" 2>&1; then
    echo "skip real sshd legs: this sshd will not run unprivileged here: $(head -1 "$WORK/sshd-t")"
  else
    # try <keys…>: fleet connect's own ssh command for mac-a, run for real
    try() {
      python3 - "$BIN/fleet-connect.py" "$WORK" "$(id -un)" "$@" <<'EOF'
import importlib.util, os, subprocess, sys
spec = importlib.util.spec_from_file_location("fc", sys.argv[1]); fc = importlib.util.module_from_spec(spec); spec.loader.exec_module(fc)
w, me, keys = sys.argv[2], sys.argv[3], sys.argv[4:]
m = {"hostname": "selftest-2983", "alias": "selftest-2983", "host_keys": keys}
try:
    os.unlink(fc.known_hosts_path())
except OSError:
    pass
route = {"kind": "direct", "name": "tailnet", "host": "127.0.0.1", "port": 22}
opts = ["BatchMode=yes", "GlobalKnownHostsFile=/dev/null", "IdentitiesOnly=yes", "IdentityFile=" + w + "/user",
        "ProxyCommand=/usr/sbin/sshd -i -f " + w + "/sshd_config"]
# a person's own known_hosts only where the fleet's is not given (no keys)
if not keys:
    opts.append("UserKnownHostsFile=" + w + "/empty")
cmd = fc.ssh_command(m, route, me, "", opts, known_hosts=fc.write_known_hosts(m))
cmd = cmd[:1] + ["-F", "/dev/null", "-v"] + cmd[1:] + ["true"]
p = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
e = p.stderr
# ssh's own words: the key matched what it knows; it refused; it would have asked
print("matched" if "is known and matches" in e else "-",
      "refused" if "Host key verification failed" in e else "-",
      "asked" if "authenticity of host" in e else "-",
      "changed" if "HOST IDENTIFICATION HAS CHANGED" in e else "-")
EOF
    }
    r=$(try)
    [ "$r" = "- refused - -" ] && st_ok_all "sshd: no listed key → ssh's host-key refusal (the newcomer's question)" || st_miss "no key: $r"
    r=$(try "$HOSTPUB")
    [ "$r" = "matched - - -" ] && st_ok_all "sshd: the hub's key → matched on the first connection, no question" || st_miss "listed key: $r"
    r=$(try "$OTHERPUB")
    [ "$r" = "- refused - changed" ] && st_ok_all "sshd: a key the hub did not list → still refused" || st_miss "changed key: $r"
  fi
fi

st_done
