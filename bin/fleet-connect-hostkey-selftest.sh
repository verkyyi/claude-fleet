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
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fleet-connect-hostkey-selftest.XXXXXX") || exit 2
trap 'rm -rf "${WORK:?}"' EXIT INT TERM HUP
export HOME="$WORK/home"
mkdir -p "$HOME/.ssh"
export FLEET_KNOWN_HOSTS="$WORK/fleet-known-hosts"
unset FLEET_CERT

fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

for k in host other user; do ssh-keygen -q -t ed25519 -N '' -C "c-$k" -f "$WORK/$k" || exit 2; done
HOSTPUB=$(cut -d' ' -f1-2 "$WORK/host.pub")
OTHERPUB=$(cut -d' ' -f1-2 "$WORK/other.pub")

# ── 1 — the file and the command, as functions ──────────────────────────────
out=$(python3 - "$BIN/fleet-connect.py" "$HOSTPUB" "$OTHERPUB" <<'EOF'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fc", sys.argv[1]); fc = importlib.util.module_from_spec(spec); spec.loader.exec_module(fc)
hk, other = sys.argv[2], sys.argv[3]
path = fc.known_hosts_path()
open(path, "w").write("fleet-m9 %s\nfleet-m4 %s\n" % (other, other))
m = {"hostname": "mini", "alias": "m4", "host_keys": [hk, "ssh-ed25519 AAAA\nfleet-m9 x", "nope", 7]}
print(fc.write_known_hosts(m), open(path).read().replace("\n", "|"))
print(fc.write_known_hosts({"hostname": "m5"}), fc.write_known_hosts({"alias": "m5", "host_keys": []}))
route = {"kind": "direct", "name": "tailnet", "host": "127.0.0.1", "port": 22}
print(" ".join(fc.ssh_command(m, route, "alice", "", known_hosts=True)))
print(" ".join(fc.ssh_command(m, route, "alice", "")))
EOF
)
[ "$(sed -n 1p <<<"$out")" = "True fleet-m9 $OTHERPUB|fleet-m4 $HOSTPUB|" ] \
  && ok "write_known_hosts: this machine's lines replaced, another's kept, a bad key dropped" \
  || bad "write_known_hosts: $(sed -n 1p <<<"$out")"
[ "$(sed -n 2p <<<"$out")" = "False False" ] && ok "write_known_hosts: no listed key → nothing written" \
  || bad "no keys: $(sed -n 2p <<<"$out")"
[[ "$(sed -n 3p <<<"$out")" == *"HostKeyAlias=fleet-m4 "*"UserKnownHostsFile=$FLEET_KNOWN_HOSTS ~/.ssh/known_hosts"* ]] \
  && ok "ssh_command: the fleet's known_hosts first, then the person's own" || bad "ssh_command: $(sed -n 3p <<<"$out")"
[[ "$(sed -n 4p <<<"$out")" != *UserKnownHostsFile* ]] && ok "ssh_command: no keys → ssh's own known_hosts, as before" \
  || bad "ssh_command without keys: $(sed -n 4p <<<"$out")"

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
    # try <keys…>: fleet connect's own ssh command for m4, run for real
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
    [ "$r" = "- refused - -" ] && ok "sshd: no listed key → ssh's host-key refusal (the newcomer's question)" || bad "no key: $r"
    r=$(try "$HOSTPUB")
    [ "$r" = "matched - - -" ] && ok "sshd: the hub's key → matched on the first connection, no question" || bad "listed key: $r"
    r=$(try "$OTHERPUB")
    [ "$r" = "- refused - changed" ] && ok "sshd: a key the hub did not list → still refused" || bad "changed key: $r"
  fi
fi

[ "$fail" = 0 ] && echo "PASS fleet-connect-hostkey-selftest" || echo "FAIL fleet-connect-hostkey-selftest"
exit "$fail"
