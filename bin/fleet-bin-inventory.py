#!/usr/bin/env python3
"""Read-only bin ownership/reference inventory; COMPONENTS.md owns the rules."""
import argparse
import csv
from collections import Counter
from fnmatch import fnmatchcase
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOTS = ('bin', 'hooks', 'launchd', 'systemd', 'commands', 'skills', 'plugins',
         'mod', 'conf', 'tokenledger', 'extras', '.github', 'shell')
SKIP = {'.git', '__pycache__', 'node_modules', '.venv', 'vendor'}
CATEGORIES = {'核心', '按需', '移除', '待定'}
TOKEN = re.compile(r'[\w.-]+', re.UNICODE)


def files(root):
    """Git's non-ignored source set, or a plain directory for hermetic fixtures."""
    if (root / '.git').exists():
        result = subprocess.run(['git', '-C', str(root), 'ls-files', '-z',
                                 '--cached', '--others', '--exclude-standard',
                                 '--', *ROOTS], check=True, stdout=subprocess.PIPE)
        return sorted({os.fsdecode(p) for p in result.stdout.split(b'\0')
                       if p and (root / os.fsdecode(p)).is_file()})
    found = []
    for folder in ROOTS:
        for parent, dirs, names in os.walk(root / folder):
            dirs[:] = sorted(d for d in dirs if d not in SKIP)
            found.extend((Path(parent) / n).relative_to(root).as_posix()
                         for n in names if (Path(parent) / n).is_file())
    return sorted(found)


def read_rules(root):
    components, rules = {}, []
    mapping = False
    for line in (root / 'docs/dev/COMPONENTS.md').read_text().splitlines():
        if line == '<!-- bin-inventory:rules -->':
            mapping = True
            continue
        if line == '<!-- /bin-inventory:rules -->':
            mapping = False
        cells = [c.strip() for c in line.strip().strip('|').split('|')]
        if not line.startswith('|') or len(cells) != 3:
            continue
        if not mapping and cells[1] in CATEGORIES:
            components[cells[0]] = cells[1]
        elif mapping and cells[0] not in ('组件名前缀', '---'):
            matches = [name for name in components if name.startswith(cells[0])]
            if len(matches) != 1:
                raise ValueError('组件名前缀必须唯一: ' + cells[0])
            rules.append((matches[0], cells[1].replace('`', '').split()))
    if not components or not rules:
        raise ValueError('COMPONENTS.md 缺少组件表或 bin-inventory:rules')
    return components, rules


def is_test(path):
    p = Path(path)
    return ('selftest' in p.name or p.stem.endswith(('_test', '.test', '.spec'))
            or bool({'test', 'tests', 'fixtures', '__tests__'} & set(p.parts))
            or any(x in p.name for x in ('-fixture.', '-fake-', '-rig.')))


def inventory(root):
    components, rules = read_rules(root)
    sources = files(root)
    names = sorted(p[4:] for p in sources if p.startswith('bin/'))
    callers = {n: set() for n in names}
    tests = {n for n in names if is_test('bin/' + n)}
    aliases = {}
    for n in names:
        if '/' not in n or Path(n).suffix:
            aliases.setdefault(Path(n).name, set()).add(n)
        # Python modules are invoked by import without the .py suffix.
        if n.endswith('.py') and Path(n).stem.isidentifier():
            aliases.setdefault(Path(n).stem, set()).add(n)
    outgoing = {}
    discovered = set()
    nested = {n: re.compile(r'(?<![\w.-])' + re.escape(n) + r'(?![\w.-])')
              for n in names if '/' in n}
    for path in sources:
        content = (root / path).read_bytes()
        if b'\0' in content:
            continue
        body = content.decode('utf-8', errors='replace')
        references = set()
        for token in set(TOKEN.findall(body)):
            references.update(aliases.get(token, ()))
        # Bare 'claude' / 'codex' means the agent, not our session-shell wrapper.
        for n, pattern in nested.items():
            if pattern.search(body):
                references.add(n)
        references.discard(path[4:] if path.startswith('bin/') else '')
        outgoing[path] = references
        for n in references:
            callers[n].add(path)
        # The suite's actual discovery entry, not invented literal callers.
        if path == 'bin/run-selftests.sh' and '*-selftest.sh' in body:
            for n in names:
                if '/' not in n and n.endswith('-selftest.sh'):
                    callers[n].add(path)
                    discovered.add(n)

    def mapped(name):
        for component, patterns in rules:
            if any(fnmatchcase(name, pattern) for pattern in patterns):
                return component
        return ''

    owners = {n: mapped(n) for n in names if n not in tests}

    def subject_stem(name):
        return Path(name).stem.lstrip('.').replace('_', '-')

    for n in sorted(tests):
        # Exact subject (including the common omitted fleet- prefix) first.
        stem = re.sub(r'-selftest(?:-\d+)?$', '', subject_stem(n))
        subjects = [p for p in names if p not in tests and
                    subject_stem(p) in (stem, 'fleet-' + stem)]
        if not subjects:
            # A named scenario such as fleet-cleanup-idle-policy-selftest.
            subjects = [p for p in outgoing.get('bin/' + n, ()) if p not in tests
                        and subject_stem(p) != 'fleet'
                        and stem.startswith(subject_stem(p) + '-')]
            subjects.sort(key=lambda p: (-len(Path(p).stem), p))
            subjects = subjects[:1]
        inherited = {owners[p] for p in subjects if owners.get(p)}
        owners[n] = next(iter(inherited)) if len(inherited) == 1 else mapped(n)
        if not owners[n]:
            # Cross-component checks belong to the existing verification component.
            owners[n] = next(c for c in components if c.startswith('构建与验证'))
    # A Python selftest/fixture reached from a CI-discovered shell test is used.
    # Never extend this exemption to production files used only by tests.
    reached = set(discovered)
    pending = list(discovered)
    while pending:
        for target in outgoing.get('bin/' + pending.pop(), ()):
            if target in tests and target not in reached:
                reached.add(target)
                pending.append(target)
    rows = []
    for n in names:
        refs = sorted(callers[n])
        production = [p for p in refs if not is_test(p)]
        reason = ''
        if not refs:
            reason = '扫描范围内无静态引用；复核外部入口及动态拼接'
        elif not production and n not in reached:
            reason = '仅测试/夹具引用；复核人工入口及测试专用依赖'
        rows.append(dict(file='bin/' + n, component=owners.get(n, ''),
                         callers=refs, production=production, reason=reason,
                         category=components.get(owners.get(n, ''), ''),
                         test=n in tests))
    return rows


def summary(rows):
    classified = sum(bool(r['component']) for r in rows)
    candidates = sum(bool(r['reason']) for r in rows)
    unknown = sum(not r['component'] and not r['reason'] for r in rows)
    return f'总数\t{len(rows)}\n已归类\t{classified}\n待删候选\t{candidates}\n未归类\t{unknown}\n'


def tsv(rows):
    output = io.StringIO()
    writer = csv.writer(output, delimiter='\t', lineterminator='\n')
    writer.writerow(('文件', '组件', '调用方数', '首个调用方'))
    for r in rows:
        writer.writerow((r['file'], r['component'] or '待删候选',
                         len(r['callers']), next(iter(r['callers']), '—')))
    return output.getvalue()


def markdown(rows):
    counts = Counter(r['component'] or '待删候选（暂无组件）' for r in rows)
    categories = {r['component']: r['category'] for r in rows}
    lines = ['# 程序文件归属盘点', '',
             '由 `python3 bin/fleet-bin-inventory.py --markdown > docs/dev/BIN-INVENTORY.md` 生成。',
             '这是生成时分支的快照；实时数据用 `--summary` / `--tsv`，逐文件全部引用用 `--references`。',
             '组件、类别与归属模式来自 [COMPONENTS.md](COMPONENTS.md)，规则按表顺序首个匹配。', '',
             '```text', summary(rows).rstrip(), '```', '',
             '已归类与待删候选可以重叠；未归类 = 既无组件、也无候选理由的文件。',
             '覆盖 bin/ 的全部 Git 非忽略文件（含隐藏助手、数据、自测和新增未提交文件）；',
             '统计会随主干增加/删除文件变化，不把历史 1104 当成固定分母。', '',
             '## 如何读调用方', '',
             '扫描 bin、hooks、launchd、systemd、commands、skills、plugins、mod、conf、',
             'tokenledger、extras、.github 和 shell；按完整文件名 token 匹配 source / exec / 路径引用，',
             '并匹配 Python 模块名。自身引用不计，每个引用文件只计一次。',
             '调用方是静态引用文件，包含注释和文档提及，不能证明实际执行或可达；',
             '动态拼接、外部安装、操作者直接调用可能没有字面引用，候选不是删除许可。',
             '通用拷贝/打包不是调用；文档中的盘点表不反过来充当调用方。',
             'CI 的 `*-selftest.sh` 通配符发现单独计为 run-selftests.sh 引用；',
             '自测优先继承同名被测脚本（允许省略 fleet- 前缀），再取最长被测名称前缀；',
             '其余依显式规则，跨组件检查归构建与验证。被 CI 自测引用链触达的测试/夹具保留；',
             '只有测试引用的生产文件仍列候选，不能据此删除测试专用依赖。', '',
             '## 组件汇总', '', '| 组件 | 类别 | 文件数 |', '|---|---|---:|']
    for c, count in sorted(counts.items()):
        lines.append(f'| {c} | {categories.get(c, "—")} | {count} |')
    lines += ['', '## 待删候选（逐项复核，未删除任何文件）', '',
              '| 文件 | 组件 | 类型 | 引用文件数 | 首个引用 | 候选理由 |',
              '|---|---|---|---:|---|---|']
    for r in rows:
        if r['reason']:
            first = next(iter(r['callers']), '—')
            lines.append(f'| `{r["file"]}` | {r["component"] or "待复核"} | '
                         f'{"测试/夹具" if r["test"] else "程序/数据"} | '
                         f'{len(r["callers"])} | `{first}` | {r["reason"]} |')
    unknown = [r for r in rows if not r['component'] and not r['reason']]
    lines += ['', '## 未归类', '']
    lines += [f'- `{r["file"]}`' for r in unknown] or ['无。']
    return '\n'.join(lines) + '\n'


def selftest():
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        def put(path, text):
            file = root / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(text)
        put('docs/dev/COMPONENTS.md', '''| 组件 | 类别 | 理由 |
| 测试组件 | 核心 | fixture |
| 构建与验证 | 核心 | fixture |
<!-- bin-inventory:rules -->
| 组件名前缀 | bin/ 文件模式 | 说明 |
|---|---|---|
| 测试组件 | `live.sh orphan.sh only-test.sh lib.py session-shell/*` | fixture |
| 构建与验证 | `run-selftests.sh` | runner |
<!-- /bin-inventory:rules -->
''')
        for name in ('live.sh', 'orphan.sh', 'only-test.sh', 'lib.py', 'new.sh'):
            put('bin/' + name, '# ' + name + '\n')  # self reference never counts
        put('bin/only-test-selftest.sh', 'bash "$BIN/only-test.sh"\n')
        put('bin/live-selftest.sh', 'python3 live-selftest.py\n')
        put('bin/live-selftest.py', 'import lib\n')
        put('bin/run-selftests.sh', 'set -- *-selftest.sh\n')
        put('hooks/start.sh', 'source ../bin/live.sh\nexec ../bin/live.sh\n# new.sh\n')
        put('mod/use.py', 'import lib\n')
        put('bin/session-shell/claude', '# wrapper\n')
        put('hooks/agent.sh', 'claude --help\n')
        put('conf/wrapper.conf', 'bin/session-shell/claude\n')
        put('shell/client.sh', 'bash ../bin/live.sh\n')
        put('conf/false.conf', 'not-orphan.sh orphan.sh.bak orphan.sh-extra\n')
        put('docs/report.md', 'orphan.sh\n')
        rows = inventory(root)
        by = {r['file']: r for r in rows}
        assert by['bin/live.sh']['callers'] == ['hooks/start.sh', 'shell/client.sh']
        assert not by['bin/live.sh']['reason']
        assert by['bin/orphan.sh']['callers'] == []
        assert by['bin/orphan.sh']['reason'].startswith('扫描范围内无')
        assert by['bin/only-test.sh']['reason'].startswith('仅测试')
        assert by['bin/only-test-selftest.sh']['component'] == '测试组件'
        assert not by['bin/only-test-selftest.sh']['reason']
        assert by['bin/lib.py']['callers'] == ['bin/live-selftest.py', 'mod/use.py']
        assert not by['bin/live-selftest.py']['reason']
        assert by['bin/session-shell/claude']['callers'] == ['conf/wrapper.conf']
        assert '未归类\t1\n' in summary(rows)
        assert len(list(csv.reader(io.StringIO(tsv(rows)), delimiter='\t'))) == len(rows) + 1
        assert markdown(rows) == markdown(inventory(root))
        # Both public inventory formats must refuse an unclassified live file
        # while still printing every row; registering it must clear that gate.
        def check_cli(expected, rows):
            for flag, render in (('--summary', summary), ('--tsv', tsv)):
                result = subprocess.run([sys.executable, str(Path(__file__).resolve()),
                                         '--root', str(root), flag],
                                        capture_output=True, text=True)
                assert result.returncode == expected, (flag, result.returncode, result.stderr)
                assert result.stdout == render(rows), (flag, result.stdout)
        check_cli(1, rows)
        put('docs/dev/COMPONENTS.md', (root / 'docs/dev/COMPONENTS.md').read_text()
            .replace('`live.sh orphan.sh', '`new.sh live.sh orphan.sh'))
        assert '未归类\t0\n' in summary(inventory(root))
        check_cli(0, inventory(root))
        print('PASS inventory: runtime/orphan/test-only, inheritance, boundaries, imports, unknown, TSV, deterministic')
        print('PASS inventory CLI: unknown live file exits 1; mapped file exits 0; summary/TSV retain all files')

        # Exercise the shipped rules, not just the synthetic mapping above.
        # Synthetic callers keep ownership separate from actual reachability.
        root = root / 'rules'
        put('docs/dev/COMPONENTS.md', (Path(__file__).resolve().parent.parent /
                                    'docs/dev/COMPONENTS.md').read_text())
        groups = {
            '终端看台与薄客户端': ('fleet_pending_tool.py', 'fleet_status_evidence.py'),
            '执行会话与跨会话协作 MCP': ('fleet_task_ticket.py',),
            '构建与验证': ('nogh-task-acceptance.py', 'nogh-task-boundary-test.py',
                       'nogh-task-browser.mjs', 'nogh-task-deny-probe.py'),
        }
        names = [name for group in groups.values() for name in group]
        for name in names:
            put('bin/' + name, '# fixture\n')
        put('hooks/start.sh', '\n'.join(names))
        put('bin/fleet-pending-tool.sh', '# unreferenced mapped fixture\n')
        rows = inventory(root)
        by = {r['file']: r for r in rows}
        for component, group in groups.items():
            for name in group:
                assert by['bin/' + name]['component'].startswith(component), name
                assert by['bin/' + name]['category'] == '核心', name
        assert by['bin/fleet-pending-tool.sh']['reason'].startswith('扫描范围内无')
        check_cli(0, rows)
        # These adjacent names are NOT covered by the seven exact registrations.
        unknown = ('fleet_pending_tool_future.py', 'fleet_status_evidence_future.py',
                   'fleet_task_ticket_future.py', 'nogh-task-future.py')
        for name in unknown:
            put('bin/' + name, '# fixture\n')
        put('hooks/start.sh', '\n'.join(names + list(unknown)))
        rows = inventory(root)
        assert '未归类\t4\n' in summary(rows)
        assert '待删候选\t1\n' in summary(rows)
        check_cli(1, rows)
        print('PASS shipped rules: seven exact owners; adjacent unknowns exit 1; orphan retained; full summary/TSV')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    mode = parser.add_mutually_exclusive_group()
    for flag in ('summary', 'tsv', 'markdown', 'references', 'selftest'):
        mode.add_argument('--' + flag, action='store_true')
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return 0
    rows = inventory(args.root.resolve())
    if args.references:
        writer = csv.writer(sys.stdout, delimiter='\t', lineterminator='\n')
        writer.writerow(('文件', '调用方', '类型'))
        for r in rows:
            for caller in r['callers']:
                writer.writerow((r['file'], caller, '测试' if is_test(caller) else '非测试'))
    else:
        render = tsv if args.tsv else markdown if args.markdown else summary
        print(render(rows), end='')
    return int(any(not r['component'] and not r['reason'] for r in rows))


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f'inventory: {exc}', file=sys.stderr)
        sys.exit(2)
