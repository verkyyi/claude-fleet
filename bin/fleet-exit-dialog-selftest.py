#!/usr/bin/env python3
# selftest-entry
"""fleet_exit_dialog.py: Claude Code's exit dialog for pending timers, read as
it is DRAWN (T1385). The CAPTURED_* screens are Claude Code 2.1.322 on an
isolated tmux socket at 45 / 90 / 200 columns with three CronCreate timers: a
long Chinese prompt, a long English one and a two-line one. Also drives
fleet_park_wake.py, .fleet-transfer.py (loop_exit_confirmation),
fleet_session_gate.py and fleet-status-7501.py's cancel-exit through their tests.
"""
from pathlib import Path
import runpy
import sys
import unittest

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import fleet_exit_dialog as d  # noqa: E402

ZH = ('检查一下仓库里所有未合并的拉取请求，逐个阅读评审意见并修复失败的检查项，确认门禁全部变绿之后再合并，'
      '最后把结果整理成一份简短的中文摘要发给操作者，摘要里要包括每个拉取请求的编号、标题、处理结果以及遗留问题。')
EN = ('Review every open pull request in the repository, read each review comment carefully, '
      'fix the failing checks, and merge once the gate is green.')
TWO = 'line one short\nline two follows here'
JOBS = [ZH, EN, TWO]

CAPTURED_45 = ('▔' * 45 + '\n'
    '   Background work is running\n'
    '   The following will stop when you exit:\n'
    '\n'
    '   scheduled   · Runs once in 50d ·\n'
    '   task       检查一下仓库里所有未合并的拉\n'
    '              取请求，逐个阅读评审…\n'
    '   scheduled  · Runs once in 50d · Review\n'
    '   task      every open pull request in\n'
    '             the repository,…\n'
    '   scheduled   · Runs once in 50d · line\n'
    '   task       one short…\n'
    '\n'
    '   ❯ 1. Exit and stop tasks\n'
    '     2. Move to background and exit\n'
    '     3. Stay\n'
    '\n'
    '   Enter to confirm · Esc to cancel\n')
CAPTURED_90 = ('▔' * 90 + '\n'
    '   Background work is running\n'
    '   The following will stop when you exit:\n'
    '\n'
    '   scheduled task · Runs once in 50d ·\n'
    '                 检查一下仓库里所有未合并的拉取请求，逐个阅读评审…\n'
    '   scheduled task · Runs once in 50d · Review every open pull request in the\n'
    '                 repository,…\n'
    '   scheduled task · Runs once in 50d · line one short…\n'
    '\n'
    '   ❯ 1. Exit and stop tasks\n'
    '     2. Move to background and exit\n'
    '     3. Stay\n'
    '\n'
    '   Enter to confirm · Esc to cancel\n')
CAPTURED_200 = ('▔' * 200 + '\n'
    '   Background work is running\n'
    '   The following will stop when you exit:\n'
    '\n'
    '   scheduled task · Runs once in 50d · 检查一下仓库里所有未合并的拉取请求，逐个阅读评审…\n'
    '   scheduled task · Runs once in 50d · Review every open pull request in the repository,…\n'
    '   scheduled task · Runs once in 50d · line one short…\n'
    '\n'
    '   ❯ 1. Exit and stop tasks\n'
    '     2. Move to background and exit\n'
    '     3. Stay\n'
    '\n'
    '   Enter to confirm · Esc to cancel\n')


def fits(prompt, item):
    return d.prompt_shown(prompt, item['prompt'], item['cut'])


class Drawn(unittest.TestCase):
    def test_real_captures_match_at_every_width(self):
        for screen in (CAPTURED_45, CAPTURED_90, CAPTURED_200):
            items = d.parse(screen)
            self.assertEqual([i['desc'] for i in items], ['Runs once in 50d'] * 3, screen)
            self.assertTrue(all(i['cut'] for i in items))
            self.assertTrue(d.matches(items, JOBS, fits), screen)
            self.assertTrue(d.matches(items, list(reversed(JOBS)), fits))
            self.assertTrue(d.open_dialog(screen))

    def test_count_selection_and_footer_must_be_exact(self):
        for screen in (CAPTURED_45, CAPTURED_200):
            self.assertFalse(d.matches(d.parse(screen), JOBS[:2], fits), 'a third timer is not ours')
            self.assertFalse(d.matches(d.parse(screen), JOBS + ['another'], fits))
            moved = screen.replace('❯ 1. Exit', '  1. Exit').replace('  2. Move', '❯ 2. Move')
            self.assertIsNone(d.parse(moved))
            self.assertFalse(d.open_dialog(moved))
            self.assertIsNone(d.parse(screen.replace('Enter to confirm · Esc to cancel', '')))
            self.assertIsNone(d.parse(screen + 'normal prompt\n'))
            self.assertIsNone(d.parse(screen.replace('scheduled', 'background', 1)))
            # A row at the task's own depth that is not a task is not a wrap.
            self.assertIsNone(d.parse(screen.replace('   ❯ 1.', '   shell · npm run dev\n   ❯ 1.')))

    def test_same_prefix_other_words_is_never_ours(self):
        # The shown part diverges from the job's prompt after a shared prefix.
        other = ZH[:18] + '逐个处理别的事情'
        for shown, cut in ((other, True), (other, False), (ZH[:24], False), (ZH, False)):
            screen = CAPTURED_200.replace(ZH[:24] + '…', shown + ('…' if cut else ''))
            items = d.parse(screen)
            self.assertIsNotNone(items)
            self.assertEqual(d.matches(items, JOBS, fits), shown == ZH and not cut, shown)
        # A whole prompt shown uncut is the job only if it is the whole prompt.
        self.assertFalse(d.prompt_shown(ZH + '并且再做一件事', ZH, False))
        self.assertFalse(d.prompt_shown(ZH, ZH + '并且再做一件事', False))

    def test_cut_prefix_has_a_floor(self):
        self.assertTrue(d.prompt_shown(ZH, ZH[:12], True))
        self.assertFalse(d.prompt_shown(ZH, ZH[:11], True))
        self.assertFalse(d.prompt_shown(EN, 'Review every', True))     # 11 non-space
        self.assertTrue(d.prompt_shown(EN, 'Review every open', True))
        self.assertTrue(d.prompt_shown('short\nsecond', 'short', True))  # its whole first line
        self.assertFalse(d.prompt_shown('short one\nsecond', 'short', True))

    def test_two_jobs_sharing_the_shown_prefix_are_refused(self):
        twin = ZH[:30] + '另外一个结尾'   # draws exactly as ZH does
        screen = CAPTURED_200.replace(EN[:49] + '…', ZH[:24] + '…')
        self.assertFalse(d.matches(d.parse(screen), [ZH, twin, TWO], fits))
        self.assertFalse(d.matches(d.parse(CAPTURED_200), [ZH, twin, TWO], fits))

    def test_wrap_rules(self):
        self.assertEqual(d._shown('a b', 'a\nb'), 3)
        self.assertEqual(d._shown('ab', 'a\nb'), 2)          # a wrap may split a word
        self.assertIsNone(d._shown('ab', 'a b'))             # a space may not
        self.assertIsNone(d._shown('1 2', '12'))
        self.assertTrue(d.same('* * * * *', '* * * * *'))
        self.assertFalse(d.same('* * * * *', '*/5 * * * *'))


class Callers(unittest.TestCase):
    def test_transfer_reads_the_narrow_cut_dialog(self):
        import json, tempfile
        helper = runpy.run_path(str(BIN / '.fleet-transfer.py'))
        confirm = helper['loop_exit_confirmation']
        invocation = '/loop 30m ' + ZH
        shown = ('/loop 30m ' + ZH)[:30]
        screen = ('   Background work is running\n   The following will stop when you exit:\n\n'
                  '   scheduled   · Runs once in 5m ·\n'
                  '   task       ' + shown[:16] + '\n              ' + shown[16:] + '…\n\n'
                  '   ❯ 1. Exit and stop tasks\n     2. Move to background and exit\n     3. Stay\n\n'
                  '   Enter to confirm · Esc to cancel\n')
        with tempfile.TemporaryDirectory() as tmp:
            bundle = Path(tmp)
            (bundle / 'manifest.json').write_text(json.dumps(dict(quota_loop_replacement=dict(
                authorization=dict(invocation=invocation)))))
            self.assertTrue(confirm(screen, bundle))
            self.assertTrue(confirm(screen))
            self.assertFalse(confirm(screen.replace(shown[16:], shown[16:20] + '另外的任务内容啊'), bundle))
            self.assertFalse(confirm(screen.replace('scheduled', 'background'), bundle))
        self.assertTrue(helper['DIALOG']['open_dialog'](screen))
        self.assertFalse(helper['DIALOG']['open_dialog'](screen.replace('❯ 1.', '1.')))


if __name__ == '__main__':
    unittest.main()
