package api

import (
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
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

// A replica beat stuck on a dead database connection holds drain.mu across its
// write (beatReplica). /readyz must still answer at once (task N9GH: on the
// box every /readyz waited behind it — 10 s with TCP_USER_TIMEOUT, ~15 min the
// day of the outage — while /healthz, which never asked Draining(), stayed
// fast). Drain still turns /readyz 503.
func TestReadyzDoesNotWaitBehindAStuckReplicaBeat(t *testing.T) {
	h := newHarness(t)
	get := func() (int, time.Duration) {
		t0 := time.Now()
		resp, err := h.http.Client().Get(h.http.URL + "/readyz")
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode, time.Since(t0)
	}
	h.srv.drain.mu.Lock() // a beat's write that does not come back
	done := make(chan struct{})
	var code int
	var took time.Duration
	go func() { code, took = get(); close(done) }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		h.srv.drain.mu.Unlock()
		<-done
		t.Fatalf("/readyz waited behind the replica beat's lock (%v)", took)
	}
	if code != 200 {
		t.Fatalf("/readyz = %d while a beat is stuck, want 200", code)
	}
	h.srv.Drain()
	if c, _ := get(); c != 503 {
		t.Fatalf("/readyz after Drain = %d, want 503", c)
	}
	h.srv.drain.mu.Unlock()
}
