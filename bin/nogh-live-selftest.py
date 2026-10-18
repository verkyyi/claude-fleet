#!/usr/bin/env python3
"""C9 live isolation contracts, offline; never a live acceptance receipt.

Each entry includes setup/cleanup and has a 15-second hard bound.
"""
import importlib.util
import copy
import hashlib
import json
import os
from pathlib import Path
import signal
import selectors
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

import nogh_live_contract as live
import nogh_live_observer as observer
import nogh_live_driver as driver
import nogh_live_render as template
import nogh_live_identity as identity
import nogh_live_http as adapter
import nogh_live_gateway as gateway
import nogh_live_evidence as evidence

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("render", ROOT / "extras/managed-node/render.py")
render = importlib.util.module_from_spec(spec)
spec.loader.exec_module(render)


class StrictGuard(unittest.TestCase):
    def test_ipv6_install_failure_never_admits_test_workload(self):
        with tempfile.TemporaryDirectory(prefix="c9-guard-") as temp:
            for name, body in {
                "iptables-nft-restore": "cat >/dev/null\nexit 0",
                "iptables-nft": "printf '%s\\n' '-P OUTPUT DROP'",
                "ip6tables-nft": "printf '%s\\n' '-P OUTPUT DROP'",
                "ip6tables-nft-restore": "cat >/dev/null\necho C9_TEST_V6_FAILED >&2\nexit 1",
                "ss": "exit 0",
            }.items():
                path = Path(temp) / name
                path.write_text("#!/bin/sh\n" + body + "\n")
                path.chmod(0o700)
            guard = render.c9_egress_guard("test@sha256:" + "a" * 64, [])
            result = subprocess.run(guard["command"], env={"PATH": temp + ":/usr/bin:/bin"},
                                    capture_output=True, timeout=3)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'C9_TEST_V6_FAILED', result.stderr)
            self.assertNotIn(b"C9_GUARD_READY", result.stdout)

    def test_no_cidr_wildcard_mapping_or_implicit_loopback_dns(self):
        for ip in ('0.0.0.0', '10.0.0.0/8', '::ffff:192.0.2.1', '224.0.0.1'):
            with self.assertRaises(ValueError):
                render.c9_egress_guard('image', [dict(ip=ip, port=443, protocol='tcp')])
        script = render.c9_egress_guard('image', [dict(ip='192.0.2.5', port=443, protocol='tcp')])['command'][-1]
        self.assertIn('-d 192.0.2.5/32 -p tcp --dport 443 -j ACCEPT', script)
        self.assertNotIn('-o lo -j ACCEPT', script)
        self.assertNotIn('--dport 53', script)
        self.assertNotIn('--ctstate ESTABLISHED,RELATED', script)
        self.assertEqual(script.count(':OUTPUT DROP [0:0]'), 2)


def plan():
    uid = lambda: str(uuid.uuid4())
    run = uid()
    endpoints = [dict(role=role, name='c9-' + role, uid=uid(),
                      login='test-' + role, image='test@sha256:' + 'a' * 64,
                      binding=dict(endpoint_id='ep_' + role, fleet_id=uid(), machine_id=uid(),
                                   hostname='host-' + role, owner='gh:123') if role.startswith('node-') else None,
                      observer_digest='sha256:' + 'b' * 64,
                      command_digest='sha256:' + 'c' * 64 if role in ('hub', 'node-a', 'node-b') else None,
                      tls_cert_digest='sha256:' + 'd' * 64 if role == 'proxy' else None,
                      pod_ip='192.0.2.%d' % (10 + n), execution_generation=1)
                 for n, role in enumerate(sorted(live.ROLES))]
    p = dict(version=1, purpose='c9-disposable-test', run_id=run, generation=1,
             source_sha='a' * 40, namespace='c9-' + run, namespace_uid=uid(), cluster_uid=uid(),
             controller='system:serviceaccount:c9-' + run + ':c9-controller', row='A1',
             hub=dict(origin='https://hub.test:8443', key_digest='sha256:' + 'd' * 64, commit='a' * 40),
             expires_at=time.time() + 120, budget_seconds=45, endpoints=endpoints, routes=[],
             probes=dict(github_ipv4='203.0.113.1', github_ipv6='2001:db8::1',
                         bypass_ipv4='203.0.113.2', bypass_port=3128))
    by_role = {e['role']: e for e in endpoints}
    for source in sorted(live.ROLES):
        for target, purpose, port in (('hub', 'hub', 8443), ('proxy', 'provider', 3128),
                                     ('dns', 'dns', 53)):
            p['routes'].append(dict(**{'from': source, 'to': target}, purpose=purpose,
                                    ip=by_role[target]['pod_ip'], port=port, protocol='tcp',
                                    origin='' if purpose == 'dns' else 'http://%s.test:%d' % (target, port)))
    p['routes'].append(dict(**{'from': 'proxy', 'to': 'provider-origin'}, purpose='provider',
                            ip='198.51.100.1', port=443, protocol='tcp', origin='https://provider.test:443'))
    p['routes'].append(dict(**{'from': 'proxy', 'to': 'forge-origin'}, purpose='forge',
                            ip='198.51.100.2', port=443, protocol='tcp', origin='https://forge.test:443'))
    return p


class WorkloadEvidence(unittest.TestCase):
    def record(self, kind='business'):
        return dict(kind=kind, name='test-api-result', data=dict(observed='fixture-only'))

    def capture(self, p=None):
        return evidence.Capture(p or plan(), 'node-a')

    def finish(self, capture):
        for key in capture.streams:
            capture.feed(key, b'')
        return capture.finish()

    def test_real_inherited_stdout_stderr_are_bound_to_launch_and_original_pod(self):
        p = plan(); capture = self.capture(p)
        selector = selectors.DefaultSelector()
        process = None
        try:
            outputs = capture.pipes()
            # A detached descendant inherits only the chosen launch's streams.
            # Its late record must be retained after the direct child exits.
            command = ('import json,os,time; child=os.fork(); '
                       'os._exit(0) if child else None; time.sleep(0.02); '
                       'os.write(1,(json.dumps(%r)+"\\n").encode()); '
                       'os.write(2,(json.dumps(%r)+"\\n").encode())' %
                       (self.record(), self.record('native')))
            process = subprocess.Popen([sys.executable, '-c', command], stdin=subprocess.DEVNULL,
                                       close_fds=True, **outputs['row:A1'])
            capture.close_writers()
            for fd, key in capture.readers.items():
                selector.register(fd, selectors.EVENT_READ, key)
            deadline = time.monotonic() + 2
            while selector.get_map():
                self.assertLess(time.monotonic(), deadline)
                for key, _ in selector.select(0.05):
                    block = os.read(key.fd, 65536)
                    capture.feed(key.data, block)
                    if not block: selector.unregister(key.fd)
            self.assertEqual(process.wait(timeout=1), 0)
            bundle = capture.finish()
            proof = dict(workload_evidence_digest=live.fingerprint(bundle))
            evidence.check(p, 'node-a', bundle, proof)
            evidence.row_coverage(p, {'node-a': bundle})
            self.assertEqual({r['stream'] for r in bundle['records']}, {'stdout', 'stderr'})
            self.assertEqual({r['launch'] for r in bundle['records']}, {'row:A1'})
            ep = next(e for e in p['endpoints'] if e['role'] == 'node-a')
            self.assertEqual(bundle['endpoint_uid'], ep['uid'])
            self.assertEqual(bundle['run_id'], p['run_id'])
            self.assertEqual(bundle['row'], 'A1')
            for field, changed in [('endpoint_uid', str(uuid.uuid4())), ('row', 'A2'), ('run_id', str(uuid.uuid4()))]:
                bad = dict(bundle, **{field: changed})
                with self.assertRaises(live.Refused): evidence.check(p, 'node-a', bad, proof)
            bad = copy.deepcopy(bundle); bad['records'][0]['body']['data']['observed'] = 'changed'
            with self.assertRaises(live.Refused): evidence.check(p, 'node-a', bad, proof)
        finally:
            selector.close(); capture.close()
            if process is not None and process.poll() is None:
                process.kill(); process.wait(timeout=1)

    def test_output_limit_partial_line_missing_eof_and_unstructured_output_refuse(self):
        with self.assertRaises(live.Refused): self.capture().finish()
        for raw in (b'not JSON\n', b'\xff\n', b'x' * (evidence.MAX_LINE + 1),
                    live.canonical(self.record()), b'{}\n'):
            capture = self.capture()
            with self.assertRaises(live.Refused):
                capture.feed(('row:A1', 'stdout'), raw)
                self.finish(capture)
        capture = self.capture()
        with self.assertRaises(live.Refused):
            capture.feed(('row:A1', 'stdout'), b'x' * (evidence.MAX_BYTES + 1))
        capture = self.capture()
        with self.assertRaises(live.Refused):
            for _ in range(evidence.MAX_RECORDS + 1):
                capture.feed(('row:A1', 'stdout'), live.canonical(self.record()) + b'\n')

    def test_exit_zero_empty_or_missing_restored_evidence_cannot_substitute(self):
        p = plan(); capture = self.capture(p)
        bundle = self.finish(capture)
        with self.assertRaises(live.Refused): evidence.row_coverage(p, {'node-a': bundle})
        p['row'] = 'A4'; capture = self.capture(p)
        for phase in ('row:A4', 'row:A4-denied'):
            for kind in ('business', 'native'):
                capture.feed((phase, 'stdout'), live.canonical(self.record(kind)) + b'\n')
        with self.assertRaises(live.Refused):
            evidence.row_coverage(p, {'node-a': self.finish(capture)})


class Binding(unittest.TestCase):
    def test_valid_plan_is_only_a_digest_not_live_success(self):
        self.assertRegex(live.validate(plan()), '^sha256:[a-f0-9]{64}$')

    def test_production_shared_and_incomplete_targets_refuse(self):
        changes = [lambda p: p.update(namespace='fleet-workers'),
                   lambda p: p.update(purpose='production'),
                   lambda p: p.update(expires_at=time.time() - 1),
                   lambda p: p.update(budget_seconds=60),
                   lambda p: p['endpoints'].pop(),
                   lambda p: p['endpoints'][1].update(uid=p['endpoints'][0]['uid']),
                   lambda p: p['endpoints'][1].update(pod_ip=p['endpoints'][0]['pod_ip']),
                   lambda p: p['endpoints'][3]['binding'].update(endpoint_id=p['endpoints'][2]['binding']['endpoint_id']),
                   lambda p: p['endpoints'][1].update(image='test:latest'),
                   lambda p: p.update(token='SECRET_MUST_NOT_APPEAR'),
                   lambda p: p['routes'][-1].update(origin='https://user:SECRET@forge.test:9418'),
                   lambda p: p['routes'][-1].update(ip='198.51.100.0/24'),
                   lambda p: p['routes'][-1].update(origin='git://github.com:9418'),
                   lambda p: p['routes'][-1].update(**{'from': 'node-a'})]
        for change in changes:
            p = plan(); change(p)
            with self.assertRaises(live.Refused) as error:
                live.validate(p)
            self.assertNotIn('SECRET', str(error.exception))

    def test_private_manifest_never_replaces_old_generation_or_follows_link(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'manifest.json'
            p = plan(); live.write_private(path, p)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(live.read_private(path), p)
            with self.assertRaises(FileExistsError): live.write_private(path, plan())
            link = Path(temp) / 'link'; link.symlink_to(path)
            with self.assertRaises(OSError): live.read_private(link)
            path.chmod(0o644)
            with self.assertRaises(live.Refused): live.read_private(path)


class Observations(unittest.TestCase):
    def setUp(self):
        self.p = plan()
        self.interval = live.Interval(self.p, 'node-a', 'A1', 1)

    def event(self, kind, data, **changes):
        i = self.interval
        event = dict(run_id=i.run_id, generation=i.generation, endpoint_uid=i.binding['uid'],
                     execution_generation=i.binding['execution_generation'], interval=i.serial,
                     seq=i.sequence + 1, kind=kind, data=data)
        event.update(changes)
        i.event(event)

    def ready(self):
        self.event('ready', dict(coverage='exclusive-pid-namespace', inherited_sockets=0, io_uring='ENOSYS'))
        self.event('fork', dict(pid=123, parent=0))

    def end(self):
        self.event('exit', dict(pid=123))
        self.event('end', dict(pending_syscalls=0, command_exit=0))
        self.event('eof', dict(observer_exit=0))

    def test_missing_observer_or_eof_never_pass(self):
        with self.assertRaises(live.Refused): self.interval.seal()
        self.ready()
        self.event('exit', dict(pid=123))
        self.event('end', dict(pending_syscalls=0, command_exit=0))
        with self.assertRaises(live.Refused): self.interval.seal()

    def test_complete_observation_still_is_not_live_acceptance(self):
        self.ready(); self.end()
        receipt = self.interval.seal()
        self.assertEqual(receipt['observation'], 'COMPLETE')
        self.assertEqual(receipt['live'], 'NOT RUN')

    def test_old_generation_late_or_missing_event_is_sticky(self):
        for change in (dict(generation=0), dict(execution_generation=0), dict(interval=0), dict(seq=4),
                       dict(endpoint_uid=str(uuid.uuid4()))):
            self.setUp(); self.ready()
            with self.assertRaises(live.Refused): self.event('exit', dict(pid=123), **change)
            with self.assertRaises(live.Refused): self.end()
            with self.assertRaises(live.Refused): self.interval.seal()

    def test_unknown_and_failed_attempts_fail_zero(self):
        for category in live.COUNTERS[:5]:
            self.setUp(); self.ready()
            self.event('attempt', dict(pid=123, category=category, count=1))
            self.end()
            with self.assertRaises(live.Refused): self.interval.seal()

    def test_unowned_child_and_new_root_after_exit_refuse(self):
        self.ready()
        with self.assertRaises(live.Refused): self.event('fork', dict(pid=456, parent=999))
        self.setUp(); self.ready(); self.event('exit', dict(pid=123))
        with self.assertRaises(live.Refused): self.event('fork', dict(pid=456, parent=0))

    def test_io_uring_not_fenced_and_inherited_socket_refuse(self):
        for changes in (dict(io_uring='allowed'), dict(inherited_sockets=1), dict(coverage='proc-sample')):
            self.setUp()
            ready = dict(coverage='exclusive-pid-namespace', inherited_sockets=0, io_uring='ENOSYS')
            ready.update(changes)
            with self.assertRaises(live.Refused): self.event('ready', ready)


class TraceMetadata(unittest.TestCase):
    def make_trace(self, calls):
        trace = observer.Trace(plan(), 'node-a')
        trace.feed('7 1.000 execve("/usr/bin/python3", [""...], 0x1) = 0 <0.001>\n')
        trace.feed('7 1.010 write(198, ""..., 1) = 1 <0.001>\n')
        for n, call in enumerate(calls):
            trace.feed('7 %.3f %s <0.001>\n' % (1.1 + n / 100, call))
        size = observer.PHASES.index('end') + 1
        trace.feed('7 2.000 write(198, ""..., %d) = %d <0.001>\n' % (size, size))
        trace.feed('7 2.100 +++ exited with 0 +++\n')
        return trace

    def test_failed_connect_does_not_turn_inet_socket_local(self):
        trace = self.make_trace([
            'socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) = 3',
            'connect(3, {sa_family=AF_INET, sin_port=htons(443), sin_addr=inet_addr("203.0.113.1")}, 16) = -1 EINPROGRESS (Operation now in progress)',
            'connect(3, {sa_family=AF_UNIX, sun_path=""...}, 16) = -1 EAFNOSUPPORT (Address family not supported)',
            'write(3, ""..., 99) = -1 EPIPE (Broken pipe)',
            'writev(3, [{iov_base=""..., iov_len=1}], 1) = -1 EPIPE (Broken pipe)',
        ])
        self.assertEqual(trace.finish(0)['intervals']['startup']['github_network'], 3)

    def test_netlink_route_query_allowed_but_raw_ip_refuses(self):
        self.make_trace(['socket(AF_NETLINK, SOCK_RAW|SOCK_CLOEXEC, NETLINK_ROUTE) = 3']).finish(0)
        with self.assertRaises(live.Refused):
            self.make_trace(['socket(AF_INET, SOCK_RAW, IPPROTO_RAW) = 3'])

    def test_rights_and_incomplete_stream_are_not_zero(self):
        with self.assertRaises(live.Refused):
            self.make_trace(['recvmsg(3, {msg_control=[{cmsg_type=SCM_RIGHTS, cmsg_data=[4]}]}, 0) = 1'])
        trace = self.make_trace([])
        trace.pending[8] = (1.5, 'connect(')
        with self.assertRaises(live.Refused): trace.finish(0)

    def test_kernel_typed_local_ipc_rights_do_not_hide_internet_sockets(self):
        self.make_trace([
            'recvmsg(3<UNIX-STREAM:[111->222]>, {msg_control=[{cmsg_type=SCM_RIGHTS, cmsg_data=[4</memfd:browser (deleted)>, 5<UNIX-STREAM:[333->444]>]}]}, 0) = 1',
            'write(4</memfd:browser (deleted)>, ""..., 1) = 1',
        ]).finish(0)
        with self.assertRaises(live.Refused):
            self.make_trace(['recvmsg(3, {msg_control=[{cmsg_type=SCM_RIGHTS, cmsg_data=[4<TCP:[192.0.2.1:10->203.0.113.1:443]>]}]}, 0) = 1'])
        # tmux's client hands the server its standard fds; -yy decodes a
        # character device as path<char M:N> (live, #4625). Accepted; a block
        # device or a socket inside the same shape is still refused.
        self.make_trace([
            'recvmsg(3<UNIX-STREAM:[111->222]>, {msg_control=[{cmsg_type=SCM_RIGHTS, cmsg_data=[7</dev/null<char 1:3>>, 8</dev/pts/0<char 136:0>>]}]}, 0) = 1',
        ]).finish(0)
        for bad in ('7</dev/sda<block 8:0>>', '7</dev/null<char 1:3><TCP:[192.0.2.1:10->203.0.113.1:443]>>'):
            with self.assertRaises(live.Refused):
                self.make_trace(['recvmsg(3, {msg_control=[{cmsg_type=SCM_RIGHTS, cmsg_data=[' + bad + ']}]}, 0) = 1'])

    def test_fd_annotations_never_rewrite_quoted_exec_names(self):
        text, fds = observer.descriptor_metadata('execve("/tmp/3<gh>", [], 0) = 0')
        self.assertEqual(text, 'execve("/tmp/3<gh>", [], 0) = 0')
        self.assertEqual(fds, {})
        text, fds = observer.descriptor_metadata('write(198</dev/null<char 1:3>>, ""..., 1) = 1')
        self.assertEqual(text, 'write(198, ""..., 1) = 1')
        text, fds = observer.descriptor_metadata('recvmsg(3, {cmsg_data=[4</memfd:test>(deleted)]}, 0) = 1')
        self.assertEqual(text, 'recvmsg(3, {cmsg_data=[4]}, 0) = 1')
        self.assertEqual(fds[4], '/memfd:test (deleted)')

    def test_teardown_attempts_are_kept(self):
        trace = self.make_trace(['socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP) = 3'])
        trace.decode(7, 2.05, 2.06,
                     'sendto(3, ""..., 2, 0, {sa_family=AF_INET, sin_port=htons(443), sin_addr=inet_addr("203.0.113.1")}, 16) = -1 EPERM')
        self.assertEqual(trace.finish(0)['intervals']['end']['github_network'], 1)

    def test_shared_fd_close_during_accept_cannot_hide_write(self):
        trace = self.make_trace(['socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) = 3'])
        trace.decode(7, 1.2, 1.21, 'clone(flags=CLONE_FILES) = 8')
        trace.decode(7, 1.3, 1.6, 'accept(3, NULL, NULL) = 4')
        trace.decode(8, 1.4, 1.5, 'close(4) = 0')
        trace.decode(8, 1.7, 1.8, 'write(4, ""..., 1) = 1')
        trace.exited.add(8)
        with self.assertRaisesRegex(live.Refused, 'FD_ORDER_AMBIGUOUS'):
            trace.finish(0)

    def test_resumed_call_rejoins_like_an_uninterrupted_one(self):
        # live (#4625): strace's unfinished prefix ends `0,  <unfinished` (two
        # spaces); a resumed socketpair's fds must read as the plain call's.
        trace = observer.Trace(plan(), 'node-a')
        for line in ('7 1.000 execve("/usr/bin/python3", [""...], 0x1) = 0 <0.001>',
                     '7 1.010 write(198, ""..., 1) = 1 <0.001>',
                     '7 1.100 socketpair(AF_UNIX, SOCK_STREAM, 0,  <unfinished ...>',
                     '7 1.200 <... socketpair resumed>[8<UNIX:[11->12]>, 9<UNIX:[12->11]>]) = 0 <0.001>',
                     '7 1.300 write(9<UNIX:[12->11]>, ""..., 1) = 1 <0.001>',
                     # ...and one cut after its LAST argument (a proxy's reply)
                     '7 1.400 socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) = 3 <0.001>',
                     '7 1.500 sendto(3<TCP:[192.0.2.1:1->192.0.2.2:2]>, ""..., 39, MSG_NOSIGNAL, NULL, 0 <unfinished ...>',
                     '7 1.600 <... sendto resumed>) = 39 <0.001>',
                     '7 2.000 write(198, ""..., %d) = %d <0.001>' % ((observer.PHASES.index('end') + 1,) * 2),
                     '7 2.100 +++ exited with 0 +++'):
            trace.feed(line + '\n')
        trace.finish(0)

    def test_refusal_names_its_check_and_syscall_only(self):
        # A live run keeps no raw trace: the failure record says WHICH check
        # refused and on WHICH syscall, as identifiers — never the line (#4625).
        trace = observer.Trace(plan(), 'node-a')
        with self.assertRaises(live.Refused) as caught:
            trace.feed('7 1.0 <... wait4 resumed> <unfinished ...>) = ?\n')
        self.assertEqual(str(caught.exception), 'TRACE_FORMAT_OR_COVERAGE')
        self.assertEqual(caught.exception.detail, 'UNMATCHED_RESUME@wait4')
        trace = observer.Trace(plan(), 'node-a')
        with self.assertRaises(live.Refused) as caught:
            trace.feed('7 1.0 connect(3, {sa_family=AF_INET, sin_port=htons(443), sin_addr=inet_addr("/secret/path")}, 16) = 0\n')
        self.assertNotIn('secret', caught.exception.detail)
        self.assertRegex(caught.exception.detail, r'^[A-Z0-9_]+@connect$')
        import nogh_live_runtime as runtime
        self.assertTrue(runtime.DETAIL.fullmatch('UNMATCHED_RESUME@wait4'))
        for bad in ('x', 'A B', 'CODE@/etc/passwd', 'CODE@Upper', 'A' * 65):
            self.assertIsNone(runtime.DETAIL.fullmatch(bad), bad)

    def test_inert_close_beside_a_sibling_fork_is_ordered_enough(self):
        # live (#4625): a Go agent's thread closes a pipe while another forks.
        # No socket is made, dropped or copied, so attribution cannot change.
        trace = self.make_trace(['socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) = 3'])
        trace.decode(7, 1.2, 1.21, 'clone(flags=CLONE_VM|CLONE_FILES|CLONE_THREAD) = 8')
        trace.decode(7, 1.3, 1.6, 'fork() = 9')
        trace.decode(8, 1.4, 1.5, 'close(5) = 0')
        trace.decode(8, 1.42, 1.45, 'dup2(6, 7) = 7')
        trace.exited.update({8, 9})
        trace.finish(0)
        # ...but a socket made, or a tracked socket closed, beside the fork is not
        for racing in ('socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) = 5', 'close(3) = 0', 'dup2(3, 6) = 6'):
            trace = self.make_trace(['socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) = 3'])
            trace.decode(7, 1.2, 1.21, 'clone(flags=CLONE_VM|CLONE_FILES|CLONE_THREAD) = 8')
            trace.decode(7, 1.3, 1.6, 'fork() = 9')
            trace.decode(8, 1.4, 1.5, racing)
            trace.exited.update({8, 9})
            with self.assertRaisesRegex(live.Refused, 'FD_ORDER_AMBIGUOUS'):
                trace.finish(0)

    def test_call_cut_off_by_process_exit_is_a_failed_attempt(self):
        # live (#4625): a thread inside a syscall when a sibling exit_groups.
        trace = observer.Trace(plan(), 'node-a')
        for line in ('7 1.000 execve("/usr/bin/python3", [""...], 0x1) = 0 <0.001>',
                     '7 1.010 write(198, ""..., 1) = 1 <0.001>',
                     '7 1.100 clone(flags=CLONE_VM|CLONE_FILES|CLONE_THREAD) = 8 <0.001>',
                     '8 1.200 socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) = 3 <0.001>',
                     '8 1.300 connect(3, {sa_family=AF_INET, sin_port=htons(443), sin_addr=inet_addr("203.0.113.1")}, 16 <unfinished ...>',
                     '7 1.400 wait4(-1,  <unfinished ...>',
                     '7 1.500 <... wait4 resumed> <unfinished ...>) = ?',
                     '8 1.500 <... connect resumed> <unfinished ...>) = ?',
                     '8 1.600 +++ exited with 0 +++',
                     '7 2.000 write(198, ""..., %d) = %d <0.001>' % ((observer.PHASES.index('end') + 1,) * 2),
                     '7 2.100 +++ exited with 0 +++'):
            trace.feed(line + '\n')
        self.assertEqual(trace.finish(0)['intervals']['startup']['github_network'], 1)
        with self.assertRaises(live.Refused):  # a resume with nothing pending stays refused
            observer.Trace(plan(), 'node-a').feed('7 1.0 <... wait4 resumed> <unfinished ...>) = ?\n')

    def test_fork_alias_reconnect_during_write_refuses(self):
        trace = self.make_trace(['socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) = 3'])
        trace.decode(7, 1.2, 1.21, 'fork() = 8')
        trace.decode(7, 1.3, 1.6, 'connect(3, {sa_family=AF_INET, sin_port=htons(443), sin_addr=inet_addr("203.0.113.1")}, 16) = 0')
        trace.decode(8, 1.4, 1.5, 'write(3, ""..., 1) = 1')
        trace.exited.add(8)
        with self.assertRaisesRegex(live.Refused, 'FD_ORDER_AMBIGUOUS'):
            trace.finish(0)

    def test_vfork_child_exec_before_parent_returns_is_supported(self):
        trace = self.make_trace([])
        trace.decode(7, 1.2, 1.6, 'vfork() = 8')
        trace.decode(8, 1.3, 1.4, 'execve("/usr/bin/true", [], 0x1) = 0')
        trace.exited.add(8)
        self.assertEqual(trace.finish(0)['processes'], 2)

    def test_namespace_and_pidfd_socket_injection_refuse(self):
        for call in ('unshare(CLONE_FILES) = 0', 'pidfd_getfd(4, 5, 0) = 7', 'setns(4, 0) = 0'):
            with self.assertRaises(live.Refused): self.make_trace([call])


def proofs(p):
    phases = driver.schedule(p['row'])
    result = {}
    for ep in p['endpoints']:
        intervals = {phase: {} for phase in phases}
        intervals['startup']['io_uring_fenced'] = 1
        intervals['allow:hub']['allow_hub'] = 1
        for phase in phases:
            if phase.startswith('deny:'):
                category = 'github_cli' if phase.split(':')[1] in ('gh-path', 'gh-absolute', 'execveat') else \
                    'unknown' if phase == 'deny:proxy-bypass' else 'github_network'
                intervals[phase][category] = 1
        result[ep['role']] = dict(observer='COMPLETE', processes=1, endpoint_uid=ep['uid'],
            execution_generation=1, generation=p['generation'], plan_digest=live.validate(p),
            intervals=intervals, command_results={s: 0 for s in phases if s != 'end'}, gateway=[])
    result['proxy']['gateway'] = [dict(type='gateway', source=r, category='success_provider', phase='allow:provider')
                                 for r in live.ROLES]
    return result


class Verdict(unittest.TestCase):
    def test_gate_requires_controls_identity_eof_and_every_role(self):
        p = plan(); values = proofs(p)
        self.assertEqual(driver.seal(p, values)['g3_g4'], 'PASS')
        for change in (
            lambda x: x.pop('dns'),
            lambda x: x['node-a'].update(observer='LOST'),
            lambda x: x['node-a'].update(endpoint_uid=str(uuid.uuid4())),
            lambda x: x['node-a'].update(execution_generation=2),
            lambda x: x['node-a'].update(generation=0),
            lambda x: x['node-a']['intervals']['end'].update(github_network=1),
            lambda x: x['node-a']['command_results'].update(identity=1),
            lambda x: x['node-a']['intervals']['deny:github-v6'].clear(),
            lambda x: x['proxy']['gateway'].clear(),
        ):
            candidate = copy.deepcopy(values); change(candidate)
            with self.assertRaises(live.Refused): driver.seal(p, candidate)

    def test_gateway_attribution_is_not_overwritten_by_endpoint_order(self):
        p = plan(); values = proofs(p)
        values['dns']['gateway'].append(dict(type='gateway', source='node-a',
                                             category='github_network', phase='row:A1'))
        with self.assertRaises(live.Refused): driver.seal(p, values)

    def test_a4_does_not_infer_real_checks_from_work_exit(self):
        p = plan(); p['row'] = 'A4'; values = proofs(p)
        with self.assertRaises(live.Refused): driver.seal(p, values)


class HubIdentity(unittest.TestCase):
    def setUp(self):
        self.p = plan()
        key = b'ed25519 C9-FIXTURE-ONLY\n'
        self.p['hub']['key_digest'] = 'sha256:' + hashlib.sha256(key).hexdigest()
        self.responses = {'/v1/fleet/account-key': key, '/v1/me': {'role': 'operator'},
                          '/version': {'commit': 'a' * 7}, '/v1/nodes': {'nodes': []},
                          '/v1/fleet/fleet_list': {'fleets': []}, '/v1/fleet/accounts': {'accounts': []}}
        for ep in self.p['endpoints']:
            if not ep['binding']: continue
            b = ep['binding']
            self.responses['/v1/nodes']['nodes'].append(dict(endpoint_id=b['endpoint_id'],
                connected=True, compatible=True, machine_id=b['machine_id'], hostname=b['hostname'], os_user=ep['login']))
            self.responses['/v1/fleet/fleet_list']['fleets'].append(dict(fleet_id=b['fleet_id'],
                registered=True, availability='online', endpoint_id=b['endpoint_id'],
                machine_id=b['machine_id'], os_user=ep['login']))
            self.responses['/v1/fleet/accounts']['accounts'].append(dict(hostname=b['hostname'],
                login=ep['login'], state='active', principal_id=b['owner'], endpoint_id='different-admin-endpoint'))
            self.responses['/v1/fleet/fleet_status?fleet_id=' + b['fleet_id']] = dict(source='live',
                fleet_id=b['fleet_id'], machine_id=b['machine_id'], os_user=ep['login'], machine_name=b['hostname'])

    def get(self, path, raw=False):
        self.assertNotIn('refresh', path)
        return self.responses[path]

    def test_exact_normal_identity_and_account_owner_join(self):
        self.assertEqual(len(identity.verify(self.p, self.get)['endpoints']), 2)
        self.responses['/v1/fleet/accounts']['accounts'][0]['principal_id'] = 'different-owner'
        with self.assertRaisesRegex(live.Refused, 'OWNER_CHANGED'):
            identity.verify(self.p, self.get)

    def test_cold_start_is_retryable_but_mismatch_is_not(self):
        nodes = self.responses['/v1/nodes']['nodes']
        nodes[0]['connected'] = False
        with self.assertRaises(identity.NotReady): identity.verify(self.p, self.get)
        nodes[0]['machine_id'] = 'wrong-machine'
        with self.assertRaisesRegex(live.Refused, 'NODE_BINDING_CHANGED'):
            identity.await_ready(self.p, self.get, seconds=0)

    def test_cached_status_and_changed_key_cannot_be_live(self):
        status = next(v for k, v in self.responses.items() if k.startswith('/v1/fleet/fleet_status?'))
        status['source'] = 'cache'
        with self.assertRaises(identity.NotReady): identity.verify(self.p, self.get)
        self.responses['/v1/fleet/account-key'] = b'ed25519 WRONG\n'
        with self.assertRaisesRegex(live.Refused, 'HUB_KEY_CHANGED'): identity.verify(self.p, self.get)

    def test_live_read_timeout_is_not_ready_and_has_its_own_bound(self):
        # live (#4625): fleet_status is the hub asking the node under strace —
        # a read past 2 s timed out as a bare TimeoutError and failed identity.
        from unittest import mock
        seen = []
        class Opener:
            def open(self, request, timeout):
                seen.append((request.full_url.split('8443', 1)[-1], timeout))
                raise TimeoutError('read timed out')
        with mock.patch.object(identity.Path, 'read_text', return_value='tok'), \
                mock.patch.object(identity.urllib.request, 'build_opener', return_value=Opener()), \
                mock.patch.object(identity.ssl, 'create_default_context'):
            get = identity.reader(self.p)
            with self.assertRaises(identity.NotReady):
                get('/v1/fleet/fleet_status?fleet_id=x')
            with self.assertRaises(identity.NotReady):
                get('/version')
        self.assertEqual([t for _, t in seen], [identity.LIVE_READ_TIMEOUT, 2])

class Templates(unittest.TestCase):
    def test_api_omits_only_known_zero_value_fields(self):
        p = plan(); ep = p['endpoints'][0]; pod = template.pod(p, ep)
        for key in ('hostNetwork', 'hostPID', 'hostIPC'): pod['spec'].pop(key)
        pod['spec']['dnsConfig'].pop('searches')
        for c in pod['spec']['containers'] + pod['spec']['initContainers']: c.pop('tty')
        template.check_pod(p, ep, pod)
        pod['spec'].pop('automountServiceAccountToken')
        with self.assertRaises(live.Refused): template.check_pod(p, ep, pod)

    def test_unbound_recipe_has_no_fabricated_object_identity(self):
        p = plan(); p['routes'] = []
        for ep in p['endpoints']:
            for key in ('uid', 'pod_ip', 'execution_generation'): ep.pop(key)
        with self.assertRaises(live.Refused): template.render(p)
        objects = template.render(p, test_only=True)
        pods = [o for o in objects if o['kind'] == 'Pod']
        self.assertEqual(len(pods), 5)
        self.assertTrue(all('uid' not in pod['metadata'] for pod in pods))
        for pod in pods:
            mounts = pod['spec']['containers'][0]['volumeMounts']
            self.assertTrue(any(m.get('subPath') == 'resolv.conf' for m in mounts))
        # The API server types containers and initContainers apart: a `+` of the
        # two has no CEL overload and failed the -pods policy's typeChecking live
        # (#4625). Each list carries the same container rule on its own.
        expressions = [v['expression'] for o in objects if o['kind'] == 'ValidatingAdmissionPolicy'
                       for v in o['spec']['validations']]
        self.assertFalse(any('containers + object.spec.initContainers' in e for e in expressions))
        rule = [e for e in expressions if 'object.spec.containers.all(c, ' in e]
        self.assertEqual(len(rule), 1)
        self.assertIn('object.spec.initContainers.all(c, ' + template.CONTAINER_RULE.split(' %s')[0], rule[0])
        # A Pod CREATE carries no subResource key; an unguarded read errors and
        # failurePolicy Fail denied all five Pods live (#4625).
        for e in expressions:
            reads = e.count('request.subResource')
            self.assertEqual(reads, 2 * e.count('has(request.subResource)'), e)

    def test_extra_process_and_capability_surfaces_refuse(self):
        p = plan(); ep = next(e for e in p['endpoints'] if e['role'] == 'node-a')
        for change in (
            lambda pod: pod['spec']['containers'][0].update(lifecycle={'postStart': {'exec': {'command': ['false']}}}),
            lambda pod: pod['spec']['containers'][0]['securityContext'].update(procMount='Unmasked'),
            lambda pod: pod['spec']['containers'][0]['securityContext']['capabilities']['add'].append('NET_ADMIN'),
        ):
            pod = template.pod(p, ep); change(pod)
            with self.assertRaises(live.Refused): template.check_pod(p, ep, pod)

    def test_proxy_authority_has_no_ambiguous_spelling(self):
        self.assertEqual(adapter.authority('api.example.test:443'), ('api.example.test', 443))
        for bad in ('api.example.test', 'API.example.test:443', 'a@b:443', 'a:0443', '[::1]:443',
                    '127.0.0.1:443', 'a.:443'):
            with self.assertRaises(live.Refused): adapter.authority(bad)

    def test_restored_dns_stays_denied_until_its_interval(self):
        import struct
        p = plan(); p['row'] = 'A4'
        p['routes'].append(dict(**{'from': 'proxy', 'to': 'github-origin'}, purpose='github_restored',
                                ip='198.51.100.3', port=443, protocol='tcp', origin='https://api.github.com:443'))
        policy = gateway.Policy(p, 'dns')
        query = struct.pack('!6H', 1, 0x100, 1, 0, 0, 0) + b'\x03api\x06github\x03com\x00\x00\x01\x00\x01'
        source = p['endpoints'][0]['pod_ip']
        for phase, status in [('deny:dns-udp', 3), ('row:A4-denied', 3), ('row:A4-restored', 0)]:
            with patch.object(policy, 'phase', return_value=phase), patch.object(policy, 'record'):
                self.assertEqual(policy.dns(query, source)[3] & 15, status)

    def test_terminal_wait_retries_only_original_running_status(self):
        from types import SimpleNamespace
        cluster = SimpleNamespace(remaining=lambda cap: 0)
        with patch.object(driver, 'terminal_snapshot', side_effect=[live.Refused('POD_NOT_TERMINAL'), None]) as read:
            driver.terminal(cluster, plan())
            self.assertEqual(read.call_count, 2)
        with patch.object(driver, 'terminal_snapshot', side_effect=live.Refused('TEST_TEMPLATE_CHANGED')) as read:
            with self.assertRaises(live.Refused): driver.terminal(cluster, plan())
            self.assertEqual(read.call_count, 1)


class LiveRowEntry(unittest.TestCase):
    """#4630: the entry must be able to carry a real row, not only fixtures."""

    def test_phase_result_waits_for_the_phase_bound_not_five_seconds(self):
        from types import SimpleNamespace
        self.assertEqual(driver.reply_seconds('result', 'row:A1'), observer.phase_timeout('row:A1') + 5)
        self.assertGreaterEqual(driver.reply_seconds('result', 'row:A7'), 30)
        self.assertGreaterEqual(driver.reply_seconds('result', 'identity'), 30)  # await_ready's 20 s (+ one 6 s live read) fits
        self.assertEqual(driver.reply_seconds('result', 'deny:gh-path'), 2 + 5)
        self.assertEqual(driver.reply_seconds('marked', 'row:A1'), 5)
        asked = []
        cluster = SimpleNamespace(remaining=lambda cap: asked.append(cap) or cap)
        read, write = os.pipe()
        try:
            channel = driver.Channel.__new__(driver.Channel)
            channel.cluster, channel.buffer, channel.total = cluster, bytearray(), 0
            channel.process = SimpleNamespace(stdout=os.fdopen(read, 'rb', buffering=0))
            os.write(write, live.canonical(dict(type='result', phase='row:A3', exit=0)) + b'\n')
            self.assertEqual(channel.receive('result', 'row:A3')['exit'], 0)
            self.assertEqual(asked, [35])
        finally:
            os.close(write); channel.process.stdout.close()

    def test_hub_name_bypasses_the_proxy_and_workloads_get_the_test_ca(self):
        import nogh_live_runtime as runtime
        p = plan()
        env = runtime.workload_environment(p, 'http://192.0.2.99:3128')
        direct = env['NO_PROXY'].split(',')
        self.assertIn('hub.test', direct)
        self.assertTrue({e['pod_ip'] for e in p['endpoints']} <= set(direct))
        self.assertEqual(env['no_proxy'], env['NO_PROXY'])
        self.assertEqual(env['HTTPS_PROXY'], 'http://192.0.2.99:3128')
        self.assertEqual(env['SSL_CERT_FILE'], '/run/c9-credentials/ca.pem')

    def test_proxy_upstream_verifies_against_the_system_store_not_ssl_cert_file(self):
        import ssl
        calls = []

        def honours_env(*_):
            raise AssertionError('honours SSL_CERT_FILE')

        with tempfile.TemporaryDirectory(prefix='c9-ca-') as temp:
            system = Path(temp) / 'system.pem'; system.write_text('')
            store = Path(temp) / 'certs'; store.mkdir()
            paths = ssl.DefaultVerifyPaths(None, None, 'SSL_CERT_FILE', str(system), 'SSL_CERT_DIR', str(store))
            with patch.object(ssl.SSLContext, 'load_verify_locations',
                              lambda self, cafile=None, capath=None, cadata=None: calls.append((cafile, capath))), \
                    patch.object(ssl.SSLContext, 'load_default_certs', honours_env), \
                    patch.object(ssl.SSLContext, 'set_default_verify_paths', honours_env), \
                    patch.object(adapter.ssl, 'get_default_verify_paths', return_value=paths), \
                    patch.dict(os.environ, SSL_CERT_FILE=str(Path(temp) / 'test-ca.pem')):
                context = adapter.system_context()
                self.assertEqual(calls, [(str(system), str(store))])
                self.assertTrue(context.check_hostname)
                self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
                gone = ssl.DefaultVerifyPaths(None, None, '', str(Path(temp) / 'no.pem'), '', str(Path(temp) / 'no'))
                with patch.object(adapter.ssl, 'get_default_verify_paths', return_value=gone):
                    with self.assertRaises(live.Refused): adapter.system_context()
        self.assertIn('context=system_context()', (ROOT / 'bin/nogh_live_http.py').read_text())

    def test_overlay_has_workload_logins_and_a_seeded_toolchain(self):
        import re
        text = (ROOT / 'extras/managed-node/c9/Dockerfile').read_text()
        logins = dict(re.findall(r'^ARG (C9_(?:HUB|NODE_A|NODE_B)_LOGIN)=(\S+)$', text, re.M))
        self.assertEqual(len(logins), 3)
        self.assertTrue(all(live.NAME.fullmatch(v) for v in logins.values()))
        self.assertIn('id=10001;', text)
        self.assertIn('useradd --uid "$id" --gid "$id"', text)
        self.assertIn('groupadd --gid "$id"', text)
        self.assertIn('seed=/opt/claude-fleet/seed/current', text)
        for tool in ('tmux', 'claude'):
            self.assertIn('for t in tmux claude;', text)
        self.assertIn('ln -sfn "$seed/bin/ccquota" /usr/local/bin/ccquota', text)
        self.assertNotIn('/var/db/fleet-node/runtime/current', text)

    def test_bypass_port_cannot_be_a_dns_or_github_port(self):
        for port in (53, 80, 443):
            p = plan(); p['probes']['bypass_port'] = port
            with self.assertRaises(live.Refused) as refused: live.validate(p)
            self.assertEqual(str(refused.exception), 'PROBE_PORT')
        live.validate(plan())

    def test_digests_are_the_values_the_guard_and_identity_check(self):
        import nogh_live_runtime as runtime
        with tempfile.TemporaryDirectory(prefix='c9-digest-') as temp:
            work = Path(temp) / 'workload'; work.write_bytes(b'#!/bin/sh\n')
            key = Path(temp) / 'key'; key.write_bytes(b'ed25519 AAAA\n')
            got = driver.digests(str(work), str(key))
            self.assertEqual(got['observer_digest'], runtime.build_digest())
            self.assertEqual(got['command_digest'], 'sha256:' + hashlib.sha256(b'#!/bin/sh\n').hexdigest())
            self.assertEqual(got['key_digest'], 'sha256:' + hashlib.sha256(b'ed25519 AAAA\n').hexdigest())
            key.write_bytes(b'{"error":"x"}')
            with self.assertRaises(live.Refused): driver.digests(None, str(key))


if __name__ == "__main__":
    signal.alarm(15)
    unittest.main()
