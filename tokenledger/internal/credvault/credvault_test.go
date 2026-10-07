package credvault

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/verkyyi/claude-fleet/tokenledger/internal/store"
)

func testKey() []byte {
	k := make([]byte, 32)
	for i := range k {
		k[i] = byte(i)
	}
	return k
}

func newVault(t *testing.T, r Refresher) *Vault {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "hub.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	if err := st.EnsureNodes(); err != nil {
		t.Fatal(err)
	}
	s, err := NewSealer(testKey())
	if err != nil {
		t.Fatal(err)
	}
	return &Vault{Store: st, Sealer: s, Refresher: r}
}

// countingRefresher mints "AT-<n>" valid for ttl, rotating the refresh token,
// and holds each refresh for delay so concurrent callers really overlap.
type countingRefresher struct {
	n     atomic.Int64
	ttl   time.Duration
	delay time.Duration
	fail  atomic.Bool
}

func (c *countingRefresher) Refresh(_ context.Context, _ string, s Secret) (Access, Secret, error) {
	n := c.n.Add(1)
	time.Sleep(c.delay)
	if c.fail.Load() {
		return Access{}, s, errors.New("invalid_grant")
	}
	exp := time.Now().Add(c.ttl)
	next := s
	next.RefreshToken = fmt.Sprintf("RT-%d", n)
	return Access{AccessToken: fmt.Sprintf("AT-%d", n), ExpiresAt: &exp}, next, nil
}

func TestConcurrentLeaseRefreshesOnce(t *testing.T) {
	r := &countingRefresher{ttl: 8 * time.Hour, delay: 50 * time.Millisecond}
	v := newVault(t, r)
	if err := v.Put("p1", Claude, "main", Secret{RefreshToken: "RT-0"}); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	got := make([]string, 16)
	for i := range got {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			a, err := v.Lease(context.Background(), "p1", Claude, "main")
			if err != nil {
				t.Error(err)
				return
			}
			got[i] = a.AccessToken
		}(i)
	}
	wg.Wait()
	if n := r.n.Load(); n != 1 {
		t.Fatalf("16 concurrent leases refreshed %d times, want exactly 1", n)
	}
	for _, g := range got {
		if g != "AT-1" {
			t.Fatalf("a waiter got %q, want the one refresh's AT-1", g)
		}
	}
	// The rotated refresh token was saved before anyone got the lease.
	c, _ := v.Store.Credential("p1", Claude, "main")
	var s Secret
	if err := v.Sealer.Open(c.SecretSealed, &s, "p1", Claude, "main", "secret"); err != nil || s.RefreshToken != "RT-1" {
		t.Fatalf("stored secret = %+v (%v), want the rotated RT-1", s, err)
	}
}

func TestLeaseReusesUntilMinTTL(t *testing.T) {
	r := &countingRefresher{ttl: 8 * time.Hour}
	v := newVault(t, r)
	now := time.Now()
	v.Now = func() time.Time { return now }
	_ = v.Put("p1", Claude, "main", Secret{RefreshToken: "RT-0"})
	for i := 0; i < 3; i++ {
		if _, err := v.Lease(context.Background(), "p1", Claude, "main"); err != nil {
			t.Fatal(err)
		}
	}
	if r.n.Load() != 1 {
		t.Fatalf("refreshed %d times for three leases inside the TTL", r.n.Load())
	}
	now = now.Add(5*time.Hour + time.Minute) // under 3h left of 8h
	a, err := v.Lease(context.Background(), "p1", Claude, "main")
	if err != nil || a.AccessToken != "AT-2" || r.n.Load() != 2 {
		t.Fatalf("near expiry: %+v %v refreshes=%d, want a fresh AT-2", a, err, r.n.Load())
	}
}

func TestRefreshFailureFallsBackThenErrors(t *testing.T) {
	r := &countingRefresher{ttl: 4 * time.Hour}
	v := newVault(t, r)
	now := time.Now()
	v.Now = func() time.Time { return now }
	_ = v.Put("p1", Claude, "main", Secret{RefreshToken: "RT-0"})
	if _, err := v.Lease(context.Background(), "p1", Claude, "main"); err != nil {
		t.Fatal(err)
	}
	r.fail.Store(true)
	now = now.Add(2 * time.Hour) // 2h left < MinTTL: refresh, which fails
	a, err := v.Lease(context.Background(), "p1", Claude, "main")
	if err != nil || a.AccessToken != "AT-1" {
		t.Fatalf("failed refresh with a still-valid token: %+v %v, want AT-1", a, err)
	}
	now = now.Add(3 * time.Hour) // expired
	if _, err := v.Lease(context.Background(), "p1", Claude, "main"); !errors.Is(err, ErrRefreshFailed) {
		t.Fatalf("failed refresh, nothing valid: err = %v, want ErrRefreshFailed", err)
	}
	c, _ := v.Store.Credential("p1", Claude, "main")
	if !strings.Contains(c.RefreshError, "invalid_grant") {
		t.Fatalf("refresh_error = %q", c.RefreshError)
	}
}

func TestSealBindsRowAndHalf(t *testing.T) {
	s, _ := NewSealer(testKey())
	blob, err := s.Seal(Secret{RefreshToken: "x"}, "p1", Claude, "main", "secret")
	if err != nil {
		t.Fatal(err)
	}
	var out Secret
	if err := s.Open(blob, &out, "p1", Claude, "main", "secret"); err != nil || out.RefreshToken != "x" {
		t.Fatalf("open own blob: %+v %v", out, err)
	}
	if strings.Contains(string(blob), `"x"`) {
		t.Fatal("blob holds the plaintext")
	}
	for _, alt := range [][4]string{{"p2", Claude, "main", "secret"}, {"p1", Codex, "main", "secret"}, {"p1", Claude, "main", "access"}} {
		if err := s.Open(blob, &out, alt[0], alt[1], alt[2], alt[3]); err == nil {
			t.Fatalf("blob opened as %v", alt)
		}
	}
	other := testKey()
	other[0] ^= 1
	s2, _ := NewSealer(other)
	if err := s2.Open(blob, &out, "p1", Claude, "main", "secret"); err == nil {
		t.Fatal("blob opened with another key")
	}
}

func TestLoadKey(t *testing.T) {
	enc := base64.StdEncoding.EncodeToString(testKey())
	env := map[string]string{}
	get := func(k string) string { return env[k] }
	if _, ok, err := LoadKey(get); ok || err != nil {
		t.Fatalf("unset: ok=%v err=%v", ok, err)
	}
	env["CCQUOTA_FLEET_CRED_KEY"] = enc
	if k, ok, err := LoadKey(get); !ok || err != nil || len(k) != 32 {
		t.Fatalf("env: %v %v %v", len(k), ok, err)
	}
	env["CCQUOTA_FLEET_CRED_KEY"] = "c2hvcnQ="
	if _, _, err := LoadKey(get); err == nil {
		t.Fatal("short key accepted")
	}
}

func TestHTTPRefresher(t *testing.T) {
	var gotClaude, gotCodex map[string]string
	exp := time.Now().Add(10 * 24 * time.Hour).Unix()
	jwt := "e30." + base64.RawURLEncoding.EncodeToString([]byte(fmt.Sprintf(`{"exp":%d}`, exp))) + ".sig"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]string
		_ = json.NewDecoder(r.Body).Decode(&body)
		switch r.URL.Path {
		case "/claude":
			gotClaude = body
			fmt.Fprint(w, `{"access_token":"sk-ant-oat01-new","refresh_token":"sk-ant-ort01-new","expires_in":28800,"scope":"user:inference user:profile"}`)
		case "/codex":
			gotCodex = body
			fmt.Fprintf(w, `{"access_token":%q,"refresh_token":"rt-new","id_token":"idt-new"}`, jwt)
		case "/bad":
			w.WriteHeader(400)
			fmt.Fprint(w, `{"error":"invalid_grant"}`)
		}
	}))
	defer srv.Close()
	r := &HTTPRefresher{ClaudeTokenURL: srv.URL + "/claude", CodexTokenURL: srv.URL + "/codex"}

	a, s, err := r.Refresh(context.Background(), Claude, Secret{RefreshToken: "rt-old", SubscriptionType: "max"})
	if err != nil || a.AccessToken != "sk-ant-oat01-new" || s.RefreshToken != "sk-ant-ort01-new" || a.ExpiresAt == nil ||
		a.SubscriptionType != "max" || len(a.Scopes) != 2 {
		t.Fatalf("claude: %+v %+v %v", a, s, err)
	}
	if gotClaude["grant_type"] != "refresh_token" || gotClaude["refresh_token"] != "rt-old" || gotClaude["client_id"] != ClaudeClientID {
		t.Fatalf("claude request body %v", gotClaude)
	}

	a, s, err = r.Refresh(context.Background(), Codex, Secret{RefreshToken: "rt-old", AccountID: "acct"})
	if err != nil || a.AccessToken != jwt || s.RefreshToken != "rt-new" || a.IDToken != "idt-new" || a.AccountID != "acct" ||
		a.ExpiresAt == nil || a.ExpiresAt.Unix() != exp {
		t.Fatalf("codex: %+v %+v %v", a, s, err)
	}
	if gotCodex["client_id"] != CodexClientID || gotCodex["refresh_token"] != "rt-old" {
		t.Fatalf("codex request body %v", gotCodex)
	}

	r.ClaudeTokenURL = srv.URL + "/bad"
	if _, s, err := r.Refresh(context.Background(), Claude, Secret{RefreshToken: "keep"}); err == nil || s.RefreshToken != "keep" ||
		!strings.Contains(err.Error(), "invalid_grant") {
		t.Fatalf("bad grant: %+v %v", s, err)
	}
}

// A Claude setup token (claude-fleet#1463) is issued exactly as stored: no
// refresh, no rotation, nothing cached — so any number of machines read one
// row and never log each other out. Its expiry is the operator's word and the
// vault refuses to store or issue one that has passed.
func TestSetupTokenIssuedAsIsAndNeverRefreshed(t *testing.T) {
	ref := &countingRefresher{ttl: 8 * time.Hour}
	v := newVault(t, ref)
	now := time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)
	v.Now = func() time.Time { return now }
	exp := now.Add(365 * 24 * time.Hour)
	tok := "sk-ant-oat01-LONGLIVED"

	if err := v.Put("pool", Claude, "icloud", Secret{SetupToken: tok, ExpiresAt: &exp, SubscriptionType: "max"}); err != nil {
		t.Fatal(err)
	}
	row, err := v.Store.Credential("pool", Claude, "icloud")
	if err != nil || row.Kind != KindSetupToken || row.SecretExpiresAt == nil || !row.SecretExpiresAt.Equal(exp) {
		t.Fatalf("row = %+v, %v", row, err)
	}
	for i := 0; i < 3; i++ {
		acc, err := v.Lease(context.Background(), "pool", Claude, "icloud")
		if err != nil {
			t.Fatal(err)
		}
		if acc.AccessToken != tok || acc.ExpiresAt == nil || !acc.ExpiresAt.Equal(exp) || acc.SubscriptionType != "max" ||
			len(acc.Scopes) != 1 || acc.Scopes[0] != "user:inference" {
			t.Fatalf("lease %d = %+v", i, acc)
		}
	}
	if n := ref.n.Load(); n != 0 {
		t.Fatalf("a setup token was refreshed %d time(s)", n)
	}
	row, _ = v.Store.Credential("pool", Claude, "icloud")
	if len(row.AccessSealed) != 0 || row.Version != 1 {
		t.Fatalf("a setup token lease wrote the row: %+v", row)
	}

	// The shape the operator must send.
	for name, s := range map[string]Secret{
		"both":       {RefreshToken: "rt", SetupToken: tok, ExpiresAt: &exp},
		"no expiry":  {SetupToken: tok},
		"not an oat": {SetupToken: "sk-ant-api03-key", ExpiresAt: &exp},
		"neither":    {},
	} {
		if err := s.Validate(Claude); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if (Secret{RefreshToken: "rt"}).Kind(Claude) != KindRefreshToken || (Secret{Token: "t"}).Kind(GitHub) != KindToken {
		t.Fatal("kinds of the existing shapes changed")
	}

	// Expired: refused at put, and refused at lease once the date passes.
	past := now.Add(-time.Hour)
	if err := v.Put("pool", Claude, "old", Secret{SetupToken: tok, ExpiresAt: &past}); !errors.Is(err, ErrSetupTokenExpired) {
		t.Fatalf("expired put: %v", err)
	}
	now = exp.Add(time.Minute)
	if _, err := v.Lease(context.Background(), "pool", Claude, "icloud"); !errors.Is(err, ErrSetupTokenExpired) {
		t.Fatalf("expired lease: %v", err)
	}
	if n := ref.n.Load(); n != 0 {
		t.Fatalf("an expired setup token was sent to the refresher %d time(s)", n)
	}

	// A refresh-token row beside it still refreshes as before.
	now = exp.Add(-time.Hour)
	if err := v.Put("pool", Claude, "rt", Secret{RefreshToken: "RT-0"}); err != nil {
		t.Fatal(err)
	}
	if acc, err := v.Lease(context.Background(), "pool", Claude, "rt"); err != nil || acc.AccessToken != "AT-1" {
		t.Fatalf("refresh-token lease = %+v, %v", acc, err)
	}
}

// revokingRefresher is countingRefresher whose refusal is the provider's own
// (a *ProviderRefusal): set code to refuse every refresh with it.
type revokingRefresher struct {
	countingRefresher
	code atomic.Value // string
}

func (r *revokingRefresher) Refresh(ctx context.Context, p string, s Secret) (Access, Secret, error) {
	if c, _ := r.code.Load().(string); c != "" {
		r.n.Add(1)
		return Access{}, s, &ProviderRefusal{Status: http.StatusUnauthorized, Code: c, Body: `{"error":{"code":"` + c + `"}}`}
	}
	return r.countingRefresher.Refresh(ctx, p, s)
}

// claude-fleet#2007: token_revoked keeps the token's exp, so the clock alone
// would hand a dead access out for days. A node's report drops the cache and
// the next lease refreshes.
func TestUpstreamRejectedAccessIsReplaced(t *testing.T) {
	r := &countingRefresher{ttl: 183 * time.Hour}
	v := newVault(t, r)
	if err := v.Put("p1", Codex, "work", Secret{RefreshToken: "RT-0", AccountID: "acct"}); err != nil {
		t.Fatal(err)
	}
	a, err := v.Lease(context.Background(), "p1", Codex, "work")
	if err != nil || a.AccessToken != "AT-1" {
		t.Fatalf("first lease %+v %v", a, err)
	}
	if a, _ := v.Lease(context.Background(), "p1", Codex, "work"); a.AccessToken != "AT-1" || r.n.Load() != 1 {
		t.Fatalf("cached lease %+v refreshes=%d", a, r.n.Load())
	}
	dropped, err := v.RejectUpstream("p1", Codex, "work", AccessFingerprint("AT-1"), "token_revoked", "alice@m4")
	if err != nil || !dropped {
		t.Fatalf("reject: dropped=%v err=%v", dropped, err)
	}
	a, err = v.Lease(context.Background(), "p1", Codex, "work")
	if err != nil || a.AccessToken != "AT-2" {
		t.Fatalf("lease after the upstream rejected AT-1: %+v %v, want AT-2", a, err)
	}
	// A late report about the token already replaced changes nothing.
	if dropped, err := v.RejectUpstream("p1", Codex, "work", AccessFingerprint("AT-1"), "token_revoked", "bob@m1"); err != nil || dropped {
		t.Fatalf("stale reject: dropped=%v err=%v", dropped, err)
	}
	if a, _ := v.Lease(context.Background(), "p1", Codex, "work"); a.AccessToken != "AT-2" || r.n.Load() != 2 {
		t.Fatalf("after a stale report %+v refreshes=%d, want AT-2 from the cache", a, r.n.Load())
	}
	audit, _ := v.Store.CredAuditLog("p1", 50)
	var rows []string
	for _, x := range audit {
		if x.Action == store.CredUpstreamRejected {
			rows = append(rows, x.Detail)
		}
	}
	if len(rows) != 1 || !strings.Contains(rows[0], "token_revoked") || !strings.Contains(rows[0], "alice@m4") {
		t.Fatalf("upstream_rejected audit rows = %q", rows)
	}
}

func TestUpstreamRevokedRefreshRefusedNeedsReauth(t *testing.T) {
	r := &revokingRefresher{countingRefresher: countingRefresher{ttl: 183 * time.Hour}}
	v := newVault(t, r)
	_ = v.Put("p1", Codex, "work", Secret{RefreshToken: "RT-0", AccountID: "acct"})
	if _, err := v.Lease(context.Background(), "p1", Codex, "work"); err != nil {
		t.Fatal(err)
	}
	// The whole grant was revoked: the refresh token is dead too.
	r.code.Store("refresh_token_invalidated")
	if _, err := v.RejectUpstream("p1", Codex, "work", AccessFingerprint("AT-1"), "token_revoked", "alice@m4"); err != nil {
		t.Fatal(err)
	}
	_, err := v.Lease(context.Background(), "p1", Codex, "work")
	if !errors.Is(err, ErrReauthRequired) {
		t.Fatalf("lease after a revoked grant: %v, want ErrReauthRequired (never the old AT-1)", err)
	}
	c, _ := v.Store.Credential("p1", Codex, "work")
	if !c.ReauthRequired || c.ReauthRequiredAt == nil || !strings.Contains(c.RefreshError, "refresh_token_invalidated") {
		t.Fatalf("row = %+v, want reauth_required", c)
	}
	// Nothing more is asked of the provider, nothing more is leased.
	n := r.n.Load()
	if _, err := v.Lease(context.Background(), "p1", Codex, "work"); !errors.Is(err, ErrReauthRequired) || r.n.Load() != n {
		t.Fatalf("second lease: %v, refreshes %d → %d (want no new refresh)", err, n, r.n.Load())
	}
	audit, _ := v.Store.CredAuditLog("p1", 50)
	found := false
	for _, x := range audit {
		found = found || x.Action == store.CredReauth
	}
	if !found {
		t.Fatalf("no %s audit row in %+v", store.CredReauth, audit)
	}
	// A new login, stored, clears it.
	r.code.Store("")
	if err := v.Put("p1", Codex, "work", Secret{RefreshToken: "RT-new", AccountID: "acct"}); err != nil {
		t.Fatal(err)
	}
	if a, err := v.Lease(context.Background(), "p1", Codex, "work"); err != nil || a.AccessToken == "AT-1" {
		t.Fatalf("lease after a new login: %+v %v", a, err)
	}
	if c, _ := v.Store.Credential("p1", Codex, "work"); c.ReauthRequired {
		t.Fatal("a put left reauth_required set")
	}
}

// A refused refresh with no upstream report keeps serving the cached token
// (it was never refused) but stops refreshing; once it runs out, reauth.
func TestRevokedRefreshTokenKeepsUnrefusedCache(t *testing.T) {
	r := &revokingRefresher{countingRefresher: countingRefresher{ttl: 4 * time.Hour}}
	v := newVault(t, r)
	now := time.Now()
	v.Now = func() time.Time { return now }
	_ = v.Put("p1", Codex, "work", Secret{RefreshToken: "RT-0", AccountID: "acct"})
	_, _ = v.Lease(context.Background(), "p1", Codex, "work")
	r.code.Store("invalid_grant")
	now = now.Add(2 * time.Hour)
	if a, err := v.Lease(context.Background(), "p1", Codex, "work"); err != nil || a.AccessToken != "AT-1" {
		t.Fatalf("%+v %v, want the still-valid AT-1", a, err)
	}
	n := r.n.Load()
	if a, err := v.Lease(context.Background(), "p1", Codex, "work"); err != nil || a.AccessToken != "AT-1" || r.n.Load() != n {
		t.Fatalf("%+v %v refreshes %d→%d, want AT-1 and no new refresh", a, err, n, r.n.Load())
	}
	now = now.Add(3 * time.Hour)
	if _, err := v.Lease(context.Background(), "p1", Codex, "work"); !errors.Is(err, ErrReauthRequired) {
		t.Fatalf("expired: %v, want ErrReauthRequired", err)
	}
}

func TestSetupTokenRevokedUpstreamNeedsReauth(t *testing.T) {
	v := newVault(t, &countingRefresher{})
	exp := time.Now().Add(300 * 24 * time.Hour)
	tok := "sk-ant-oat01-setup"
	if err := v.Put("p1", Claude, "main", Secret{SetupToken: tok, ExpiresAt: &exp}); err != nil {
		t.Fatal(err)
	}
	if dropped, _ := v.RejectUpstream("p1", Claude, "main", AccessFingerprint("other"), "401", ""); dropped {
		t.Fatal("a report about another token marked the setup token")
	}
	if dropped, err := v.RejectUpstream("p1", Claude, "main", AccessFingerprint(tok), "token_revoked", "alice@m4"); err != nil || !dropped {
		t.Fatalf("reject: %v %v", dropped, err)
	}
	if _, err := v.Lease(context.Background(), "p1", Claude, "main"); !errors.Is(err, ErrReauthRequired) {
		t.Fatalf("lease of a revoked setup token: %v", err)
	}
}

func TestNeedsReauthOnlyForTheProvidersRevokedAnswer(t *testing.T) {
	for _, c := range []struct {
		status int
		body   string
		want   bool
	}{
		{400, `{"error":"invalid_grant","error_description":"Refresh token revoked"}`, true},
		{401, `{"error":{"code":"refresh_token_reused","message":"…"}}`, true},
		{401, `{"error":{"code":"refresh_token_expired"}}`, true},
		{400, `{"error":"invalid_request"}`, false},
		{503, `{"error":"invalid_grant"}`, false},
		{403, `<html>blocked</html>`, false},
	} {
		_, _, err := parseRefresh(Codex, Secret{RefreshToken: "x"}, c.status, []byte(c.body), time.Now())
		if got := NeedsReauth(err); got != c.want {
			t.Errorf("%d %s: NeedsReauth = %v, want %v (err %v)", c.status, c.body, got, c.want, err)
		}
	}
	if NeedsReauth(fmt.Errorf("%w: no node", ErrRefreshUnavailable)) {
		t.Error("refresh_unavailable is not the provider's answer")
	}
}

// Two hub replicas on one database (claude-fleet#2123): each has its own row
// mutex, so only CrossLock keeps them from refreshing one account twice — the
// double refresh that gets a grant revoked upstream. Here CrossLock is a plain
// shared mutex; internal/leader's Postgres advisory lock is the real one.
func TestTwoReplicasRefreshOnce(t *testing.T) {
	for _, shared := range []bool{false, true} {
		r := &countingRefresher{ttl: 8 * time.Hour, delay: 50 * time.Millisecond}
		a := newVault(t, r)
		b := &Vault{Store: a.Store, Sealer: a.Sealer, Refresher: r}
		var mu sync.Mutex
		if shared {
			cross := func(context.Context, string) (func(), error) { mu.Lock(); return mu.Unlock, nil }
			a.CrossLock, b.CrossLock = cross, cross
			a.Replica, b.Replica = "hub-a", "hub-b"
		}
		if err := a.Put("p1", Claude, "main", Secret{RefreshToken: "RT-0"}); err != nil {
			t.Fatal(err)
		}
		var wg sync.WaitGroup
		for i := 0; i < 8; i++ {
			for _, v := range []*Vault{a, b} {
				wg.Add(1)
				go func(v *Vault) {
					defer wg.Done()
					if _, err := v.Lease(context.Background(), "p1", Claude, "main"); err != nil && shared {
						t.Error(err)
					}
				}(v)
			}
		}
		wg.Wait()
		n := r.n.Load()
		if shared && n != 1 {
			t.Fatalf("two replicas with CrossLock refreshed %d times, want exactly 1", n)
		}
		if !shared && n < 2 {
			// The hazard this guards against, shown: without it both refresh.
			t.Fatalf("without CrossLock two replicas refreshed %d times; the test no longer shows the double refresh", n)
		}
		if shared {
			audits, err := a.Store.CredAuditLog("p1", 10)
			if err != nil {
				t.Fatal(err)
			}
			found := false
			for _, x := range audits {
				if x.Action == store.CredRefresh && strings.Contains(x.Detail, "replica=hub-") {
					found = true
				}
			}
			if !found {
				t.Fatalf("refresh audit carries no replica: %+v", audits)
			}
		}
	}
}
