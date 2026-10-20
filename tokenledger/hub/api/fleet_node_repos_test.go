package api

import (
	"encoding/json"
	"net/http"
	"reflect"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func nodeRepos(t *testing.T, h *harness, tok string) NodeReposResponse {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+NodeReposPath, nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("repos: %d", res.StatusCode)
	}
	var out NodeReposResponse
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	return out
}

// claude-fleet T673: a managed machine reads the union of the repos its
// person's machines host — never another person's, never a client's — with
// its own role and each machine's starts of the last 24 hours.
func TestNodeReposPersonUnion(t *testing.T) {
	h := newFleetHarness(t)
	enablePeople(t, h, pAlice, pBob)
	h.srv.FleetAdmins = []string{"frank"}
	for _, a := range []FleetAccountRequest{
		{Action: "adopt", PrincipalID: pAlice, Hostname: "mac-a", Login: "alice"},
		{Action: "adopt", PrincipalID: pAlice, Hostname: "mac-c", Login: "alice"},
		{Action: "adopt", PrincipalID: pBob, Hostname: "mac-b", Login: "bob"},
	} {
		if code := operatorPost(t, h, a); code != 200 {
			t.Fatalf("adopt %s@%s: %d", a.Login, a.Hostname, code)
		}
	}
	caps := []string{control.CapRead, control.CapWrite, control.CapLaunch}
	ta, tb, tc := h.enroll(t, "mac-a"), h.enroll(t, "mac-b"), h.enroll(t, "mac-c")
	na, nb, nc := connectWriteNodeCaps(t, h, ta, caps...), connectWriteNodeCaps(t, h, tb, caps...), connectWriteNodeCaps(t, h, tc, caps...)
	fa := fakeFleet(t, machineA, "fleet-a", writeRepo, "/u/alice/cf", 5)
	fa.Repos = []string{writeRepo, "org/a-only"}
	fc := fakeFleet(t, machineC, "fleet-c", writeRepo, "/u/alice/cf", 6)
	fc.Repos = []string{"Verkyyi/Claude-Fleet", "Org/C-Only"}
	fb := fakeFleet(t, machineB, "fleet-b", writeRepo, "/u/bob/cf", 7)
	fb.Repos = []string{writeRepo, "bob/secret"}
	na.beatLoad("mac-a", "alice", machineA, 1, 1, fa)
	nb.beatLoad("mac-b", "bob", machineB, 1, 1, fb)
	nc.beatLoad("mac-c", "alice", machineC, 1, 1, fc)
	waitFor(t, 3*time.Second, "three fleets registered", func() bool {
		fs, _ := h.srv.Store.Fleets()
		return len(fs) == 3
	})
	if err := h.srv.Store.SetEndpointRole("ep_mac-a", store.NodeRoleManaged); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	for i, row := range []struct {
		fleet string
		at    time.Time
	}{{fa.FleetID, now}, {fa.FleetID, now.Add(-time.Hour)}, {fa.FleetID, now.Add(-48 * time.Hour)}, {fc.FleetID, now}, {fb.FleetID, now}} {
		ts := row.at.Format(time.RFC3339Nano)
		if _, err := h.srv.Store.DB().Exec(`INSERT INTO fleet_operations (id, fleet_id, action, request, actor, idem, status, created, updated)
			VALUES (?, ?, 'worker_start', '{}', 'test', ?, 'succeeded', ?, ?)`, "op"+string(rune('0'+i)), row.fleet, "idem"+string(rune('0'+i)), ts, ts); err != nil {
			t.Fatal(err)
		}
	}

	got := nodeRepos(t, h, ta)
	if got.Owner != pAlice || got.Role != store.NodeRoleManaged {
		t.Fatalf("owner/role: %+v", got)
	}
	if want := []string{"org/a-only", "Org/C-Only", writeRepo}; !reflect.DeepEqual(got.Repos, want) {
		t.Fatalf("alice's set %v, want %v", got.Repos, want)
	}
	if len(got.Machines) != 2 {
		t.Fatalf("alice's machines: %+v", got.Machines)
	}
	for _, m := range got.Machines {
		switch m.Hostname {
		case "mac-a":
			if !m.Self || m.Starts24h != 2 || !reflect.DeepEqual(m.Repos, []string{"org/a-only", writeRepo}) {
				t.Fatalf("mac-a: %+v", m)
			}
		case "mac-c":
			if m.Self || m.Starts24h != 1 {
				t.Fatalf("mac-c: %+v", m)
			}
		default:
			t.Fatalf("another person's machine listed: %+v", m)
		}
	}
	if b := nodeRepos(t, h, tb); !reflect.DeepEqual(b.Repos, []string{"bob/secret", writeRepo}) || len(b.Machines) != 1 {
		t.Fatalf("bob's set: %+v", b)
	}

	// A client hosts nothing (claude-fleet#4886): its leftover list leaves the set.
	if err := h.srv.Store.SetEndpointRole("ep_mac-c", store.NodeRoleClient); err != nil {
		t.Fatal(err)
	}
	if got := nodeRepos(t, h, ta); !reflect.DeepEqual(got.Repos, []string{"org/a-only", writeRepo}) {
		t.Fatalf("a client's repos still in the set: %v", got.Repos)
	}
}
