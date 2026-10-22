#!/usr/bin/env python3
"""fleet_worker_life.py — what a worker window needs (T545, EPIC T542 C7;
hibernation itself went with T548, C8): its lazy dependencies, the worker
identity reads, the agent's MCP classification the busy walk and the
continuation share (fleet_agent_mcp.py); and that the old names (fleet-sleep.py's
subcommands, fleet_sleep_argv.py, fleet_sleep_mcp.py) still forward for one
version — every hibernation subcommand a quiet exit 0."""
import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

BIN=Path(sys.argv.pop(1)).absolute()
LIB=runpy.run_path(str(BIN/'fleet_worker_life.py'))


class ModuleLoadingTest(unittest.TestCase):
    def test_dependencies_load_once_on_first_use(self):
        dependency = LIB['LazyModule']('fixture.py')
        with patch.object(runpy, 'run_path', return_value={'value': 42}) as load:
            self.assertFalse(dependency.loaded)
            load.assert_not_called()
            self.assertEqual(dependency['value'], 42)
            self.assertEqual(dependency['value'], 42)
            with self.assertRaises(KeyError):
                dependency['absent']
            load.assert_called_once_with(str(BIN / 'fixture.py'))

    def test_failed_import_can_retry(self):
        dependency = LIB['LazyModule']('fixture.py')
        with patch.object(runpy, 'run_path', side_effect=[OSError('unavailable'), {'value': 42}]):
            with self.assertRaises(OSError):
                dependency['value']
            self.assertFalse(dependency.loaded)
            self.assertEqual(dependency['value'], 42)

    def test_dependency_overrides_restore_full_module(self):
        dependency = LIB['LazyModule']('fixture.py')
        with patch.object(runpy, 'run_path', return_value={'value': 42, 'other': 7}) as load:
            with patch.dict(dependency, value=99):
                self.assertEqual(dependency['value'], 99)
                self.assertEqual(dependency['other'], 7)
            self.assertEqual(dependency['value'], 42)
            self.assertEqual(dependency['other'], 7)
            load.assert_called_once()


class WorkerMetadataTest(unittest.TestCase):
    def test_worker_metadata_uses_three_reads(self):
        with patch.object(LIB['Worker'], 'tm', side_effect=[
                '@7|fixture', '%8  \n%9 1 ', '0||1|draft | name']) as read:
            worker = LIB['Worker']('fixture', '@7')
        self.assertEqual((worker.window, worker.pane), ('@7', '%8'))
        self.assertEqual(read.call_count, 3)

    def test_foreign_session_and_multiple_workers_are_refused(self):
        for replies, reason in ((['@7|other'], 'wrong fleet'),
                                (['@7|fixture', '%8  \n%9  '], 'exactly one worker')):
            with self.subTest(reason=reason), patch.object(LIB['Worker'], 'tm', side_effect=replies):
                with self.assertRaisesRegex(ValueError, reason):
                    LIB['Worker']('fixture', '@7')

    def test_worker_exclusions_survive_batched_reads(self):
        for metadata in ('1||1|task', '0|||task',
                         '0||1|home', '0||1|plan', 'incomplete'):
            with self.subTest(metadata=metadata), patch.object(LIB['Worker'], 'tm',
                    side_effect=['@7|fixture', '%8  ', metadata, '']):  # no @norepo exemption
                with self.assertRaises(ValueError):
                    LIB['Worker']('fixture', '@7')


class McpRestartTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='fleet-mcp-sleep-')
        self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name).resolve()
        self.node=self.root/'node';self.node.touch()
        self.script=self.root/'server.js';self.script.touch()
        self.config={'safe':{'command':str(self.node),'args':[str(self.script)]}}
        self.status={'data':[{'name':'safe','runtimeStatus':'ready','toolsError':None}]}
        self.rows={2:(1,'node')};self.argv={2:[str(self.node),str(self.script)]}
        self.exes={2:self.node};self.source={}
        owner=self
        class Client:
            def call(self,method,args):
                if method=='config/read':return {'config':{'mcp_servers':owner.config}}
                if method=='mcpServerStatus/list':return owner.status
                raise AssertionError(method)
        self.client=Client()

    def classify(self):
        return LIB['MCP']['classify'](self.source,LIB['MCP']['inventory'](self.client),self.rows,1,
                                      lambda pid:self.argv[pid],lambda pid:self.exes[pid])

    def claude_inventory(self,argv,config_home=None):
        return LIB['MCP']['claude_inventory'](argv,self.root/'worktree',config_home or self.root/'home')

    def test_claude_strict_inventory_is_exactly_the_mcp_config_documents(self):
        inventory=LIB['MCP']['claude_inventory']
        one=self.root/'one.json';one.write_text(json.dumps({'mcpServers':{'safe':self.config['safe']}}))
        two=self.root/'two.json';two.write_text(json.dumps({'mcpServers':{'remote':{'type':'http','url':'https://example.invalid'}}}))
        for argv in (['claude','--strict-mcp-config','--mcp-config='+str(one)],
                     ['claude','--mcp-config',str(one),'--strict-mcp-config'],
                     ['claude','--strict-mcp-config','--mcp-config='+json.dumps({'mcpServers':{'safe':self.config['safe']}})]):
            config,statuses=inventory(argv,self.root/'nowhere')
            self.assertEqual((set(config),statuses),({'safe'},None))
        config,_=inventory(['claude','--mcp-config',str(one),str(two),'--strict-mcp-config','prompt'],self.root/'nowhere')
        self.assertEqual(set(config),{'safe','remote'})
        with self.assertRaisesRegex(ValueError,'more than once'):
            inventory(['claude','--strict-mcp-config','--mcp-config',str(one),str(one)],self.root/'nowhere')
        for bad in ('{"mcpServers":[]}','{"mcpServers":{"x":1}}','not json',str(self.root/'missing.json')):
            with self.assertRaisesRegex(ValueError,'incomplete'):
                inventory(['claude','--strict-mcp-config','--mcp-config='+bad],self.root/'nowhere')
        with self.assertRaisesRegex(ValueError,'incomplete'):  # no store beneath a non-strict launch
            inventory(['claude','--mcp-config='+str(one)],self.root/'nowhere',self.root/'nowhere')

    def test_claude_store_scopes_rank_local_over_project_over_user(self):
        wt=self.root/'worktree';wt.mkdir();home=self.root/'home';home.mkdir()
        user={'command':'/u','args':[]};local={'command':'/l','args':[]};project={'command':'/p','args':[]}
        (wt/'.mcp.json').write_text(json.dumps({'mcpServers':{'shared':project,'approved':project,'pending':project,'refused':project}}))
        store={'mcpServers':{'shared':user,'only-user':user,'muted':user},
               'projects':{str(wt.resolve()):{'mcpServers':{'shared':local,'only-local':local},
                                              'enabledMcpjsonServers':['approved','refused'],'disabledMcpjsonServers':['refused'],
                                              'disabledMcpServers':['muted','plugin:x:y']}}}
        (home/'.claude.json').write_text(json.dumps(store))
        flag=self.root/'flag.json';flag.write_text(json.dumps({'mcpServers':{'only-user':{'command':'/f','args':[]}}}))
        config,statuses=self.claude_inventory(['claude','--mcp-config='+str(flag)])
        self.assertIsNone(statuses)
        self.assertEqual({name:conf['command'] for name,conf in config.items()},
                         {'shared':'/l','only-local':'/l','approved':'/p','only-user':'/f'})
        store['projects']={}
        (home/'.claude.json').write_text(json.dumps(store))
        config,_=self.claude_inventory(['claude'])
        self.assertEqual(set(config),{'shared','only-user','muted'})

    def test_claude_plugin_servers_carry_the_clis_names_and_gates(self):
        # A plugin's server is `plugin:<plugin>:<server>`, from the enabled plugins'
        # install roots (issue #830). Anything unresolvable contributes nothing.
        wt=self.root/'worktree';wt.mkdir();home=self.root/'home';home.mkdir()
        (home/'.claude.json').write_text(json.dumps({'projects':{str(wt.resolve()):{'disabledMcpServers':['plugin:muted:tool']}}}))
        (home/'settings.json').write_text(json.dumps({'enabledPlugins':{'shipped@market':True,'muted@market':True,'off@market':False,'ghost@market':True,'twice@market':True,'broken@market':True}}))
        (wt/'.claude').mkdir();(wt/'.claude'/'settings.json').write_text(json.dumps({'enabledPlugins':{'wrapped@market':True}}))
        def install(key,servers,wrapped=False,manifest='.mcp.json'):
            root=home/'plugins'/'cache'/key;(root/'.claude-plugin').mkdir(parents=True)
            (root/manifest).write_text(json.dumps({'mcpServers':servers} if wrapped else servers) if isinstance(servers,dict) else servers)
            return {'installPath':str(root)}
        registry={'shipped@market':[install('shipped',{'tool':{'command':'${CLAUDE_PLUGIN_ROOT}/bin/tool','args':['--root','${CLAUDE_PLUGIN_ROOT}'],'env':{'HOME':'${CLAUDE_PLUGIN_ROOT}'}}})],
                  'wrapped@market':[install('wrapped',{'tool':{'command':'/w','args':[]},'remote':{'type':'http','url':'https://example.invalid'}},wrapped=True)],
                  'muted@market':[install('muted',{'tool':{'command':'/m','args':[]}})],
                  'off@market':[install('off',{'tool':{'command':'/o','args':[]}})],
                  'twice@market':[install('twice-a',{'tool':{'command':'/t','args':[]}}),install('twice-b',{'tool':{'command':'/t','args':[]}})],
                  'broken@market':[install('broken','{not json')]}
        (home/'plugins'/'installed_plugins.json').write_text(json.dumps({'version':2,'plugins':registry}))
        inventory=LIB['MCP']['claude_inventory']
        config,_=inventory(['claude'],wt,home)
        root=registry['shipped@market'][0]['installPath']
        self.assertEqual(config,{'plugin:shipped:tool':{'command':root+'/bin/tool','args':['--root',root],'env':{'HOME':root}},
                                 'plugin:wrapped:tool':{'command':'/w','args':[]},
                                 'plugin:wrapped:remote':{'type':'http','url':'https://example.invalid'}})
        self.assertEqual(inventory(['claude','--strict-mcp-config'],wt,home)[0],{})
        (home/'plugins'/'installed_plugins.json').unlink()
        self.assertEqual(inventory(['claude'],wt,home)[0],{})

    def test_exact_config_and_explicit_contract_required(self):
        self.config['remote']={'url':'https://example.invalid/mcp','command':None,'args':None}
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='',FLEET_CONF_DIR='/cf'):
            with self.assertRaisesRegex(ValueError,'restartability contract'):self.classify()
        # The refusal names the exact line and file that lifts it (#786): a
        # failover refusal is otherwise visible only in request.json.
        self.source['session']='fleet-x'
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='other',FLEET_CONF_DIR='/cf'):
            with self.assertRaisesRegex(ValueError,'add FLEET_SLEEP_MCP_RESTARTABLE=other,safe to /cf/fleets/fleet-x/conf'):self.classify()
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='safe'):
            self.assertEqual(self.classify(),{2})
            self.assertEqual(set(self.source['sleep_mcp']),{'safe'})
            self.argv[2].append('--different')
            self.assertEqual(self.classify(),set())
            self.argv[2].pop();self.exes[2]=self.root/'impostor'
            self.assertEqual(self.classify(),set())

    def test_bare_interpreter_name_matches_the_launchers_build_not_the_verifiers_path(self):
        # The daemon's PATH resolved `node` to node 26 while Codex had started the
        # server under node@22: a bare command name must match the running
        # program's name and exact argv, whatever build the verifier would find.
        other=self.root/'path'/'node';other.parent.mkdir();other.touch();other.chmod(0o755)
        self.config['safe']={'command':'node','args':[str(self.script)]}
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='safe'):
            for path in (str(other.parent),str(self.root/'empty')):
                with patch.dict(os.environ,PATH=path):
                    self.assertEqual(self.classify(),{2})
            with patch.dict(os.environ,PATH=str(other.parent)):
                self.exes[2]=self.root/'python';self.exes[2].touch()
                self.assertEqual(self.classify(),set())
                self.exes[2]=self.node;self.argv[2]=[str(self.node),str(self.script),'--other']
                self.assertEqual(self.classify(),set())

    def test_children_and_partial_inventory_still_veto(self):
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='safe'):
            self.rows[3]=(2,'browser');self.argv[3]=['browser'];self.exes[3]=self.root/'browser'
            with self.assertRaisesRegex(ValueError,'child process'):self.classify()
            del self.rows[3]
            self.status['nextCursor']='more'
            with self.assertRaisesRegex(ValueError,'incomplete'):self.classify()
            del self.status['nextCursor']
            self.status['data'].append(None)
            with self.assertRaisesRegex(ValueError,'incomplete'):self.classify()
            self.status['data'].pop()
            self.status['data'][0]['runtimeStatus']='starting'
            with self.assertRaisesRegex(ValueError,'not ready'):self.classify()

    def test_older_runtime_requires_initialize_and_tool_inventory(self):
        ready=LIB['MCP']['runtime_ready']
        self.assertFalse(ready({'runtimeStatus':None}))
        old={'runtimeStatus':None,'serverInfo':{'name':'safe'},'tools':{'read':{}},'toolsError':None}
        self.assertTrue(ready(old))
        old['toolsError']='failed';self.assertFalse(ready(old))

    def test_npx_package_entrypoint_is_allowed_but_its_browser_is_not(self):
        wrapper=self.root/'npx';wrapper.touch()
        package=self.root/'node_modules/safe-mcp';package.mkdir(parents=True)
        script=package/'cli.js';script.touch()
        (package/'package.json').write_text(json.dumps({'name':'safe-mcp','bin':{'safe':'cli.js'}}))
        self.config['safe']={'command':str(wrapper),'args':['safe-mcp@1.0','--stdio']}
        self.argv[2]=[str(self.node),str(wrapper),'safe-mcp@1.0','--stdio']
        self.rows[3]=(2,'node');self.argv[3]=[str(self.node),str(script),'--stdio'];self.exes[3]=self.node
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='safe'):
            self.assertEqual(self.classify(),{2,3})
            self.argv[2]=['npm exec safe-mcp@1.0 --stdio','','','']
            self.assertEqual(self.classify(),{2,3})
            self.exes[3]=self.root/'different-node'
            self.assertEqual(self.classify(),set())
            self.exes[3]=self.node
            self.rows[4]=(3,'browser')
            with self.assertRaisesRegex(ValueError,'job/browser'):self.classify()
            del self.rows[4]
            self.argv[3].append('--wrong')
            self.assertEqual(self.classify(),set())  # rewritten wrapper cannot prove its child

    def test_a_plugin_stdio_server_is_restartable_by_default(self):
        # #1583: `plugin:playwright:playwright` refused a hard-walled source 3x on
        # 2026-10-04 for want of a conf line. A plugin's stdio server restarts with
        # every Claude process; `!plugin:*` / `!<name>` take the default back, and a
        # bare third-party name still needs the explicit contract.
        name='plugin:playwright:playwright'
        config={name:self.config['safe']}
        readers=(lambda pid:self.argv[pid],lambda pid:self.exes[pid])
        classify=lambda:LIB['MCP']['classify'](self.source,(config,None),self.rows,1,*readers)
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE=''):
            self.assertEqual(classify(),{2})
        for off in ('!plugin:*','other,!'+name):
            with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE=off):
                with self.assertRaisesRegex(ValueError,'restartability contract'):classify()
        self.rows[4]=(2,'browser');self.rows[5]=(4,'renderer')   # a browser beneath it still vetoes
        self.argv[4]=['/x/chrome'];self.exes[4]=Path('/x/chrome')
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE=''):
            with self.assertRaisesRegex(ValueError,'MCP service plugin:playwright:playwright owns'):classify()
        self.assertFalse(LIB['MCP']['contracted']('safe',set()))

    def test_busy_classify_drops_the_contract_but_keeps_identification(self):
        # child_busy (#864) asks "MCP service or agent work?", not "may it sleep?":
        # an uncontracted server and its job/browser are still infrastructure, an
        # unidentified process is still work.
        self.rows[4]=(2,'browser');self.rows[5]=(4,'renderer')
        readers=(lambda pid:self.argv[pid],lambda pid:self.exes[pid])
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE=''):
            with self.assertRaisesRegex(ValueError,'restartability contract'):self.classify()
            self.assertEqual(LIB['MCP']['classify'](self.source,(self.config,None),self.rows,1,*readers,strict=False),{2,4,5})
            self.argv[2]=self.argv[2]+['--different']
            self.assertEqual(LIB['MCP']['classify'](self.source,(self.config,None),self.rows,1,*readers,strict=False),set())

    def test_uvx_reexec_requires_sibling_binary_and_isolated_entrypoint(self):
        uvx=self.root/'uvx';uvx.touch()
        uv=self.root/'uv';uv.touch()
        self.config['safe']={'command':str(uvx),'args':['--from','safe-mcp','safe-mcp']}
        self.exes[2]=uv;self.argv[2]=[str(uv),'tool','uvx','--from','safe-mcp','safe-mcp']
        env=self.root/'env';(env/'bin').mkdir(parents=True)
        (env/'pyvenv.cfg').touch()
        python=env/'bin/python';python.touch()
        entry=env/'bin/safe-mcp';entry.touch()
        self.rows[3]=(2,'python');self.exes[3]=python;self.argv[3]=[str(python),str(entry)]
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='safe'):
            self.assertEqual(self.classify(),{2,3})
            (env/'pyvenv.cfg').unlink()
            with self.assertRaisesRegex(ValueError,'unverified child'):self.classify()


    # Issue #4537: conf/mcp-worker.json launches the fleet's own server as
    # `bash -c 'exec python3 "${FLEET_MCP_BIN:-$HOME/.claude/fleet/bin}/fleet-mcp.py"'`.
    # After the exec the kernel is Python running the EXPANDED path — possibly an
    # install since deleted. Identity comes from the started process's own
    # environment; the restartability contract is a separate, unchanged gate.
    SHELL_EXEC='exec python3 "${FLEET_MCP_BIN:-$HOME/.claude/fleet/bin}/fleet-mcp.py"'
    FRAMEWORK=Path('/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python')

    def shell_exec_case(self,env=None,script=None,command='bash',args=None):
        self.config={'fleet':{'command':command,'args':args if args is not None else ['-c',script or self.SHELL_EXEC]}}
        self.status={'data':[{'name':'fleet','runtimeStatus':'ready','toolsError':None}]}
        self.rows={2:(1,'Python')}
        self.argv={2:[str(self.FRAMEWORK),'/gone/old/bin/fleet-mcp.py']}
        self.exes={2:self.FRAMEWORK}
        self.env=dict(HOME='/home/x',FLEET_MCP_BIN='/gone/old/bin',PATH='/nowhere') if env is None else env
        self.parent_env=None  # None: the agent handed down exactly self.env
        self.births={1:(10,0),2:(20,0)}
        self.socket_stdin=set()
        self.env_reads=[]

    def env_reader(self,pid,names):
        env=self.env if pid!=1 or self.parent_env is None else self.parent_env
        if isinstance(env,Exception):raise env
        self.env_reads.append((pid,set(names)))
        birth=self.births[pid]
        if callable(birth):birth=birth()
        return dict(names=frozenset(env),values={k:v for k,v in env.items() if k in names},birth=birth,
                    functions=frozenset(k for k,v in env.items() if v.startswith('() {')),
                    stdin_socket=pid in self.socket_stdin)

    def shell_classify(self,env_reader=True,strict=True):
        return LIB['MCP']['classify'](self.source,LIB['MCP']['inventory'](self.client),self.rows,1,
                                      lambda pid:self.argv[pid],lambda pid:self.exes[pid],strict=strict,
                                      env_reader=self.env_reader if env_reader else None)

    def test_shell_exec_launcher_is_identified_from_the_started_environment(self):
        self.shell_exec_case()
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='fleet'):
            self.assertFalse(Path('/gone/old/bin/fleet-mcp.py').exists())
            self.assertEqual(self.shell_classify(),{2})
            self.assertEqual(set(self.source['sleep_mcp']),{'fleet'})
            self.assertEqual(self.source['sleep_mcp_basis'],{'fleet':'shell-exec'})
            # Only the names the script reads (+ PATH) are asked for, never the block.
            self.assertIn((2,{'FLEET_MCP_BIN','HOME','PATH'}),self.env_reads)
            self.assertIn((1,{'FLEET_MCP_BIN','HOME','PATH'}),self.env_reads)
            # No env reader (the old call shape) proves nothing: unverified, as before.
            self.source={}
            self.assertEqual(self.shell_classify(env_reader=False),set())
            self.assertNotIn('sleep_mcp_basis',self.source)
            # The default branch, an absolute bash and an empty override.
            self.env=dict(HOME='/gone',PATH='/nowhere');self.argv[2][1]='/gone/.claude/fleet/bin/fleet-mcp.py'
            self.assertEqual(self.shell_classify(),{2})
            self.env['FLEET_MCP_BIN']=''
            self.assertEqual(self.shell_classify(),{2})
            self.config['fleet']['command']='/bin/bash'
            self.assertEqual(self.shell_classify(),{2})

    def test_shell_exec_identity_is_not_a_restartability_contract(self):
        self.shell_exec_case()
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE=''):
            with self.assertRaisesRegex(ValueError,'fleet has no restartability contract'):self.shell_classify()
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='other,!fleet,plugin:x:y'):
            with self.assertRaisesRegex(ValueError,'fleet has no restartability contract'):self.shell_classify()
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='fleet'):
            self.status={'data':[{'name':'fleet','runtimeStatus':'starting'}]}
            with self.assertRaisesRegex(ValueError,'not ready or has unknown'):self.shell_classify()
            self.status={'data':[]}
            with self.assertRaisesRegex(ValueError,'not ready or has unknown'):self.shell_classify()
            self.status={'data':[{'name':'fleet','runtimeStatus':'ready','toolsError':None}]}
            # A real tool/job beneath the server is still a blocker.
            self.rows[3]=(2,'python');self.argv[3]=['python3','-c','job'];self.exes[3]=self.FRAMEWORK
            with self.assertRaisesRegex(ValueError,'unverified child'):self.shell_classify()
        # Non-strict (busy) still identifies it, and still keeps the job visible.
        self.source={'agent':'codex'}
        self.assertEqual(self.shell_classify(strict=False),{2})

    def test_remounted_skips_only_contract_and_readiness(self):
        # Issue #4775: the continuation proves the next lifetime mounts the
        # fleet's own service afresh from the current install. That replaces the
        # sleep contract and readiness for it — never identity or the job check.
        self.shell_exec_case()
        self.status={'data':[{'name':'fleet','runtimeStatus':None,'toolsError':'MCP startup failed'}]}
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE=''):
            with self.assertRaisesRegex(ValueError,'no restartability contract'):self.shell_classify()
            classify=lambda **k:LIB['MCP']['classify'](self.source,LIB['MCP']['inventory'](self.client),self.rows,1,
                lambda pid:self.argv[pid],lambda pid:self.exes[pid],env_reader=self.env_reader,**k)
            self.assertEqual(classify(remounted=frozenset({'fleet'})),{2})
            self.assertEqual(self.source['sleep_mcp_basis'],{'fleet':'shell-exec+remounted'})
            # Another name does not cover it; identity still has to hold.
            with self.assertRaisesRegex(ValueError,'no restartability contract'):classify(remounted=frozenset({'other'}))
            self.env=dict(FLEET_MCP_BIN='/another/bin')
            self.assertEqual(classify(remounted=frozenset({'fleet'})),set())
            self.env=dict(HOME='/home/x',FLEET_MCP_BIN='/gone/old/bin',PATH='/nowhere')
            self.rows[3]=(2,'python');self.argv[3]=['python3','-c','job'];self.exes[3]=self.FRAMEWORK
            with self.assertRaisesRegex(ValueError,'unverified child'):classify(remounted=frozenset({'fleet'}))
        # The walk takes it for a strict Codex source only.
        quiet=LIB['quiet_processes']
        for source in ({'agent':'claude','pid':1},):
            with self.assertRaisesRegex(ValueError,'strict Codex walk'):quiet(dict(source),remounted=['fleet'])
        with self.assertRaisesRegex(ValueError,'strict Codex walk'):quiet({'agent':'codex','pid':1},strict=False,remounted=['fleet'])

    def test_shell_exec_refuses_what_the_started_environment_cannot_prove(self):
        self.shell_exec_case()
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='fleet'):
            for env in (dict(HOME='/home/x',FLEET_MCP_BIN='/another/bin'),     # expands elsewhere
                        dict(PATH='/nowhere'),                                  # nothing to expand
                        dict(FLEET_MCP_BIN='/gone/old/bin',BASH_ENV='/rc'),     # code ran first
                        dict(FLEET_MCP_BIN='/gone/old/bin',ENV='/rc'),
                        dict(FLEET_MCP_BIN='/gone/old/bin',SHELLOPTS='allexport'),
                        dict(FLEET_MCP_BIN='/gone/old/bin',**{'BASH_FUNC_exec%%':'() { :; }'}),
                        dict(FLEET_MCP_BIN='/gone/old/bin',python3='() { :; }'),  # bash 3.2's old export form
                        dict(FLEET_MCP_BIN='/gone/old/bin',EXECIGNORE='*'),
                        dict(FLEET_MCP_BIN='/gone/old/bin',BASH_COMPAT='31'),
                        dict(FLEET_MCP_BIN='/gone/old/bin',SSH_CLIENT='1 2 3'),    # ~/.bashrc
                        OSError(3,'gone'),ValueError('malformed')):
                self.env=env
                self.assertEqual(self.shell_classify(),set(),env)
            self.env=dict(FLEET_MCP_BIN='/gone/old/bin')
            self.assertEqual(self.shell_classify(),{2})
            # stdin a socket: bash read /etc/bashrc + ~/.bashrc, which no variable shows.
            self.socket_stdin={2}
            self.assertEqual(self.shell_classify(),set())
            self.socket_stdin=set()
            # The agent's own ssh session is normal and is not handed down.
            self.parent_env=dict(FLEET_MCP_BIN='/gone/old/bin',SSH_CLIENT='1 2 3',SSH_TTY='/dev/ttys0')
            self.assertEqual(self.shell_classify(),{2})
            self.parent_env=None
            # The shell's start is proven from the AGENT that launched it: a hook
            # there may have rewritten the environment and exec'd before the -c
            # script ran, leaving no trace in the process it left behind.
            for parent in (dict(FLEET_MCP_BIN='/gone/old/bin',BASH_ENV='/rc'),
                           dict(FLEET_MCP_BIN='/gone/old/bin',BASHOPTS='x'),
                           dict(FLEET_MCP_BIN='/gone/old/bin',**{'BASH_FUNC_python3%%':'() { :; }'}),
                           dict(FLEET_MCP_BIN='/somewhere/else'),               # not what it handed down
                           dict(),                                              # it had none to hand down
                           OSError(3,'gone')):
                self.parent_env=parent
                self.assertEqual(self.shell_classify(),set(),parent)
            # An agent may hand down fewer variables than it has, never other values.
            self.parent_env=dict(FLEET_MCP_BIN='/gone/old/bin',HOME='/h',UNRELATED='x')
            self.assertEqual(self.shell_classify(),{2})
            # The config's env is what the shell got, and may carry no hook itself.
            self.parent_env=dict(HOME='/h');self.config['fleet']['env']={'FLEET_MCP_BIN':'/gone/old/bin'}
            self.assertEqual(self.shell_classify(),{2})
            self.config['fleet']['env']={'FLEET_MCP_BIN':'/other/bin'}
            self.assertEqual(self.shell_classify(),set())
            self.config['fleet']['env']={'FLEET_MCP_BIN':'/gone/old/bin','BASH_ENV':'/rc'}
            self.assertEqual(self.shell_classify(),set())
            self.config['fleet'].pop('env');self.parent_env=None
            # Codex forwards env_vars by name from its own environment: naming a
            # hook there (or anything that is not a list of names) proves nothing.
            for forwarded in (['FLEET_MCP_BIN','BASH_ENV'],['ENV'],['BASH_FUNC_python3%%'],['SSH_CLIENT'],'BASH_ENV',[1]):
                self.config['fleet']['env_vars']=forwarded
                self.assertEqual(self.shell_classify(),set(),forwarded)
            self.config['fleet']['env_vars']=['FLEET_MCP_BIN','TMUX']
            self.assertEqual(self.shell_classify(),{2})
            self.config['fleet'].pop('env_vars')
            # A process started before its parent, or a number reused mid-check.
            self.births[1]=(30,0)
            self.assertEqual(self.shell_classify(),set())
            self.births[1]=(10,0);seen=iter([(20,0),(21,0)]);self.births[2]=lambda:next(seen)
            self.assertEqual(self.shell_classify(),set())
            self.births[2]=(20,0)
            self.assertEqual(self.shell_classify(),{2})
            # The kernel must be what the shell exec'd: argv exact, program by name.
            self.argv[2]=[str(self.FRAMEWORK),'/gone/old/bin/fleet-mcp.py','--extra']
            self.assertEqual(self.shell_classify(),set())
            self.argv[2]=[str(self.FRAMEWORK),'/gone/old/bin/fleet-mcp.py'];self.exes[2]=Path('/usr/bin/node')
            self.assertEqual(self.shell_classify(),set())
            # A shell that has not exec'd yet is the configured launcher; its child is not.
            self.exes[2]=Path('/bin/bash');self.argv[2]=['bash','-c',self.SHELL_EXEC]
            self.rows[3]=(2,'Python');self.argv[3]=[str(self.FRAMEWORK),'/gone/old/bin/fleet-mcp.py'];self.exes[3]=self.FRAMEWORK
            with self.assertRaisesRegex(ValueError,'unverified child'):self.shell_classify()

    def test_shell_exec_parses_only_the_one_proven_shape(self):
        self.shell_exec_case()
        refused=['exec python3 $FLEET_MCP_BIN/fleet-mcp.py',                 # unquoted: split + glob
                 'exec python3 "$(echo /gone/old/bin)/fleet-mcp.py"',
                 'exec python3 "`echo /gone/old/bin`/fleet-mcp.py"',
                 'cd /; exec python3 "${FLEET_MCP_BIN}/fleet-mcp.py"',
                 'exec python3 "${FLEET_MCP_BIN}/fleet-mcp.py"; true',
                 'exec python3 "${FLEET_MCP_BIN}/fleet-mcp.py" && true',
                 'exec -a python3 python3 "${FLEET_MCP_BIN}/fleet-mcp.py"',
                 'exec -c python3 "${FLEET_MCP_BIN}/fleet-mcp.py"',
                 'exec python3 ~/fleet-mcp.py',
                 'exec python3 "${PWD}/fleet-mcp.py"',
                 'exec python3 "${BASH_SOURCE}/fleet-mcp.py"',
                 'exec python3 "${FLEET_MCP_BIN:=/x}/fleet-mcp.py"',
                 'exec python3 "${FLEET_MCP_BIN#/}/fleet-mcp.py"',
                 'exec python3 "${FLEET_MCP_BIN:-${HOME:-/x}}/fleet-mcp.py"',
                 'exec python3 "${FLEET_MCP_BIN}/fleet-mcp.py',
                 'exec python3 "${FLEET_MCP_BIN}/fleet\\-mcp.py"',
                 'exec "py$X" "${FLEET_MCP_BIN}/fleet-mcp.py"',
                 'exec /usr/bin/python3 "${FLEET_MCP_BIN}/fleet-mcp.py"',
                 'python3 "${FLEET_MCP_BIN}/fleet-mcp.py"',
                 'exec',
                 'exec python3 "${FLEET_MCP_BIN}"/*.py']
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='fleet'):
            for script in refused:
                self.shell_exec_case(script=script)
                self.assertEqual(self.shell_classify(),set(),script)
            for args in (['-lc',self.SHELL_EXEC],['-c',self.SHELL_EXEC,'arg0'],['-c'],[self.SHELL_EXEC]):
                self.shell_exec_case(args=args)
                self.assertEqual(self.shell_classify(),set(),args)
            self.shell_exec_case(command='sh')
            self.assertEqual(self.shell_classify(),set())
            for script in ("exec python3 '/gone/old/bin/fleet-mcp.py'",
                           'exec python3 "$FLEET_MCP_BIN/fleet-mcp.py"',
                           'exec python3 "${FLEET_MCP_BIN}"/fleet-mcp.py',
                           '  exec   python3 "${FLEET_MCP_BIN}/fleet-mcp.py"  '):
                self.shell_exec_case(script=script)
                self.assertEqual(self.shell_classify(),{2},script)

    def test_shell_exec_ambiguous_configs_prove_nothing(self):
        self.shell_exec_case()
        self.config['copy']=dict(self.config['fleet'])
        self.status['data'].append({'name':'copy','runtimeStatus':'ready'})
        with patch.dict(os.environ,FLEET_SLEEP_MCP_RESTARTABLE='fleet,copy'):
            self.assertEqual(self.shell_classify(),set())

    def test_shell_exec_is_offered_to_codex_only(self):
        # Claude hands its MCP children its whole, mutable environment, so its
        # classify / resume calls pass no env reader and the shape stays refused.
        src=(BIN/'fleet_worker_life.py').read_text()
        calls=[line for line in src.splitlines() if "MCP['classify'](" in line]
        self.assertEqual(len(calls),3)
        claude=[line for line in calls if 'inventory,rows' in line]
        self.assertEqual(len(claude),1)
        self.assertNotIn('env_reader',claude[0])
        self.assertTrue(all("env_reader=MCP['shell_exec_reader'](client,ARGV['process_env'])" in line for line in calls if line not in claude))
        # ...and a Codex only for a release whose MCP environment was measured.
        reader=lambda pid,names:None
        pick=LIB['MCP']['shell_exec_reader']
        client=lambda agent:type('C',(),{'initialized':{'userAgent':agent}})()
        self.assertIs(pick(client('claude_fleet/0.160.1 (Mac OS 27.0.0; arm64) unknown (claude_fleet; 1)'),reader),reader)
        # 0.162.1: measured in #4775.
        self.assertIs(pick(client('claude_fleet/0.162.1 (Mac OS 27.0.0; arm64)'),reader),reader)
        for agent in ('claude_fleet/0.161.0 (Mac OS)','claude_fleet/0.160.10','claude_fleet/0.162.10','codex/0.160.1-alpha','0.160.1',None,7):
            self.assertIsNone(pick(client(agent),reader),agent)
        self.assertIsNone(pick(object(),reader))

    def test_shell_exec_real_kernel_after_the_install_is_deleted(self):
        # The real readers on a real shell: an agent process starts
        # `bash -c 'exec …'`, the old install is deleted while it runs, and a
        # BASH_ENV hook that redirects the exec is refused — in the agent's
        # environment, in the config's, or added by the agent on its own.
        agent=self.root/'agent.py'
        agent.write_text('import json,os,subprocess,sys,time\n'
                         'import socket\n'
                         'stdin=socket.socketpair()[0] if sys.argv[3]=="socket" else subprocess.DEVNULL\n'
                         'c=subprocess.Popen(["bash","-c",sys.argv[1]],env=dict(os.environ,**json.loads(sys.argv[2])),stdin=stdin)\n'
                         'print(c.pid,flush=True);time.sleep(60)\n')
        old=self.root/'old'/'bin';evil=self.root/'evil'
        argv,exe,env_reader=LIB['ARGV']['process_argv'],LIB['ARGV']['process_executable'],LIB['ARGV']['process_env']
        def launch(agent_env=None,handed=None,stdin='null'):
            for d in (old,evil):
                d.mkdir(parents=True,exist_ok=True)
                (d/'fleet-mcp.py').write_text('import time\ntime.sleep(60)\n')
            rc=self.root/'rc'
            rc.write_text('unset BASH_ENV\nexport FLEET_MCP_BIN=%s\nexec python3 "$FLEET_MCP_BIN/fleet-mcp.py"\n'%evil)
            env={'PATH':os.environ['PATH'],'HOME':str(self.root/'home'),'FLEET_MCP_BIN':str(old),
                 'SECRET_TOKEN':'never-read',**(agent_env or {})}
            proc=subprocess.Popen([sys.executable,str(agent),self.SHELL_EXEC,json.dumps(handed or {}),stdin],env=env,
                                  stdout=subprocess.PIPE,stdin=subprocess.DEVNULL)
            self.addCleanup(lambda:(proc.kill(),proc.wait(),proc.stdout.close()))
            pid=int(proc.stdout.readline())
            self.addCleanup(lambda:subprocess.run(['kill',str(pid)],capture_output=True))
            # Settled = the same exec'd Python twice in a row: macOS's python3
            # shim re-execs the framework binary after bash's exec.
            until=time.monotonic()+10;last=None
            while time.monotonic()<until:
                try:now=(exe(pid),argv(pid))
                except OSError:now=None
                if now and now==last and now[0].name!='bash' and now[1][-1].endswith('fleet-mcp.py'):break
                last=now;time.sleep(.2)
            shutil.rmtree(self.root/'old')
            return proc.pid,pid
        conf={'command':'bash','args':['-c',self.SHELL_EXEC]}
        match=lambda pid,parent,c=conf,reader=env_reader:LIB['MCP']['configured_process'](pid,c,argv,exe,reader,parent)
        parent,pid=launch()
        self.assertFalse(old.exists())
        read=env_reader(pid,{'FLEET_MCP_BIN'})
        self.assertIn('SECRET_TOKEN',read['names'])
        self.assertEqual(read['values'],{'FLEET_MCP_BIN':str(old)})   # only what was asked
        self.assertEqual(read['birth'],LIB['ARGV']['process_birth'](pid))
        self.assertFalse(read['stdin_socket'])
        self.assertTrue(match(pid,parent))
        self.assertFalse(match(pid,parent,reader=None))           # the old call shape proves nothing
        self.assertFalse(match(pid,None))                          # nor does a missing parent
        self.assertFalse(match(pid,parent,{'command':'bash','args':['-c',self.SHELL_EXEC.replace('FLEET_MCP_BIN','OTHER_BIN')]}))
        self.assertFalse(match(pid,parent,{'command':'bash','args':['-c','exec python3 "${FLEET_MCP_BIN}/other.py"']}))
        hook={'BASH_ENV':str(self.root/'rc')}
        for agent_env,handed,conf_env in ((hook,None,None),(None,hook,hook),(None,hook,None)):
            parent,pid=launch(agent_env,handed)
            c=dict(conf,env=conf_env) if conf_env else conf
            self.assertFalse(match(pid,parent,c),(agent_env,handed,conf_env))
            # Whether or not this bash honoured the hook, nothing matches: not the
            # config, not even the bare words that would expand to the evil path.
            self.assertFalse(match(pid,parent,{'command':'bash','args':['-c','exec python3 "${FLEET_MCP_BIN}/fleet-mcp.py"']}))
        # The boundary, pinned: an agent that adds a hook at RUNTIME (not in its
        # start environment, not in the config) whose hook unsets itself and execs
        # the very same argv leaves a kernel this function cannot tell apart — it
        # matches. That is why only Codex callers pass an env reader: Codex 0.160.1
        # hands an MCP child only its allowlist + env_vars + env (measured), so a
        # hook can reach bash only through the config, which is checked above.
        quiet=self.root/'quiet-rc'
        quiet.write_text('unset BASH_ENV\nexec python3 "$FLEET_MCP_BIN/fleet-mcp.py"\n')
        parent,pid=launch(None,{'BASH_ENV':str(quiet)})
        # ran = the hook unset itself; if this bash skipped it, BASH_ENV is still there and refused.
        self.assertEqual(match(pid,parent),'BASH_ENV' not in env_reader(pid,set())['names'])
        # A socket on stdin (and SHLVL < 2) makes bash read ~/.bashrc instead —
        # upstream bash's rshd/sshd rule — and no environment says so; fd 0 does.
        parent,pid=launch(stdin='socket')
        self.assertTrue(env_reader(pid,set())['stdin_socket'])
        self.assertFalse(match(pid,parent))

class CompatForwardTest(unittest.TestCase):
    # compat-1v: 下一批删 — the old names stay one version.
    def test_old_module_names_forward_to_the_renamed_ones(self):
        for old,new in (('fleet_sleep_argv.py','fleet_agent_argv.py'),('fleet_sleep_mcp.py','fleet_agent_mcp.py')):
            a=runpy.run_path(str(BIN/old));b=runpy.run_path(str(BIN/new))
            names={k for k in b if not k.startswith('__')}
            self.assertTrue(names and names<=set(a),old)
            self.assertTrue(all(a[k] is not None for k in names),old)

    def test_sleep_forwards_the_moved_subcommands_with_their_exit_codes(self):
        sleep=runpy.run_path(str(BIN/'fleet-sleep.py'))
        self.assertEqual(set(sleep['LIFE']['ACTIONS']),
                         {'hook','busy','holds-exit','deliver','dispose','restore','hold','release'})
        env=dict(os.environ,TMUX='',TMUX_PANE='')
        for script in ('fleet-sleep.py','fleet_worker_life.py'):
            # hook outside tmux: a quiet no-op, exit 0, as before the move
            p=subprocess.run([sys.executable,str(BIN/script),'hook'],input='{}',env=env,
                             text=True,capture_output=True,timeout=30)
            self.assertEqual((p.returncode,p.stdout),(0,''),script+p.stderr)
            # busy on a socket that is not there: 2 = cannot tell, never idle
            p=subprocess.run([sys.executable,str(BIN/script),'busy','--session','no-such-fleet-%d'%os.getpid(),'@1'],
                             env=env,text=True,capture_output=True,timeout=30)
            self.assertEqual(p.returncode,2,script+p.stderr)
            self.assertTrue(p.stderr.startswith('fleet-sleep: '),p.stderr)
            # deliver to no worker: 1, one line on stderr
            p=subprocess.run([sys.executable,str(BIN/script),'deliver','--session','no-such-fleet-%d'%os.getpid(),'@1'],
                             input='x',env=env,text=True,capture_output=True,timeout=30)
            self.assertEqual(p.returncode,1,script+p.stderr)
        # hibernation's own subcommands (T548): a quiet exit 0, python and shell
        for argv in (['python3',str(BIN/'fleet-sleep.py'),'scan','--session','x'],
                     ['bash',str(BIN/'fleet-sleep.sh'),'wake','x','@1','--dwell','2','--nav'],
                     ['bash',str(BIN/'fleet-sleep.sh'),'keep-awake','x','@1'],
                     ['python3',str(BIN/'fleet_worker_life.py'),'holds-exit','--session','x','@1']):
            p=subprocess.run(argv,env=env,text=True,capture_output=True,timeout=30)
            want=1 if 'holds-exit' in argv else 0
            self.assertEqual((p.returncode,p.stdout,p.stderr),(want,'',''),argv)


if __name__=='__main__':
    unittest.main()
