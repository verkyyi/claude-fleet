package door

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"context"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
)

func newKey(t *testing.T) ssh.Signer {
	t.Helper()
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	s, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func echoServer(t *testing.T, tag string) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				io.WriteString(c, tag+":")
				io.Copy(c, c)
			}()
		}
	}()
	return ln.Addr().String()
}

// The pods' jump on the door's own server (A5SQ ④, BREAK-IT
// door-jump-ccquota): the jump account takes a routed person's key, opens a
// tunnel only to that person's own pod sshd, and nothing else — no session,
// no other pod, no address of its choosing; an unlisted key is refused; the
// pull says jump=1 with the namespace (the hub offers the jump only then).
func TestJumpOnlyToTheirOwnPod(t *testing.T) {
	alice, bob, stranger := newKey(t), newKey(t), newKey(t)
	nk := func(s ssh.Signer) control.EntryNodeKey {
		return control.EntryNodeKey{FP: ssh.FingerprintSHA256(s.PublicKey()), Type: s.PublicKey().Type()}
	}
	var mu sync.Mutex
	var asked string
	gone := false // alice's key leaves the hub's list
	hub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != control.EntryRoutesNodePath || r.Header.Get("Authorization") != "Bearer tok" {
			http.Error(w, "no", 403)
			return
		}
		mu.Lock()
		asked = r.URL.RawQuery
		ak := []control.EntryNodeKey{nk(alice)}
		if gone {
			ak = nil
		}
		mu.Unlock()
		json.NewEncoder(w).Encode(control.EntryRouteList{Version: 1,
			Routes: []control.EntryRoute{{Login: "alice", Principal: "gh:a", Service: "u-aaaa1"}, {Login: "bob", Principal: "gh:b", Service: "u-bbbb2"}},
			Logins: map[string]control.EntryNodeLogin{"alice": {Person: "gh:a", Keys: ak},
				"bob": {Person: "gh:b", Keys: []control.EntryNodeKey{nk(bob)}}}})
	}))
	defer hub.Close()
	_, hk, _ := ed25519.GenerateKey(rand.Reader)
	host, _ := NewHostKey(hk)
	d, err := New(Config{Hub: hub.URL, Token: "tok", HostKey: host, Namespace: "fleet-workers",
		JumpTargets: map[string]string{"u-aaaa1": echoServer(t, "alice-pod"), "u-bbbb2": echoServer(t, "bob-pod")}})
	if err != nil {
		t.Fatal(err)
	}
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go d.Serve(ctx, ln)
	deadline := time.Now().Add(5 * time.Second)
	for d.JumpKeys() < 2 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	mu.Lock()
	if asked != "jump=1&ns=fleet-workers&home=1" {
		t.Fatalf("the pull asked %q", asked)
	}
	mu.Unlock()
	dial := func(key ssh.Signer) (*ssh.Client, error) {
		return ssh.Dial("tcp", ln.Addr().String(), &ssh.ClientConfig{User: "fleet-jump", Auth: []ssh.AuthMethod{ssh.PublicKeys(key)},
			HostKeyCallback: ssh.InsecureIgnoreHostKey(), Timeout: 5 * time.Second})
	}
	if _, err := dial(stranger); err == nil {
		t.Fatal("an unlisted key got into the jump account")
	}
	cl, err := dial(alice)
	if err != nil {
		t.Fatalf("alice into the jump account: %v", err)
	}
	defer cl.Close()
	c, err := cl.Dial("tcp", "u-aaaa1.fleet-workers.svc.cluster.local:22")
	if err != nil {
		t.Fatalf("alice's tunnel to her pod: %v", err)
	}
	io.WriteString(c, "hi")
	buf := make([]byte, 12)
	if _, err := io.ReadFull(c, buf); err != nil || string(buf) != "alice-pod:hi" {
		t.Fatalf("through the tunnel: %q %v", buf, err)
	}
	c.Close()
	for _, other := range []string{"u-bbbb2.fleet-workers.svc.cluster.local:22", "u-aaaa1.fleet-workers.svc.cluster.local:2222",
		"127.0.0.1:22", "hub.example:443"} {
		if c, err := cl.Dial("tcp", other); err == nil {
			c.Close()
			t.Fatalf("alice's tunnel to %s opened", other)
		}
	}
	if _, err := cl.NewSession(); err == nil {
		t.Fatal("a session on the jump account")
	}
	if ok, _, _ := cl.SendRequest("tcpip-forward", true, ssh.Marshal(struct {
		A string
		P uint32
	}{"0.0.0.0", 8080})); ok {
		t.Fatal("a remote forward on the jump account")
	}
	if !strings.Contains(asked, "home=1") {
		t.Fatal("the pull did not ask for the homes")
	}
	// her key leaves the list: the connection she holds opens no new tunnel
	mu.Lock()
	gone = true
	mu.Unlock()
	if err := d.Pull(ctx); err != nil {
		t.Fatal(err)
	}
	if c, err := cl.Dial("tcp", "u-aaaa1.fleet-workers.svc.cluster.local:22"); err == nil {
		c.Close()
		t.Fatal("a key gone from the list still tunnels")
	}
}
