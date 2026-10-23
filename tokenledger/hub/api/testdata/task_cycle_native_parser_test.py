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
reader = runpy.run_path(str(HERE / 'task_cycle_native.py'))
parse = reader['native_turns']
history_outputs = reader['history_read_outputs']
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


class NativeHistoryOutput(unittest.TestCase):
    path = '/fixture/exact-original-rollout.jsonl'

    def rows(self, output, call_id='read-original', path=None):
        return [dict(type='response_item', payload=dict(type='custom_tool_call', call_id='read-original',
                    input='read ' + (self.path if path is None else path))),
                dict(type='response_item', payload=dict(type='custom_tool_call_output', call_id=call_id, output=output))]

    def proof(self, output, **kwargs):
        return history_outputs(self.rows(output, **kwargs), self.path, 'first-nonce', 'private-fact')

    def block(self, code=0, output='first-nonce private-fact'):
        return dict(type='text', text=json.dumps(dict(exit_code=code, output=output)))

    def test_native_blocks_and_legacy_string(self):
        self.assertEqual(len(self.proof([dict(type='text', text='Script completed'), self.block()])), 1)
        self.assertEqual(len(self.proof(self.block()['text'])), 1)
        self.assertEqual(len(self.proof('Wall time: 0.1 seconds\nProcess exited with code 0\nFinal output:\nfirst-nonce private-fact')), 1)

    def test_failed_result_cannot_quote_success(self):
        quoted = json.dumps(dict(exit_code=0, output='first-nonce private-fact'))
        self.assertEqual(self.proof([self.block(1, quoted)]), [])
        self.assertEqual(self.proof('Process exited with code 1\nFinal output:\nProcess exited with code 0\nfirst-nonce private-fact'), [])
        self.assertEqual(self.proof([dict(type='text', text=quoted[:-1])]), [], 'truncated JSON is not a receipt')
        self.assertEqual(self.proof([self.block(False)]), [], 'boolean false is not integer exit_code zero')

    def test_success_and_markers_cannot_cross_blocks(self):
        self.assertEqual(self.proof([self.block(output='first-nonce'), self.block(output='private-fact')]), [])
        self.assertEqual(self.proof([self.block(output='unrelated'), self.block(1)]), [])

    def test_matching_call_and_exact_source_required(self):
        self.assertEqual(self.proof([self.block()], call_id='another-call'), [])
        self.assertEqual(self.proof([self.block()], path='/fixture/other-rollout.jsonl'), [])
        self.assertEqual(self.proof([self.block()], path=self.path + '.unrelated'), [])
        rows = self.rows([self.block()])
        rows.pop(0)
        self.assertEqual(history_outputs(rows, self.path, 'first-nonce', 'private-fact'), [])


if __name__ == '__main__':
    unittest.main()
