package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

// The status bar's two summaries by connection certificate (claude-fleet#1502).

func postSummary(t *testing.T, h *harness, auth func(http.Header), body any) (int, SummaryResponse, string) {
	t.Helper()
	var rd *bytes.Reader
	method := http.MethodGet
	if body != nil {
		b, _ := json.Marshal(body)
		rd, method = bytes.NewReader(b), http.MethodPost
	} else {
		rd = bytes.NewReader(nil)
	}
	req, _ := http.NewRequest(method, h.http.URL+control.SummaryPath, rd)
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
	var out SummaryResponse
	_ = json.Unmarshal(raw.Bytes(), &out)
	return resp.StatusCode, out, raw.String()
}

func summaryKeys(out SummaryResponse) (machines, accounts []string) {
	for _, m := range out.Machines {
		machines = append(machines, m.Hostname)
	}
	for _, a := range out.PerAccount {
		accounts = append(accounts, a.AccountUUID)
	}
	sort.Strings(machines)
	sort.Strings(accounts)
	return
}

// A certificate reads its holder's own machines and the subscriptions their
// logins report under — nothing of anyone else's, no viewer token involved;
// the operator's token reads everything; a proof made for another door, or
// none, is refused.
func TestFleetSummaryByCertificate(t *testing.T) {
	h := newFleetHarness(t)
	k := newCertKit(t)
	h.srv.SSHCA = sshca.New(k.ca)
	now := time.Now()
	p, _ := h.srv.Store.AdoptPrincipal("wx-alice", "alice", "Alice", now)
	h.srv.Store.AdoptAccount(p, "m5", now)
	connectNode(t, h, "m5-alice", "m5", "alice", false)
	connectNode(t, h, "m4-bob", "m4", "bob", false)
	waitFor(t, 3*time.Second, "two nodes", func() bool { return len(roster(t, h).Nodes) == 2 })

	good := k.cert(t, "person:wx-alice", []string{"alice"}, now.Add(-time.Minute), now.Add(12*time.Hour))
	signed := func(c *ssh.Certificate, ns string, msg func(int64) string, ts int64) SummaryRequest {
		return SummaryRequest{Cert: string(ssh.MarshalAuthorizedKey(c)), TS: ts,
			Sig: sshsig(t, k.user, ns, []byte(msg(ts)))}
	}

	code, out, raw := postSummary(t, h, nil, signed(good, control.SummarySigNamespace, control.SummarySigMessage, now.Unix()))
	if code != 200 {
		t.Fatalf("a valid certificate: HTTP %d %s", code, raw)
	}
	ms, as := summaryKeys(out)
	if len(ms) != 1 || ms[0] != "m5" {
		t.Fatalf("alice's machines = %v, want [m5]", ms)
	}
	if len(as) != 1 || as[0] != "acct-m5-alice" {
		t.Fatalf("alice's subscriptions = %v, want [acct-m5-alice]", as)
	}
	for _, a := range out.PerAccount {
		if a.Limits != nil && len(a.Limits.EndpointShares) != 0 {
			t.Fatalf("a person's reading carries endpoint_shares: %+v", a.Limits.EndpointShares)
		}
	}

	for name, req := range map[string]SummaryRequest{
		"stale timestamp":    signed(good, control.SummarySigNamespace, control.SummarySigMessage, now.Add(-10*time.Minute).Unix()),
		"sessions signature": signed(good, control.SessionsSigNamespace, control.SessionsSigMessage, now.Unix()),
		"no signature":       {Cert: string(ssh.MarshalAuthorizedKey(good)), TS: now.Unix()},
	} {
		if code, _, raw := postSummary(t, h, nil, req); code != http.StatusUnauthorized {
			t.Errorf("%s: HTTP %d %s, want 401", name, code, raw)
		}
	}
	if code, _, _ := postSummary(t, h, nil, nil); code != http.StatusUnauthorized {
		t.Errorf("no credential: HTTP %d, want 401", code)
	}

	// Someone with no account anywhere sees nothing — not someone else's.
	h.srv.Store.AdoptPrincipal("wx-carol", "carol", "Carol", now)
	carol := k.cert(t, "person:wx-carol", []string{"carol"}, now.Add(-time.Minute), now.Add(time.Hour))
	code, out, raw = postSummary(t, h, nil, signed(carol, control.SummarySigNamespace, control.SummarySigMessage, now.Unix()))
	if ms, as := summaryKeys(out); code != 200 || len(ms) != 0 || len(as) != 0 {
		t.Errorf("no account: HTTP %d %s, want 200 with nothing in it", code, raw)
	}

	// The operator's door: a GET with the viewer token, everything.
	code, out, raw = postSummary(t, h, asOperator, nil)
	ms, as = summaryKeys(out)
	if code != 200 || len(ms) != 2 || len(as) != 2 {
		t.Fatalf("operator: HTTP %d %s, want both machines and both subscriptions", code, raw)
	}
}

// Each machine carries the repos its registered fleets host (claude-fleet#1927),
// narrowed like the machines: a newcomer whose list is still empty learns
// which repo a first session opens in from their own machines only; a fleet
// no longer configured adds nothing; a machine with no fleet carries [].
func TestFleetSummaryCarriesHostedRepos(t *testing.T) {
	h := newFleetHarness(t)
	k := newCertKit(t)
	h.srv.SSHCA = sshca.New(k.ca)
	now := time.Now()
	p, _ := h.srv.Store.AdoptPrincipal("wx-alice", "alice", "Alice", now)
	h.srv.Store.AdoptAccount(p, "m5", now)
	a := connectNode(t, h, "m5-alice", "m5", "alice", false)
	b := connectNode(t, h, "m4-bob", "m4", "bob", false)
	connectNode(t, h, "m3-bob", "m3", "bob", false)
	waitFor(t, 3*time.Second, "three nodes", func() bool { return len(roster(t, h).Nodes) == 3 })
	if _, err := h.srv.Store.RecordFleetSnapshot(a.id, "m5", "alice", "mach-m5", []store.FleetReport{
		{FleetID: "11111111-1111-4111-8111-111111111111", Name: "f1", Repo: "acme/web", Repos: []string{"acme/web", "acme/api"}, Checkout: "/c"},
		{FleetID: "22222222-2222-4222-8222-222222222222", Name: "f2", Repo: "acme/web", Checkout: "/d"}}, now); err != nil {
		t.Fatal(err)
	}
	if _, err := h.srv.Store.RecordFleetSnapshot(b.id, "m4", "bob", "mach-m4", []store.FleetReport{
		{FleetID: "33333333-3333-4333-8333-333333333333", Name: "f3", Repo: "bob/secret", Checkout: "/e"},
		{FleetID: "44444444-4444-4444-8444-444444444444", Name: "f4", Repo: "bob/old", Checkout: "/f"}}, now); err != nil {
		t.Fatal(err)
	}
	// m4's second snapshot drops a fleet it used to report: present=0, not hosted.
	if _, err := h.srv.Store.RecordFleetSnapshot(b.id, "m4", "bob", "mach-m4", []store.FleetReport{
		{FleetID: "33333333-3333-4333-8333-333333333333", Name: "f3", Repo: "bob/secret", Checkout: "/e"}}, now); err != nil {
		t.Fatal(err)
	}

	good := k.cert(t, "person:wx-alice", []string{"alice"}, now.Add(-time.Minute), now.Add(12*time.Hour))
	ts := now.Unix()
	req := SummaryRequest{Cert: string(ssh.MarshalAuthorizedKey(good)), TS: ts,
		Sig: sshsig(t, k.user, control.SummarySigNamespace, []byte(control.SummarySigMessage(ts)))}
	code, out, raw := postSummary(t, h, nil, req)
	if code != 200 || len(out.Machines) != 1 {
		t.Fatalf("alice: HTTP %d %s, want her one machine", code, raw)
	}
	if got := strings.Join(out.Machines[0].Repos, ","); got != "acme/api,acme/web" {
		t.Fatalf("m5 repos = %q, want acme/api,acme/web", got)
	}

	code, out, raw = postSummary(t, h, asOperator, nil)
	if code != 200 {
		t.Fatalf("operator: HTTP %d %s", code, raw)
	}
	got := map[string]string{}
	for _, m := range out.Machines {
		got[m.Hostname] = strings.Join(m.Repos, ",")
	}
	if got["m4"] != "bob/secret" || got["m5"] != "acme/api,acme/web" || got["m3"] != "" {
		t.Fatalf("operator repos = %v", got)
	}
	if strings.Contains(raw, `"repos":null`) || strings.Count(raw, `"repos":`) < 3 {
		t.Fatalf("every machine carries repos, [] for none (an older hub sends no key): %s", raw)
	}
}

// A node token reads what its login's owner reads with a certificate
// (claude-fleet#2630): node.env is the one credential every node daemon holds,
// so the quota watch and the other-machine rows stop reading 401 on a login
// with no viewer token. A node whose login is no active account, a revoked
// token and garbage are refused; the sessions door admits the same.
func TestFleetReadDoorsByNodeToken(t *testing.T) {
	h := newFleetHarness(t)
	now := time.Now()
	p, _ := h.srv.Store.AdoptPrincipal("wx-alice", "alice", "Alice", now)
	h.srv.Store.AdoptAccount(p, "m5", now)
	alice := connectNode(t, h, "m5-alice", "m5", "alice", false)
	bob := connectNode(t, h, "m4-bob", "m4", "bob", false)
	waitFor(t, 3*time.Second, "two nodes", func() bool { return len(roster(t, h).Nodes) == 2 })
	asNode := func(tok string) func(http.Header) {
		return func(hdr http.Header) { hdr.Set("Authorization", "Bearer "+tok) }
	}

	code, out, raw := postSummary(t, h, asNode(alice.token), nil)
	if code != 200 {
		t.Fatalf("alice's node token: HTTP %d %s", code, raw)
	}
	ms, as := summaryKeys(out)
	if len(ms) != 1 || ms[0] != "m5" || len(as) != 1 || as[0] != "acct-m5-alice" {
		t.Fatalf("alice's node token reads machines %v subscriptions %v, want [m5] [acct-m5-alice]", ms, as)
	}
	for _, a := range out.PerAccount {
		if a.Limits != nil && len(a.Limits.EndpointShares) != 0 {
			t.Fatalf("a node's reading carries endpoint_shares: %+v", a.Limits.EndpointShares)
		}
	}
	if code, _, raw := postSessions(t, h, asNode(alice.token), nil); code != 200 {
		t.Fatalf("alice's node token on the sessions door: HTTP %d %s", code, raw)
	}

	for name, tok := range map[string]string{
		"login with no account": bob.token,
		"unknown token":         "not-a-node-token",
	} {
		if code, _, raw := postSummary(t, h, asNode(tok), nil); code != http.StatusUnauthorized {
			t.Errorf("summary, %s: HTTP %d %s, want 401", name, code, raw)
		}
		if code, _, raw := postSessions(t, h, asNode(tok), nil); code != http.StatusUnauthorized {
			t.Errorf("sessions, %s: HTTP %d %s, want 401", name, code, raw)
		}
	}
}

// A machine carries the fleet version its newest heard login reported
// (claude-fleet#2692): the summary has no `nodes`, so without it every machine
// read "no fleet version reported". A login with no claude-fleet that beats
// later does not blank it; a machine where none reported has no key.
func TestFleetSummaryCarriesMachineFleetVersion(t *testing.T) {
	h := newFleetHarness(t)
	a := connectNode(t, h, "m5-alice", "m5", "alice", false)
	c := connectNode(t, h, "m5-carol", "m5", "carol", false)
	connectNode(t, h, "m4-bob", "m4", "bob", false)
	beat(t, a.c, control.Proto, control.Heartbeat{Hostname: "m5", OSUser: "alice", FleetVersion: "aaaaaaa"})
	waitFor(t, 3*time.Second, "alice's version", func() bool {
		for _, n := range roster(t, h).Nodes {
			if n.OSUser == "alice" && n.FleetVersion == "aaaaaaa" {
				return true
			}
		}
		return false
	})
	time.Sleep(20 * time.Millisecond)
	beat(t, c.c, control.Proto, control.Heartbeat{Hostname: "m5", OSUser: "carol"})
	code, out, raw := postSummary(t, h, asOperator, nil)
	if code != 200 {
		t.Fatalf("operator: HTTP %d %s", code, raw)
	}
	got := map[string]string{}
	for _, m := range out.Machines {
		got[m.Hostname] = m.FleetVersion
	}
	if got["m5"] != "aaaaaaa" || got["m4"] != "" {
		t.Fatalf("machine fleet versions = %v, want m5 aaaaaaa, m4 none (%s)", got, raw)
	}
	if strings.Count(raw, `"fleet_version":`) != 1 {
		t.Fatalf("only m5 carries the key: %s", raw)
	}
}
