package api

// CCQUOTA_READONLY=1 (claude-fleet#2122): while the database is moved, a write
// is 503 + Retry-After, a read is served as usual.

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/pricing"
)

func TestReadOnlyRefusesWritesServesReads(t *testing.T) {
	// A hub with data, then restarted read-only on the same store.
	h := newHarness(t)
	tok := h.enroll(t, "a")
	if resp := h.push(t, tok, batchFor("acct-a", "a", []string{"a1"}, "/a")); resp.StatusCode != 200 {
		t.Fatalf("ingest before read-only: %d", resp.StatusCode)
	}
	st := h.srv.Store
	if err := st.SetReadOnly(); err != nil {
		t.Fatal(err)
	}
	srv := &Server{Store: st, Pricing: pricing.Default(), ViewerToken: viewerToken, LiveStore: NewLive(), ReadOnly: true}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	do := func(method, path string) (*http.Response, string) {
		req, _ := http.NewRequest(method, ts.URL+path, strings.NewReader(`{}`))
		req.Header.Set("Authorization", "Bearer "+viewerToken)
		resp, err := ts.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return resp, string(b)
	}

	for _, w := range []struct{ method, path string }{
		{"POST", "/v1/ingest"}, {"POST", "/v1/live/report"}, {"POST", "/v1/accounts/label"}, {"PUT", "/v1/fleet/settings"}, {"DELETE", "/v1/findings/mutes"},
	} {
		resp, body := do(w.method, w.path)
		if resp.StatusCode != http.StatusServiceUnavailable || resp.Header.Get("Retry-After") != "15" || !strings.Contains(body, "read_only") {
			t.Errorf("%s %s: HTTP %d Retry-After %q %s, want 503 + Retry-After", w.method, w.path, resp.StatusCode, resp.Header.Get("Retry-After"), body)
		}
	}
	for _, path := range []string{"/v1/usage", "/v1/summary", "/v1/endpoints"} {
		if resp, body := do("GET", path); resp.StatusCode != http.StatusOK {
			t.Errorf("GET %s: HTTP %d %s, want 200 while read-only", path, resp.StatusCode, body)
		}
	}
	// The store under the gate refuses a write no request makes.
	if err := st.Enroll("ep_b", "b", "hash"); err == nil {
		t.Error("the read-only store took a write")
	}
	if resp, body := do("GET", "/healthz"); resp.StatusCode != http.StatusOK || body != `{"mode":"read-only","status":"ok"}`+"\n" {
		t.Errorf("/healthz while read-only: %d %q", resp.StatusCode, body)
	}
}

// Off, /healthz says what it always said and a write is not stopped at the door.
func TestReadOnlyOffChangesNothing(t *testing.T) {
	h := newHarness(t)
	resp, err := h.http.Client().Get(h.http.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(b) != `{"status":"ok"}`+"\n" {
		t.Errorf("/healthz = %q", b)
	}
	resp, err = h.http.Client().Post(h.http.URL+"/v1/ingest", "application/json", strings.NewReader(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode == http.StatusServiceUnavailable || resp.Header.Get("Retry-After") != "" {
		t.Errorf("ingest with read-only off: HTTP %d Retry-After %q", resp.StatusCode, resp.Header.Get("Retry-After"))
	}
}
