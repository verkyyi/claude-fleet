package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// Real CLI -> authenticated HTTP -> store -> unified filer. Only GitHub and
// process launch are fixtures; no production credentials or tmux are reachable.
func TestTaskDispatchCLI(t *testing.T) {
	h, _, nodes := peerHarness(t)
	h.srv.FleetAdmins = []string{"frank"}
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	bin := filepath.Join(dir, "fake")
	if err = os.MkdirAll(bin, 0700); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{
		"gh":   "#!/bin/sh\ncase \"$1 $2\" in 'api rate_limit') echo 100;; 'issue create') echo https://github.com/org/repo/issues/71;; esac\n",
		"tmux": "#!/bin/sh\nexit 1\n",
	} {
		if err = os.WriteFile(filepath.Join(bin, name), []byte(body), 0700); err != nil {
			t.Fatal(err)
		}
	}
	env := []string{}
	for _, v := range os.Environ() {
		k := strings.SplitN(v, "=", 2)[0]
		if !strings.HasPrefix(k, "FLEET_") && !strings.HasPrefix(k, "CCQUOTA_") && k != "TMUX" && k != "TMUX_PANE" && k != "HOME" && k != "PATH" {
			env = append(env, v)
		}
	}
	env = append(env, "HOME="+dir, "PATH="+bin+":"+os.Getenv("PATH"), "FLEET_CONF_DIR="+dir+"/conf", "FLEET_SKIP_GLOBAL_CONF=1", "FLEET_GH_WRITE_DIRECT=1", "CCQUOTA_FLEET=1", "CCQUOTA_HUB_URL="+h.http.URL, "CCQUOTA_TOKEN="+nodes["bob4"].token)
	if err = os.MkdirAll(filepath.Join(dir, "conf"), 0700); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(dir, "conf/node.env"), []byte("CCQUOTA_HUB_URL="+h.http.URL+"\nCCQUOTA_TOKEN="+nodes["bob4"].token+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("bash", filepath.Join(root, "bin/fleet-task-record.sh"), "dispatch", "--title", "rule integration", "--repo", "org/repo", "--rule", "1", "--agent", "codex")
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("dispatch --rule 1 --agent codex: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), "https://github.com/org/repo/issues/71") {
		t.Fatalf("no issue: %s", out)
	}
	st, task := nodeTaskCall(t, h, nodes["bob4"].token, "GET", NodeTasksPath+"/T1", nil)
	if st != 200 {
		t.Fatal(st, task)
	}
	rec := task["task"].(map[string]any)
	if rec["ticket_ref"] != "gh:org/repo#71" || rec["resolved_agent"] != "codex" || !strings.Contains(rec["request_payload"].(string), `n=1 v=`) {
		t.Fatalf("association/provenance lost: %v", rec)
	}
}

// Every retry uses the production HTTP schema and persistence, not a curl
// echo mock. GitHub failure injection and the native process are fixtures.
func TestTaskDispatchRecoveryChain(t *testing.T) {
	for _, failure := range []string{"quota", "create-ack", "post-rate", "empty-rate", "link-before", "link-ack", "mcp"} {
		t.Run(failure, func(t *testing.T) {
			h, _, target, source, _ := twoNodesCaps(t, control.CapLaunch)
			root, _ := filepath.Abs("../../..")
			dir := t.TempDir()
			bin, fake := filepath.Join(dir, "bin"), filepath.Join(dir, "fake")
			for _, d := range []string{bin, fake, filepath.Join(dir, "conf")} {
				if err := os.MkdirAll(d, 0700); err != nil {
					t.Fatal(err)
				}
			}
			entries, err := os.ReadDir(filepath.Join(root, "bin"))
			if err != nil {
				t.Fatal(err)
			}
			for _, e := range entries {
				if err = os.Symlink(filepath.Join(root, "bin", e.Name()), filepath.Join(bin, e.Name())); err != nil {
					t.Fatal(err)
				}
			}
			write := func(path, body string) {
				t.Helper()
				_ = os.Remove(path)
				if err := os.WriteFile(path, []byte(body), 0700); err != nil {
					t.Fatal(err)
				}
			}
			write(filepath.Join(fake, "tmux"), "#!/bin/sh\nexit 1\n")
			write(filepath.Join(fake, "gh"), taskDispatchGHFixture)
			write(filepath.Join(bin, "dash-issue-session.sh"), "#!/bin/bash\nexec python3 \"$(dirname \"$0\")/fixture-place.py\" \"$@\"\n")
			write(filepath.Join(bin, "fixture-place.py"), taskDispatchPlaceFixture)
			write(filepath.Join(bin, "fleet-control-read.sh"), `#!/bin/bash
exec python3 -c 'import json,os; print(json.dumps(dict(task=os.environ.get("FLEET_CONTROL_TASK"),dispatch=json.loads(os.environ["FLEET_DISPATCH"]),launch=json.loads(os.environ["FLEET_LAUNCH"]))))'
`)
			write(filepath.Join(dir, "mode"), failure)
			// A proxy drops one link response before/after the REAL server's
			// commit. It never pretends a rejected request was accepted.
			proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				raw, _ := io.ReadAll(r.Body)
				r.Body = io.NopCloser(bytes.NewReader(raw))
				mode, _ := os.ReadFile(filepath.Join(dir, "mode"))
				link := bytes.Contains(raw, []byte(`"ticket_link"`))
				if link && string(mode) == "link-before" {
					_ = os.Remove(filepath.Join(dir, "mode"))
					http.Error(w, "fixture unavailable before commit", 502)
					return
				}
				if link && string(mode) == "link-ack" {
					_ = os.Remove(filepath.Join(dir, "mode"))
					out := httptest.NewRecorder()
					h.http.Config.Handler.ServeHTTP(out, r)
					if out.Code != 200 {
						t.Errorf("real link rejected: %d %s", out.Code, out.Body.String())
					}
					http.Error(w, "fixture lost ack after commit", 502)
					return
				}
				h.http.Config.Handler.ServeHTTP(w, r)
			}))
			defer proxy.Close()
			token := h.tokens["mac-d"]
			write(filepath.Join(dir, "conf/node.env"), "CCQUOTA_HUB_URL="+proxy.URL+"\nCCQUOTA_TOKEN="+token+"\n")
			env := []string{}
			for _, v := range os.Environ() {
				k := strings.SplitN(v, "=", 2)[0]
				if !strings.HasPrefix(k, "FLEET_") && !strings.HasPrefix(k, "CCQUOTA_") && k != "TMUX" && k != "TMUX_PANE" && k != "HOME" && k != "PATH" {
					env = append(env, v)
				}
			}
			env = append(env, "HOME="+dir, "PATH="+fake+":"+os.Getenv("PATH"), "FLEET_CONF_DIR="+dir+"/conf", "FLEET_SKIP_GLOBAL_CONF=1", "FLEET_GH_WRITE_DIRECT=1", "FIXTURE_DIR="+dir, "FIXTURE_REPO="+writeRepo, "FIXTURE_SOURCE="+source.FleetID, "FIXTURE_BIN="+bin)
			if failure == "mcp" {
				// The full source spawner, including authority/cap/placement gates.
				// Only its external tmux, git fixture and ccquota transport are local.
				_ = os.Remove(filepath.Join(bin, "dash-issue-session.sh"))
				if err = os.Symlink(filepath.Join(root, "bin/dash-issue-session.sh"), filepath.Join(bin, "dash-issue-session.sh")); err != nil {
					t.Fatal(err)
				}
				repos := filepath.Join(dir, "conf/fleets/fixture/repos")
				if err = os.MkdirAll(repos, 0700); err != nil {
					t.Fatal(err)
				}
				write(filepath.Join(repos, "verkyyi-claude-fleet.conf"), "FLEET_REPO=verkyyi/claude-fleet\nFLEET_MAIN="+dir+"/main\nFLEET_BASE_BRANCH=master\n")
				write(filepath.Join(repos, ".order"), "verkyyi-claude-fleet\n")
				write(filepath.Join(dir, "conf/fleets/fixture/conf"), "FLEET_SESSION=fixture\nCCQUOTA_FLEET=1\n")
				write(filepath.Join(dir, "conf/fleets/fixture/identity"), source.FleetID+"\n")
				cmd := exec.Command("git", "init", "-q", "-b", "master", filepath.Join(dir, "main"))
				if out, e := cmd.CombinedOutput(); e != nil {
					t.Fatal(e, string(out))
				}
				write(filepath.Join(fake, "tmux"), "#!/bin/bash\nif [ \"$1\" = -L ] || [ \"$1\" = -S ]; then shift 2; fi\ncase \"$1\" in display-message) case \"$*\" in *session_name*) echo fixture;; esac;; esac\nexit 0\n")
				write(filepath.Join(fake, "ccquota"), "#!/bin/bash\nif [ \"$1\" = place ]; then shift; exec python3 \"$FIXTURE_BIN/fixture-place.py\" --ccquota \"$@\"; fi\nprintf '%s\\n' \"$*\" >> \"$FIXTURE_DIR/legacy-lease\"\nexit 1\n")
				env = append(env, "FLEET_SESSION=fixture", "CCQUOTA_FLEET=1", "FLEET_PRESPAWN_DEDUP=0", "FLEET_TASK_AUTHORITY=legacy", "FLEET_MAX_SESSIONS=0", "FLEET_GLOBAL_MAX_SESSIONS=0", "FLEET_START_WARM=0", "FLEET_SCRATCH_POOL=0", "FLEET_CODEX_READY_CHECK=0", "FLEET_SPAWN_OVERLAP=0")
			}
			target.setOpGet(func(e map[string]any) (any, *control.Error) {
				// Exercise the real controller validation + adapter transport.
				p := e["params"].(map[string]any)
				raw, _ := json.Marshal(p)
				cmd := exec.Command("python3", "-c", taskDispatchAdapterFixture)
				cmd.Env = env
				cmd.Stdin = bytes.NewReader(raw)
				out, err := cmd.CombinedOutput()
				if err != nil {
					t.Errorf("adapter: %v %s", err, out)
				}
				return verifiedLaunchFixture(e)
			})
			invoke := func() (string, error) {
				cmd := exec.Command("bash", filepath.Join(bin, "fleet-task-record.sh"), "dispatch", "--title", "recovery "+failure, "--repo", writeRepo, "--rule", "1", "--agent", "codex", "--spawn")
				if failure == "mcp" {
					cmd = exec.Command("python3", "-c", taskDispatchMCPFixture)
				}
				cmd.Env = env
				out, err := cmd.CombinedOutput()
				return string(out), err
			}
			if failure != "mcp" {
				out, err := invoke()
				if err == nil || !strings.Contains(out, "T1") || target.count() != 0 {
					t.Fatalf("partial success hidden: %v %s starts=%d", err, out, target.count())
				}
			}
			for i := 0; i < 2; i++ {
				out, err := invoke()
				if err != nil {
					t.Fatalf("same request retry %d: %v\n%s", i, err, out)
				}
			}
			if target.count() != 1 {
				t.Fatalf("starts=%d", target.count())
			}
			if raw, e := os.ReadFile(filepath.Join(dir, "legacy-lease")); e == nil {
				t.Fatalf("accepted task used legacy lease: %s", raw)
			}
			task, err := h.srv.Store.FleetTask(1)
			if err != nil {
				t.Fatal(err)
			}
			if task.TicketRef != "gh:"+writeRepo+"#71" || task.ResolvedAgent != "codex" || task.State != store.TaskRunning || task.Generation != 1 || !strings.Contains(task.RequestPayload, "n=1 v=") {
				t.Fatalf("lost accepted contract: %+v", task)
			}
			if _, err = h.srv.Store.FleetTask(2); err == nil {
				t.Fatal("duplicate accepted task")
			}
			var github struct {
				Creates  int `json:"creates"`
				Attempts int `json:"attempts"`
			}
			raw, _ := os.ReadFile(filepath.Join(dir, "github.json"))
			if json.Unmarshal(raw, &github) != nil || github.Creates != 1 || github.Attempts != 1 {
				t.Fatalf("GitHub duplicates: %s", raw)
			}
			var adapter map[string]any
			raw, _ = os.ReadFile(filepath.Join(dir, "adapter.json"))
			if json.Unmarshal(raw, &adapter) != nil || adapter["task"] != task.Ref {
				t.Fatalf("binding lost: %s", raw)
			}
			t.Logf("fixture %s: one accepted T / issue / execution; rule and explicit Codex retained; controller task/dispatch/launch agree; native receipt is a fixture", failure)
		})
	}
}

const taskDispatchGHFixture = `#!/usr/bin/env python3
import json,os,pathlib,sys
d=pathlib.Path(os.environ['FIXTURE_DIR']); repo=os.environ['FIXTURE_REPO']; p=d/'github.json'
s=json.loads(p.read_text()) if p.exists() else dict(creates=0,attempts=0,body='')
args=sys.argv[1:]; mode=(d/'mode').read_text() if (d/'mode').exists() else ''
if args[:2]==['api','rate_limit']:
 if mode=='quota':
  (d/'mode').unlink();print(0)
 else: print(100)
elif args[:2]==['issue','create']:
 s['attempts']+=1
 s['creates']+=1;s['body']=args[args.index('--body')+1];p.write_text(json.dumps(s))
 if mode=='create-ack':
  (d/'mode').unlink();print('connection reset after create',file=sys.stderr);sys.exit(1)
 if mode in ('post-rate','empty-rate'):
  (d/'mode').unlink()
  if mode=='post-rate': print('https://github.com/'+repo+'/issues/71')
  print('GraphQL: secondary rate limit',file=sys.stderr);sys.exit(1)
 print('https://github.com/'+repo+'/issues/71')
elif args and args[0]=='api' and '/issues?' in args[1] and s['creates']:
 print('__fleet_count__\t1');print('71\t'+s['body'].replace('\n',' '))
`

const taskDispatchPlaceFixture = `import json,os,pathlib,sys,urllib.request
sys.path.insert(0,os.environ['FIXTURE_BIN'])
from fleet_dispatch import validate
args=sys.argv[1:];d=validate(json.loads(os.environ['FLEET_DISPATCH']))
ccquota=args[0]=='--ccquota'
if ccquota: repo,num,wid=args[-3:]
else:
 assert args[args.index('--task')+1]==d['task']
 repo,num,wid=args[args.index('--repo')+1],args[0],os.environ['FIXTURE_SOURCE']+'/issue-'+args[0]
node=dict(x.split('=',1) for x in (pathlib.Path(os.environ['FLEET_CONF_DIR'])/'node.env').read_text().splitlines())
data=dict(issue=int(num),repo=repo,worker_id=wid,dispatch=d,wait=3)
req=urllib.request.Request(node['CCQUOTA_HUB_URL']+'/v1/node/place',data=json.dumps(data).encode(),headers={'Authorization':'Bearer '+node['CCQUOTA_TOKEN'],'Content-Type':'application/json'})
try:
 with urllib.request.urlopen(req,timeout=10) as r: out=json.load(r)
except urllib.error.HTTPError as e:
 print(e.read().decode(),file=sys.stderr);sys.exit(1)
assert out['dispatch']==d,out
if ccquota:
 if os.environ.get('FLEET_DISPATCH_RESULT'): pathlib.Path(os.environ['FLEET_DISPATCH_RESULT']).write_text(json.dumps(out['dispatch']))
 assert out['outcome']['state']=='done',out
 print('REMOTE mac-c '+out['operation']['operation_id']+' done @7')
else: print(json.dumps(out))
`

const taskDispatchAdapterFixture = `import json,os,pathlib,sys
sys.path.insert(0,os.environ['FIXTURE_BIN'])
import fleet_control
from fleet_hub_common import validate_write
p=json.load(sys.stdin);validate_write('worker_start',p)
c=object.__new__(fleet_control.Control);c.bin=pathlib.Path(os.environ['FIXTURE_BIN']);c.environment=lambda:dict(os.environ)
rc,out,err=c.adapter('start','fixture',str(p['issue']),p['agent'],task=p['task'],dispatch=p['dispatch'],launch=p['launch'])
assert rc==0,err
r=json.loads(out);assert r['task']==p['launch']['task']==p['dispatch']['task']
assert r['launch']['provider']==r['dispatch']['resolved_agent']=='codex'
(pathlib.Path(os.environ['FIXTURE_DIR'])/'adapter.json').write_text(json.dumps(r))
`

const taskDispatchMCPFixture = `import importlib.util,json,os,pathlib,sys
sys.path.insert(0,os.environ['FIXTURE_BIN'])
p=pathlib.Path(os.environ['FIXTURE_BIN'])/'fleet-mcp.py';spec=importlib.util.spec_from_file_location('m',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
m.BIN=pathlib.Path(os.environ['FIXTURE_BIN'])
m.hub_env=lambda ttl:dict(os.environ)
r=m.tool_task(dict(title='recovery mcp',repo=os.environ['FIXTURE_REPO'],rule=1,coding_agent='codex',spawn=True))
print(r['stdout']);print(r['stderr'],file=sys.stderr);sys.exit(r['exit'])
`
