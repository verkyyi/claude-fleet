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

// The test identity (claude-fleet#1931, EPIC #1906 C12): a session's test or
// drill never connects as the person. A request marked as a session's
// (X-Fleet-Worker) that asks for the person's lease is refused 403 with the
// reason; the test identity gets a lease of its own that takes nothing over,
// leaves where the person is (ClientLeaseOf, a person's get) untouched, is
// handed no action key's actions, and polls as active.
func TestFleetClientTestIdentity(t *testing.T) {
	h := newFleetHarness(t)
	k := newCertKit(t)
	h.srv.SSHCA = sshca.New(k.ca)
	now := time.Now()
	h.srv.Store.AdoptPrincipal("wx-alice", "alice", "Alice", now)
	alice := k.cert(t, "person:wx-alice", []string{"alice"}, now.Add(-time.Minute), now.Add(12*time.Hour))
	post := func(c *ssh.Certificate, path, worker string, r ClientLeaseRequest) (int, ClientLeaseResponse, string) {
		t.Helper()
		r.Cert, r.TS = string(ssh.MarshalAuthorizedKey(c)), time.Now().Unix()
		r.Sig = sshsig(t, k.user, control.ClientSigNamespace, []byte(control.ClientSigMessage(r.TS)))
		b, _ := json.Marshal(r)
		req, _ := http.NewRequest(http.MethodPost, h.http.URL+path, bytes.NewReader(b))
		if worker != "" {
			req.Header.Set(workerAssertHeader, worker)
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
	where := func() string {
		t.Helper()
		code, out, raw := post(alice, control.ClientPath, "", ClientLeaseRequest{Action: "get"})
		if code != 200 {
			t.Fatalf("person's get: HTTP %d %s", code, raw)
		}
		if out.Lease == nil {
			return out.State
		}
		return out.State + " " + out.Lease.ID + " " + out.Lease.Device
	}

	code, mac, raw := post(alice, control.ClientPath, "", ClientLeaseRequest{Action: "acquire", Device: "MacBook",
		Caps: []string{"open_url", "iterm2"}})
	if code != 200 || mac.State != "active" || mac.Identity != "" {
		t.Fatalf("the person's acquire: HTTP %d %s", code, raw)
	}
	before := where()

	// A session asking for the person's lease: 403 + why, nothing changes.
	for _, ident := range []string{"", "person"} {
		code, _, raw = post(alice, control.ClientPath, "fwa1.x.y", ClientLeaseRequest{Action: "acquire", Device: "m4-drill", Identity: ident})
		if code != http.StatusForbidden || !strings.Contains(raw, "test identity") {
			t.Fatalf("a session's acquire as %q: HTTP %d %s, want 403 naming the test identity", ident, code, raw)
		}
	}
	if got := where(); got != before {
		t.Fatalf("a refused session acquire moved the person's where: %q → %q", before, got)
	}

	// The test identity, both doors: its own lease, no takeover, where unchanged.
	code, tst, raw := post(alice, ClientTestPath, "fwa1.x.y", ClientLeaseRequest{Action: "acquire", Device: "m4-drill",
		Caps: []string{"open_url", "iterm2"}})
	if code != 200 || tst.State != "active" || tst.Identity != "test" || tst.TookOver != nil || tst.Lease == nil {
		t.Fatalf("test acquire: HTTP %d %s", code, raw)
	}
	if len(tst.Lease.Caps) != 0 {
		t.Fatalf("a test lease reports no caps (it only looks): %v", tst.Lease.Caps)
	}
	code, tst2, raw := post(alice, control.ClientPath, "", ClientLeaseRequest{Action: "acquire", Device: "m4-drill-2", Identity: "test"})
	if code != 200 || tst2.Identity != "test" || tst2.TookOver != nil || tst2.Evicted != nil || len(tst2.Clients) != 2 {
		t.Fatalf("a second test acquire sits beside the first TEST lease (#1932), never the person's: HTTP %d %s", code, raw)
	}
	if got := where(); got != before {
		t.Fatalf("a test acquire moved the person's where: %q → %q", before, got)
	}
	if l, ok := h.srv.ClientLeaseOf("alice", time.Now()); ok && l.ID != mac.Lease.ID {
		t.Fatalf("ClientLeaseOf = %+v, want the MacBook", l)
	}
	if l, ok := h.srv.ClientLeaseOf("Alice", time.Now()); ok && l.ID != mac.Lease.ID {
		t.Fatalf("ClientLeaseOf = %+v, want the MacBook", l)
	}
	// The person's renewal still reads active; the test's renewal reads active.
	if _, r, raw := post(alice, control.ClientPath, "", ClientLeaseRequest{Action: "renew", Lease: mac.Lease.ID}); r.State != "active" {
		t.Fatalf("person's renew after a test acquire: %s", raw)
	}
	if _, r, raw := post(alice, ClientTestPath, "fwa1.x.y", ClientLeaseRequest{Action: "renew", Lease: tst2.Lease.ID}); r.State != "active" || r.Identity != "test" {
		t.Fatalf("test renew: %s", raw)
	}
	if _, r, raw := post(alice, ClientTestPath, "", ClientLeaseRequest{Action: "get"}); r.Lease == nil || r.Lease.ID != tst2.Lease.ID {
		t.Fatalf("test get reads the test slot: %s", raw)
	}
	// A test lease polls its actions as active, with none.
	poll := ClientActionPoll{Lease: tst2.Lease.ID}
	poll.TS = time.Now().Unix()
	poll.Cert = string(ssh.MarshalAuthorizedKey(alice))
	poll.Sig = sshsig(t, k.user, control.ClientSigNamespace, []byte(control.ClientSigMessage(poll.TS)))
	b, _ := json.Marshal(poll)
	resp, err := http.Post(h.http.URL+control.ClientPath+"/actions", "application/json", bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	var pr ClientActionPollResponse
	_ = json.NewDecoder(resp.Body).Decode(&pr)
	resp.Body.Close()
	if resp.StatusCode != 200 || pr.State != "active" || len(pr.Actions) != 0 {
		t.Fatalf("test lease poll: HTTP %d %+v", resp.StatusCode, pr)
	}
	// A wrong word at either door is refused.
	if code, _, _ := post(alice, ClientTestPath, "", ClientLeaseRequest{Action: "get", Identity: "person"}); code != 400 {
		t.Fatalf("person at the test door: HTTP %d, want 400", code)
	}
	if code, _, _ := post(alice, control.ClientPath, "", ClientLeaseRequest{Action: "get", Identity: "root"}); code != 400 {
		t.Fatalf("unknown identity: HTTP %d, want 400", code)
	}
	// Releasing the test lease leaves the person's.
	post(alice, ClientTestPath, "", ClientLeaseRequest{Action: "release", Lease: tst2.Lease.ID})
	if got := where(); got != before {
		t.Fatalf("a test release moved the person's where: %q → %q", before, got)
	}
}
