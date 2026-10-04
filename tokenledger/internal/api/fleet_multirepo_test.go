package api

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/fleetid"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// A multi-repo fleet's every repo is placeable (claude-fleet#1512, EPIC
// #1524 C2): the 2026-10-04 drill's two machines, whose fleets host the same
// two repos with the first one swapped.

const monoRepo = "GuangZhouShanyouGame/24haowan-monorepo"

// swappedRepoNodes is m5 = monorepo first + a claude-fleet overlay, m4 =
// claude-fleet first + a monorepo overlay; both take moves, m5 is busy.
func swappedRepoNodes(t *testing.T) (*harness, *writeNode, *writeNode, control.Fleet, control.Fleet) {
	t.Helper()
	h := newFleetHarness(t)
	caps := []string{control.CapRead, control.CapWrite, control.CapMove}
	m5 := connectWriteNodeCaps(t, h, h.enroll(t, "m5"), caps...)
	m4 := connectWriteNodeCaps(t, h, h.enroll(t, "m4"), caps...)
	f5 := fakeFleet(t, machineA, "fleet-24haowan-monorepo", monoRepo, "/u/verk/24haowan-monorepo")
	f5.Repos = []string{monoRepo, writeRepo}
	f4 := fakeFleet(t, machineB, "fleet", writeRepo, "/u/verk/claude-fleet")
	f4.Repos = []string{writeRepo, monoRepo}
	m5.beatLoad("m5", "verk", machineA, 10, 3, f5)
	m4.beatLoad("m4", "verk", machineB, 1, 1, f4)
	waitFor(t, 3*time.Second, "both fleets registered", func() bool {
		return len(getFleet(t, h, "/v1/fleet/fleet_list", 200)["fleets"].([]any)) == 2
	})
	return h, m5, m4, f5, f4
}

// repoWID is a multi-repo fleet's worker id: <fleet>/<slug>:issue-<N>.
func repoWID(fleet, repo string, issue int) string {
	return fleetid.WorkerID(fleet, fleetid.WorkerKey(issue, false, "", repo))
}

func candidateMachines(t *testing.T, out map[string]any) []string {
	t.Helper()
	pl, _ := out["placement"].(map[string]any)
	cs, _ := pl["candidates"].([]any)
	var got []string
	for _, c := range cs {
		got = append(got, c.(map[string]any)["machine"].(string))
	}
	return got
}

// Both repos have both machines as candidates, whichever fleet hosts which
// first — and the busy m5's claude-fleet issue goes to m4 by load, under the
// key m4's fleet knows it by.
func TestMultiRepoPlaceSeesEveryHostedRepo(t *testing.T) {
	h, _, m4, f5, f4 := swappedRepoNodes(t)
	tok5, tok4 := h.tokens["m5"], h.tokens["m4"]

	// m4 is idle: its monorepo issue stays LOCAL, but m5 was weighed too.
	st, out := placeCall(t, h, tok4, map[string]any{"repo": monoRepo, "issue": 3, "worker_id": repoWID(f4.FleetID, monoRepo, 3)})
	if got := candidateMachines(t, out); st != 200 || out["local"] != true || len(got) != 2 {
		t.Fatalf("monorepo place from m4 = %d %v; want LOCAL with both machines weighed (got %v)", st, out, got)
	}

	wid5 := repoWID(f5.FleetID, writeRepo, 7)
	if st, out := leaseCall(t, h, tok5, map[string]any{"action": "acquire", "repo": writeRepo, "issue": 7, "worker_id": wid5}); st != 200 {
		t.Fatalf("m5's lease: %d %v", st, out)
	}
	st, out = placeCall(t, h, tok5, map[string]any{"repo": writeRepo, "issue": 7, "worker_id": wid5, "idempotency_key": "place-7"})
	if got := candidateMachines(t, out); st != 200 || out["local"] != false || len(got) != 2 {
		t.Fatalf("claude-fleet place from m5 = %d %v; want m4 out of two candidates (got %v)", st, out, got)
	}
	if pl := out["placement"].(map[string]any); pl["machine"] != "m4" || pl["fleet_id"] != f4.FleetID {
		t.Fatalf("placement = %v; want m4's fleet", pl)
	}
	if p := m4.writes[0]["params"].(map[string]any); p["repo"] != writeRepo || p["issue"].(float64) != 7 {
		t.Fatalf("m4 was sent %v; want claude-fleet #7", p)
	}
	ls, err := h.srv.Store.Leases(time.Now())
	if want := repoWID(f4.FleetID, writeRepo, 7); err != nil || len(ls) != 1 || ls[0].WorkerID != want {
		t.Fatalf("leases = %+v %v; want #7 held by %s", ls, err, want)
	}
}

// The drill's move: m5's idle monorepo session can go to m4, which hosts the
// monorepo as an overlay — plan names m4, and the move lands as m4's
// <slug>:issue-N.
func TestMultiRepoMoveReachesOverlayHost(t *testing.T) {
	h, m5, m4, f5, f4 := swappedRepoNodes(t)
	tok5 := h.tokens["m5"]
	wid5, wid4 := repoWID(f5.FleetID, monoRepo, 7), repoWID(f4.FleetID, monoRepo, 7)
	if st, out := leaseCall(t, h, tok5, map[string]any{"action": "acquire", "repo": monoRepo, "issue": 7, "worker_id": wid5}); st != 200 {
		t.Fatalf("m5's lease: %d %v", st, out)
	}
	st, out := moveCall(t, h, tok5, map[string]any{"action": "plan", "repo": monoRepo, "worker_id": wid5})
	if got := candidateMachines(t, out); st != 200 || out["local"] != false || len(got) != 2 ||
		out["placement"].(map[string]any)["machine"] != "m4" {
		t.Fatalf("plan = %d %v; want m4 out of two candidates (got %v)", st, out, got)
	}

	body := moveBody(wid5, uploadBundle(t, h, tok5, []byte("bundle")), "done")
	body["repo"] = monoRepo
	st, out = moveCall(t, h, tok5, body)
	if st != 200 || out["to_wid"] != wid4 {
		t.Fatalf("move = %d %v; want it sent to m4 as %s", st, out, wid4)
	}
	if p := m4.writes[0]["params"].(map[string]any); m5.count() != 0 ||
		p["worker_key"] != fleetid.RepoSlug(monoRepo)+":issue-7" || p["repo"] != monoRepo {
		t.Fatalf("m4 was sent %v; want the monorepo key", p)
	}
}

// targetKey re-spells a key for the fleet it lands in; a target that never
// reported its repos keeps today's key verbatim.
func TestTargetKey(t *testing.T) {
	one := store.FleetRow{Repo: writeRepo, Repos: []string{writeRepo}}
	two := store.FleetRow{Repo: writeRepo, Repos: []string{writeRepo, monoRepo}}
	old := store.FleetRow{Repo: writeRepo}
	slug := fleetid.RepoSlug(monoRepo)
	for _, c := range []struct {
		key    string
		target store.FleetRow
		want   string
	}{
		{"issue-7", old, "issue-7"},
		{slug + ":issue-7", old, slug + ":issue-7"},
		{"issue-7", one, "issue-7"},
		{slug + ":issue-7", one, "issue-7"},
		{"issue-7", two, slug + ":issue-7"},
		{slug + ":scratch-2", two, slug + ":scratch-2"},
	} {
		if got := targetKey(c.key, c.target, monoRepo); got != c.want {
			t.Errorf("targetKey(%q, %v) = %q; want %q", c.key, c.target.Repos, got, c.want)
		}
	}
}

// Degenerate: an agent that sends no repos is matched on its one repo
// exactly as before, and the registry keeps "not reported" as nil.
func TestMultiRepoOldAgentMatchesOwnRepoOnly(t *testing.T) {
	old := store.FleetRow{Repo: monoRepo}
	if !hostsRepo(old, monoRepo) || !hostsRepo(old, "24haowan-monorepo") || hostsRepo(old, writeRepo) {
		t.Fatal("an old agent's fleet must match its own repo and nothing else")
	}
	if hostsRepo(store.FleetRow{}, writeRepo) {
		t.Fatal("a fleet with no repo matched")
	}
	h, _, _, f5, f4 := twoNodes(t)
	for _, id := range []string{f5.FleetID, f4.FleetID} {
		r, err := h.srv.Store.Fleet(id)
		if err != nil || r.Repos != nil || len(r.HostedRepos()) != 1 || r.HostedRepos()[0] != writeRepo {
			t.Fatalf("fleet %s = %+v %v; want no reported list, hosted = [repo]", id, r, err)
		}
	}
	got := getFleet(t, h, "/v1/fleet/fleet_list", 200)
	raw, _ := json.Marshal(got["fleets"])
	var views []map[string]any
	_ = json.Unmarshal(raw, &views)
	for _, v := range views {
		if _, ok := v["repos"]; ok {
			t.Fatalf("fleet_list carries repos for an agent that sent none: %v", v)
		}
	}
}

// The registry keeps a reported list as sent, minus anything that is not
// owner/name, and fleet_list shows it.
func TestMultiRepoRegistryStoresList(t *testing.T) {
	h, _, _, f5, _ := swappedRepoNodes(t)
	r, err := h.srv.Store.Fleet(f5.FleetID)
	if err != nil || len(r.Repos) != 2 || r.Repos[0] != monoRepo || r.Repos[1] != writeRepo {
		t.Fatalf("m5's fleet = %+v %v; want [monorepo, claude-fleet]", r.Repos, err)
	}
	if got := reportedRepos([]string{writeRepo, "", "not a repo", writeRepo, monoRepo}); len(got) != 2 ||
		got[0] != writeRepo || got[1] != monoRepo {
		t.Fatalf("reportedRepos = %v", got)
	}
	if got := reportedRepos(nil); got != nil {
		t.Fatalf("reportedRepos(nil) = %v; want nil", got)
	}
}
