package api

import (
	"net/http"
	"testing"
)

// The ticket registry (claude-fleet#2676): a node registers a ticket it opened
// with its own token; the row carries the person behind the login, re-registering
// refreshes it, another person's id is refused, and nothing but the registry
// fields is taken.
func TestFleetTicketRegister(t *testing.T) {
	h, tok5, tok4, _, _ := sessHarness(t)
	reg := func(tok string, body map[string]any) (int, map[string]any) {
		t.Helper()
		return sessDo(t, h, http.MethodPost, FleetTicketRegisterPath, tok, "", body)
	}
	row := map[string]any{"id": "gh:verkyyi/claude-fleet#2700", "backend": "gh", "title": "写设计页（编排架构）",
		"state": "open", "url": "https://github.com/verkyyi/claude-fleet/issues/2700", "origin": "orchestrator"}
	st, out := reg(tok5, row)
	if st != http.StatusCreated || out["owner"] != "gh:1005" || out["title"] != "写设计页（编排架构）" || out["origin"] != "orchestrator" {
		t.Fatalf("register: %d %v", st, out)
	}
	// a re-register is the same row, refreshed
	row["state"] = "closed"
	if st, out = reg(tok5, row); st != http.StatusCreated || out["state"] != "closed" {
		t.Fatalf("re-register: %d %v", st, out)
	}
	list, err := h.srv.Store.FleetTicketsFor("gh:1005", 0)
	if err != nil || len(list) != 1 || list[0].State != "closed" || list[0].EndpointID != "ep_m5" {
		t.Fatalf("the person's list: %v %v", list, err)
	}
	// m4's login is nobody's: registered with no owner — and it cannot take m5's id
	if st, out = reg(tok4, row); st != http.StatusConflict {
		t.Fatalf("another person's id: %d %v", st, out)
	}
	other := map[string]any{"id": "gh:verkyyi/claude-fleet#2701", "title": "调研", "url": "https://github.com/verkyyi/claude-fleet/issues/2701"}
	if st, out = reg(tok4, other); st != http.StatusCreated || out["owner"] != "" || out["state"] != "open" || out["backend"] != "gh" {
		t.Fatalf("a login with no person: %d %v", st, out)
	}
	for name, bad := range map[string]map[string]any{
		"hub backend reserved": {"id": "hub:7", "title": "x"},
		"not an id":            {"id": "verkyyi/claude-fleet#7", "title": "x"},
		"body is refused":      {"id": "gh:a/b#7", "title": "x", "body": "the whole thread"},
		"another page":         {"id": "gh:a/b#7", "title": "x", "url": "https://evil.example/a/b/issues/7"},
		"two-line title":       {"id": "gh:a/b#7", "title": "x\ny"},
		"no title":             {"id": "gh:a/b#7"},
		"state":                {"id": "gh:a/b#7", "title": "x", "state": "merged"},
	} {
		if st, out := reg(tok5, bad); st != http.StatusBadRequest {
			t.Fatalf("%s: %d %v", name, st, out)
		}
	}
	if st, _ := reg("not-a-token", row); st != http.StatusUnauthorized {
		t.Fatalf("no node token → %d", st)
	}
	if st, _ := sessDo(t, h, http.MethodGet, FleetTicketRegisterPath, tok5, "", nil); st != http.StatusMethodNotAllowed {
		t.Fatalf("GET → %d", st)
	}
}
