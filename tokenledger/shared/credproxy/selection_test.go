package credproxy

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// A binding is for future requests. Two replicas can have overlapping requests
// on different revisions; neither may restart, replay or retoken an old stream.
func TestCodexSelectionPinsInflightAcrossReplicas(t *testing.T) {
	release := make(chan struct{})
	var once sync.Once
	done := func() { once.Do(func() { close(release) }) }
	var mu sync.Mutex
	var seen []string
	h := newHarness(t, true, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		auth := r.Header.Get("Authorization")
		mu.Lock()
		seen = append(seen, auth+" "+string(body))
		mu.Unlock()
		if string(body) == "first" {
			w.Header().Set("Content-Type", "text/event-stream")
			io.WriteString(w, "data: first\n\n")
			w.(http.Flusher).Flush()
			select {
			case <-release:
			case <-r.Context().Done():
				return
			}
			io.WriteString(w, "data: tail "+auth+"\n\n")
		} else {
			io.WriteString(w, auth)
		}
	})
	defer done()
	h.hub.set(func() { h.hub.bind[PassPrefix+"s"] = "old" })
	req, _ := http.NewRequest(http.MethodPost, h.proxy.URL+"/v1/proxy/codex/responses", strings.NewReader("first"))
	req.Header.Set("Authorization", "Bearer "+PassPrefix+"s")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	res, err := http.DefaultClient.Do(req.WithContext(ctx))
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	reader := bufio.NewReader(res.Body)
	first, err := reader.ReadString('\n')
	if err != nil || first != "data: first\n" {
		t.Fatalf("%q %v", first, err)
	}
	h.hub.set(func() { h.hub.bind[PassPrefix+"s"] = "new" })
	// Independent proxy cache / replica, same authenticated worker at the hub.
	other, err := New(Config{Resolver: h.hub, Direct: true, CodexURL: h.up.URL, Audit: func(string) {}})
	if err != nil {
		t.Fatal(err)
	}
	p2 := httptest.NewServer(other.Handler())
	defer p2.Close()
	next, _ := http.NewRequest(http.MethodPost, p2.URL+"/v1/proxy/codex/responses", strings.NewReader("second"))
	next.Header.Set("Authorization", "Bearer "+PassPrefix+"s")
	second, err := http.DefaultClient.Do(next.WithContext(ctx))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(second.Body)
	second.Body.Close()
	if string(body) != "Bearer tok-new" {
		t.Fatalf("new request: %s", body)
	}
	done()
	tail, err := io.ReadAll(reader)
	if err != nil || !strings.Contains(string(tail), "tail Bearer tok-old") {
		t.Fatalf("old stream changed: %s %v", tail, err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(seen) != 2 || seen[0] != "Bearer tok-old first" || seen[1] != "Bearer tok-new second" {
		t.Fatalf("replayed or changed body: %v", seen)
	}
}

func TestCodexSelectionBoundaryProtocol(t *testing.T) {
	var requests []ResolveRequest
	hub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var q ResolveRequest
		if err := json.NewDecoder(r.Body).Decode(&q); err != nil {
			t.Error(err)
		}
		requests = append(requests, q)
		json.NewEncoder(w).Encode(Resolution{Valid: true})
	}))
	defer hub.Close()
	h := &HubResolver{URL: hub.URL, Token: "fixture"}
	if _, err := h.Resolve(context.Background(), "fixture-pass", Codex); err != nil {
		t.Fatal(err)
	}
	if _, err := h.Resolve(context.Background(), "fixture-pass", Claude); err != nil {
		t.Fatal(err)
	}
	if _, err := h.RejectAccess(context.Background(), "fixture-pass", Codex, Resolution{Owner: "pool", Account: "a", AccessToken: "fixture-access"}, "token_expired"); err != nil {
		t.Fatal(err)
	}
	if len(requests) != 3 || !requests[0].RequestBoundary || requests[1].RequestBoundary || requests[2].RequestBoundary {
		t.Fatalf("unsafe selection point: %+v", requests)
	}
}

func TestCodexSelectionNeverReplaysAcrossAccountOn401(t *testing.T) {
	resolver := &rejectionResolver{result: Resolution{Valid: true, Owner: "pool", Account: "other", AccessToken: "new"}}
	p, err := New(Config{Resolver: resolver, Direct: true, Audit: func(string) {}})
	if err != nil {
		t.Fatal(err)
	}
	original := &http.Response{StatusCode: 401, Header: http.Header{}, Body: io.NopCloser(strings.NewReader(`{"error":{"code":"token_expired"}}`))}
	res := Resolution{Valid: true, Owner: "pool", Account: "default", AccessToken: "old"}
	got := p.refreshRejected(context.Background(), original, "fixture", Codex, &res)
	if got != original || res.Account != "default" || resolver.reports.Load() != 1 {
		t.Fatal("401 replayed across account")
	}
}
