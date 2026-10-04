package fleetid

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const testMachine = "3f2a9c1e-7b4d-4e8a-9c2f-1a2b3c4d5e6f"

// Golden values printed by bin/fleet_hub_common.py + uuid.uuid5 themselves
// (claude-fleet#1409). They pin the scheme even where python3 is absent; the
// live cross-check below re-derives them from the Python on every run that has
// it.
var fleetGolden = []struct{ session, repo, checkout, want string }{
	{"fleet-claude-fleet", "verkyyi/claude-fleet", "/Users/verkyyi/projects/claude-fleet", "df89feac-6efa-5b59-86ea-9c60779fc731"},
	{"fleet-24haowan-monorepo", "", "", "f936a944-068f-5d71-bd22-9d24fa14e676"},
	{"名字", "owner/仓库", "/home/张三/x", "92f76867-bb33-55c1-990c-a55ea1ea8134"},
	// Every byte encoding/json would have spelled differently.
	{"s", "a<b>&c", "q\"uote\\back\nnl\ttab\x01\x7f ", "471d5063-d36f-507f-b6ef-7518c90397d6"},
}

type keyCase struct {
	Issue    int
	Scratch  bool
	Worktree string
	Repo     string
	Want     string
}

var keyGolden = []keyCase{
	{12, false, "", "", "issue-12"},
	{0, true, "/w/claude-fleet-scratch-7", "", "scratch-7"},
	{0, true, "/w/scratch-x", "", ""},
	{5, false, "", "verkyyi/claude-fleet", "verkyyi-claude-fleet:issue-5"},
	{5, false, "", "?", ""},
	{0, false, "", "", ""},
	{0, true, "/w/x-scratch-03/", "", ""},
	{0, true, "/w/x-scratch-30/", "o/r", "o-r:scratch-30"},
	{7, true, "/w/x-scratch-1", "", "issue-7"},
}

func TestFleetIDGolden(t *testing.T) {
	for _, c := range fleetGolden {
		got, err := FleetID(testMachine, c.session, c.repo, c.checkout)
		if err != nil || got != c.want {
			t.Errorf("FleetID(%q,%q,%q) = %q, %v; want %q", c.session, c.repo, c.checkout, got, err, c.want)
		}
	}
}

func TestFleetIDRefusesNonCanonicalMachine(t *testing.T) {
	for _, m := range []string{"", "not-a-uuid", strings.ToUpper(testMachine), "3f2a9c1e7b4d4e8a9c2f1a2b3c4d5e6f"} {
		if _, err := FleetID(m, "s", "", ""); err == nil {
			t.Errorf("FleetID(%q) accepted a non-canonical machine id", m)
		}
	}
}

func TestWorkerKeyGolden(t *testing.T) {
	for _, c := range keyGolden {
		if got := WorkerKey(c.Issue, c.Scratch, c.Worktree, c.Repo); got != c.Want {
			t.Errorf("WorkerKey(%d,%v,%q,%q) = %q; want %q", c.Issue, c.Scratch, c.Worktree, c.Repo, got, c.Want)
		}
	}
}

func TestParseWorkerID(t *testing.T) {
	fid, key, err := ParseWorkerID(fleetGolden[0].want + "/verkyyi-claude-fleet:issue-5")
	if err != nil || fid != fleetGolden[0].want || key != "verkyyi-claude-fleet:issue-5" {
		t.Fatalf("ParseWorkerID = %q %q %v", fid, key, err)
	}
	for _, bad := range []string{"", "x/issue-1", fleetGolden[0].want + "/issue-0", fleetGolden[0].want + "/pr-3",
		strings.ToUpper(fleetGolden[0].want) + "/issue-1", fleetGolden[0].want + "/issue-1/x"} {
		if _, _, err := ParseWorkerID(bad); err == nil {
			t.Errorf("ParseWorkerID(%q) accepted", bad)
		}
	}
	if WorkerID("f", "") != "" || WorkerID("f", "issue-1") != "f/issue-1" {
		t.Error("WorkerID")
	}
}

// TestMatchesPython runs the Python implementation on the same inputs and
// compares every value — the issue's 完成判据, one input at a time. Skipped
// only when there is no python3 or no bin/ beside tokenledger/ (a module
// checkout on its own); the golden tables above still hold the line there.
func TestMatchesPython(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("no python3")
	}
	bin, _ := filepath.Abs("../../../bin")
	if _, err := os.Stat(filepath.Join(bin, "fleet_hub_common.py")); err != nil {
		t.Skip("no claude-fleet bin/ beside tokenledger/")
	}

	type fleetIn struct{ Session, Repo, Checkout string }
	fleets := []fleetIn{}
	for _, c := range fleetGolden {
		fleets = append(fleets, fleetIn{c.session, c.repo, c.checkout})
	}
	// Plus shapes the golden table does not hold.
	fleets = append(fleets, fleetIn{"a bé", "o/r", "/p with space/\x1f"}, fleetIn{`A`, "/", "\U0001F600"})
	machines := []string{testMachine, "00000000-0000-4000-8000-000000000000", "ffffffff-ffff-4fff-bfff-ffffffffffff"}

	in, _ := json.Marshal(map[string]any{"machines": machines, "fleets": fleets, "keys": keyGolden})
	script := `
import json, sys, uuid
from fleet_hub_common import canonical, worker_key
req = json.load(sys.stdin)
out = {"fleets": [], "keys": []}
for m in req["machines"]:
    for f in req["fleets"]:
        out["fleets"].append(str(uuid.uuid5(uuid.UUID(m), canonical([f["Session"], f["Repo"], f["Checkout"]]))))
for k in req["keys"]:
    out["keys"].append(worker_key(k["Issue"] or None, k["Scratch"], k["Worktree"], k["Repo"]) or "")
print(json.dumps(out))
`
	cmd := exec.Command(py, "-c", script)
	cmd.Dir = bin
	cmd.Stdin = strings.NewReader(string(in))
	raw, err := cmd.Output()
	if err != nil {
		t.Fatalf("python: %v", err)
	}
	var want struct{ Fleets, Keys []string }
	if err := json.Unmarshal(raw, &want); err != nil {
		t.Fatalf("python output: %v: %s", err, raw)
	}
	i := 0
	for _, m := range machines {
		for _, f := range fleets {
			got, err := FleetID(m, f.Session, f.Repo, f.Checkout)
			if err != nil || got != want.Fleets[i] {
				t.Errorf("FleetID(%s, %q,%q,%q) = %q, %v; python says %q", m, f.Session, f.Repo, f.Checkout, got, err, want.Fleets[i])
			}
			i++
		}
	}
	for j, k := range keyGolden {
		if got := WorkerKey(k.Issue, k.Scratch, k.Worktree, k.Repo); got != want.Keys[j] {
			t.Errorf("WorkerKey(%+v) = %q; python says %q", k, got, want.Keys[j])
		}
	}
}
