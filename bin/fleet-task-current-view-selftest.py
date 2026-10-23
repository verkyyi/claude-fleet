#!/usr/bin/env python3
# selftest-entry
"""Historical text and outcomes cannot change Task status or written codes."""
import os
import tempfile
import unittest
from unittest.mock import patch
import fleet_view as view

class CurrentView(unittest.TestCase):
    def test_old_board_tag_and_question_text_do_not_create_native_wait(self):
        for state in ('idle','done','unknown',''):
            row=dict(kind='sess',fid='old',state=state,ask='historical question',task='T42')
            groups={g:[] for g in view.GROUPS};groups['queue']=[row]
            board=dict(rows=[dict(id='old',task='T42',task_id='task-fid',code='ABCD',state=state,
                                 group='ask',tag='waiting_you',words=['旧问题','Old question'])])
            got,_=view.board_apply(board,groups,[],[],'node','login')
            self.assertEqual(view.task_status(got['ask'][0]),'quiet')
    def test_task_code_is_stable_across_session_and_neighbor_states(self):
        with tempfile.TemporaryDirectory() as root, patch.dict(os.environ,{'FLEET_CONF_DIR':root}):
            for state in ('working','idle','done','needs'):
                row=dict(kind='sess',task='T42',task_id='22222222-2222-4222-8222-222222222222',
                         task_code='ABCD',fid='11111111-1111-4111-8111-111111111111',id='OLD',state=state,group='queue')
                view.id_display({'queue':[row]})
                self.assertEqual((row['id'],row['code']),('ABCD','ABCD'))
    def test_duplicate_native_warning_does_not_invent_question(self):
        rows=[dict(native='same',id='ABCD',fid='one',state='idle',sym='idle'),
              dict(native='same',id='EFGH',fid='two',state='working',sym='work')]
        view.id_conflicts(rows)
        self.assertTrue(all(r.get('conflict') for r in rows))
        self.assertEqual([view.task_status(r) for r in rows],['quiet','work'])
    def test_native_wait_still_shows(self):
        for state in ('needs','blocked'):
            self.assertEqual(view.task_status(dict(state=state)),'needs')
if __name__=='__main__':unittest.main()
