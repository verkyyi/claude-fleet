package e2e

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"fmt"
	"net"
	"net/http"
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
	// as a home whose entry sshd also carries a host certificate (the "host
	// key never changes" work): a client that asks for certificates first gets one
	_, hcak, _ := ed25519.GenerateKey(rand.Reader)
	hca, _ := ssh.NewSignerFromKey(hcak)
	hc := &ssh.Certificate{Key: signer.PublicKey(), CertType: ssh.HostCert, KeyId: "host:home",
		ValidPrincipals: []string{"home"}, ValidBefore: ssh.CertTimeInfinity}
	if err := hc.SignCert(rand.Reader, hca); err != nil {
		t.Fatal(err)
	}
	if cs, err := ssh.NewCertSigner(hc, signer); err == nil {
		cfg.AddHostKey(cs)
	}
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
// doorE2E is one door in front of one hub, alice's home a machine whose
// agent relays to a home sshd: login(user, key) runs "hostname" through it.
type doorE2E struct {
	h          *harness
	host       string
	dca        *sshca.CA
	alice, bob ssh.Signer
	audit      *syncBuf
	login      func(user string, key ssh.Signer) (string, error)
}

// newDoorE2E builds it; tune adjusts the door's config, and a door with a
// RelayURL serves its relay listener on relayAddr.
func newDoorE2E(t *testing.T, relayAddr string, tune func(*door.Config)) doorE2E {
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
	dcfg := door.Config{Hub: h.HTTP.URL, Token: h.Tokens["door"], HostKey: dhost, Audit: audit}
	if tune != nil {
		tune(&dcfg)
	}
	d, err := door.New(dcfg)
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
	if relayAddr != "" {
		rl, err := net.Listen("tcp", relayAddr)
		if err != nil {
			t.Fatal(err)
		}
		hs := &http.Server{Handler: d.RelayHandler()}
		t.Cleanup(func() { hs.Close() })
		go hs.Serve(rl)
	}
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
	return doorE2E{h: h, host: host, dca: dca, alice: alice, bob: bob, audit: audit, login: login}
}

func TestDoorTakesEachPersonHome(t *testing.T) {
	r := newDoorE2E(t, "", nil)
	h, host, dca, alice, bob, audit, login := r.h, r.host, r.dca, r.alice, r.bob, r.audit, r.login
	now := time.Now()
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
	// the hub's pin for the home is wrong: refused, and the client is told why
	if err := h.Srv.Store.SetEntryHostKey(host, dca.PublicKey(), now); err != nil {
		t.Fatal(err)
	}
	if out, _ := login("alice", alice); !strings.Contains(out, "fleet 门：接不到你的家") || !strings.Contains(out, "host key") {
		t.Fatalf("a refused hop told the client %q", out)
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

// The US door (JXBE): a door with its own relay listener offers it on every
// stream home, and the home's agent (CapRelayVia) dials its data half there
// instead of through the hub — the login works and the door records via
// "door". A listener the agent cannot reach falls back to the hub within the
// door's wait: still home, via "hub".
func TestDoorHomeDialsBackToTheDoor(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	relayAddr := ln.Addr().String()
	ln.Close()
	r := newDoorE2E(t, relayAddr, func(c *door.Config) { c.RelayURL = "ws://" + relayAddr + control.DoorRelayPath })
	out, err := r.login("alice", r.alice)
	if err != nil || out != "home-of-alice" {
		t.Fatalf("alice through the door's own relay: %q %v\naudit: %s", out, err, r.audit.String())
	}
	if a := r.audit.String(); !strings.Contains(a, `"via":"door"`) {
		t.Fatalf("the home's bytes did not come straight to the door: %s", a)
	}
	if _, err := r.login("alice", r.bob); err == nil {
		t.Fatal("bob's key as alice went through")
	}

	// nothing listens where the door says it does: the hub carries it
	dead, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	deadAddr := dead.Addr().String()
	dead.Close()
	r2 := newDoorE2E(t, "", func(c *door.Config) {
		c.RelayURL = "ws://" + deadAddr + control.DoorRelayPath
		c.ViaWait = 2 * time.Second
	})
	out, err = r2.login("alice", r2.alice)
	if err != nil || out != "home-of-alice" {
		t.Fatalf("alice when the home cannot dial back: %q %v\naudit: %s", out, err, r2.audit.String())
	}
	if a := r2.audit.String(); !strings.Contains(a, `"via":"hub"`) {
		t.Fatalf("the fallback did not go through the hub: %s", a)
	}
}
