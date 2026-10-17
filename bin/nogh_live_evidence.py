#!/usr/bin/env python3
"""Private, bounded workload evidence; separate from independent counters.

Only inherited stdout/stderr of the observed workload tree enter these pipes.
The supervisor supplies provenance, never a workload-supplied Pod/run identity.
JSONL bodies are owner-selected, credential-free API/native evidence, not trace
payloads. Capturing a statement does not verify its business assertion.
"""
import json
import os

from nogh_live_contract import fingerprint, keys, require, validate

MAX_LINE = 4096
MAX_BYTES = 128 * 1024  # per role, across all launches and both streams
MAX_RECORDS = 512
WORKLOAD_ROLES = ('hub', 'node-a', 'node-b')


def launches(plan, role):
    if role not in WORKLOAD_ROLES:
        return []
    return ['start', 'row:' + plan['row']] + (
        ['row:A4-denied', 'row:A4-restored'] if plan['row'] == 'A4' else []) + ['stop']


def body(value):
    keys(value, 'kind name data', 'EVIDENCE_RECORD_FIELDS')
    require(value['kind'] in ('business', 'native', 'diagnostic')
            and isinstance(value['name'], str) and 0 < len(value['name']) <= 128
            and isinstance(value['data'], dict) and value['data'], 'EVIDENCE_RECORD_FORMAT')


def binding(plan, role):
    ep = next(e for e in plan['endpoints'] if e['role'] == role)
    return dict(version=1, run_id=plan['run_id'], row=plan['row'], role=role,
                generation=plan['generation'], endpoint_uid=ep['uid'],
                execution_generation=ep['execution_generation'], plan_digest=validate(plan))


class Capture:
    def __init__(self, plan, role):
        self.binding = binding(plan, role)
        self.streams = [(phase, stream) for phase in launches(plan, role)
                        for stream in ('stdout', 'stderr')]
        self.buffers = {key: bytearray() for key in self.streams}
        self.records, self.closed, self.total = [], set(), 0
        self.readers, self.writers = {}, {}

    def pipes(self):
        for key in self.streams:
            reader, writer = os.pipe()
            self.readers[reader] = key
            self.writers[key] = writer
        return {phase: {stream: self.writers[phase, stream] for stream in ('stdout', 'stderr')}
                for phase, _ in self.streams}

    def close_writers(self):
        for fd in self.writers.values():
            os.close(fd)
        self.writers.clear()

    def close(self):
        self.close_writers()
        for fd in self.readers:
            os.close(fd)
        self.readers.clear()

    def feed(self, key, block):
        require(key in self.buffers and key not in self.closed, 'EVIDENCE_STREAM_CHANGED')
        buffer = self.buffers[key]
        if not block:
            require(not buffer, 'EVIDENCE_PARTIAL_LINE')
            self.closed.add(key)
            return
        self.total += len(block)
        require(self.total <= MAX_BYTES, 'EVIDENCE_BYTE_LIMIT')
        buffer.extend(block)
        while b'\n' in buffer:
            line, _, rest = buffer.partition(b'\n')
            require(0 < len(line) <= MAX_LINE and len(self.records) < MAX_RECORDS, 'EVIDENCE_RECORD_LIMIT')
            try:
                value = json.loads(line.decode('utf-8', 'strict'))
            except (ValueError, UnicodeError):
                require(False, 'EVIDENCE_JSON_REQUIRED')
            body(value)
            self.records.append(dict(seq=len(self.records) + 1, launch=key[0], stream=key[1], body=value))
            buffer[:] = rest
        require(len(buffer) <= MAX_LINE, 'EVIDENCE_LINE_LIMIT')

    def finish(self):
        require(self.closed == set(self.streams), 'EVIDENCE_EOF_MISSING')
        return dict(self.binding, type='workload-evidence', records=self.records,
                    bytes=self.total, capture='COMPLETE', verdict='OWNER VERDICT REQUIRED')


def check(plan, role, bundle, proof):
    expected = binding(plan, role)
    require(all(bundle.get(k) == v for k, v in expected.items())
            and bundle.get('type') == 'workload-evidence' and bundle.get('capture') == 'COMPLETE'
            and proof.get('workload_evidence_digest') == fingerprint(bundle), 'EVIDENCE_BINDING_CHANGED')
    records = bundle.get('records')
    require(isinstance(records, list) and len(records) <= MAX_RECORDS
            and type(bundle.get('bytes')) is int and 0 <= bundle['bytes'] <= MAX_BYTES, 'EVIDENCE_LIMIT')
    for seq, record in enumerate(records, 1):
        keys(record, 'seq launch stream body', 'EVIDENCE_ENVELOPE_FIELDS')
        require(record['seq'] == seq and record['launch'] in launches(plan, role)
                and record['stream'] in ('stdout', 'stderr'), 'EVIDENCE_SEQUENCE')
        body(record['body'])


def row_coverage(plan, bundles):
    # Nonempty real material is required; an exit code cannot fill this gap.
    # The owner still judges whether these records prove each C9 assertion.
    for phase in launches(plan, 'hub'):
        if not phase.startswith('row:'):
            continue
        kinds = {record['body']['kind'] for bundle in bundles.values() for record in bundle['records']
                 if record['launch'] == phase}
        require({'business', 'native'} <= kinds, 'ROW_BUSINESS_NATIVE_EVIDENCE_MISSING')
