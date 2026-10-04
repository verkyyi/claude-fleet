package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"sort"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/control"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
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

	good := k.cert(t, "wecom:wx-alice", []string{"alice"}, now.Add(-time.Minute), now.Add(12*time.Hour))
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
	carol := k.cert(t, "wecom:wx-carol", []string{"carol"}, now.Add(-time.Minute), now.Add(time.Hour))
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
