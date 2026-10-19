package api

import (
	"io"
	"net/http"
	"strings"
	"testing"
)

// /readyz answers 200 on a working store and 503 — saying nothing more — once
// the database is gone; the deploy probe writes, coalesces, and is refused
// (503) when the write cannot go through.
func TestReadyzAndDeployProbe(t *testing.T) {
	h := newHarness(t)
	do := func(method, path string) (int, string) {
		req, _ := http.NewRequest(method, h.http.URL+path, nil)
		resp, err := h.http.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		b, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return resp.StatusCode, string(b)
	}
	if code, body := do("GET", "/readyz"); code != 200 || body != `{"status":"ready"}`+"\n" {
		t.Fatalf("/readyz = %d %q", code, body)
	}
	if code, body := do("POST", "/v1/deploy-probe"); code != 200 || !strings.Contains(body, `"wrote":true`) {
		t.Fatalf("first probe = %d %q", code, body)
	}
	if code, body := do("POST", "/v1/deploy-probe"); code != 200 || !strings.Contains(body, `"wrote":false`) {
		t.Fatalf("a probe inside %v = %d %q, want 200 without a write", deployProbeEvery, code, body)
	}
	if code, _ := do("GET", "/v1/deploy-probe"); code != http.StatusMethodNotAllowed {
		t.Fatalf("GET /v1/deploy-probe = %d, want 405", code)
	}
	h.srv.Store.Close()
	if code, body := do("GET", "/readyz"); code != 503 || body != `{"status":"not ready"}`+"\n" {
		t.Fatalf("/readyz with the database gone = %d %q", code, body)
	}
	h.srv.probe.mu.Lock()
	h.srv.probe.lastWrite = h.srv.probe.lastWrite.Add(-deployProbeEvery)
	h.srv.probe.mu.Unlock()
	if code, _ := do("POST", "/v1/deploy-probe"); code != 503 {
		t.Fatalf("probe with the database gone = %d, want 503", code)
	}
	// liveness never asks the database
	if code, _ := do("GET", "/healthz"); code != 200 {
		t.Fatalf("/healthz with the database gone = %d, want 200", code)
	}
}
