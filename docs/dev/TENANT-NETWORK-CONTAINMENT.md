# Mac tenant internal-network containment

This emergency containment is explicitly installed by an operator on a shared
Mac. It is independent of the trial-account list and does not expire when the
Hub is unavailable. It is not installed fleet-wide by the release train.

Run the reviewed script as root, with an explicit list of trusted owner and
infrastructure logins:

```sh
sudo /usr/bin/python3 -I bin/fleet-tenant-network-contain.py install --trusted OWNER OWNER_WORKER CI_LOGIN
sudo launchctl bootstrap system /Library/LaunchDaemons/com.claude-fleet.tenant-network-contain.plist
```

Every ordinary UID >= 500 is restricted immediately, including future accounts,
except the explicitly resolved trusted UIDs. System UIDs below 500 remain
trusted. Review the exception list when deleting/reusing UIDs. PF rules live in
`/etc/pf.anchors/fleet-tenant-net`, under the existing `com.apple/*` anchor. No
main-ruleset reload, NAT change, global state flush, or machine restart occurs.

TCP/UDP to RFC1918, CGNAT/Tailnet, loopback, link-local, benchmarking, multicast,
reserved IPv4, IPv6 ULA/link-local/multicast and local NAT64 space is refused.
The one tenant loopback exception is TCP `127.0.0.1:18923`, the authenticated
Fleet credential proxy. This deliberately prevents tenant localhost development
connections too: a broad loopback exception would expose the host's SSH and
proxy services. An allowed per-tenant development route requires separate design.

PF cannot associate ICMP with UIDs. Internal IPv4 ICMP and IPv6 ICMP are therefore
blocked for the whole machine, including owners, except IPv6 error messages and
router/neighbour discovery. Owner SSH/TCP connections remain allowed.

System sshd disables forwarding for non-trusted logins using
`/etc/ssh/sshd_config.d/090-fleet-tenant-network.conf`. Existing SSH transports
must reconnect to pick this up. The separately generated Fleet entry sshd config
is not modified; the PF destination rules still apply to tenant-owned sockets.

The root-owned launchd job runs at boot and every 30 seconds. The supported
`/var/db/fleet-node/keep-labels` exception prevents the supervisor from retiring
this local service. It reloads an absent anchor and ensures PF is enabled. The
network is not guaranteed isolated before launchd first runs at boot; this is
containment for live shared Macs, not a VM/network-namespace security boundary.

## Live validation on two Minis, 2026-10-22

- Nine existing external/member/spare/service logins: Tailnet IPv4 SSH, LAN SSH,
  and localhost SSH failed after succeeding before containment; Hub HTTPS TCP
  and the credential proxy remained accessible.
- Owner worker login: Tailnet IPv4, LAN, localhost and Hub connections succeeded.
- IPv6 loopback SSH: restricted login failed, trusted login succeeded. The
  MacBook's Tailnet IPv6 was unreachable for both and is not acceptance evidence.
- A restricted UDP probe incremented the PF UDP block counter.
- LAN router ping succeeded before the ICMP rule, failed afterward, and
  incremented the ICMP block counter.
- `sshd -t` passed; effective system sshd config reports forwarding disabled for
  a tenant and enabled for the owner.
- Hub authenticated node inventory still reports current managed tenant nodes
  online. No full new agent task was launched as part of this network check.

No broad port scans, credential reads from tenant homes, tmux destruction or
global connection/state flushes are part of validation. Existing PF states are
not forcibly removed; inspect established tenant connections separately. Public
proxy/VPN services, privilege escalation, non-IP sockets and globally addressed
internal resources need additional controls; use isolated VMs/PODs for a strong
untrusted-code boundary.

## Rollback

```sh
sudo /usr/bin/python3 -I '/Library/Application Support/claude-fleet/tenant-network-contain.py' rollback
```

This unloads only this job, removes its system-sshd drop-in and keep-list entry,
and flushes only its PF filter rules. It does not disable PF or alter other
anchors. Keep the root-owned script/rules for inspection. Reconnect SSH to pick
up forwarding changes.
