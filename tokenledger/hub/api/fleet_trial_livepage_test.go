package api

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/hub/store"
)

// fakeLivePage is 活页's partner door as HBXZ's contract says it: provision
// is idempotent per openid (created only the first time), revoke records.
type fakeLivePage struct {
	mu        sync.Mutex
	srv       *httptest.Server
	accounts  map[string]string // openid → token
	provision atomic.Int32
	down      atomic.Bool
	revoked   []string // openid:reason
	last      livePageProvision
	auth      string
}

func newFakeLivePage(t *testing.T) *fakeLivePage {
	f := &fakeLivePage{accounts: map[string]string{}}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.auth = r.Header.Get("X-Partner-Token")
		if f.auth != "partner-key" || r.Header.Get("Authorization") != "" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if r.URL.Path == "/internal/partner/provision" {
			f.provision.Add(1)
		}
		if f.down.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		b, _ := io.ReadAll(r.Body)
		switch r.URL.Path {
		case "/internal/partner/provision":
			var in livePageProvision
			_ = json.Unmarshal(b, &in)
			f.last = in
			tok, had := f.accounts[in.OpenID]
			if !had {
				tok = "sk-space-trial-" + in.OpenID
				f.accounts[in.OpenID] = tok
			}
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(map[string]any{"user": map[string]any{"id": "u1", "is_new": !had},
				"workspace": map[string]any{"id": "w1"}, "token": map[string]any{"id": "t1", "prefix": "sk-space-", "plain": tok, "kind": "partner"}})
		case "/internal/partner/revoke":
			var in struct {
				OpenID     string `json:"openid"`
				Source     string `json:"source"`
				Deregister bool   `json:"deregister"`
			}
			_ = json.Unmarshal(b, &in)
			what := "revoke"
			if in.Deregister {
				what = "deregister"
			}
			f.revoked = append(f.revoked, in.OpenID+":"+what)
			_ = json.NewEncoder(w).Encode(map[string]any{"found": true, "revoked": true, "deregistered": in.Deregister})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeLivePage) revokes() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return strings.Join(f.revoked, ",")
}

func livePageCall(t *testing.T, h *harness, method, tok string) (int, livePageAnswer, string) {
	t.Helper()
	r, _ := http.NewRequest(method, h.http.URL+LivePageTokenNodePath, bytes.NewReader(nil))
	if tok != "" {
		r.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var a livePageAnswer
	_ = json.Unmarshal(raw, &a)
	return resp.StatusCode, a, string(raw)
}

// livePageHarness: alice on mac-c is a trial member (limits with an end) who
// scanned in by the service account; 活页's door is the fake.
func livePageHarness(t *testing.T) (*harness, string, *fakeLivePage) {
	t.Helper()
	h, tok, _ := newVaultHarness(t)
	f := newFakeLivePage(t)
	h.srv.LivePage = &LivePagePartner{URL: f.srv.URL, Key: "partner-key"}
	h.srv.FleetPublicURL = "https://claudefleet.example/"
	now := time.Now()
	if err := h.srv.Store.SetFleetSetting(MemberLimitsPrefix+pAlice, "until="+now.Add(72*time.Hour).UTC().Format(time.RFC3339), now); err != nil {
		t.Fatal(err)
	}
	if err := h.srv.Store.SetHubReach(store.HubReach{Owner: pAlice, Channel: store.ReachWeChatMP, Addr: "oAlice", Followed: true}); err != nil {
		t.Fatal(err)
	}
	return h, tok, f
}

// The switch is off by default: nothing is provisioned, the proxy is told so.
func TestLivePageOffByDefault(t *testing.T) {
	h, tok, f := livePageHarness(t)
	if code, a, raw := livePageCall(t, h, http.MethodPost, tok); code != http.StatusForbidden || a.Code != "off" || a.Token != "" {
		t.Fatalf("off: HTTP %d %s, want 403 off", code, raw)
	}
	if f.provision.Load() != 0 {
		t.Fatal("provisioned with the switch off")
	}
	if _, why := checkTrialLivePage(h.srv, "maybe"); why == "" {
		t.Fatal("fleet.trial.livepage took a value outside off | on")
	}
	// on, but no door configured: still off
	h.srv.LivePage = nil
	_ = h.srv.Store.SetFleetSetting(TrialLivePageKey, "on", time.Now())
	if code, a, _ := livePageCall(t, h, http.MethodGet, tok); code != http.StatusForbidden || a.Code != "off" {
		t.Fatalf("no door: HTTP %d %+v, want 403 off", code, a)
	}
}

// The first ask provisions — and only the first: GET never does, a second
// POST answers the kept key, a parallel burst opens one account; the key is
// in no audit row; the partner got the openid, the source and the terms.
func TestLivePageProvisionOnce(t *testing.T) {
	h, tok, f := livePageHarness(t)
	_ = h.srv.Store.SetFleetSetting(TrialLivePageKey, "on", time.Now())
	if code, a, raw := livePageCall(t, h, http.MethodGet, tok); code != 200 || !a.Eligible || a.Ready || a.Token != "" {
		t.Fatalf("GET before: HTTP %d %s, want eligible, not ready, no key", code, raw)
	}
	if f.provision.Load() != 0 {
		t.Fatal("a GET provisioned")
	}
	var wg sync.WaitGroup
	news := atomic.Int32{}
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			code, a, raw := livePageCall(t, h, http.MethodPost, tok)
			if code != 200 || a.Token != "sk-space-trial-oAlice" {
				t.Errorf("POST: HTTP %d %s", code, raw)
			}
			if a.New {
				news.Add(1)
			}
		}()
	}
	wg.Wait()
	if n := f.provision.Load(); n != 1 {
		t.Fatalf("%d provisions for one person, want 1", n)
	}
	if news.Load() != 1 {
		t.Fatalf("%d answers said new, want exactly 1", news.Load())
	}
	if f.last.OpenID != "oAlice" || f.last.Source != livePageSource || f.last.ConsentTerms != livePageTermsVersion || f.last.Until == "" ||
		len(f.last.EmbedOrigins) != 1 || f.last.EmbedOrigins[0] != "https://claudefleet.example" {
		t.Fatalf("provision body %+v", f.last)
	}
	if code, a, _ := livePageCall(t, h, http.MethodGet, tok); code != 200 || !a.Ready || a.Token != "" {
		t.Fatalf("GET after: HTTP %d %+v, want ready and no key", code, a)
	}
	c, _ := h.srv.Store.PartnerCred(pAlice, store.PartnerLivePage)
	if c == nil || bytes.Contains(c.Sealed, []byte("sk-space")) {
		t.Fatal("the key is not kept sealed")
	}
	log, _ := h.srv.Store.HubAuditLog(200)
	for _, e := range log {
		if strings.Contains(e.Detail, "sk-space") || strings.Contains(e.Target, "sk-space") {
			t.Fatalf("the key in the audit: %+v", e)
		}
	}
	// no token, or a stranger's: refused
	if code, _, _ := livePageCall(t, h, http.MethodPost, ""); code != http.StatusUnauthorized {
		t.Fatalf("no token: HTTP %d, want 401", code)
	}
}

// Not a trial (a member with no end) and no service-account WeChat: refused,
// nothing opened.
func TestLivePageOnlyTrials(t *testing.T) {
	h, tok, f := livePageHarness(t)
	now := time.Now()
	_ = h.srv.Store.SetFleetSetting(TrialLivePageKey, "on", now)
	_ = h.srv.Store.SetFleetSetting(MemberLimitsPrefix+pAlice, "tokens=1000", now)
	if code, a, _ := livePageCall(t, h, http.MethodPost, tok); code != http.StatusForbidden || a.Code != "not_trial" {
		t.Fatalf("a member: HTTP %d %+v, want 403 not_trial", code, a)
	}
	if f.provision.Load() != 0 {
		t.Fatal("provisioned for a member")
	}
}

// A door that is down: 503 with a retry-after, the next ask inside the
// back-off does not knock again, and once it is up the key comes.
func TestLivePageDoorDownBacksOff(t *testing.T) {
	h, tok, f := livePageHarness(t)
	_ = h.srv.Store.SetFleetSetting(TrialLivePageKey, "on", time.Now())
	f.down.Store(true)
	if code, a, raw := livePageCall(t, h, http.MethodPost, tok); code != http.StatusServiceUnavailable || a.Code != "failed" || a.RetryAfter <= 0 {
		t.Fatalf("down: HTTP %d %s, want 503 failed + retry_after", code, raw)
	}
	if code, a, _ := livePageCall(t, h, http.MethodPost, tok); code != http.StatusServiceUnavailable || a.RetryAfter <= 0 {
		t.Fatalf("inside the back-off: HTTP %d %+v", code, a)
	}
	if n := f.provision.Load(); n != 1 {
		t.Fatalf("the door was knocked %d times inside the back-off, want 1", n)
	}
	f.down.Store(false)
	// the back-off passed
	_, _ = h.srv.Store.DB().Exec(`UPDATE hub_partner_creds SET fail_at = fail_at - 3600`)
	if code, a, raw := livePageCall(t, h, http.MethodPost, tok); code != 200 || a.Token == "" || !a.New || f.provision.Load() != 2 {
		t.Fatalf("up again: HTTP %d %s", code, raw)
	}
}

// The trial's end takes the key back (403 ended from then on), tells 活页
// once and the person once; 转正 takes it back as converted; removing the
// person closes their 活页 account (erase) even after an earlier revoke.
func TestLivePageRevokes(t *testing.T) {
	h, tok, f := livePageHarness(t)
	now := time.Now()
	_ = h.srv.Store.SetFleetSetting(TrialLivePageKey, "on", now)
	if code, _, raw := livePageCall(t, h, http.MethodPost, tok); code != 200 {
		t.Fatalf("provision: HTTP %d %s", code, raw)
	}
	// still within the trial: the sweep leaves it
	h.srv.SweepLivePage(now)
	if f.revokes() != "" {
		t.Fatalf("a live trial's key revoked: %s", f.revokes())
	}
	// the trial's end passes
	_ = h.srv.Store.SetFleetSetting(MemberLimitsPrefix+pAlice, "until="+now.Add(-time.Minute).UTC().Format(time.RFC3339), now)
	h.srv.SweepLivePage(now.Add(2 * time.Minute))
	if got := f.revokes(); got != "oAlice:revoke" {
		t.Fatalf("after the end: told %q, want oAlice:revoke", got)
	}
	if code, a, _ := livePageCall(t, h, http.MethodPost, tok); code != http.StatusForbidden || a.Code != "ended" || a.Token != "" {
		t.Fatalf("after the end: HTTP %d %+v, want 403 ended", code, a)
	}
	if !h.srv.livePageEnded(pAlice) {
		t.Fatal("livePageEnded false after the end")
	}
	h.srv.SweepLivePage(now.Add(4 * time.Minute))
	if got := f.revokes(); got != "oAlice:revoke" {
		t.Fatalf("told twice: %q", got)
	}
	ns, _ := h.srv.Store.ClaimNotices(now.Add(time.Hour), time.Minute, 50)
	ends := 0
	for _, n := range ns {
		if n.Kind == store.NotifyKindLivePageEnd && n.Owner == pAlice {
			ends++
		}
	}
	if ends != 1 {
		t.Fatalf("%d end notices, want 1", ends)
	}
	// they delete their data: 活页 closes the account now
	h.srv.eraseLivePage(pAlice, now.Add(5*time.Minute))
	if got := f.revokes(); got != "oAlice:revoke,oAlice:deregister" {
		t.Fatalf("erase: told %q", got)
	}
	h.srv.eraseLivePage(pAlice, now.Add(6*time.Minute))
	if got := f.revokes(); got != "oAlice:revoke,oAlice:deregister" {
		t.Fatalf("erase twice: told %q", got)
	}
}

// 转正 (the end leaves the limits): revoked as converted; the door down at
// the time is told on a later sweep.
func TestLivePageConvertedToldLater(t *testing.T) {
	h, tok, f := livePageHarness(t)
	now := time.Now()
	_ = h.srv.Store.SetFleetSetting(TrialLivePageKey, "on", now)
	if code, _, raw := livePageCall(t, h, http.MethodPost, tok); code != 200 {
		t.Fatalf("provision: HTTP %d %s", code, raw)
	}
	_ = h.srv.Store.SetFleetSetting(MemberLimitsPrefix+pAlice, "tokens=1000", now)
	f.down.Store(true)
	h.srv.SweepLivePage(now.Add(2 * time.Minute))
	if f.revokes() != "" {
		t.Fatal("a down door recorded a revoke")
	}
	f.down.Store(false)
	h.srv.SweepLivePage(now.Add(4 * time.Minute))
	if got := f.revokes(); got != "oAlice:revoke" {
		t.Fatalf("told %q, want oAlice:revoke", got)
	}
}
