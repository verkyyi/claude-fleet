#!/usr/bin/env python3
"""Offline regression from live #5's Codex rollout (private markers replaced).

The fixture preserves native turn/message shapes, including duplicate event
and response representations and injected user-role environment context.
"""
import copy
import json
from pathlib import Path
import runpy
import sys
import unittest

HERE = Path(__file__).resolve().parent
BIN = HERE.parents[3] / 'bin'
sys.path.insert(0, str(BIN))
parse = runpy.run_path(str(HERE / 'task_cycle_native.py'))['native_turns']
text_blocks = runpy.run_path(str(BIN / '.fleet-transfer.py'))['text_blocks']
SEED = ('This is a bounded isolated acceptance fixture. Do not use subagents, external network, git push, deployment or MCP. '
        'First turn: make no tool calls and reply exactly: first-nonce FACT=private-fact. '
        'If explicitly continued in a fresh Session, read acceptance-next.txt in this worktree, then read the exact previous native transcript '
        'identified by your continuation seed and follow acceptance-next.txt. Do not repeat this first reply.')


class NativeTranscript(unittest.TestCase):
    def setUp(self):
        self.rows = [json.loads(line) for line in (HERE / 'task_cycle_codex_rollout.jsonl').read_text().splitlines()]

    def read(self, rows=None, seed=SEED):
        return parse(self.rows if rows is None else rows, seed, ['first-nonce', 'second-nonce'], 'private-fact', text_blocks)

    def test_real_schema_one_turn(self):
        out = self.read()
        for key in ('started_turns', 'user_turns', 'completed_turns', 'final_answers'):
            self.assertEqual(out[key], 1, key)
        self.assertEqual(out['nonce_replies'], {'first-nonce': 1, 'second-nonce': 0})

    def test_input_must_match_full_delivery(self):
        self.assertEqual(self.read(seed='first-nonce')['user_turns'], 0)
        # Matching response_item alone cannot replace the native user event.
        self.rows = [r for r in self.rows if r['payload'].get('item', {}).get('type') != 'UserMessage']
        self.assertEqual(self.read()['user_turns'], 0)

    def test_exact_final_not_substring_or_commentary(self):
        for mode in ('prefix', 'phase'):
            rows = copy.deepcopy(self.rows)
            for row in rows:
                p = row['payload']
                if p.get('role') == 'assistant':
                    if mode == 'prefix': p['content'][0]['text'] = 'extra ' + p['content'][0]['text']
                    else: p['phase'] = 'commentary'
            self.assertEqual(self.read(rows)['nonce_replies']['first-nonce'], 0)

    def test_turn_and_completion_identity(self):
        for row in self.rows:
            if row['payload']['type'] == 'task_complete': row['payload']['turn_id'] = 'another-turn'
        self.assertEqual(self.read()['completed_turns'], 0)

    def test_duplicates_are_not_hidden(self):
        self.assertEqual(self.read(self.rows + self.rows)['started_turns'], 2)
        final = next(r for r in self.rows if r['payload'].get('phase') == 'final_answer')
        idx = self.rows.index(final)
        self.assertEqual(self.read(self.rows[:idx] + [final] + self.rows[idx:])['final_answers'], 2)
        done = next(r for r in self.rows if r['payload']['type'] == 'task_complete')
        self.assertEqual(self.read(self.rows + [done])['completed_turns'], 2)

    def test_incomplete_turn(self):
        rows = [r for r in self.rows if r['payload']['type'] != 'task_complete']
        self.assertEqual(self.read(rows)['completed_turns'], 0)
        self.assertEqual(self.read(rows)['nonce_replies']['first-nonce'], 0)


if __name__ == '__main__':
    unittest.main()
