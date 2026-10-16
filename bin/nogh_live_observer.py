#!/usr/bin/env python3
"""Bounded strace metadata decoder for the opt-in C9 supervisor.

Raw lines never leave this object or become exception messages. Unlike the
fixture reader, unknown formats, raw sockets, empty execveat paths, missing
fork/exit records and truncated streams are failures. A decoded stream alone
does not authorize a live verdict: admission, positive controls and the full
endpoint matrix are separate gates.
"""
import ipaddress
import math
from pathlib import PurePosixPath
import re

from nogh_live_contract import Refused, require

PHASES = ('startup', 'identity', 'deny:github-name', 'deny:github-v4', 'deny:github-v6',
          'deny:dns-udp', 'deny:dns-tcp', 'deny:proxy-bypass', 'deny:gh-path',
          'deny:gh-absolute', 'deny:execveat', 'deny:sendmsg', 'deny:sendmmsg',
          'allow:hub', 'allow:provider') + tuple('row:A%d' % n for n in range(1, 13)) + \
         ('row:A4-denied', 'row:A4-restored', 'end')
MARKER_FD = 198
TRACE_CALLS = ('process,socket,socketpair,connect,accept,accept4,sendto,sendmsg,sendmmsg,'
               'dup,dup2,dup3,fcntl,close,close_range,write,writev,sendfile,splice,recvmsg,recvmmsg,'
               'io_uring_setup,io_uring_enter,pidfd_getfd,unshare,setns')
STRACE_OPTIONS = ['-f', '-q', '-ttt', '-T', '-v', '-s', '0', '--kill-on-exit',
                  '-e', 'trace=' + TRACE_CALLS, '-e', 'inject=io_uring_setup:error=ENOSYS']


class Trace:
    def __init__(self, plan, role, max_events=100000):
        self.plan, self.role, self.max_events = plan, role, max_events
        self.routes = {(r['ip'], r['port'], r['protocol']): r['purpose']
                       for r in plan['routes'] if r['from'] == role}
        self.root = None
        self.parents, self.exited, self.markers, self.events, self.pending = {}, set(), [], [], {}
        self.lines, self.failed = 0, None
        self.actions = []
        self.pending_bytes = 0

    def feed(self, line):
        try:
            self._feed(line)
        except (ValueError, TypeError, IndexError, OverflowError):
            self.failed = 'TRACE_FORMAT_OR_COVERAGE'
            raise Refused(self.failed) from None

    def _feed(self, line):
        require(not self.failed, 'TRACE_ALREADY_FAILED')
        self.lines += 1
        require(len(line) <= 262144 and self.lines <= self.max_events, 'TRACE_LIMIT')
        # -f -o uses a numeric PID prefix, even for the original tracee.
        match = re.fullmatch(r'\s*(\d+)\s+(\d+\.\d+)\s+(.*)\n?', line.rstrip('\n'))
        require(match is not None, 'TRACE_PREFIX')
        pid, at, call = int(match[1]), float(match[2]), match[3]
        require(pid > 0 and math.isfinite(at), 'TRACE_IDENTITY')
        if call.startswith('+++ exited with ') or call.startswith('+++ killed by '):
            require(pid not in self.exited, 'DUPLICATE_EXIT')
            self.exited.add(pid)
            return
        if call.startswith('--- SIG'):
            return  # no payload, signal text or si_* fields retained
        if '<unfinished ...>' in call:
            require(pid not in self.pending, 'NESTED_UNFINISHED')
            self.pending_bytes += len(call)
            require(self.pending_bytes <= 1024 * 1024, 'PENDING_MEMORY_LIMIT')
            self.pending[pid] = (at, call.split('<unfinished ...>', 1)[0])
            return
        if call.startswith('<... '):
            resumed = re.match(r'<\.\.\. (\w+) resumed>(.*)', call)
            require(resumed is not None and pid in self.pending, 'UNMATCHED_RESUME')
            start, prefix = self.pending.pop(pid)
            self.pending_bytes -= len(prefix) + len('<unfinished ...>')
            require(prefix.startswith(resumed[1] + '('), 'RESUME_CHANGED_SYSCALL')
            self.decode(pid, start, at, prefix + resumed[2])
            return
        duration = re.search(r' <(\d+\.\d+)>$', call)
        until = at + (float(duration[1]) if duration else 0)
        self.decode(pid, at, until, call)

    def record(self, pid, start, end, category, count=1):
        require(len(self.events) < self.max_events, 'EVENT_LIMIT')
        self.events.append((pid, start, end, category, count))

    def decode(self, pid, start, end, call):
        found = re.match(r'(\w+)\(', call)
        require(found is not None, 'UNKNOWN_SYSCALL_FORMAT')
        name = found[1]
        self.action_end = end
        if name in ('execve', 'execveat'):
            path = re.match(r'execve\("([^"\\]*)"', call) if name == 'execve' else \
                re.match(r'execveat\([^,]+, "([^"\\]*)"', call)
            # Empty-path fd execution and escaped/truncated file names must not
            # silently become zero CLI attempts. A later backend can support
            # kernel fd identity without weakening this refusal.
            require(path is not None and path[1], 'EXECUTABLE_IDENTITY_UNAVAILABLE')
            if self.root is None:
                self.root = pid
                self.parents[pid] = 0
            if re.search(r'\)\s+= 0(?:\s|$)', call):
                self.action((start, 'exec', pid, None))
            if PurePosixPath(path[1]).name == 'gh':
                self.record(pid, start, end, 'github_cli')
            return
        if name in ('clone', 'clone3', 'fork', 'vfork'):
            child = re.search(r'\)\s+= (\d+)', call)
            if child and int(child[1]):
                child = int(child[1])
                require(child not in self.parents and child != pid, 'PROCESS_ID_REUSED')
                self.parents[child] = pid
                self.action((start, 'fork', pid, (child, 'CLONE_FILES' in call)))
            else:
                require('= -1 ' in call, 'UNREADABLE_FORK_RESULT')
            return
        if name in ('exit', 'exit_group', 'wait4', 'waitid'):
            return
        if name in ('write', 'writev', 'sendfile', 'splice'):
            marker = re.match(r'write\(%d, .*?, (\d+)\)\s+= (\d+)' % MARKER_FD, call)
            if pid == self.root and marker:
                size = int(marker[1])
                require(size == int(marker[2]) and 1 <= size <= len(PHASES), 'MARKER_INCOMPLETE')
                require(not self.markers or start >= self.markers[-1][0], 'CLOCK_REVERSED')
                phase = PHASES[size - 1]
                require(phase not in [p for _, p in self.markers], 'DUPLICATE_PHASE')
                self.markers.append((start, phase))
                return
            fd = re.match(r'\w+\((\d+)', call)
            if name == 'splice':
                fd = re.match(r'splice\(\d+, (?:NULL|\[[^]]*\]), (\d+)', call)
            require(fd is not None, 'WRITE_FD_FORMAT')
            self.action((start, 'write', pid, (int(fd[1]), end)))
            return
        if name in ('recvmsg', 'recvmmsg'):
            # A transferred socket cannot silently acquire an untracked FD.
            # This version refuses SCM_RIGHTS rather than inventing an owner.
            require('SCM_RIGHTS' not in call and 'MSG_CTRUNC' not in call, 'FD_TRANSFER_UNSUPPORTED')
            return
        if name == 'io_uring_setup':
            require('= -1 ENOSYS' in call and '(INJECTED)' in call, 'IO_URING_UNFENCED')
            self.record(pid, start, end, 'io_uring_fenced')
            return
        if name == 'io_uring_enter':
            raise Refused('IO_URING_SUBMISSION')
        if name in ('pidfd_getfd', 'unshare', 'setns'):
            require('= -1 ' in call, 'UNOBSERVED_FD_OR_NAMESPACE_TRANSFER')
            return
        if name in ('socket', 'socketpair'):
            require(re.match(r'socket\(AF_(?:INET6?|UNIX|NETLINK),', call)
                    or (name == 'socketpair' and call.startswith('socketpair(AF_UNIX,')), 'UNSUPPORTED_SOCKET')
            require(('SOCK_RAW' not in call or
                     (call.startswith('socket(AF_NETLINK,') and 'NETLINK_ROUTE' in call))
                    and 'SOCK_PACKET' not in call, 'UNSUPPORTED_SOCKET')
            protocol = 'udp' if 'SOCK_DGRAM' in call else 'tcp' if 'SOCK_STREAM' in call else None
            local = 'AF_UNIX' in call or 'AF_NETLINK' in call
            require(local or protocol is not None, 'UNSUPPORTED_TRANSPORT')
            result = re.search(r'\)\s+= (-?\d+)', call)
            require(result is not None, 'SOCKET_RESULT')
            if int(result[1]) >= 0:
                fds = [int(result[1])]
                if name == 'socketpair':
                    pair = re.search(r', \[(\d+), (\d+)\]\)\s+= 0', call)
                    require(pair is not None, 'SOCKETPAIR_RESULT')
                    fds = [int(pair[1]), int(pair[2])]
                for fd in fds:
                    self.action((start, 'socket', pid,
                                         (fd, protocol, 'local' if local else 'unknown', 'SOCK_CLOEXEC' in call)))
            return
        if name in ('close', 'close_range', 'dup', 'dup2', 'dup3', 'fcntl'):
            result = re.search(r'\)\s+= (-?\d+)', call)
            require(result is not None, 'FD_RESULT')
            if int(result[1]) < 0:
                return
            fd = re.match(r'\w+\((\d+)', call)
            require(fd is not None, 'FD_FORMAT')
            fd = int(fd[1])
            if name == 'close':
                self.action((start, 'close', pid, fd))
            elif name == 'close_range':
                last = re.match(r'close_range\(\d+, (\d+|~0U), ([^)]+)\)', call)
                require(last is not None and 'CLOSE_RANGE_UNSHARE' not in call, 'FD_RANGE_UNSUPPORTED')
                self.action((start, 'range', pid,
                                     (fd, 2 ** 32 if last[1] == '~0U' else int(last[1]),
                                      'CLOSE_RANGE_CLOEXEC' in last[2])))
            elif name.startswith('dup') or 'F_DUPFD' in call:
                self.action((start, 'dup', pid, (fd, int(result[1]), 'CLOEXEC' in call)))
            elif 'F_SETFD' in call:
                self.action((start, 'cloexec', pid, (fd, 'FD_CLOEXEC' in call)))
            return
        require(name in ('connect', 'sendto', 'sendmsg', 'sendmmsg', 'accept', 'accept4'), 'UNSUPPORTED_SYSCALL')
        fd_match = re.match(r'\w+\((-?\d+)', call)
        require(fd_match is not None, 'NETWORK_FD')
        fd = int(fd_match[1])
        families = re.findall(r'sa_family=(AF_\w+)', call)
        require(all(f in ('AF_INET', 'AF_INET6', 'AF_UNIX', 'AF_NETLINK', 'AF_UNSPEC') for f in families),
                'UNSUPPORTED_DESTINATION')
        # UNIX is allowed only because the admission contract isolates the mount
        # and network namespaces, forbids host sockets and closes inherited FDs.
        inet = [f for f in families if f in ('AF_INET', 'AF_INET6')]
        destinations = re.findall(r'\{sa_family=AF_INET6?[, ].*?\}', call)
        require(len(destinations) == len(inet), 'TRUNCATED_DESTINATION_ARRAY')
        targets = []
        for target in destinations:
            addr = re.search(r'(?:inet_addr\(|inet_pton\(AF_INET6, )"([^"]+)"', target)
            port = re.search(r'(?:sin_port|sin6_port)=htons\((\d+)\)', target)
            require(addr is not None and port is not None, 'UNKNOWN_DESTINATION')
            ip = ipaddress.ip_address(addr[1])
            ip = getattr(ip, 'ipv4_mapped', None) or ip
            targets.append((str(ip), int(port[1])))
        if name in ('accept', 'accept4'):
            result = re.search(r'\)\s+= (-?\d+)', call)
            require(result is not None, 'ACCEPT_RESULT')
            if int(result[1]) >= 0:
                self.action((start, 'accept', pid, (fd, int(result[1]), targets, 'SOCK_CLOEXEC' in call)))
            return
        if name == 'connect':
            require(families, 'UNREADABLE_CONNECT_DESTINATION')
        elif not families:
            require(('msg_name=NULL' in call) if name in ('sendmsg', 'sendmmsg') else
                    re.search(r', NULL, 0\)\s+=', call), 'UNREADABLE_SEND_DESTINATION')
        count = max(1, call.count('msg_hdr=')) if name == 'sendmmsg' else 1
        local = bool(families) and all(f in ('AF_UNIX', 'AF_NETLINK') for f in families)
        result = re.search(r'\)\s+= (-?\d+)', call)
        require(result is not None, 'NETWORK_RESULT')
        connected = name == 'connect' and (int(result[1]) == 0 or 'EINPROGRESS' in call)
        disconnected = 'AF_UNSPEC' in families and int(result[1]) == 0
        self.action((start, 'network', pid, (fd, name, targets, count, local, end,
                                                     connected, disconnected)))

    def action(self, value):
        self.actions.append((*value, self.action_end))

    def classify(self, target, protocol):
        ip, port = target
        purpose = self.routes.get((ip, port, protocol))
        if purpose == 'github_restored':
            return 'restored_candidate'
        if purpose:
            return 'allow_' + ('hub' if purpose == 'peer' else purpose)
        if port == 53:
            return 'dns_denied'
        return 'github_network' if port in (80, 443) else 'unknown'

    def socket_events(self):
        """Replay metadata, refusing concurrent FD/OFD ordering ambiguity.

        strace can print a child's first syscall before its parent's clone return.
        Sorting metadata after EOF preserves that relationship without guessing a
        missing parent. FD aliases share their connected destination.
        """
        tables = {self.root: {}}
        pending = {}

        def descendant(child, parent):
            while child in self.parents and child:
                if child == parent:
                    return True
                child = self.parents[child]
            return False

        def access(key, first, last, write, at, until, pid, new_child=None):
            active = [item for item in pending.get(key, []) if item[0] > at]
            for end, old_first, old_last, old_write, old_pid, old_child in active:
                if pid == old_pid or last < old_first or old_last < first or not (write or old_write):
                    continue
                # A child can run before clone/vfork returns; that causal
                # ordering is known, unlike a sibling mutating the fork snapshot.
                if old_child is not None and descendant(pid, old_child):
                    continue
                require(False, 'FD_ORDER_AMBIGUOUS')
            active.append((until, first, last, write, pid, new_child))
            pending[key] = active

        for at, action, pid, data, until in sorted(self.actions, key=lambda e: e[0]):
            require(pid in tables, 'FD_OWNER_UNKNOWN')
            table = tables[pid]
            table_key = ('table', id(table))
            limit = 2 ** 32
            touches = []
            if action == 'fork' and not data[1]:
                touches = [(0, limit, False)]
            elif action == 'exec': touches = [(0, limit, True)]
            elif action == 'socket': touches = [(data[0], data[0], True)]
            elif action == 'close': touches = [(data, data, True)]
            elif action == 'range': touches = [(data[0], data[1], True)]
            elif action == 'dup': touches = [(data[0], data[0], False), (data[1], data[1], True)]
            elif action == 'cloexec': touches = [(data[0], data[0], True)]
            elif action == 'accept': touches = [(data[0], data[0], False), (data[1], data[1], True)]
            elif action in ('write', 'network'): touches = [(data[0], data[0], False)]
            for first, last, write in touches:
                access(table_key, first, last, write, at, until, pid, data[0] if action == 'fork' else None)
            if action in ('write', 'network') and data[0] in table:
                # dup and fork retain the same open-file-description even when
                # their FD tables differ. A concurrent connect/disconnect makes
                # destination attribution uncertain and must never read as zero.
                state = table[data[0]][0]
                access(('socket', id(state)), 0, 0,
                       action == 'network' and (data[-1] or data[-2]), at, until, pid)
            if action == 'fork':
                child, shared = data
                tables[child] = table if shared else table.copy()
            elif action == 'exec':
                tables[pid] = {fd: entry for fd, entry in table.items() if not entry[1]}
            elif action == 'socket':
                fd, protocol, category, cloexec = data
                table[fd] = ([protocol, category], cloexec)
            elif action == 'close':
                table.pop(data, None)
            elif action == 'range':
                first, last, cloexec = data
                for fd in list(table):
                    if first <= fd <= last:
                        if cloexec: table[fd] = (table[fd][0], True)
                        else: del table[fd]
            elif action == 'dup':
                old, new, cloexec = data
                if old != new:
                    table.pop(new, None)
                    if old in table: table[new] = (table[old][0], cloexec)
            elif action == 'cloexec':
                fd, flag = data
                if fd in table: table[fd] = (table[fd][0], flag)
            elif action == 'accept':
                old, new, targets, cloexec = data
                source = table.get(old, ([None, 'unknown'], False))[0]
                category = 'local' if source[1] == 'local' else 'unknown'
                # The fresh namespace's INPUT rules admit only original run
                # endpoints. NULL sockaddr (libuv) does not remove that fence.
                if source[0] in ('tcp', 'udp') and (not targets or
                        all(t[0] in {e['pod_ip'] for e in self.plan['endpoints']} for t in targets)):
                    category = 'allow_' + ('provider' if self.role == 'proxy' else 'dns' if self.role == 'dns' else 'hub')
                table[new] = ([source[0], category], cloexec)
            elif action == 'write':
                fd, end = data
                if fd in table and table[fd][0][1] != 'local':
                    self.record(pid, at, end, table[fd][0][1])
            elif action == 'network':
                fd, name, targets, count, local, end, connected, disconnected = data
                state = table.get(fd, ([None, 'unknown'], False))[0]
                categories = [self.classify(t, state[0]) for t in targets]
                if local:
                    require(state[1] == 'local' or name == 'connect', 'SOCKET_FAMILY_CHANGED')
                    categories = ['local']
                if connected and categories:
                    state[1] = categories[0]
                if disconnected:
                    state[1] = 'unknown'
                if not categories:
                    categories = [state[1]] * count
                elif name == 'sendmmsg' and len(categories) < count and not local:
                    categories += [state[1]] * (count - len(categories))
                for category in categories:
                    if category != 'local': self.record(pid, at, end, category)

    def finish(self, observer_exit):
        require(observer_exit == 0 and not self.failed and not self.pending, 'OBSERVER_LOST_OR_TRUNCATED')
        require(self.root is not None and self.markers and self.markers[0][1] == 'startup'
                and self.markers[-1][1] == 'end', 'MISSING_INTERVAL_BOUNDARY')
        require(set(self.parents) == self.exited, 'PROCESS_TREE_INCOMPLETE')
        self.socket_events()
        for pid in self.parents:
            seen, current = set(), pid
            while current:
                require(current not in seen and current in self.parents, 'UNOWNED_PROCESS')
                seen.add(current); current = self.parents[current]
            require(self.root in seen, 'UNOWNED_PROCESS')
        intervals = {}
        for (begin, phase), (end, _) in zip(self.markers, self.markers[1:] + [(float('inf'), 'closed')]):
            if phase == 'startup':
                begin = float('-inf')
            counts = {}
            for pid, start, until, category, count in self.events:
                require(pid in self.parents, 'UNOWNED_EVENT')
                # A syscall straddling a boundary is counted on both sides.
                if start <= end and until >= begin:
                    if category == 'restored_candidate':
                        category = 'allow_github_restored' if phase == 'row:A4-restored' else 'github_network'
                    counts[category] = counts.get(category, 0) + count
            intervals[phase] = counts
        return dict(intervals=intervals, events=len(self.events), processes=len(self.parents),
                    observer='COMPLETE', live='NOT RUN')
