package door

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// One port, two servers: TLS to the browser listener, plain to the relay —
// the relay's homes see nothing change (XX79).
func TestSplitTLSSharesOnePort(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	tl, pl := SplitTLS(ln, time.Second)
	say := func(w string) http.Handler {
		return http.HandlerFunc(func(rw http.ResponseWriter, _ *http.Request) { io.WriteString(rw, w) })
	}
	ts := httptest.NewUnstartedServer(say("browser"))
	ts.Listener = tl
	ts.StartTLS()
	defer ts.Close()
	go (&http.Server{Handler: say("relay")}).Serve(pl)
	get := func(c *http.Client, u string) string {
		t.Helper()
		r, err := c.Get(u)
		if err != nil {
			t.Fatal(err)
		}
		defer r.Body.Close()
		b, _ := io.ReadAll(r.Body)
		return string(b)
	}
	addr := ln.Addr().String()
	for i := 0; i < 3; i++ {
		if got := get(ts.Client(), "https://"+addr+"/"); got != "browser" {
			t.Fatalf("TLS reached %q", got)
		}
		if got := get(&http.Client{Transport: &http.Transport{DisableKeepAlives: true}}, "http://"+addr+"/relay"); got != "relay" {
			t.Fatalf("plain reached %q", got)
		}
	}
	// a silent connection is closed, and does not hold up the next
	c, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := c.Read(make([]byte, 1)); err == nil {
		t.Fatal("a silent connection was answered")
	}
}
