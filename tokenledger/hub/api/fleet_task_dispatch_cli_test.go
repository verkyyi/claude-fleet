package api

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Real CLI -> authenticated HTTP -> store. Only process launch is a fixture; no
// production credentials or tmux are reachable. A repo task the hub accepts is
// the record alone (claude-fleet#4897); since #4898 nothing is filed on GitHub,
// so the filing / ticket-link recovery chain this file also held left with it.
// drives: bin/fleet-task-record.sh bin/dash-issue-session.sh
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
		"gh":   "#!/bin/sh\necho \"$*\" >> \"$HOME/gh.log\"\n",
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
	env = append(env, "HOME="+dir, "PATH="+bin+":"+os.Getenv("PATH"), "FLEET_CONF_DIR="+dir+"/conf", "FLEET_SKIP_GLOBAL_CONF=1", "CCQUOTA_FLEET=1", "CCQUOTA_HUB_URL="+h.http.URL, "CCQUOTA_TOKEN="+nodes["bob4"].token)
	if err = os.MkdirAll(filepath.Join(dir, "conf"), 0700); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(dir, "conf/node.env"), []byte("CCQUOTA_HUB_URL="+h.http.URL+"\nCCQUOTA_TOKEN="+nodes["bob4"].token+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	// The rule table left (claude-fleet#4340, #4790): the dispatch goes through
	// and the payload carries no rule mark.
	cmd := exec.Command("bash", filepath.Join(root, "bin/fleet-task-record.sh"), "dispatch", "--title", "rule integration", "--repo", "org/repo", "--agent", "codex")
	cmd.Env = env
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("dispatch --agent codex: %v\n%s", err, out)
	}
	if strings.TrimSpace(string(out)) != "T1" {
		t.Fatalf("the dispatch names its record alone: %s", out)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "gh.log")); len(b) > 0 {
		t.Fatalf("a task dispatch reached gh: %s", b)
	}
	st, task := nodeTaskCall(t, h, nodes["bob4"].token, "GET", NodeTasksPath+"/T1", nil)
	if st != 200 {
		t.Fatal(st, task)
	}
	rec := task["task"].(map[string]any)
	if rec["ticket_ref"] != nil && rec["ticket_ref"] != "" || rec["resolved_agent"] != "codex" || strings.Contains(rec["request_payload"].(string), `n=1 v=`) {
		t.Fatalf("association/provenance lost: %v", rec)
	}
}
