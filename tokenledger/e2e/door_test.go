package e2e

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/agent"
	"github.com/verkyyi/claude-fleet/tokenledger/agent/door"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/api"
	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/control"
	"github.com/verkyyi/claude-fleet/tokenledger/shared/sshca"
)

// doorHomeSSHD is a home's entry port as the door meets it: it takes only a
// certificate of ca for login, from loopback, and answers exec "hostname"
// with "home-of-<login>". It returns its address and its host key line.
func doorHomeSSHD(t *testing.T, ca ssh.PublicKey, login string) (string, string) {
	t.Helper()
	_, hk, _ := ed25519.GenerateKey(rand.Reader)
	signer, _ := ssh.NewSignerFromKey(hk)
	checker := &ssh.CertChecker{IsUserAuthority: func(auth ssh.PublicKey) bool { return bytes.Equal(auth.Marshal(), ca.Marshal()) }}
	cfg := &ssh.ServerConfig{PublicKeyCallback: func(c ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
		if c.User() != login {
			return nil, fmt.Errorf("not %s", login)
		}
		return checker.Authenticate(c, key)
	}}
	cfg.AddHostKey(signer)
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
				_, chans, reqs, err := ssh.NewServerConn(c, cfg)
				if err != nil {
					return
				}
				go ssh.DiscardRequests(reqs)
				for nc := range chans {
					ch, in, err := nc.Accept()
					if err != nil {
						return
					}
					go func() {
						defer ch.Close()
						for req := range in {
							if req.Type != "exec" {
								req.Reply(false, nil)
								continue
							}
							req.Reply(true, nil)
							fmt.Fprint(ch, "home-of-"+login)
							ch.SendRequest("exit-status", false, ssh.Marshal(struct{ S uint32 }{0}))
							return
						}
					}()
				}
			}()
		}
	}()
	return ln.Addr().String(), strings.TrimSpace(string(ssh.MarshalAuthorizedKey(signer.PublicKey())))
}

// The completion criterion's door half (A5SQ ③): an ordinary SSH client, to
// the door's one address, as alice with alice's key, lands at alice's home —
// through the door's own SSH server, the hub's door-session certificate and the
// home agent's stream onto its entry port — and the home sees a door-session
// certificate, never the person's key. Bob's key as alice, and alice as a
// login the book does not take home, are refused at the door.
func TestDoorTakesEachPersonHome(t *testing.T) {
	h := newFleetHarness(t)
	k := newCertKit(t)
	h.Srv.SSHCA = sshca.New(k.ca)
	dca, err := h.Srv.SSHCA.Derive("door-session")
	if err != nil {
		t.Fatal(err)
	}
	dcaPub, _, _, _, _ := ssh.ParseAuthorizedKey([]byte(dca.PublicKey()))
	now := time.Now()
	for k, v := range map[string]string{api.EntryKey: "on", api.DoorKey: "fleet-door"} {
		if err := h.Srv.Store.SetFleetSetting(k, v, now); err != nil {
			t.Fatal(err)
		}
	}
	// the door: a machine link of its own
	h.Enroll(t, "door")
	identify(t, h, "door", "fleet-door", "root")
	dn := dialMachine(t, h, h.Tokens["door"])
	dn.beat("", control.Heartbeat{Hostname: "fleet-door", OSUser: "root", ObservedAt: now})
	waitFor(t, 3*time.Second, "the door's host recorded", func() bool {
		ep, err := h.Srv.Store.EndpointByID("ep_door")
		return err == nil && h.Srv.EndpointHostForTest(*ep) == "fleet-door"
	})
	// alice's home: this machine, its agent relaying to a home sshd
	homeAddr, homeKey := doorHomeSSHD(t, dcaPub, "alice")
	agentSetEntryTarget(t, homeAddr)
	host, _ := startSSHRelayAgent(t, h, "mac-c", testSSHD(t))
	if err := h.Srv.Store.SetEntryHostKey(host, homeKey, now); err != nil {
		t.Fatal(err)
	}
	if _, err := h.Srv.Store.SetEntryHome(store.EntryHome{Person: "gh:alice", Machine: host, Login: "alice", SetBy: "t", SetAt: now}); err != nil {
		t.Fatal(err)
	}
	keyOf := func(person, name string) ssh.Signer {
		_, priv, _ := ed25519.GenerateKey(rand.Reader)
		s, _ := ssh.NewSignerFromKey(priv)
		pk := s.PublicKey()
		b64 := strings.Fields(string(ssh.MarshalAuthorizedKey(pk)))[1]
		if _, _, _, err := h.Srv.Store.AddEntryKey(store.EntryKey{ID: "k-" + name, Person: person, FP: ssh.FingerprintSHA256(pk),
			Type: pk.Type(), B64: b64, Name: name, Created: now}); err != nil {
			t.Fatal(err)
		}
		return s
	}
	alice, bob := keyOf("gh:alice", "alice-phone"), keyOf("gh:bob", "bob-phone")

	// the door's own SSH server
	_, dk, _ := ed25519.GenerateKey(rand.Reader)
	dhost, _ := door.NewHostKey(dk)
	audit := &syncBuf{b: &bytes.Buffer{}}
	d, err := door.New(door.Config{Hub: h.HTTP.URL, Token: h.Tokens["door"], HostKey: dhost, Audit: audit})
	if err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go d.Serve(ctx, ln)
	waitFor(t, 5*time.Second, "the door's book", func() bool { return d.Homes() == 1 })

	login := func(user string, key ssh.Signer) (string, error) {
		cl, err := ssh.Dial("tcp", ln.Addr().String(), &ssh.ClientConfig{User: user, Auth: []ssh.AuthMethod{ssh.PublicKeys(key)},
			HostKeyCallback: ssh.FixedHostKey(dhostPub(dhost)), Timeout: 10 * time.Second})
		if err != nil {
			return "", err
		}
		defer cl.Close()
		s, err := cl.NewSession()
		if err != nil {
			return "", err
		}
		out, err := s.CombinedOutput("hostname")
		return string(out), err
	}
	out, err := login("alice", alice)
	if err != nil || out != "home-of-alice" {
		t.Fatalf("alice through the door: %q %v\naudit: %s", out, err, audit.String())
	}
	if _, err := login("alice", bob); err == nil {
		t.Fatal("bob's key as alice went through")
	}
	if _, err := login("bob", bob); err == nil {
		t.Fatal("bob, whose home the book does not take, went through")
	}
	if a := audit.String(); !strings.Contains(a, `"result":"home"`) || !strings.Contains(a, `"home":"alice@`+host+`"`) {
		t.Fatalf("audit: %s", audit.String())
	}
}

func dhostPub(k door.HostKey) ssh.PublicKey {
	pk, _, _, _, _ := ssh.ParseAuthorizedKey([]byte(door.PublicKeyLine(k)))
	return pk
}

func agentSetEntryTarget(t *testing.T, addr string) {
	agent.SetEntryRelayTargetForTest(addr)
	t.Cleanup(func() { agent.SetEntryRelayTargetForTest("") })
}

// syncBuf is a bytes.Buffer the door's goroutines may write together.
type syncBuf struct {
	mu sync.Mutex
	b  *bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) { s.mu.Lock(); defer s.mu.Unlock(); return s.b.Write(p) }

func (s *syncBuf) String() string { s.mu.Lock(); defer s.mu.Unlock(); return s.b.String() }
