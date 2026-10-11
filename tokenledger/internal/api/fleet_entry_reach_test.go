package api

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"net"
	"net/http"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
)

// Can the outside reach a home machine's entry port (claude-fleet#3072,
// EPIC #3067 C6).

// reachSSHD is a real sshd on 127.0.0.1 showing a fresh ed25519 host key; it
// takes no login. It returns the port and the key.
func reachSSHD(t *testing.T) (int, ssh.PublicKey) {
	t.Helper()
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	signer, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		t.Fatal(err)
	}
	cfg := &ssh.ServerConfig{PublicKeyCallback: func(ssh.ConnMetadata, ssh.PublicKey) (*ssh.Permissions, error) {
		return nil, net.ErrClosed
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
				_, _, _, _ = ssh.NewServerConn(c, cfg)
			}()
		}
	}()
	return ln.Addr().(*net.TCPAddr).Port, signer.PublicKey()
}

func reachKey(t *testing.T) ssh.PublicKey {
	t.Helper()
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	k, _ := ssh.NewPublicKey(pub)
	return k
}

// listenWith is a 127.0.0.1 listener that does serve(c) with each
// connection.
func listenWith(t *testing.T, serve func(net.Conn)) int {
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
			go serve(c)
		}
	}()
	return ln.Addr().(*net.TCPAddr).Port
}

func closedPort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	p := ln.Addr().(*net.TCPAddr).Port
	ln.Close()
	return p
}

// The completion criterion's probe half, against real listeners: the entry's
// own key answers; another key is 钥匙不符 and does not count; the three
// failures each have their reason — timeout, refused, host key — and a
// listener that is no sshd is not one.
func TestEntryReachProbe(t *testing.T) {
	old := entryProbeTimeout
	entryProbeTimeout = 700 * time.Millisecond
	t.Cleanup(func() { entryProbeTimeout = old })
	ctx := context.Background()
	port, key := reachSSHD(t)

	if why := entryProbeSSH(ctx, "127.0.0.1", port, key); why != "" {
		t.Fatalf("the entry's own host key: %q, want reachable", why)
	}
	if why := entryProbeSSH(ctx, "127.0.0.1", port, reachKey(t)); why != control.ReachHostKey {
		t.Fatalf("an sshd with another host key: %q, want %q", why, control.ReachHostKey)
	}
	if why := entryProbeSSH(ctx, "127.0.0.1", closedPort(t), key); why != control.ReachRefused {
		t.Fatalf("a closed port: %q, want %q", why, control.ReachRefused)
	}
	silent := listenWith(t, func(c net.Conn) { time.Sleep(3 * time.Second); c.Close() })
	if why := entryProbeSSH(ctx, "127.0.0.1", silent, key); why != control.ReachTimeout {
		t.Fatalf("a port that never answers: %q, want %q", why, control.ReachTimeout)
	}
	web := listenWith(t, func(c net.Conn) { c.Write([]byte("HTTP/1.1 400 Bad Request\r\n\r\n")); c.Close() })
	if why := entryProbeSSH(ctx, "127.0.0.1", web, key); why != control.ReachNotSSH {
		t.Fatalf("a web server on the port: %q, want %q", why, control.ReachNotSSH)
	}
}

// The hub dials only public unicast addresses: a report cannot point it at a
// private, loopback, link-local, carrier-NAT or documentation one. Carrier
// NAT is said when the router's outside address is not public, or differs
// from where the hub saw the machine come from.
func TestEntryReachCandidates(t *testing.T) {
	ip := netip.MustParseAddr
	rep := control.EntryReachReport{Port: 22022, Listening: true,
		V6: []string{"fd00::5", "fe80::1", "::1", "2001:db8::1", "2408:8207:1:2::9", "bogus", "1.2.3.4"}}
	got, np := entryReachCandidates(rep, ip("203.0.114.7"), true)
	var s []string
	for _, c := range got {
		s = append(s, netip.AddrPortFrom(c.addr, uint16(c.port)).String()+"/"+c.via)
	}
	if strings.Join(s, " ") != "203.0.114.7:22022/source [2408:8207:1:2::9]:22022/ipv6" || np != "" {
		t.Fatalf("candidates %v (%q), want the public source and the one global IPv6", s, np)
	}
	for _, src := range []string{"10.0.0.5", "127.0.0.1", "100.100.1.1", "192.168.1.249"} {
		if got, _ := entryReachCandidates(control.EntryReachReport{Port: 22022}, ip(src), false); len(got) != 0 {
			t.Fatalf("source %s was dialled: %v", src, got)
		}
	}
	// the router forwarded 22022 to outside port 40022 on the same address
	rep = control.EntryReachReport{Port: 22022, PortMap: &control.EntryPortMap{Method: "natpmp", ExternalIP: "203.0.114.7", ExternalPort: 40022}}
	if got, np := entryReachCandidates(rep, ip("203.0.114.7"), true); len(got) != 1 || got[0].port != 40022 || np != "" {
		t.Fatalf("a mapped port: %+v %q, want 203.0.114.7:40022 only", got, np)
	}
	// the router already forwards :22023 (the machine's public= route): the
	// source and the route's own address are knocked on there
	pub := control.EntryReachReport{Port: 22022, PublicHost: "gw.example", PublicPort: 22023}
	got, _ = entryReachCandidates(pub, ip("23.119.126.213"), true, ip("23.119.126.213"), ip("23.119.126.214"), ip("10.1.1.1"))
	s = nil
	for _, c := range got {
		s = append(s, netip.AddrPortFrom(c.addr, uint16(c.port)).String()+"/"+c.via)
	}
	if strings.Join(s, " ") != "23.119.126.213:22023/source 23.119.126.214:22023/route" {
		t.Fatalf("public route: %v, want the source and the route's other public address on :22023", s)
	}
	// the router's outside address is the carrier's
	rep.PortMap.ExternalIP = "100.77.0.3"
	if got, np := entryReachCandidates(rep, ip("203.0.114.7"), true); np != "cgnat" || len(got) != 1 || got[0].port != 22022 {
		t.Fatalf("router outside 100.77.0.3: %+v %q, want cgnat and the source on 22022", got, np)
	}
	// public, but not the address the machine reaches the hub from
	rep.PortMap.ExternalIP = "198.51.99.1"
	if _, np := entryReachCandidates(rep, ip("203.0.114.7"), true); np != "cgnat" {
		t.Fatalf("router outside ≠ source: %q, want cgnat", np)
	}
	// seen through the ingress coming from carrier space
	if _, np := entryReachCandidates(control.EntryReachReport{Port: 22022}, ip("100.80.1.1"), true); np != "cgnat" {
		t.Fatalf("source 100.80.1.1 via the ingress: %q, want cgnat", np)
	}
	// …but a direct peer there is as likely the tailnet: nobody can tell
	if _, np := entryReachCandidates(control.EntryReachReport{Port: 22022}, ip("100.80.1.1"), false); np != "" {
		t.Fatalf("a direct tailnet peer: %q, want no verdict", np)
	}
}

func reachPost(t *testing.T, h *harness, tok string, rep control.EntryReachReport, xff string) (int, control.EntryReachVerdict, string) {
	t.Helper()
	code, raw := entryCall(t, h, http.MethodPost, control.EntryReachNodePath, func(hd http.Header) {
		asNode(tok)(hd)
		if xff != "" {
			hd.Set("X-Forwarded-For", xff)
		}
	}, rep)
	var v control.EntryReachVerdict
	_ = json.Unmarshal([]byte(raw), &v)
	return code, v, raw
}

func reachKeyLine(k ssh.PublicKey) string {
	return strings.TrimSpace(string(ssh.MarshalAuthorizedKey(k)))
}

// BREAK-IT entry-public-unreachable: an address that resolves but nothing
// answers at is never in reachable(machine) — end to end through the
// handler, with real dials: the machine's live entry sshd counts, the same
// machine's IPv6 whose port is closed does not, and neither counts once the
// check is older than EntryReachFresh.
func TestEntryReachUnreachableNotRecorded(t *testing.T) {
	h := entryHarness(t)
	_, tok := rootNode(t, h, "root5", "macmini", control.CapEntryKeys)
	old, oldT := entryDialable, entryProbeTimeout
	discard := netip.MustParsePrefix("100::/64") // RFC 6666: routes nowhere
	entryDialable = func(a netip.Addr) bool { return a.IsLoopback() || discard.Contains(a) || entryPublicAddr(a) }
	entryProbeTimeout = 2 * time.Second
	t.Cleanup(func() { entryDialable, entryProbeTimeout = old, oldT })
	port, key := reachSSHD(t)
	if d := os.Getenv("FLEET_DRILL_ENTRY"); d != "" {
		// BREAK-IT's drill: the real entry sshd (OpenSSH, the entry's own config)
		// on 127.0.0.1 — "<port> <host key .pub>".
		f := strings.Fields(d)
		b, err := os.ReadFile(f[1])
		if err != nil {
			t.Fatal(err)
		}
		if key, _, _, _, err = ssh.ParseAuthorizedKey(b); err != nil {
			t.Fatal(err)
		}
		port, _ = strconv.Atoi(f[0])
	}
	// httptest's peer is 127.0.0.1: the source candidate is the live sshd.
	rep := control.EntryReachReport{Port: port, HostKey: reachKeyLine(key), Listening: true,
		V6: []string{"100::1"}} // resolves, routes nowhere
	code, v, raw := reachPost(t, h, tok, rep, "")
	if code != 200 {
		t.Fatalf("report: HTTP %d %s", code, raw)
	}
	if len(v.Addrs) != 2 || !v.Addrs[0].Reachable || v.Addrs[0].Addr != "127.0.0.1" || v.Addrs[1].Reachable ||
		(v.Addrs[1].Reason != control.ReachTimeout && v.Addrs[1].Reason != control.ReachNoRoute) {
		t.Fatalf("verdict %s, want 127.0.0.1 reachable and 100::1 not (timeout / unreachable)", raw)
	}
	now := time.Now()
	got, err := h.srv.EntryReachable("macmini", now)
	if err != nil || len(got) != 1 || got[0].Addr != "127.0.0.1" || got[0].Port != port || got[0].Family != "ipv4" {
		t.Fatalf("reachable(macmini) = %+v %v, want only 127.0.0.1:%d", got, err, port)
	}
	if got, _ := h.srv.EntryReachable("macmini.local", now); len(got) != 1 {
		t.Fatalf("reachable by the machine's longer name: %+v", got)
	}
	if got, _ := h.srv.EntryReachable("macmini", now.Add(EntryReachFresh+time.Minute)); len(got) != 0 {
		t.Fatalf("a stale check still counts: %+v", got)
	}
	// the key no longer matches (the address now reaches another box): it drops out
	h.srv.entryReachAt.Delete("macmini")
	rep.HostKey = reachKeyLine(reachKey(t))
	if _, v, raw = reachPost(t, h, tok, rep, ""); len(v.Addrs) == 0 || v.Addrs[0].Reason != control.ReachHostKey ||
		v.Addrs[0].LastOK == nil {
		t.Fatalf("after the key changed: %s, want 钥匙不符 with the last success kept", raw)
	}
	if got, _ := h.srv.EntryReachable("macmini", time.Now()); len(got) != 0 {
		t.Fatalf("a host-key mismatch counts as reachable: %+v", got)
	}
	// a second report inside the gap is answered from the last check, no dial
	_, v, _ = reachPost(t, h, tok, rep, "")
	if !v.Throttled {
		t.Fatalf("a report inside %v was checked again", entryReachGap)
	}
	// nothing listening: nothing is dialled, nothing counts
	h.srv.entryReachAt.Delete("macmini")
	if _, v, raw = reachPost(t, h, tok, control.EntryReachReport{Port: port, Listening: false}, ""); len(v.Addrs) != 0 {
		t.Fatalf("not listening yet dialled: %s", raw)
	}
}

// IPv6 only: a home with no public IPv4 (carrier NAT, seen through the
// ingress) but a global IPv6 its entry answers on is reachable — on that
// address alone — and the verdict still says it has no public IPv4.
func TestEntryReachIPv6Only(t *testing.T) {
	h := entryHarness(t)
	_, tok := rootNode(t, h, "root5", "macmini", control.CapEntryKeys)
	key := reachKey(t)
	old := entryProbe
	entryProbe = func(_ context.Context, addr string, port int, want ssh.PublicKey) string {
		if addr == "2408:8207:1:2::9" && port == 22022 && string(want.Marshal()) == string(key.Marshal()) {
			return ""
		}
		return control.ReachTimeout
	}
	t.Cleanup(func() { entryProbe = old })
	rep := control.EntryReachReport{Port: 22022, HostKey: reachKeyLine(key), Listening: true,
		V6: []string{"2408:8207:1:2::9"}, PortMap: &control.EntryPortMap{Method: "upnp", ExternalIP: "100.71.4.2", ExternalPort: 22022}}
	code, v, raw := reachPost(t, h, tok, rep, "100.71.4.2")
	if code != 200 || v.NoPublic != "cgnat" || v.Source != "100.71.4.2" {
		t.Fatalf("verdict %d %s, want cgnat seen from 100.71.4.2", code, raw)
	}
	got, _ := h.srv.EntryReachable("macmini", time.Now())
	if len(got) != 1 || got[0].Family != "ipv6" || got[0].Addr != "2408:8207:1:2::9" {
		t.Fatalf("reachable = %+v, want the IPv6 address alone", got)
	}
}

// Only the machine's node program reports, only with the door on, and the
// host key must be one.
func TestEntryReachDoor(t *testing.T) {
	h := entryHarness(t)
	_, tok := rootNode(t, h, "root5", "macmini", control.CapEntryKeys)
	rep := control.EntryReachReport{Port: 22022, HostKey: "not a key", Listening: true}
	if code, _, raw := reachPost(t, h, tok, rep, ""); code != http.StatusBadRequest {
		t.Fatalf("a bad host key: HTTP %d %s", code, raw)
	}
	rep.Port = 70000
	if code, _, _ := reachPost(t, h, tok, rep, ""); code != http.StatusBadRequest {
		t.Fatalf("port 70000: HTTP %d", code)
	}
	if code, _, _ := reachPost(t, h, "nope", control.EntryReachReport{Port: 22022}, ""); code != http.StatusUnauthorized {
		t.Fatalf("an unknown token: HTTP %d", code)
	}
	if err := h.srv.Store.SetFleetSetting(EntryKey, "off", time.Now()); err != nil {
		t.Fatal(err)
	}
	if code, _, _ := reachPost(t, h, tok, control.EntryReachReport{Port: 22022}, ""); code != http.StatusNotFound {
		t.Fatalf("door off: HTTP %d", code)
	}
}
