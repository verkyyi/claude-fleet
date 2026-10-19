// Package apitest is the联调 tests' one way into the hub (claude-fleet#4814,
// EPIC #4810 C4): tokenledger/e2e starts a real node (the agent module) against
// a hub built here, so the hub module itself never names the node — not even
// in a test. It is the hub/api test harness, exported: a Server on a fresh
// store (hub/store/storetest: the SQLite template, or the Postgres leg under
// CCQUOTA_DB_URL) behind an httptest server, and the requests the tests make.
// What a test needs to see inside the hub is api's `…ForTest` hooks.
//
// Nothing here is linked into ccquota: only tests import it.
package apitest

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/api"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store/storetest"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/pricing"
)

// ViewerToken is the harness hub's viewer token.
const ViewerToken = "viewer-secret"

// Harness is one hub: Srv behind HTTP, and the enrollment tokens it minted.
type Harness struct {
	Srv    *api.Server
	HTTP   *httptest.Server
	Tokens map[string]string // endpoint label -> enrollment token
}

// NewHarness is a hub on a fresh store, closed at cleanup.
func NewHarness(t *testing.T) *Harness {
	t.Helper()
	srv := &api.Server{Store: storetest.Open(t), Pricing: pricing.Default(), ViewerToken: ViewerToken,
		LiveStore: api.NewLive()}
	return serve(t, srv)
}

// NewFleetHarness is NewHarness with the fleet module on, as the hub command
// sets it up under CCQUOTA_FLEET=1.
func NewFleetHarness(t *testing.T) *Harness {
	t.Helper()
	st := storetest.OpenFleet(t)
	// Existing behavior fixtures represent an installation awaiting policy migration.
	if err := st.SetFleetSetting(api.CredPolicyModeKey, "legacy", time.Now()); err != nil {
		t.Fatal(err)
	}
	srv := &api.Server{Store: st, Pricing: pricing.Default(), ViewerToken: ViewerToken,
		LiveStore: api.NewLive(), Fleet: true}
	return serve(t, srv)
}

func serve(t *testing.T, srv *api.Server) *Harness {
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return &Harness{Srv: srv, HTTP: ts, Tokens: map[string]string{}}
}

// Enroll mints an endpoint ep_<label> and returns its token.
func (h *Harness) Enroll(t *testing.T, label string) string {
	t.Helper()
	tok, err := api.MintToken()
	if err != nil {
		t.Fatal(err)
	}
	if err := h.Srv.Store.Enroll("ep_"+label, label, api.HashToken(tok)); err != nil {
		t.Fatal(err)
	}
	h.Tokens[label] = tok
	return tok
}

// Post sends body as JSON with the viewer token: the status and the answer.
func (h *Harness) Post(t *testing.T, path string, body any) (int, map[string]any) {
	t.Helper()
	b, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	req, _ := http.NewRequest(http.MethodPost, h.HTTP.URL+path, bytes.NewReader(b))
	req.Header.Set("Authorization", "Bearer "+ViewerToken)
	req.Header.Set("Content-Type", "application/json")
	res, err := h.HTTP.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

// PostForm sends a form POST that does not follow redirects, so the test reads
// the 303 and its Set-Cookie headers itself.
func (h *Harness) PostForm(t *testing.T, path string, hdr map[string]string) *http.Response {
	t.Helper()
	return h.PostFormBody(t, path, "", hdr)
}

// PostFormBody is PostForm with a form body (a=b&c=d).
func (h *Harness) PostFormBody(t *testing.T, path, body string, hdr map[string]string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, h.HTTP.URL+path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	c := *h.HTTP.Client()
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

// GetFleet reads a fleet route with the viewer token and wants wantStatus.
func GetFleet(t *testing.T, h *Harness, path string, wantStatus int) map[string]any {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.HTTP.URL+path, nil)
	req.Header.Set("Authorization", "Bearer "+ViewerToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if resp.StatusCode != wantStatus {
		t.Fatalf("%s: HTTP %d (%v), want %d", path, resp.StatusCode, out, wantStatus)
	}
	return out
}

// Roster is GET /v1/nodes.
func Roster(t *testing.T, h *Harness) api.NodesSnapshot {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, h.HTTP.URL+"/v1/nodes", nil)
	req.Header.Set("Authorization", "Bearer "+ViewerToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("/v1/nodes: HTTP %d", resp.StatusCode)
	}
	var snap api.NodesSnapshot
	if err := json.NewDecoder(resp.Body).Decode(&snap); err != nil {
		t.Fatal(err)
	}
	return snap
}

// DialNode opens the control channel as the endpoint whose token this is.
func DialNode(t *testing.T, h *Harness, token string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	url := "ws" + strings.TrimPrefix(h.HTTP.URL, "http") + control.Path
	c, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": []string{"Bearer " + token}},
	})
	if err != nil {
		t.Fatalf("dial control channel: %v", err)
	}
	t.Cleanup(func() { c.CloseNow() })
	return c
}

// WaitFor polls cond until it holds or the deadline passes.
func WaitFor(t *testing.T, d time.Duration, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out after %s waiting for %s", d, what)
}

// OpenStore is a fresh hub store for one test (hub/store/storetest), for a test
// that builds its own Server.
func OpenStore(t testing.TB) *store.Store { return storetest.Open(t) }

// Main is a test binary's TestMain: plain m.Run, or on the Postgres leg
// (CCQUOTA_DB_URL) every test database its own schema, and the tests the leg
// does not run printed (store.TestMainPostgres) — as hub/api's own.
func Main(m *testing.M) int { return store.TestMainPostgres(m, nil) }
