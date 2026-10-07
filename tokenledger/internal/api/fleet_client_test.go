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

	// A second client of the same person: both active, nobody to standby.
	phone := call(alice, ClientLeaseRequest{Action: "acquire", Device: "iPhone", Terminal: "Termius"})
	if phone.State != "active" || phone.TookOver != nil || phone.Evicted != nil || phone.Lease.ID == mac.Lease.ID {
		t.Fatalf("second acquire = %+v, want a lease of its own, nobody pushed off", phone)
	}
	if len(phone.Clients) != 2 || phone.Primary != phone.Lease.ID {
		t.Fatalf("second acquire lists %+v primary %q, want both, the iPhone primary (just opened)", phone.Clients, phone.Primary)
	}
	if r := call(alice, ClientLeaseRequest{Action: "renew", Lease: mac.Lease.ID}); r.State != "active" {
		t.Fatalf("the MacBook's renewal = %+v, want still active", r)
	}
	if g := call(alice, ClientLeaseRequest{Action: "get"}); g.Lease == nil || g.Lease.Device != "iPhone" || len(g.Clients) != 2 {
		t.Fatalf("get = %+v, want the iPhone as the lease, both listed", g)
	}
	// Typing on the MacBook makes it the primary.
	time.Sleep(1100 * time.Millisecond) // input is kept to the second
	if r := call(alice, ClientLeaseRequest{Action: "input", Lease: mac.Lease.ID}); r.State != "active" || r.Primary != mac.Lease.ID {
		t.Fatalf("input on the MacBook = %+v, want it primary", r)
	}
	if g := call(alice, ClientLeaseRequest{Action: "get"}); g.Lease == nil || g.Lease.Device != "MacBook" {
		t.Fatalf("get after typing on the MacBook = %+v", g.Lease)
	}
	if r := call(bob, ClientLeaseRequest{Action: "renew", Lease: b.Lease.ID}); r.State != "active" || len(r.Clients) != 1 {
		t.Fatalf("bob's renewal = %+v, want his one client only", r)
	}
	// list: every client, no lease handed out, no key.
	if l := call(alice, ClientLeaseRequest{Action: "list"}); l.Lease != nil || l.ActionKey != "" || len(l.Clients) != 2 {
		t.Fatalf("list = %+v", l)
	}
	// The same server opening again keeps its lease.
	again := call(alice, ClientLeaseRequest{Action: "acquire", Lease: mac.Lease.ID, Device: "MacBook"})
	if again.Lease.ID != mac.Lease.ID || len(again.Clients) != 2 {
		t.Fatalf("re-acquire with its own id = %+v, want the same lease", again)
	}
	// Disconnect the iPhone from the MacBook: it reads taken_over/revoked, and
	// bob cannot disconnect alice's.
	if code, _, _ := postClient(t, h, nil, as(bob, ClientLeaseRequest{Action: "revoke", Target: phone.Lease.ID})); code != http.StatusNotFound {
		t.Fatalf("bob revoking alice's client: HTTP %d, want 404", code)
	}
	if r := call(alice, ClientLeaseRequest{Action: "revoke", Target: phone.Lease.ID}); r.State != "revoked" || len(r.Clients) != 1 {
		t.Fatalf("revoke = %+v", r)
	}
	if r := call(alice, ClientLeaseRequest{Action: "renew", Lease: phone.Lease.ID}); r.State != "taken_over" || r.Reason != "revoked" {
		t.Fatalf("the iPhone after revoke = %+v, want taken_over revoked", r)
	}
	if r := call(alice, ClientLeaseRequest{Action: "release", Lease: mac.Lease.ID}); r.State != "released" {
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

// Several clients at once (claude-fleet#1932): two active side by side; the
// primary follows the last input; one idle past FLEET_CLIENT_IDLE is not
// primary while another is in use; the fifth asks the one used least
// recently to leave; a lapsed lease carries on unless it was asked to leave;
// an id the hub forgot is re-adopted while there is room.
func TestClientLeaseTableSeveral(t *testing.T) {
	var tb clientLeaseTable
	t0 := time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)
	at := func(s int) time.Time { return t0.Add(time.Duration(s) * time.Second) }
	mac := tb.acquire("p:a", ClientLeaseRequest{Device: "MacBook"}, at(0))
	ph := tb.acquire("p:a", ClientLeaseRequest{Device: "iPhone"}, at(1))
	if ph.Evicted != nil || len(ph.Clients) != 2 {
		t.Fatalf("second client = %+v", ph)
	}
	prim := func(now time.Time) string { return tb.get("p:a", now).Lease.Device }
	if p := prim(at(2)); p != "iPhone" {
		t.Fatalf("primary after opening the iPhone = %s", p)
	}
	tb.renew("p:a", ClientLeaseRequest{Lease: mac.Lease.ID, LastInput: at(5).Unix()}, at(6), false)
	if p := prim(at(7)); p != "MacBook" {
		t.Fatalf("primary after typing on the MacBook = %s", p)
	}
	tb.renew("p:a", ClientLeaseRequest{Lease: ph.Lease.ID}, at(8), true)
	if p := prim(at(9)); p != "iPhone" {
		t.Fatalf("primary after tapping the iPhone = %s", p)
	}
	// A renewal with no input moves nothing; a future last_input is held to now.
	tb.renew("p:a", ClientLeaseRequest{Lease: mac.Lease.ID}, at(10), false)
	if p := prim(at(11)); p != "iPhone" {
		t.Fatalf("a plain renewal made the MacBook primary")
	}
	// Idle: the iPhone (last input at 8) sits 11 minutes; the MacBook, typed
	// at 10m, is primary even though… then both idle → latest wins.
	tb.renew("p:a", ClientLeaseRequest{Lease: mac.Lease.ID, LastInput: at(600).Unix()}, at(600), false)
	tb.renew("p:a", ClientLeaseRequest{Lease: ph.Lease.ID}, at(600), false)
	tb.renew("p:a", ClientLeaseRequest{Lease: ph.Lease.ID, LastInput: at(8).Unix()}, at(700), false)
	tb.renew("p:a", ClientLeaseRequest{Lease: mac.Lease.ID}, at(700), false)
	if p := prim(at(701)); p != "MacBook" {
		t.Fatalf("primary = %s, want the MacBook (latest input)", p)
	}
	tb.idle = 5 * time.Minute
	tb.renew("p:a", ClientLeaseRequest{Lease: ph.Lease.ID, LastInput: at(690).Unix()}, at(1000), false)
	tb.renew("p:a", ClientLeaseRequest{Lease: mac.Lease.ID, LastInput: at(980).Unix()}, at(1000), false)
	if p := prim(at(1001)); p != "MacBook" {
		t.Fatalf("primary = %s, want the MacBook (the iPhone idle)", p)
	}
	tb.idle = 0

	// Third and fourth fit; the fifth asks the one used least recently.
	ipad := tb.acquire("p:a", ClientLeaseRequest{Device: "iPad"}, at(1002))
	tb.acquire("p:a", ClientLeaseRequest{Device: "mini"}, at(1003))
	if ipad.Evicted != nil {
		t.Fatalf("the third client evicted %+v", ipad.Evicted)
	}
	fifth := tb.acquire("p:a", ClientLeaseRequest{Device: "work-pc"}, at(1004))
	if fifth.Evicted == nil || fifth.Evicted.Device != "iPhone" || len(fifth.Clients) != 4 {
		t.Fatalf("the fifth = %+v, want the iPhone (used least recently) asked to leave, 4 left", fifth)
	}
	if r := tb.renew("p:a", ClientLeaseRequest{Lease: ph.Lease.ID}, at(1005), false); r.State != "taken_over" || r.Reason != "evicted" || r.By.Device != "work-pc" {
		t.Fatalf("the iPhone's renewal = %+v, want taken_over evicted by work-pc", r)
	}
	// Enter on its screen: back in, the least recently used other one goes.
	back := tb.acquire("p:a", ClientLeaseRequest{Lease: ph.Lease.ID, Device: "iPhone"}, at(1006))
	if back.Evicted == nil || back.Evicted.Device != "MacBook" {
		t.Fatalf("taking it back = %+v, want the MacBook (980) asked to leave", back.Evicted)
	}

	// A lapsed lease nobody asked to leave carries on.
	var tl clientLeaseTable
	m := tl.acquire("p:a", ClientLeaseRequest{Device: "MacBook"}, at(0))
	tl.acquire("p:a", ClientLeaseRequest{Device: "iPhone"}, at(120))
	if r := tl.renew("p:a", ClientLeaseRequest{Lease: m.Lease.ID}, at(180), false); r.State != "active" {
		t.Fatalf("a lapsed MacBook waking = %+v, want active", r)
	}
	if r := tl.get("p:a", at(180+int(ClientLeaseTTL/time.Second)+1)); r.State != "none" {
		t.Fatalf("get after every lease lapsed = %+v, want none", r)
	}
	// A lapsed lease makes room quietly: no eviction reported.
	tl.max = 2
	if r := tl.acquire("p:a", ClientLeaseRequest{Device: "iPad"}, at(400)); r.Evicted != nil {
		t.Fatalf("a lapsed lease's room = %+v, want no eviction", r.Evicted)
	}

	// A restart: the table is empty, each client renews its id — re-adopted.
	var fresh clientLeaseTable
	for _, id := range []string{"a1", "a2"} {
		if r := fresh.renew("p:a", ClientLeaseRequest{Lease: id, Device: id}, at(0), false); r.State != "active" || r.Lease.ID != id {
			t.Fatalf("a renewal the hub forgot = %+v", r)
		}
	}
	fresh.max = 2
	if r := fresh.renew("p:a", ClientLeaseRequest{Lease: "a3"}, at(1), false); r.State != "taken_over" || r.Reason != "evicted" {
		t.Fatalf("a forgotten id past the limit = %+v, want taken_over evicted", r)
	}
	// The device a client reports is held to a short printable word.
	l := tb.acquire("p:b", ClientLeaseRequest{Device: "evil\x1b[2Jname"}, at(1))
	if l.Lease.Device != "evil[2Jname" {
		t.Fatalf("device = %q, want control bytes dropped", l.Lease.Device)
	}
	if l := tb.acquire("p:c", ClientLeaseRequest{}, at(1)); l.Lease.Device != "未知设备" {
		t.Fatalf("no device = %q, want 未知设备", l.Lease.Device)
	}
}

// FLEET_CLIENT_MAX / FLEET_CLIENT_IDLE set the limit and the idle bound.
func TestClientLeaseEnv(t *testing.T) {
	t.Setenv("FLEET_CLIENT_MAX", "2")
	t.Setenv("FLEET_CLIENT_IDLE", "90")
	var tb clientLeaseTable
	tb.init()
	if tb.max != 2 || tb.idle != 90*time.Second {
		t.Fatalf("max/idle = %d/%s", tb.max, tb.idle)
	}
	t.Setenv("FLEET_CLIENT_MAX", "")
	t.Setenv("FLEET_CLIENT_IDLE", "")
	var td clientLeaseTable
	td.init()
	if td.max != 4 || td.idle != 10*time.Minute {
		t.Fatalf("defaults = %d/%s", td.max, td.idle)
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
	// The phone opens beside it: the read follows the primary (just opened),
	// and lists both.
	h.srv.clientLeases.acquire(alice, ClientLeaseRequest{Device: "verkyyi-iphone", OS: "iOS", Terminal: "Termius",
		Via: "tailnet", Host: "m5", Caps: []string{"link"}}, now.Add(time.Second))
	if _, o := read(n["alice4"].token); o.Lease == nil || o.Lease.Device != "verkyyi-iphone" || o.Lease.Host != "m5" || o.Lease.Via != "tailnet" ||
		len(o.Clients) != 2 || o.Primary != o.Lease.ID {
		t.Fatalf("after the phone opened: %+v", o)
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

// TestClientLeaseRenewRefillsAfterRestart (claude-fleet#1995): the table lives
// in memory, so a restart forgets every lease; each client's next renewal
// re-adopts its own id AND carries its where, so where the person is reads the
// device, terminal and caps again with no reopening — each lease its own.
func TestClientLeaseRenewRefillsAfterRestart(t *testing.T) {
	var tb clientLeaseTable
	t0 := time.Date(2026, 10, 6, 19, 50, 0, 0, time.UTC)
	at := func(s int) time.Time { return t0.Add(time.Duration(s) * time.Second) }
	macW := ClientLeaseRequest{Device: "Verky's Mac", Terminal: "iTerm2 3.6", OS: "macOS", Via: "tailnet",
		Host: "m5", Caps: []string{"link", "iterm2"}}
	phW := ClientLeaseRequest{Device: "iPhone", Terminal: "Termius", OS: "iOS", Via: "tailnet", Host: "m5",
		Caps: []string{"link"}}
	mac := tb.acquire("p:a", macW, at(0))
	ph := tb.acquire("p:a", phW, at(1))
	tb = clientLeaseTable{} // the hub restarts
	if r := tb.get("p:a", at(2)); r.State != "none" {
		t.Fatalf("a restarted hub still knows a client: %+v", r)
	}
	renew := func(id string, w ClientLeaseRequest, now time.Time, input int64) ClientLeaseResponse {
		w.Action, w.Lease, w.LastInput = "renew", id, input
		return tb.renew("p:a", w, now, false)
	}
	if r := renew(ph.Lease.ID, phW, at(3), 0); r.State != "active" || r.Lease.ID != ph.Lease.ID || r.Lease.Device != "iPhone" {
		t.Fatalf("the iPhone's renewal after a restart = %+v", r)
	}
	r := renew(mac.Lease.ID, macW, at(4), at(4).Unix())
	if r.State != "active" || r.Lease.ID != mac.Lease.ID {
		t.Fatalf("the Mac's renewal after a restart = %+v", r)
	}
	got, _ := json.Marshal(tb.get("p:a", at(5)).Lease)
	var l ClientLease
	_ = json.Unmarshal(got, &l)
	if l.Device != "Verky's Mac" || l.Terminal != "iTerm2 3.6" || l.OS != "macOS" || l.Via != "tailnet" ||
		l.Host != "m5" || strings.Join(l.Caps, ",") != "link,iterm2" {
		t.Fatalf("where after one renewal = %s", got)
	}
	if n := len(tb.get("p:a", at(5)).Clients); n != 2 {
		t.Fatalf("clients after both renewed = %d, want 2", n)
	}
	// An older client's bare renewal (the id alone) still re-adopts the lease —
	// it just cannot say where it is.
	tb = clientLeaseTable{}
	if r := tb.renew("p:a", ClientLeaseRequest{Action: "renew", Lease: mac.Lease.ID}, at(6), false); r.State != "active" || r.Lease.Device != "未知设备" {
		t.Fatalf("a bare renewal after a restart = %+v", r)
	}
}
