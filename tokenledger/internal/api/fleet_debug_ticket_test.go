package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/pricing"
	"github.com/verkyyi/claude-fleet/tokenledger/internal/sshca"
)

// claude-fleet#2891 (EPIC #2889 C2): a computer that never signed in gets a
// 24-hour ticket at install; the ticket works only from that computer, only
// until it expires, only so many times a day; an admin re-issues one that the
// next computer to use it binds to, and the old one stops working.

type debugClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *debugClock) now() time.Time      { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *debugClock) add(d time.Duration) { c.mu.Lock(); c.t = c.t.Add(d); c.mu.Unlock() }

// debugHarness is the fleet harness with debug tickets on, a fake clock, and
// a stand-in upload door (C4's) behind debugTicketAuth.
func debugHarness(t *testing.T) (*harness, *debugClock, *httptest.Server) {
	t.Helper()
	st := openTestStore(t)
	if err := st.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	clk := &debugClock{t: time.Now()}
	srv := &Server{Store: st, Pricing: pricing.Default(), ViewerToken: viewerToken,
		LiveStore: NewLive(), Fleet: true,
		Debug: &DebugTickets{Dir: t.TempDir(), Key: []byte(strings.Repeat("k", 32)), Now: clk.now}}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	up := httptest.NewServer(srv.debugTicketAuth(DebugUseUpload, func(w http.ResponseWriter, r *http.Request, dt *DebugTicket) {
		fmt.Fprintf(w, "ok %s", dt.ID)
	}))
	t.Cleanup(up.Close)
	return &harness{srv: srv, http: ts, tokens: map[string]string{}}, clk, up
}

var (
	fpA = strings.Repeat("a", 64)
	fpB = strings.Repeat("b", 64)
)

func debugPost(t *testing.T, url string, body any, hdr map[string]string) (int, []byte) {
	t.Helper()
	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

func issueTicket(t *testing.T, h *harness, fp, ip string) string {
	t.Helper()
	code, out := debugPost(t, h.http.URL+DebugTicketPath, map[string]string{"fp": fp, "version": "test"},
		map[string]string{"X-Forwarded-For": ip})
	if code != http.StatusOK {
		t.Fatalf("issue = %d %s", code, out)
	}
	var r struct{ Ticket string }
	_ = json.Unmarshal(out, &r)
	if !strings.HasPrefix(r.Ticket, "fdt1.") {
		t.Fatalf("no ticket in %s", out)
	}
	return r.Ticket
}

func useTicket(t *testing.T, url, tok, fp string) (int, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, url, nil)
	req.Header.Set("Authorization", "FleetDebug "+tok)
	req.Header.Set("X-Fleet-FP", fp)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func debugAuditCount(t *testing.T, h *harness, like string) int {
	t.Helper()
	var n int
	if err := h.srv.Store.DB().QueryRow(`SELECT COUNT(*) FROM fleet_audit WHERE action = 'debug_ticket' AND outcome LIKE ?`, like).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestDebugTicketBindsExpiresAndRefusesTampering(t *testing.T) {
	h, clk, up := debugHarness(t)
	tok := issueTicket(t, h, fpA, "203.0.113.1")
	if code, body := useTicket(t, up.URL, tok, fpA); code != 200 || !strings.HasPrefix(body, "ok dt_") {
		t.Fatalf("the ticket on its own computer = %d %q", code, body)
	}
	// another computer: refused, in words that say how to get one
	if code, body := useTicket(t, up.URL, tok, fpB); code != 401 || !strings.Contains(body, "另一台电脑") || !strings.Contains(body, "fleet hub debug-ticket") {
		t.Fatalf("a copied ticket = %d %q, want 401 + how to get a new one", code, body)
	}
	// one byte changed, anywhere
	for _, i := range []int{6, len(tok) / 2, len(tok) - 2} {
		bad := []byte(tok)
		if bad[i] == 'A' {
			bad[i] = 'B'
		} else {
			bad[i] = 'A'
		}
		if code, body := useTicket(t, up.URL, string(bad), fpA); code != 401 || !strings.Contains(body, "无效") {
			t.Fatalf("byte %d changed = %d %q, want 401", i, code, body)
		}
	}
	// no ticket / no fingerprint
	if code, _ := useTicket(t, up.URL, "", fpA); code != 401 {
		t.Fatalf("no ticket = %d", code)
	}
	if code, _ := useTicket(t, up.URL, tok, ""); code != 401 {
		t.Fatalf("no fingerprint = %d", code)
	}
	// expired
	clk.add(debugTicketTTL + time.Second)
	if code, body := useTicket(t, up.URL, tok, fpA); code != 401 || !strings.Contains(body, "过期") || !strings.Contains(body, "重装一次") {
		t.Fatalf("expired = %d %q, want 401 saying how to get a new one", code, body)
	}
	if debugAuditCount(t, h, "ISSUE anon%") != 1 || debugAuditCount(t, h, "REFUSE 401 fp%") != 1 || debugAuditCount(t, h, "REFUSE 401 expired%") != 1 {
		t.Fatal("issue / refusals not audited one row each")
	}
}

func TestDebugTicketUploadQuota(t *testing.T) {
	h, clk, up := debugHarness(t)
	tok := issueTicket(t, h, fpA, "203.0.113.1")
	for i := 1; i <= debugUploadsPerDay; i++ {
		if code, body := useTicket(t, up.URL, tok, fpA); code != 200 {
			t.Fatalf("upload %d = %d %q", i, code, body)
		}
	}
	code, body := useTicket(t, up.URL, tok, fpA)
	if code != http.StatusTooManyRequests || !strings.Contains(body, "用完") {
		t.Fatalf("upload %d = %d %q, want 429", debugUploadsPerDay+1, code, body)
	}
	// GET says what is left, and takes nothing
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+DebugTicketPath, nil)
	req.Header.Set("Authorization", "FleetDebug "+tok)
	req.Header.Set("X-Fleet-FP", fpA)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var st struct{ Left map[string]int }
	_ = json.NewDecoder(resp.Body).Decode(&st)
	resp.Body.Close()
	if resp.StatusCode != 200 || st.Left[DebugUseUpload] != 0 || st.Left[DebugUseSession] != debugSessionsPerDay {
		t.Fatalf("status = %d %+v", resp.StatusCode, st)
	}
	// the next day starts over
	n := clk.now().UTC()
	clk.add(time.Date(n.Year(), n.Month(), n.Day()+1, 0, 0, 1, 0, time.UTC).Sub(n))
	if code, body := useTicket(t, up.URL, tok, fpA); code != 200 {
		t.Fatalf("the next day = %d %q", code, body)
	}
}

func TestDebugTicketSessionsHubWide(t *testing.T) {
	h, _, _ := debugHarness(t)
	var queued, opened int
	sess := httptest.NewServer(h.srv.debugTicketAuth(DebugUseSession, func(w http.ResponseWriter, r *http.Request, dt *DebugTicket) {
		if dt.Queued {
			queued++
		} else {
			opened++
		}
	}))
	defer sess.Close()
	// 7 computers × 3 sessions = 21: the 21st is queued, not refused — and a
	// queued one takes nothing from its ticket, so it may ask again
	for i := 0; i < 7; i++ {
		fp := strings.Repeat(fmt.Sprintf("%x", i+1), 64)
		tok := issueTicket(t, h, fp, fmt.Sprintf("203.0.113.%d", i+1))
		for j := 0; j < debugSessionsPerDay; j++ {
			if code, body := useTicket(t, sess.URL, tok, fp); code != 200 {
				t.Fatalf("session %d/%d = %d %q", i, j, code, body)
			}
		}
		if code, _ := useTicket(t, sess.URL, tok, fp); i < 6 && code != http.StatusTooManyRequests {
			t.Fatalf("session %d over its ticket = %d, want 429", debugSessionsPerDay+1, code)
		}
	}
	if opened != debugSessionsAllDay || queued != 2 {
		t.Fatalf("opened %d queued %d, want %d and 2", opened, queued, debugSessionsAllDay)
	}
}

func TestDebugTicketIssueRateLimits(t *testing.T) {
	h, clk, _ := debugHarness(t)
	for i := 0; i < debugIssuePerIPHour; i++ {
		issueTicket(t, h, strings.Repeat(fmt.Sprintf("%x", i+1), 64), "198.51.100.7")
	}
	// a client-claimed X-Forwarded-For entry left of the ingress's does not help
	code, body := debugPost(t, h.http.URL+DebugTicketPath, map[string]string{"fp": fpA},
		map[string]string{"X-Forwarded-For": "1.2.3.4, 198.51.100.7, 10.0.0.3"})
	if code != http.StatusTooManyRequests || !strings.Contains(body2s(body), "网络出口") {
		t.Fatalf("6th from one address = %d %s, want 429", code, body)
	}
	if debugAuditCount(t, h, "REFUSE 429 issue ip%") != 1 {
		t.Fatal("the 429 not audited")
	}
	// hub-wide
	for i := 0; i < debugIssueAllHour-debugIssuePerIPHour; i++ {
		issueTicket(t, h, fpA, fmt.Sprintf("192.0.2.%d", i/debugIssuePerIPHour+1))
	}
	if code, body := debugPost(t, h.http.URL+DebugTicketPath, map[string]string{"fp": fpA},
		map[string]string{"X-Forwarded-For": "203.0.113.99"}); code != http.StatusTooManyRequests || !strings.Contains(body2s(body), "入口") {
		t.Fatalf("61st hub-wide = %d %s, want 429", code, body)
	}
	clk.add(time.Hour + time.Second)
	issueTicket(t, h, fpA, "198.51.100.7")
}

func body2s(b []byte) string { return string(b) }

func TestDebugTicketReissueRetiresTheOld(t *testing.T) {
	h, _, up := debugHarness(t)
	// the same computer installing again: the new ticket replaces the old
	old := issueTicket(t, h, fpA, "203.0.113.1")
	cur := issueTicket(t, h, fpA, "203.0.113.1")
	if code, body := useTicket(t, up.URL, old, fpA); code != 401 || !strings.Contains(body, "替换") {
		t.Fatalf("a superseded ticket = %d %q", code, body)
	}
	if code, _ := useTicket(t, up.URL, cur, fpA); code != 200 {
		t.Fatalf("the new one = %d", code)
	}

	// the admin's re-issue: unbound, binds to the first computer, retires the rest
	reissue := func() (int, map[string]any) {
		t.Helper()
		b, _ := json.Marshal(map[string]any{"github_login": "@Arvin", "hours": 24})
		req, _ := http.NewRequest(http.MethodPost, h.http.URL+DebugTicketsPath, bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer "+viewerToken)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out map[string]any
		_ = json.NewDecoder(resp.Body).Decode(&out)
		return resp.StatusCode, out
	}
	code, out := reissue()
	if code != http.StatusCreated || !strings.HasPrefix(fmt.Sprint(out["command"]), "fleet-debug ticket fdt1.") || out["owner"] != "arvin" {
		t.Fatalf("re-issue = %d %v", code, out)
	}
	adm1 := fmt.Sprint(out["ticket"])
	if code, _ := useTicket(t, up.URL, adm1, fpA); code != 200 {
		t.Fatalf("the re-issued ticket on its first computer = %d", code)
	}
	if code, _ := useTicket(t, up.URL, cur, fpA); code != 401 {
		t.Fatalf("the install ticket after the re-issue bound = %d, want 401", code)
	}
	if code, body := useTicket(t, up.URL, adm1, fpB); code != 401 || !strings.Contains(body, "另一台电脑") {
		t.Fatalf("the re-issued ticket copied = %d %q", code, body)
	}
	// re-issuing for the same person retires the previous re-issue
	_, out = reissue()
	adm2 := fmt.Sprint(out["ticket"])
	if code, _ := useTicket(t, up.URL, adm1, fpA); code != 401 {
		t.Fatalf("the first re-issue after a second = %d, want 401", code)
	}
	if code, _ := useTicket(t, up.URL, adm2, fpB); code != 200 {
		t.Fatalf("the second re-issue = %d", code)
	}
	// the list: every ticket, its state, no ticket strings
	_, raw := h.get(t, DebugTicketsPath)
	var list struct{ Tickets []debugTicketView }
	_ = json.Unmarshal(raw, &list)
	states := map[string]int{}
	for _, v := range list.Tickets {
		states[v.State]++
		if strings.Contains(string(raw), "fdt1.") {
			t.Fatal("the list carries a ticket")
		}
	}
	if len(list.Tickets) != 4 || states["active"] != 1 || states["revoked"] != 3 {
		t.Fatalf("list = %s", raw)
	}
	// not an admin: no list
	req, _ := http.NewRequest(http.MethodGet, h.http.URL+DebugTicketsPath, nil)
	resp, _ := http.DefaultClient.Do(req)
	resp.Body.Close()
	if resp.StatusCode == 200 {
		t.Fatal("the list answered without a credential")
	}
}

func TestDebugTicketByCertificate(t *testing.T) {
	h, _, up := debugHarness(t)
	k := newCertKit(t)
	h.srv.SSHCA = sshca.New(k.ca)
	now := time.Now()
	h.srv.Store.AdoptPrincipal("wx-alice", "alice", "Alice", now)
	c := k.cert(t, "person:wx-alice", []string{"alice"}, now.Add(-time.Minute), now.Add(12*time.Hour))
	body := map[string]any{"fp": fpA, "version": "t", "cert": string(ssh.MarshalAuthorizedKey(c)), "ts": now.Unix(),
		"sig": sshsig(t, k.user, DebugSigNamespace, []byte(DebugTicketSigMessage(now.Unix(), fpA)))}
	code, out := debugPost(t, h.http.URL+DebugTicketPath, body, nil)
	if code != 200 || !strings.Contains(string(out), `"by":"cert:wx-alice"`) {
		t.Fatalf("certificate exchange = %d %s", code, out)
	}
	var r struct{ Ticket string }
	_ = json.Unmarshal(out, &r)
	if code, _ := useTicket(t, up.URL, r.Ticket, fpA); code != 200 {
		t.Fatalf("its ticket = %d", code)
	}
	// signed for another fingerprint: refused
	body["sig"] = sshsig(t, k.user, DebugSigNamespace, []byte(DebugTicketSigMessage(now.Unix(), fpB)))
	if code, _ := debugPost(t, h.http.URL+DebugTicketPath, body, nil); code != 401 {
		t.Fatalf("a signature over another fingerprint = %d, want 401", code)
	}
}

// Off — no CCQUOTA_FLEET_DEBUG_DIR — adds nothing: the debug paths answer
// exactly what any unknown path does, and no table write happens.
func TestDebugOffAddsNothing(t *testing.T) {
	h := newFleetHarness(t)
	for _, p := range []string{DebugTicketPath, DebugTicketsPath} {
		code, body := debugPost(t, h.http.URL+p, map[string]string{"fp": fpA}, nil)
		ucode, ubody := debugPost(t, h.http.URL+"/v1/fleet/no-such-route", map[string]string{"fp": fpA}, nil)
		if code == 200 || code == 201 || code != ucode || string(body) != string(ubody) {
			t.Fatalf("%s off = %d %q, an unknown path = %d %q", p, code, body, ucode, ubody)
		}
	}
	rows, err := h.srv.Store.DebugTickets(time.Time{}, 0)
	if err != nil || len(rows) != 0 {
		t.Fatalf("tickets off = %v %v", rows, err)
	}
}
