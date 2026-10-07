package api

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// enrollmentTokenRoutes is every route that takes a node's (or an agent's)
// enrollment token. The issue's bar: a revoked token is refused on EVERY one,
// and the refusal is the unknown token's, byte for byte.
var enrollmentTokenRoutes = []struct{ method, path string }{
	{http.MethodPost, "/v1/ingest"},
	{http.MethodPost, "/v1/live/report"},
	{http.MethodPost, "/v1/collectors/quota-lease"},
	{http.MethodGet, control.Path},
	{http.MethodPost, "/v1/node/lease"},
	{http.MethodPost, "/v1/node/place"},
	{http.MethodPost, "/v1/node/move"},
	{http.MethodGet, "/v1/node/self"},
	{http.MethodPost, "/v1/node/maintenance"},
	{http.MethodPost, "/v1/node/progress"},
	{http.MethodPost, "/v1/node/relay-credential"},
	{http.MethodPost, "/v1/fleet/session-cred"},
	{http.MethodGet, control.TeamBundlePath},
	{http.MethodGet, control.PersonBundlePath},
}

func rawCall(t *testing.T, h *harness, method, path, token string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(method, h.http.URL+path, bytes.NewReader([]byte("{}")))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

// Red before #1403's fix for the half that mattered: nothing pinned that a
// retired token reads as unknown on each route — only on /v1/ingest, and only
// the status. Each route is also checked to READ the token at all (a live
// token gets a different answer), so a route that refuses everyone before
// looking cannot pass vacuously.
func TestNodeRevoke_RefusedEverywhereLikeAnUnknownToken(t *testing.T) {
	h := newFleetHarness(t)
	h.srv.SessionCredKey = []byte("0123456789abcdef0123456789abcdef")
	live := h.enroll(t, "m9-live")
	gone := h.enroll(t, "m9-gone")
	unknown, _ := MintToken()

	if code, out := h.post(t, NodeRevokePath, NodeRevokeRequest{EndpointID: "ep_m9-gone", Reason: "lost"}); code != http.StatusOK {
		t.Fatalf("revoke: HTTP %d %v", code, out)
	}
	for _, rt := range enrollmentTokenRoutes {
		uc, ub := rawCall(t, h, rt.method, rt.path, unknown)
		gc, gb := rawCall(t, h, rt.method, rt.path, gone)
		if uc != gc || ub != gb {
			t.Errorf("%s %s: revoked answered %d %q, unknown %d %q — they must be identical",
				rt.method, rt.path, gc, gb, uc, ub)
		}
		if uc/100 != 4 {
			t.Errorf("%s %s: an unknown token got HTTP %d", rt.method, rt.path, uc)
		}
		lc, lb := rawCall(t, h, rt.method, rt.path, live)
		if lc == uc && lb == ub {
			t.Errorf("%s %s: a live token is answered like an unknown one (%d %q) — the route never reads it, so this check proves nothing",
				rt.method, rt.path, lc, lb)
		}
	}
}

// The operator's revoke ends what the token had already opened: the live
// control channel, the session passes it issued — and it is audited.
func TestNodeRevoke_ClosesTheLinkRevokesPassesAudits(t *testing.T) {
	h := newFleetHarness(t)
	tok := h.enroll(t, "m9")
	c := dialNode(t, h, tok)
	hello(t, c, control.Proto, 60000)
	waitFor(t, 2*time.Second, "the link to register", func() bool { return h.srv.nodes.get("ep_m9") != nil })

	now := time.Now()
	for _, id := range []string{"p1", "p2"} {
		if err := h.srv.Store.AddSessionCred(store.SessionCred{ID: id, PrincipalID: "pr", WorkerID: "w/" + id,
			Machine: "m9", EndpointID: "ep_m9", Providers: []string{"claude"}, IssuedAt: now, ExpiresAt: now.Add(time.Hour)}); err != nil {
			t.Fatal(err)
		}
	}
	if err := h.srv.Store.AddSessionCred(store.SessionCred{ID: "other", PrincipalID: "pr", WorkerID: "w/o",
		Machine: "m8", EndpointID: "ep_m8", Providers: []string{"claude"}, IssuedAt: now, ExpiresAt: now.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}

	code, out := h.post(t, NodeRevokePath, NodeRevokeRequest{EndpointID: "ep_m9", Reason: "lost"})
	if code != http.StatusOK {
		t.Fatalf("revoke: HTTP %d %v", code, out)
	}
	if out["already"] != false || out["passes"] != float64(2) || out["link_closed"] != true {
		t.Fatalf("revoke answered %v, want already=false passes=2 link_closed=true", out)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var m control.Message
	err := wsjson.Read(ctx, c, &m)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("the open link must be closed by the revoke, read: %v", err)
	}
	for id, want := range map[string]bool{"p1": true, "p2": true, "other": false} {
		p, err := h.srv.Store.SessionCredByID(id)
		if err != nil {
			t.Fatal(err)
		}
		if (p.RevokedAt != nil) != want {
			t.Errorf("pass %s revoked=%v, want %v", id, p.RevokedAt != nil, want)
		}
	}
	var n int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit
		WHERE action = 'node_revoke' AND actor = 'operator' AND fleet_id = 'endpoint:ep_m9'
		AND outcome = 'REVOKE passes=2 reason=lost'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("want one node_revoke audit row, got %d", n)
	}

	// Again: nothing changes, nothing is recorded.
	if code, out := h.post(t, NodeRevokePath, NodeRevokeRequest{EndpointID: "ep_m9"}); code != http.StatusOK || out["already"] != true {
		t.Fatalf("second revoke: HTTP %d %v, want already=true", code, out)
	}
	_ = h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'node_revoke'`).Scan(&n)
	if n != 1 {
		t.Fatalf("a no-op revoke must not be audited, got %d rows", n)
	}
	if code, _ := h.post(t, NodeRevokePath, NodeRevokeRequest{EndpointID: "ep_nobody"}); code != http.StatusNotFound {
		t.Fatalf("an unknown endpoint: HTTP %d, want 404", code)
	}
}

// A retire made by ANOTHER process (`ccquota endpoint retire` on the hub's
// database) is seen by the link on its next message.
func TestNodeRevoke_RetireElsewhereClosesOnNextBeat(t *testing.T) {
	h := newFleetHarness(t)
	tok := h.enroll(t, "m9")
	c := dialNode(t, h, tok)
	hello(t, c, control.Proto, 60000)
	waitFor(t, 2*time.Second, "the link to register", func() bool { return h.srv.nodes.get("ep_m9") != nil })

	if _, err := h.srv.Store.RetireEndpointAs("ep_m9", "cli", "", time.Now()); err != nil {
		t.Fatal(err)
	}
	beat(t, c, control.Proto, control.Heartbeat{Hostname: "m9"})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var m control.Message
	err := wsjson.Read(ctx, c, &m)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("a beat on a retired token must close the link, read: %v (msg %+v)", err, m)
	}
	waitFor(t, 2*time.Second, "the link to be forgotten", func() bool { return h.srv.nodes.get("ep_m9") == nil })
}

// The route is the operator's: a node's own token cannot revoke anyone.
func TestNodeRevoke_OperatorOnly(t *testing.T) {
	h := newFleetHarness(t)
	tok := h.enroll(t, "m9")
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+NodeRevokePath,
		strings.NewReader(`{"endpoint_id":"ep_m9"}`))
	req.Header.Set("Authorization", "Bearer "+tok)
	resp, err := h.http.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode/100 != 4 {
		t.Fatalf("a node token on the revoke route: HTTP %d", resp.StatusCode)
	}
	if _, err := h.srv.Store.EndpointByTokenHash(HashToken(tok)); err != nil {
		t.Fatalf("the node's token must still work: %v", err)
	}
}
