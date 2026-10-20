package hubfwd

import (
	"bytes"
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// hub is a fake hub that counts the TCP connections made to it.
func hub(t *testing.T) (*httptest.Server, *atomic.Int32, *atomic.Int32) {
	t.Helper()
	var conns, hits atomic.Int32
	h := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			io.WriteString(w, "ok")
			return
		}
		hits.Add(1)
		b, _ := io.ReadAll(r.Body)
		w.Header().Set("X-Seen-Auth", r.Header.Get("Authorization"))
		w.Header().Set("X-Seen-Fwd", r.Header.Get(HubHeader))
		w.WriteHeader(http.StatusOK)
		io.WriteString(w, r.Method+" "+r.URL.RequestURI()+" "+string(b))
	}))
	h.Config.ConnState = func(_ net.Conn, s http.ConnState) {
		if s == http.StateNew {
			conns.Add(1)
		}
	}
	h.Start()
	t.Cleanup(h.Close)
	return h, &conns, &hits
}

func sock(t *testing.T) string {
	t.Helper()
	d, err := os.MkdirTemp("/tmp", "hubfwd")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(d) })
	return filepath.Join(d, SockName)
}

func serve(t *testing.T, f *Forwarder, path string) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- f.Serve(ctx, path) }()
	t.Cleanup(func() { cancel(); <-done })
	deadline := time.Now().Add(3 * time.Second)
	for !exists(path) {
		if time.Now().After(deadline) {
			t.Fatal("the forwarder never listened")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func post(t *testing.T, c *http.Client, url, body string) (int, string, http.Header) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader([]byte(body)))
	req.Header.Set("Authorization", "Bearer tok")
	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b), resp.Header
}

// Three asks through the forwarder ride ONE connection to the hub (the warm
// road), carrying the caller's own credential and body unchanged.
func TestForwarderOneConnectionManyAsks(t *testing.T) {
	h, conns, hits := hub(t)
	p := sock(t)
	t.Setenv(SockEnv, p)
	serve(t, &Forwarder{Hub: h.URL, Client: &http.Client{Transport: &http.Transport{}}}, p)
	waitFor(t, func() bool { return conns.Load() == 1 }) // the warm-up's
	c := &http.Client{Transport: Transport(h.URL, nil)}
	for i := 0; i < 3; i++ {
		st, body, hdr := post(t, c, h.URL+"/v1/node/place?x=1", `{"a":1}`)
		if st != 200 || body != `POST /v1/node/place?x=1 {"a":1}` || hdr.Get("X-Seen-Auth") != "Bearer tok" {
			t.Fatalf("ask %d = %d %q %v", i, st, body, hdr)
		}
		if hdr.Get("X-Seen-Fwd") != "" {
			t.Fatal("the forwarder's own header reached the hub")
		}
	}
	if hits.Load() != 3 || conns.Load() != 1 {
		t.Fatalf("hits %d over %d connections; want 3 over 1", hits.Load(), conns.Load())
	}
}

// No socket, a socket nobody answers on, another hub, a path it does not
// carry: the direct road, once.
func TestTransportFallsBackDirect(t *testing.T) {
	h, _, hits := hub(t)
	other, _, otherHits := hub(t)

	t.Setenv(SockEnv, filepath.Join(t.TempDir(), "none.sock"))
	c := &http.Client{Transport: Transport(h.URL, nil)}
	if st, _, _ := post(t, c, h.URL+"/v1/node/place", "x"); st != 200 || hits.Load() != 1 {
		t.Fatalf("no forwarder: %d, hub hits %d", st, hits.Load())
	}

	p := sock(t)
	t.Setenv(SockEnv, p)
	serve(t, &Forwarder{Hub: other.URL}, p) // serves the OTHER hub
	c = &http.Client{Transport: Transport(h.URL, nil)}
	if st, body, _ := post(t, c, h.URL+"/v1/node/lease", "y"); st != 200 || body != "POST /v1/node/lease y" || hits.Load() != 2 {
		t.Fatalf("another hub's forwarder: %d %q, hub hits %d", st, body, hits.Load())
	}
	if otherHits.Load() != 0 {
		t.Fatal("a forwarder carried a request meant for another hub")
	}

	// a path the forwarder never carries goes direct without asking it
	c = &http.Client{Transport: Transport(other.URL, nil)}
	if st, _, _ := post(t, c, other.URL+"/v1/node/connect", "z"); st != 200 || otherHits.Load() != 1 {
		t.Fatalf("connect: %d, other hits %d", st, otherHits.Load())
	}
}

// The forwarder refuses what it does not carry, said as its own answer.
func TestForwarderRefuses(t *testing.T) {
	f := &Forwarder{Hub: "https://hub.test"}
	for _, c := range []struct{ hub, path string }{
		{"https://evil.test", "/v1/node/place"},
		{"https://hub.test", "/v1/node/connect"},
		{"https://hub.test", "/admin"},
		{"https://hub.test", "/v1/node/../admin"},
	} {
		r := httptest.NewRequest(http.MethodPost, c.path, strings.NewReader(""))
		r.Header.Set(HubHeader, c.hub)
		w := httptest.NewRecorder()
		f.ServeHTTP(w, r)
		if w.Code < 400 || w.Header().Get(ViaHeader) != "refused" {
			t.Fatalf("%v = %d %v; want refused", c, w.Code, w.Header())
		}
	}
}

// A hub the forwarder cannot reach is the caller's transport error, in the
// words a direct call uses (dial tcp …), never a 502 body read as the hub's.
func TestForwarderUnreachableIsAnError(t *testing.T) {
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	dead := "http://" + ln.Addr().String()
	ln.Close()
	p := sock(t)
	t.Setenv(SockEnv, p)
	serve(t, &Forwarder{Hub: dead}, p)
	c := &http.Client{Transport: Transport(dead, nil)}
	req, _ := http.NewRequest(http.MethodPost, dead+"/v1/node/place", strings.NewReader("x"))
	_, err := c.Do(req)
	if err == nil || !strings.Contains(err.Error(), "connection refused") {
		t.Fatalf("err = %v; want the dial's own words", err)
	}
}

func waitFor(t *testing.T, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatal("timed out")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// An https hub: the caller still speaks plain HTTP on the socket (the
// forwarder holds the TLS), and the hub sees its own Host.
func TestTransportHTTPSHubOverSocket(t *testing.T) {
	var host atomic.Value
	h := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host.Store(r.Host)
		io.WriteString(w, "tls "+r.URL.Path)
	}))
	t.Cleanup(h.Close)
	p := sock(t)
	t.Setenv(SockEnv, p)
	serve(t, &Forwarder{Hub: h.URL, Client: h.Client()}, p)
	c := &http.Client{Transport: Transport(h.URL, &http.Transport{})} // the direct road would fail: untrusted cert
	st, body, _ := post(t, c, h.URL+"/v1/node/place", "")
	if st != 200 || body != "tls /v1/node/place" || host.Load() != strings.TrimPrefix(h.URL, "https://") {
		t.Fatalf("= %d %q host %v", st, body, host.Load())
	}
}
