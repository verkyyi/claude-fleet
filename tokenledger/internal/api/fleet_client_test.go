package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
)

// The client lease (claude-fleet#1715): one person, one connected client.

func postClient(t *testing.T, h *harness, auth func(http.Header), body ClientLeaseRequest) (int, ClientLeaseResponse, string) {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, h.http.URL+control.ClientPath, bytes.NewReader(b))
	if auth != nil {
		auth(req.Header)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var raw bytes.Buffer
	raw.ReadFrom(resp.Body)
	var out ClientLeaseResponse
	_ = json.Unmarshal(raw.Bytes(), &out)
	return resp.StatusCode, out, raw.String()
}

// Same person twice → the second takes over and the first reads taken_over
// (with the taker's device) on its next renewal; taking it back flips them; a
// different person is untouched; a proof made for another door is refused.
func TestFleetClientLeaseByCertificate(t *testing.T) {
	h := newFleetHarness(t)
	k := newCertKit(t)
	h.srv.SSHCA = sshca.New(k.ca)
	now := time.Now()
	h.srv.Store.AdoptPrincipal("wx-alice", "alice", "Alice", now)
	h.srv.Store.AdoptPrincipal("wx-bob", "bob", "Bob", now)
	alice := k.cert(t, "wecom:wx-alice", []string{"alice"}, now.Add(-time.Minute), now.Add(12*time.Hour))
	bob := k.cert(t, "wecom:wx-bob", []string{"bob"}, now.Add(-time.Minute), now.Add(12*time.Hour))
	as := func(c *ssh.Certificate, r ClientLeaseRequest) ClientLeaseRequest {
		r.Cert, r.TS = string(ssh.MarshalAuthorizedKey(c)), time.Now().Unix()
		r.Sig = sshsig(t, k.user, control.ClientSigNamespace, []byte(control.ClientSigMessage(r.TS)))
		return r
	}
	call := func(c *ssh.Certificate, r ClientLeaseRequest) ClientLeaseResponse {
		t.Helper()
		code, out, raw := postClient(t, h, nil, as(c, r))
		if code != 200 {
			t.Fatalf("%s: HTTP %d %s", r.Action, code, raw)
		}
		return out
	}

	mac := call(alice, ClientLeaseRequest{Action: "acquire", Device: "MacBook", Terminal: "iTerm2"})
	if mac.State != "active" || mac.Lease == nil || mac.Lease.ID == "" || mac.TookOver != nil {
		t.Fatalf("first acquire = %+v, want an active lease and no takeover", mac)
	}
	if mac.RenewSecs != 15 || mac.TTLSecs != 45 {
		t.Fatalf("renew/ttl = %d/%d, want 15/45", mac.RenewSecs, mac.TTLSecs)
	}
	if r := call(alice, ClientLeaseRequest{Action: "renew", Lease: mac.Lease.ID}); r.State != "active" {
		t.Fatalf("renewing the only lease = %+v", r)
	}
	b := call(bob, ClientLeaseRequest{Action: "acquire", Device: "bob-laptop"})
	if b.TookOver != nil {
		t.Fatalf("bob's acquire took over %+v — another person's lease is not his", b.TookOver)
	}

	phone := call(alice, ClientLeaseRequest{Action: "acquire", Device: "iPhone", Terminal: "Termius"})
	if phone.State != "active" || phone.TookOver == nil || phone.TookOver.Device != "MacBook" {
		t.Fatalf("second acquire = %+v, want active + took_over MacBook", phone)
	}
	r := call(alice, ClientLeaseRequest{Action: "renew", Lease: mac.Lease.ID})
	if r.State != "taken_over" || r.By == nil || r.By.Device != "iPhone" {
		t.Fatalf("the MacBook's renewal = %+v, want taken_over by iPhone", r)
	}
	if g := call(alice, ClientLeaseRequest{Action: "get"}); g.Lease == nil || g.Lease.Device != "iPhone" {
		t.Fatalf("get = %+v, want the iPhone's lease", g)
	}
	if r := call(bob, ClientLeaseRequest{Action: "renew", Lease: b.Lease.ID}); r.State != "active" {
		t.Fatalf("bob's renewal after alice's takeover = %+v", r)
	}

	// Enter on the MacBook's standby screen: an acquire carrying its old id.
	back := call(alice, ClientLeaseRequest{Action: "acquire", Lease: mac.Lease.ID, Device: "MacBook"})
	if back.TookOver == nil || back.TookOver.Device != "iPhone" {
		t.Fatalf("taking it back = %+v, want took_over iPhone", back)
	}
	if r := call(alice, ClientLeaseRequest{Action: "renew", Lease: phone.Lease.ID}); r.State != "taken_over" || r.By.Device != "MacBook" {
		t.Fatalf("the iPhone's renewal = %+v, want taken_over by MacBook", r)
	}
	// The same server opening again keeps its lease — no takeover of itself.
	again := call(alice, ClientLeaseRequest{Action: "acquire", Lease: back.Lease.ID, Device: "MacBook"})
	if again.TookOver != nil || again.Lease.ID != back.Lease.ID {
		t.Fatalf("re-acquire with the current id = %+v, want the same lease, no takeover", again)
	}
	if r := call(alice, ClientLeaseRequest{Action: "release", Lease: back.Lease.ID}); r.State != "released" {
		t.Fatalf("release = %+v", r)
	}
	if g := call(alice, ClientLeaseRequest{Action: "get"}); g.State != "none" {
		t.Fatalf("get after release = %+v, want none", g)
	}

	// A proof made for another door, or none at all, is refused.
	bad := as(alice, ClientLeaseRequest{Action: "acquire"})
	bad.Sig = sshsig(t, k.user, control.SessionsSigNamespace, []byte(control.ClientSigMessage(bad.TS)))
	if code, _, _ := postClient(t, h, nil, bad); code != http.StatusUnauthorized {
		t.Fatalf("a sessions-namespace signature: HTTP %d, want 401", code)
	}
	if code, _, _ := postClient(t, h, nil, ClientLeaseRequest{Action: "acquire"}); code != http.StatusUnauthorized {
		t.Fatalf("no proof: HTTP %d, want 401", code)
	}
}

// A lapsed lease is not taken over: the next client gets a fresh one with no
// took_over, and the sleeper's renewal on waking reads taken_over. A lapsed
// lease nobody replaced carries on; an id the hub forgot (a restart) is
// re-adopted while nobody else holds one.
func TestClientLeaseTableExpiry(t *testing.T) {
	var tb clientLeaseTable
	t0 := time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)
	mac := tb.acquire("p:a", ClientLeaseRequest{Device: "MacBook"}, t0)

	// Asleep a minute, nobody came: its renewal simply carries on.
	if r := tb.renew("p:a", ClientLeaseRequest{Lease: mac.Lease.ID}, t0.Add(time.Minute)); r.State != "active" {
		t.Fatalf("a lapsed lease nobody replaced = %+v, want active", r)
	}
	// Asleep again past the TTL; the phone connects.
	t1 := t0.Add(2 * time.Minute)
	ph := tb.acquire("p:a", ClientLeaseRequest{Device: "iPhone"}, t1)
	if ph.TookOver != nil {
		t.Fatalf("an acquire after the lease lapsed took over %+v — that is not a takeover", ph.TookOver)
	}
	if r := tb.renew("p:a", ClientLeaseRequest{Lease: mac.Lease.ID}, t1.Add(time.Second)); r.State != "taken_over" || r.By.Device != "iPhone" {
		t.Fatalf("the sleeper waking = %+v, want taken_over by iPhone", r)
	}
	if r := tb.get("p:a", t1.Add(ClientLeaseTTL+time.Second)); r.State != "none" {
		t.Fatalf("get after the phone's lease lapsed = %+v, want none", r)
	}
	// A restart: the table is empty, the phone renews its id — re-adopted.
	var fresh clientLeaseTable
	if r := fresh.renew("p:a", ClientLeaseRequest{Lease: ph.Lease.ID, Device: "iPhone"}, t1); r.State != "active" || r.Lease.ID != ph.Lease.ID {
		t.Fatalf("a renewal the hub forgot = %+v, want the same id active", r)
	}
	// …but not while another client holds a live one.
	if r := fresh.renew("p:a", ClientLeaseRequest{Lease: "stale"}, t1); r.State != "taken_over" || r.By.Device != "iPhone" {
		t.Fatalf("an unknown id beside a live lease = %+v, want taken_over", r)
	}
	// The device a client reports is held to a short printable word.
	l := tb.acquire("p:b", ClientLeaseRequest{Device: "evil\x1b[2Jname"}, t1)
	if l.Lease.Device != "evil[2Jname" {
		t.Fatalf("device = %q, want control bytes dropped", l.Lease.Device)
	}
	if l := tb.acquire("p:c", ClientLeaseRequest{}, t1); l.Lease.Device != "未知设备" {
		t.Fatalf("no device = %q, want 未知设备", l.Lease.Device)
	}
}

// Where the owner is (claude-fleet#1716, C6): a node reads, with its own
// token, the client its OWNER holds right now — every field a client reported,
// the unknown words dropped — and a node of another person reads none; a
// takeover is what the next read answers.
func TestNodeClientReadsOwnersLease(t *testing.T) {
	h, _, n := peerHarness(t)
	read := func(tok string) (int, ClientLeaseResponse) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodGet, h.http.URL+"/v1/node/client", nil)
		if tok != "" {
			req.Header.Set("Authorization", "Bearer "+tok)
		}
		res, err := h.http.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		var out ClientLeaseResponse
		_ = json.NewDecoder(res.Body).Decode(&out)
		return res.StatusCode, out
	}
	if code, out := read(n["alice4"].token); code != 200 || out.State != "none" {
		t.Fatalf("nobody connected: HTTP %d %+v", code, out)
	}
	alice := clientLeaseKey(sshRelayIdentity{Principal: "Alice"})
	now := time.Now()
	h.srv.clientLeases.acquire(alice, ClientLeaseRequest{Device: "MacBook", OS: "macOS", Terminal: "iTerm2 3.6.1",
		Via: "local", Host: "MacBook", Caps: []string{"open_url", "show_file", "notify", "iterm2", "rm -rf"}}, now)
	code, out := read(n["alice4"].token)
	if code != 200 || out.State != "active" || out.Lease == nil {
		t.Fatalf("alice on m4: HTTP %d %+v", code, out)
	}
	l := out.Lease
	if l.Device != "MacBook" || l.OS != "macOS" || l.Terminal != "iTerm2 3.6.1" || l.Via != "local" || l.Host != "MacBook" {
		t.Fatalf("fields: %+v", l)
	}
	if got := strings.Join(l.Caps, ","); got != "open_url,show_file,notify,iterm2" {
		t.Fatalf("caps: %q", got)
	}
	if _, o := read(n["alice5"].token); o.Lease == nil || o.Lease.ID != l.ID {
		t.Fatalf("alice's other machine reads the same lease: %+v", o)
	}
	if _, o := read(n["bob4"].token); o.State != "none" {
		t.Fatalf("bob's node must not read alice's client: %+v", o)
	}
	// The phone takes over: the next read follows.
	h.srv.clientLeases.acquire(alice, ClientLeaseRequest{Device: "verkyyi-iphone", OS: "iOS", Terminal: "Termius",
		Via: "tailnet", Host: "m5", Caps: []string{"link"}}, now.Add(time.Second))
	if _, o := read(n["alice4"].token); o.Lease == nil || o.Lease.Device != "verkyyi-iphone" || o.Lease.Host != "m5" || o.Lease.Via != "tailnet" {
		t.Fatalf("after takeover: %+v", o.Lease)
	}
	// A bad via is dropped, not stored.
	h.srv.clientLeases.acquire(alice, ClientLeaseRequest{Device: "x", Via: "carrier-pigeon"}, now.Add(2*time.Second))
	if _, o := read(n["alice4"].token); o.Lease == nil || o.Lease.Via != "" {
		t.Fatalf("bad via kept: %+v", o.Lease)
	}
	// The operator's own login (owned by nobody) reads the operator's lease.
	h.srv.clientLeases.acquire("operator", ClientLeaseRequest{Device: "op-mac"}, now)
	if _, o := read(n["verk4"].token); o.Lease == nil || o.Lease.Device != "op-mac" {
		t.Fatalf("operator's node: %+v", o.Lease)
	}
	if code, _ := read(""); code != 401 {
		t.Fatalf("no token: HTTP %d", code)
	}
}
