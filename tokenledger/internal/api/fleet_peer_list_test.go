package api

import (
	"encoding/json"
	"io"
	"net/http"
	"testing"
)

func peersGet(t *testing.T, h *harness, tok string) (int, PeersResponse, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/node/peers", nil)
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	res, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	var out PeersResponse
	if res.StatusCode == http.StatusOK {
		if err := json.Unmarshal(raw, &out); err != nil {
			t.Fatalf("answer does not parse: %v %s", err, raw)
		}
	}
	return res.StatusCode, out, string(raw)
}

// claude-fleet#3482: a login asks for its person's OTHER logins and gets each
// with every way in — never another person's login, never its own machine.
func TestNodePeersSamePersonOnly(t *testing.T) {
	h, _, n := peerHarness(t)

	st, got, raw := peersGet(t, h, n["alice5"].token)
	if st != 200 || got.Login != "alice" || got.Hostname != "macmini" {
		t.Fatalf("alice@m5: HTTP %d %s", st, raw)
	}
	if len(got.Peers) != 1 || got.Peers[0].Hostname != "macmini-m4" || got.Peers[0].Login != "alice" || got.Peers[0].Alias != "m4" {
		t.Fatalf("alice@m5 peers %+v; want alice on macmini-m4 (m4) only", got.Peers)
	}
	routes := map[string]FleetRoute{}
	for _, r := range got.Peers[0].Routes {
		routes[r.Name] = r
	}
	if routes["public"].Host != "203.0.113.4" || routes["public"].Port != 22023 || routes["tailnet"].Host != "m4.tail.ts.net" {
		t.Fatalf("m4's routes %+v; want its public port and tailnet name", got.Peers[0].Routes)
	}

	// The operator's own login (no person owns it): the same name elsewhere.
	if st, got, raw := peersGet(t, h, n["verk4"].token); st != 200 || len(got.Peers) != 1 || got.Peers[0].Login != "verk" || got.Peers[0].Hostname != "macmini" {
		t.Fatalf("verk@m4: HTTP %d %+v %s; want verk on macmini", st, got.Peers, raw)
	}
	// Bob has no login on another machine: nobody — not alice, not verk.
	if st, got, raw := peersGet(t, h, n["bob4"].token); st != 200 || len(got.Peers) != 0 {
		t.Fatalf("bob@m4: HTTP %d %+v %s; want none", st, got.Peers, raw)
	}
	if st, _, _ := peersGet(t, h, ""); st != 401 {
		t.Fatalf("no token: HTTP %d; want 401", st)
	}
}
