package api

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/verkyyi/ccquota/internal/store"
)

// A fake tailscaled. Records every lookup so tests can assert the CLI is
// consulted exactly when it should be, and never otherwise.
type fakeWhoIs struct {
	peers map[string]WhoIs
	calls []string
	err   error
}

func (f *fakeWhoIs) lookup(ip netip.Addr) (WhoIs, error) {
	f.calls = append(f.calls, ip.String())
	if f.err != nil {
		return WhoIs{}, f.err
	}
	w, ok := f.peers[ip.String()]
	if !ok {
		return WhoIs{}, errors.New("peer not found")
	}
	return w, nil
}

func tailnetServer(t *testing.T, f *fakeWhoIs, logins ...string) *Server {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	tv := NewTailnetViewers(logins, []string{"100.85.129.58"}, f.lookup)
	return &Server{Store: st, ViewerToken: "viewer-secret", Tailnet: tv}
}

func get(s *Server, from string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/v1/accounts", nil)
	req.RemoteAddr = from
	s.Handler().ServeHTTP(rec, req)
	return rec
}

func TestTailnet_AllowlistedPeerNeedsNoToken(t *testing.T) {
	f := &fakeWhoIs{peers: map[string]WhoIs{"100.110.252.40": {Login: "verky.yi@gmail.com"}}}
	s := tailnetServer(t, f, "Verky.Yi@gmail.com") // case-insensitive
	if rec := get(s, "100.110.252.40:51234"); rec.Code != http.StatusOK {
		t.Fatalf("allowlisted tailnet peer got %d, want 200", rec.Code)
	}
	if len(f.calls) != 1 {
		t.Errorf("whois called %d times, want 1", len(f.calls))
	}
}

func TestTailnet_Denials(t *testing.T) {
	f := &fakeWhoIs{peers: map[string]WhoIs{
		"100.110.252.40": {Login: "verky.yi@gmail.com"},
		"100.70.1.2":     {Login: "keep.cj@gmail.com"},
		"100.70.1.3":     {Login: "verky.yi@gmail.com", Tagged: true},
		"100.85.129.58":  {Login: "verky.yi@gmail.com"}, // the hub's own address
	}}
	s := tailnetServer(t, f, "verky.yi@gmail.com")

	cases := []struct {
		name, from string
		whois      bool // should the CLI even be consulted?
	}{
		{"a login not on the allowlist", "100.70.1.2:1", true},
		{"a tagged node: a server, not a person", "100.70.1.3:1", true},
		// The hub's own tailnet address resolves to its OWNER, so a
		// connection from the machine to itself would identify as them --
		// which would let any other OS login on that machine be them.
		{"the hub's own tailnet address", "100.85.129.58:1", false},
		{"loopback", "127.0.0.1:1", false},
		{"a LAN address", "192.168.1.50:1", false},
		{"a public address", "8.8.8.8:1", false},
		{"garbage", "not-an-addr", false},
	}
	for _, c := range cases {
		f.calls = nil
		rec := get(s, c.from)
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s: got %d, want 401", c.name, rec.Code)
		}
		if (len(f.calls) > 0) != c.whois {
			t.Errorf("%s: whois consulted=%v, want %v", c.name, len(f.calls) > 0, c.whois)
		}
	}
}

func TestTailnet_WhoIsErrorIsADenial(t *testing.T) {
	f := &fakeWhoIs{err: errors.New("tailscaled is down")}
	s := tailnetServer(t, f, "verky.yi@gmail.com")
	if rec := get(s, "100.110.252.40:1"); rec.Code != http.StatusUnauthorized {
		t.Errorf("whois error got %d, want 401 -- fail closed", rec.Code)
	}
}

func TestTailnet_TokenStillWorksEverywhere(t *testing.T) {
	f := &fakeWhoIs{}
	s := tailnetServer(t, f, "verky.yi@gmail.com")
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/v1/accounts", nil)
	req.RemoteAddr = "192.168.1.50:1"
	req.Header.Set("Authorization", "Bearer viewer-secret")
	s.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Errorf("token from the LAN got %d, want 200", rec.Code)
	}
	if len(f.calls) != 0 {
		t.Error("a valid token still triggered a whois lookup")
	}
}

func TestTailnet_LookupsAreCached(t *testing.T) {
	f := &fakeWhoIs{peers: map[string]WhoIs{"100.110.252.40": {Login: "verky.yi@gmail.com"}}}
	s := tailnetServer(t, f, "verky.yi@gmail.com")
	for i := 0; i < 5; i++ {
		get(s, "100.110.252.40:1")
	}
	if len(f.calls) != 1 {
		t.Errorf("whois called %d times for 5 requests; want 1 (cached)", len(f.calls))
	}
	// A miss is cached too, so an unknown peer cannot make the hub fork a
	// process per request.
	f.calls = nil
	for i := 0; i < 5; i++ {
		get(s, "100.70.9.9:1")
	}
	if len(f.calls) != 1 {
		t.Errorf("whois called %d times for 5 denied requests; want 1", len(f.calls))
	}
	// And the cache expires.
	s.Tailnet.ttl = time.Nanosecond
	time.Sleep(time.Millisecond)
	f.calls = nil
	get(s, "100.110.252.40:1")
	if len(f.calls) != 1 {
		t.Error("an expired entry was not refreshed")
	}
}

func TestTailnet_OffWhenUnconfigured(t *testing.T) {
	f := &fakeWhoIs{peers: map[string]WhoIs{"100.110.252.40": {Login: "verky.yi@gmail.com"}}}
	st, _ := store.Open(filepath.Join(t.TempDir(), "t.db"))
	t.Cleanup(func() { st.Close() })
	s := &Server{Store: st, ViewerToken: "viewer-secret"} // no Tailnet
	if rec := get(s, "100.110.252.40:1"); rec.Code != http.StatusUnauthorized {
		t.Errorf("tailnet identity granted access while unconfigured (%d)", rec.Code)
	}
	if len(f.calls) != 0 {
		t.Error("whois consulted while unconfigured")
	}
}

func TestTailnet_EmptyAllowlistMeansOff(t *testing.T) {
	if NewTailnetViewers(nil, nil, nil) != nil {
		t.Error("an empty allowlist produced an active TailnetViewers; it must mean off")
	}
}

func TestTailnet_ViewerIsLogged(t *testing.T) {
	f := &fakeWhoIs{peers: map[string]WhoIs{"100.110.252.40": {Login: "verky.yi@gmail.com"}}}
	s := tailnetServer(t, f, "verky.yi@gmail.com")
	var got string
	s.LogWriter = func(line string) { got += line }
	get(s, "100.110.252.40:1")
	if !strings.Contains(got, "viewer=verky.yi@gmail.com") {
		t.Errorf("access log does not say who viewed: %q", got)
	}
}

func TestParseTailscaleWhoIs(t *testing.T) {
	// Trimmed from a real `tailscale whois --json` on 1.96.
	person := `{"Node":{"ID":1,"ComputedName":"macbook","Tags":null},"UserProfile":{"LoginName":"verky.yi@gmail.com"}}`
	server := `{"Node":{"ID":2,"ComputedName":"rds-jump","Tags":["tag:server"]},"UserProfile":{"LoginName":"tagged-devices"}}`
	w, err := parseWhoIs([]byte(person))
	if err != nil || w.Login != "verky.yi@gmail.com" || w.Tagged {
		t.Errorf("person: %+v %v", w, err)
	}
	w, err = parseWhoIs([]byte(server))
	if err != nil || !w.Tagged {
		t.Errorf("tagged server not recognised: %+v %v", w, err)
	}
	if _, err := parseWhoIs([]byte(`{}`)); err == nil {
		t.Error("an answer with no login was accepted")
	}
}
