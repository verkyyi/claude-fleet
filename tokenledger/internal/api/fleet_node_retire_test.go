package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

// claude-fleet#1928: take a machine off the hub — an admin any, a user only
// their own, a node itself — and its token and roster row go with it.

func retireNodeRow(t *testing.T, s *Server, ep, host, osUser string) {
	t.Helper()
	if err := s.Store.NodeConnected(ep, host, osUser, "v1", 1, 60000, time.Now()); err != nil {
		t.Fatal(err)
	}
}

func retireCookiePost(t *testing.T, h *ghHarness, c *http.Cookie, path string, body any) (int, map[string]any) {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+path, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.AddCookie(c)
	resp, err := noFollow.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func retireAudits(t *testing.T, s *Server, actor, ep string) int {
	t.Helper()
	var n int
	if err := s.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'node_revoke'
		AND actor = ? AND fleet_id = ?`, actor, "endpoint:"+ep).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func onRoster(t *testing.T, s *Server, ep string) bool {
	t.Helper()
	ns, err := s.Store.Nodes()
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range ns {
		if n.EndpointID == ep {
			return true
		}
	}
	return false
}

// The operator's door retires any machine: token dead, roster row gone,
// one audit row; again is a no-op; an unknown id is 404.
func TestNodeRetire_AdminAny(t *testing.T) {
	h := newFleetHarness(t)
	tok := h.enroll(t, "m9")
	retireNodeRow(t, h.srv, "ep_m9", "m9.local", "bob")

	code, out := h.post(t, NodeRetirePath, NodeRevokeRequest{EndpointID: "ep_m9", Reason: "换电脑"})
	if code != http.StatusOK || out["already"] != false || out["removed"] != true || out["os_user"] != "bob" {
		t.Fatalf("retire: HTTP %d %v", code, out)
	}
	if _, err := h.srv.Store.EndpointByTokenHash(HashToken(tok)); err == nil {
		t.Fatal("the retired machine's token must stop working")
	}
	if onRoster(t, h.srv, "ep_m9") {
		t.Fatal("the retired machine must be off the roster (/nodes)")
	}
	if n := retireAudits(t, h.srv, "operator", "ep_m9"); n != 1 {
		t.Fatalf("want one node_revoke audit row, got %d", n)
	}
	if code, out := h.post(t, NodeRetirePath, NodeRevokeRequest{EndpointID: "ep_m9"}); code != http.StatusOK || out["already"] != true || out["removed"] != false {
		t.Fatalf("second retire: HTTP %d %v, want already=true removed=false", code, out)
	}
	if n := retireAudits(t, h.srv, "operator", "ep_m9"); n != 1 {
		t.Fatalf("a no-op retire must not be audited, got %d", n)
	}
	if code, _ := h.post(t, NodeRetirePath, NodeRevokeRequest{EndpointID: "ep_nobody"}); code != http.StatusNotFound {
		t.Fatalf("an unknown endpoint: HTTP %d, want 404", code)
	}
}

// A user retires their own machine and nobody else's: another's, and one that
// does not exist, are both 403 — and the other's token keeps working.
func TestNodeRetire_UserOnlyOwn(t *testing.T) {
	h, admin, user := rolesHarness(t)
	enroll := func(label string) string {
		tok, _ := MintToken()
		if err := h.srv.Store.Enroll("ep_"+label, label, HashToken(tok)); err != nil {
			t.Fatal(err)
		}
		return tok
	}
	aliceTok := enroll("alice-new")
	adminTok := enroll("mini-node")
	retireNodeRow(t, h.srv, "ep_alice-new", "alicebook.local", aliceLogin)
	giveAccount(t, h.srv, githubPrincipal(ghAlice.ID), "alicebook.local")
	retireNodeRow(t, h.srv, "ep_mini-node", "mini.local", "verkyyi")

	for _, id := range []string{"ep_mini-node", "ep_nobody"} {
		if code, out := retireCookiePost(t, h, user, NodeRetirePath, NodeRevokeRequest{EndpointID: id}); code != http.StatusForbidden {
			t.Fatalf("user retiring %s: HTTP %d %v, want 403", id, code, out)
		}
	}
	if _, err := h.srv.Store.EndpointByTokenHash(HashToken(adminTok)); err != nil {
		t.Fatalf("a refused retire must leave the token alive: %v", err)
	}
	if !onRoster(t, h.srv, "ep_mini-node") {
		t.Fatal("a refused retire must leave the roster row")
	}

	code, out := retireCookiePost(t, h, user, NodeRetirePath, NodeRevokeRequest{EndpointID: "ep_alice-new"})
	if code != http.StatusOK || out["removed"] != true {
		t.Fatalf("user retiring their own: HTTP %d %v", code, out)
	}
	if _, err := h.srv.Store.EndpointByTokenHash(HashToken(aliceTok)); err == nil {
		t.Fatal("the user's retired machine's token must stop working")
	}
	var actor string
	_ = h.srv.Store.DB().QueryRow(`SELECT actor FROM fleet_audit WHERE action = 'node_revoke' AND fleet_id = 'endpoint:ep_alice-new'`).Scan(&actor)
	if !strings.HasPrefix(actor, "gh:") {
		t.Fatalf("the audit must name the person, got actor %q", actor)
	}

	// An admin's cookie retires anyone's.
	if code, out := retireCookiePost(t, h, admin, NodeRetirePath, NodeRevokeRequest{EndpointID: "ep_mini-node"}); code != http.StatusOK || out["removed"] != true {
		t.Fatalf("admin retiring: HTTP %d %v", code, out)
	}
}

// A node retires itself with its own token; after that the token is unknown,
// so a second leave is 401 — and leave never touches another endpoint.
func TestNodeLeave_SelfWithOwnToken(t *testing.T) {
	h := newFleetHarness(t)
	tok := h.enroll(t, "m9")
	other := h.enroll(t, "m8")
	retireNodeRow(t, h.srv, "ep_m9", "m9.local", "carol")
	retireNodeRow(t, h.srv, "ep_m8", "m8.local", "dave")

	code, body := rawCall(t, h, http.MethodPost, NodeLeavePath, tok)
	if code != http.StatusOK {
		t.Fatalf("leave: HTTP %d %s", code, body)
	}
	var out NodeRetireResponse
	if err := json.Unmarshal([]byte(body), &out); err != nil {
		t.Fatal(err)
	}
	if out.EndpointID != "ep_m9" || out.Already || !out.Removed {
		t.Fatalf("leave answered %+v", out)
	}
	if n := retireAudits(t, h.srv, "node:carol@m9", "ep_m9"); n != 1 {
		t.Fatalf("want one node_revoke row by node:carol@m9, got %d", n)
	}
	if onRoster(t, h.srv, "ep_m9") || !onRoster(t, h.srv, "ep_m8") {
		t.Fatal("leave must drop its own roster row and only its own")
	}
	if _, err := h.srv.Store.EndpointByTokenHash(HashToken(other)); err != nil {
		t.Fatalf("another node's token must keep working: %v", err)
	}
	if code, _ := rawCall(t, h, http.MethodPost, NodeLeavePath, tok); code != http.StatusUnauthorized {
		t.Fatalf("a second leave with the dead token: HTTP %d, want 401", code)
	}
	if code, _ := rawCall(t, h, http.MethodGet, NodeLeavePath, other); code != http.StatusMethodNotAllowed {
		t.Fatalf("GET leave: HTTP %d, want 405", code)
	}
}
