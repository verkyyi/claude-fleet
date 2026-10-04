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
