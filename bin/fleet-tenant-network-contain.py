#!/usr/bin/python3
"""Emergency Mac tenant containment. Root-owned installation; no Hub dependency.

Uses the existing com.apple/* PF filter anchor, without reloading the main
ruleset, flushing states, or changing NAT. Ordinary UIDs default to restricted,
including accounts created after installation. Explicit trusted UIDs are local.
This is TCP/UDP containment, not a VM security boundary.
"""
import argparse
import os
import pathlib
import plistlib
import pwd
import subprocess

ANCHOR = 'com.apple/fleet-tenant-net'
RULES = '/etc/pf.anchors/fleet-tenant-net'
SELF = '/Library/Application Support/claude-fleet/tenant-network-contain.py'
PLIST = '/Library/LaunchDaemons/com.claude-fleet.tenant-network-contain.plist'
SSH_CONF = '/etc/ssh/sshd_config.d/090-fleet-tenant-network.conf'
LABEL = 'com.claude-fleet.tenant-network-contain'
KEEP = '/var/db/fleet-node/keep-labels'
NETS = ('0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
        '169.254.0.0/16', '172.16.0.0/12', '192.168.0.0/16',
        '198.18.0.0/15', '224.0.0.0/4', '240.0.0.0/4',
        '::/128', '::1/128', 'fc00::/7', 'fe80::/10', 'ff00::/8',
        '::ffff:0:0/96', '64:ff9b:1::/48')


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)


def render(trusted):
    lines = ['table <fleet_tenant_internal> const { ' + ', '.join(NETS) + ' }']
    # PF cannot associate ICMP with a UID. Block it machine-wide for internal
    # destinations, retaining IPv6 errors and neighbour/router discovery.
    lines.append('block drop out quick inet proto icmp to <fleet_tenant_internal>')
    lines.append('pass out quick inet6 proto icmp6 to <fleet_tenant_internal> icmp6-type { 1 2 3 4 133 134 135 136 }')
    lines.append('block drop out quick inet6 proto icmp6 to <fleet_tenant_internal>')
    # Only these trusted accounts may initiate internal connections. The root
    # node/relay and system resolver have UIDs below 500 and are unaffected.
    for uid in sorted(set(trusted)):
        if uid < 500:
            raise ValueError('trusted ordinary account UID expected')
        lines.append('pass out quick proto { tcp udp } to <fleet_tenant_internal> user %d' % uid)
    # The credential proxy authenticates each tenant independently; do not
    # expose arbitrary localhost proxies/SSH forwarding as an escape hatch.
    lines.append('pass out quick on lo0 inet proto tcp to 127.0.0.1 port 18923 user >= 500')
    lines.append('block return out quick proto { tcp udp } to <fleet_tenant_internal> user >= 500')
    return '\n'.join(lines) + '\n'


def write(path, data, mode):
    p = pathlib.Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = str(p) + '.new'
    with open(tmp, 'wb') as f:
        f.write(data)
    os.chmod(tmp, mode)
    os.chown(tmp, 0, 0)
    os.replace(tmp, p)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action', choices=('install', 'enforce', 'rollback'))
    ap.add_argument('--trusted', nargs='+', default=[])
    a = ap.parse_args()
    if os.geteuid() != 0:
        ap.error('root required')
    if a.action == 'rollback':
        subprocess.run(['/bin/launchctl', 'bootout', 'system', PLIST], capture_output=True)
        run('/sbin/pfctl', '-a', ANCHOR, '-F', 'rules')
        pathlib.Path(PLIST).unlink(missing_ok=True)
        pathlib.Path(SSH_CONF).unlink(missing_ok=True)
        if pathlib.Path(KEEP).exists():
            lines = pathlib.Path(KEEP).read_text().splitlines()
            write(KEEP, ('\n'.join(l for l in lines if l.strip() != LABEL) + '\n').encode(), 0o600)
        print('containment disabled; main PF and other anchors unchanged')
        return
    if a.action == 'install':
        if not a.trusted:
            ap.error('explicit trusted accounts required')
        main_rules = run('/sbin/pfctl', '-sr').stdout
        if 'anchor "com.apple/*"' not in main_rules:
            raise RuntimeError('required existing com.apple/* anchor absent')
        data = render([pwd.getpwnam(n).pw_uid for n in a.trusted]).encode()
        candidate = '/etc/pf.anchors/fleet-tenant-net.candidate'
        write(candidate, data, 0o600)
        run('/sbin/pfctl', '-n', '-a', ANCHOR, '-f', candidate)
        if pathlib.Path(RULES).exists() and not pathlib.Path(RULES + '.before').exists():
            write(RULES + '.before', pathlib.Path(RULES).read_bytes(), 0o600)
        write(RULES, data, 0o600)
        # sshd may own forwarded sockets as a privileged user: disallow that
        # alternate route for tenant SSH connections, including Unix sockets.
        match = '*,!root,' + ','.join('!' + n for n in a.trusted)
        ssh = ('# Fleet tenant internal-network containment\nMatch User ' + match +
               '\n    DisableForwarding yes\nMatch all\n')
        old_ssh = pathlib.Path(SSH_CONF).read_bytes() if pathlib.Path(SSH_CONF).exists() else None
        write(SSH_CONF, ssh.encode(), 0o644)
        try:
            run('/usr/sbin/sshd', '-t')
        except Exception:
            if old_ssh is None:
                pathlib.Path(SSH_CONF).unlink()
            else:
                write(SSH_CONF, old_ssh, 0o644)
            raise
        write(SELF, pathlib.Path(__file__).read_bytes(), 0o700)
        # Use the supervisor's supported root-owned keep list, so its sweep
        # does not retire this locally installed containment service.
        kept = pathlib.Path(KEEP).read_text() if pathlib.Path(KEEP).exists() else ''
        if LABEL not in [l.strip() for l in kept.splitlines()]:
            write(KEEP, (kept.rstrip() + '\n' + LABEL + '\n').encode(), 0o600)
        doc = dict(Label=LABEL,
                   ProgramArguments=['/usr/bin/python3', '-I', SELF, 'enforce'],
                   RunAtLoad=True, StartInterval=30,
                   StandardErrorPath='/var/log/fleet-tenant-network.log',
                   StandardOutPath='/var/log/fleet-tenant-network.log')
        write(PLIST, plistlib.dumps(doc), 0o644)
    run('/sbin/pfctl', '-n', '-a', ANCHOR, '-f', RULES)
    current = run('/sbin/pfctl', '-a', ANCHOR, '-sr').stdout
    if not current.strip() or a.action == 'install':
        run('/sbin/pfctl', '-a', ANCHOR, '-f', RULES)
    if 'Status: Enabled' not in run('/sbin/pfctl', '-s', 'info').stdout:
        run('/sbin/pfctl', '-E')
    print('tenant internal TCP/UDP containment active')


if __name__ == '__main__':
    main()
