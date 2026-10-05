package api

import (
	"bytes"
	"encoding/json"
	"net/http"
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
